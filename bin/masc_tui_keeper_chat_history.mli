(** Reads the keeper's durable transcript into rows the chat pane can draw.

    The pane's scrollback was session-local: everything a keeper and an
    operator said was held in memory and gone on the next start, even though
    the server keeps the transcript and serves it at
    [GET /api/v1/keepers/<name>/chat/history].

    {2 What the server sends}

    An array of rows, each with [role] ("user" / "assistant" / "tool"),
    [content], and [ts]. An assistant row carrying
    [kind: "transport_failure"] is a delivery that failed rather than
    something the keeper said. An assistant row the server marks
    [autonomous_turn] also carries [blocks], among them a [t: "trace"] block
    whose [trace] steps are [think] / [reason] / [tool]; those become a
    reasoning row and a tool block ahead of whatever the turn said, and a
    turn that only called tools no longer reads as a blank line. A
    direct-conversation row's trace block is not read: its calls are already
    in the transcript as [role: "tool"] rows. A tool row's [content] is the
    call's arguments, [tool_call_name] is the tool, [tool_call_id] is the
    provider stream identity, and [execution_id] is the canonical physical
    execution after result persistence. Those become the same typed activity
    the live view uses; no rendered row is parsed to recover a fact. An
    current autonomous trace names [execution_id] explicitly and keeps
    [tool_call_id] as optional provider correlation. A row without the
    canonical field remains unknown; the reader does not reinterpret a legacy
    provider-shaped field as execution authority.

    Consecutive tool rows are folded into one block, the way a live turn draws
    its calls, rather than becoming a row each.

    {2 Ordering}

    Rows are decoded in producer order. [turn_sequence] joins direct and
    autonomous sources on the persisted absolute turn; [structural_id] keeps
    row identity through refresh. [ts] is display/pagination metadata and has
    no conversation-order authority. *)

(** The surface a row arrived on, mirrored from [Surface_ref.t] in the server.
    This library carries no [masc] dependency, so it cannot name that type;
    [test_tui_chat_surface_mirror] holds the two in step. *)
module Surface : sig
  type channel =
    | Channel_name of string
    | Channel_id of string
        (** A name and an id are cut from opposite ends when drawn: a snowflake
            id differs in its tail, a room name in its head. *)

  type t =
    | Dashboard
    | Discord of { channel : channel option }
    | Slack of { channel : channel option }
    | Webhook of string  (** the [source] the hook goes by *)
    | Agent
    | Broadcast
    | Gate of string  (** the connector's channel label *)
end

(** Who put a [role: "user"] row in front of the keeper.

    Not always the operator. On one live keeper 92 of 128 rows carried that
    role and 23 distinct speakers: another keeper, an MCP client, the
    exact-lane verifier, the dashboard, a dozen canary keepers. Drawing them
    all as "you" told the operator they had said things they had never seen. *)
type speaker =
  | Operator
      (** The row named no author, which is a person typing at an operator
          surface: this pane or the dashboard. *)
  | Named of string  (** The author the server named. *)
  | Unresolved of { id : string option }
      (** An author the producer could not name: [speaker_name] was absent or
          repeated [speaker_id]. Kept apart from {!Operator}, which means the
          person reading this pane wrote it -- folding the two turned messages
          that arrived from Slack and Discord into the reader's own words. *)

(** What one row of the transcript is. *)
type kind =
  | Addressed_to_keeper of
      { speaker : speaker
      ; surface : Surface.t option
            (** Where it came in from, when the row carried a surface this
                build can read. [None] for a row with no surface or a kind it
                was not taught — unlabelled beats guessed. *)
      }
  | Said_by_keeper
  | Autonomous_reply
      (** What an autonomous turn said after its trace. A blank reply remains
          a row, but callers can mark it instead of drawing an empty keeper
          message. *)
  | Delivery_failed of
      { origin_request_id : string option
      ; recovered_at : float option
            (** A later keeper utterance in this transcript, when a typed
                runtime interruption was followed by one. Presentation
                evidence only: it does not claim the failed operation itself
                was replayed. *)
      }
      (** An assistant row the server marked [transport_failure]: the reply
          did not reach its destination. Not keeper speech.

          [origin_request_id] is the operation the server persisted this row
          under, which is the id the client dispatched the turn with. It is
          what lets a session drop its own row for the same failure once this
          one arrives, rather than drawing both. [None] for a row the server
          wrote under another producer's key, or under none. *)
  | Tool_calls of Masc_tui_keeper_chat_transcript.tool_block
      (** One typed block of calls. Either consecutive [role: "tool"] rows,
          or the tool steps of one autonomous turn's trace block. Rendering is
          deferred to the shared [Compact | Full] projector. *)
  | Skill_activity of Masc_tui_keeper_chat_transcript.skill_activity
      (** Exact per-turn Skill activation evidence derived by the server from
          the durable activation ledger. It distinguishes served content from
          provider delivery and observed post-delivery actions. *)
  | Reasoning of string list
      (** What the keeper reasoned during one autonomous turn, as the trace
          block carried it: the lines the server kept, and a count of the
          steps it withheld. A blank [content] with a trace behind it used
          to draw as an empty line; this is what was behind it. *)
  | Memory_activity
      (** A committed or failed Memory OS journal pass. [row.text] carries
          exact added/removed claims or typed failure detail. *)

val tool_rows : Masc_tui_keeper_chat_transcript.tool_block -> string list
(** The current full-detail rows for a typed history block. This delegates to
    the shared projector; it does not own another formatter. *)

val present_delivery_failure :
  ?recovered_at:float -> string -> (string * bool) option
(** Compact a typed runtime/provider interruption into a lifecycle sentence.
    The boolean is [true] only when [recovered_at] supplied later-reply
    evidence. Unknown failures return [None] and keep their original text. *)

type attachment_note =
  { att_name : string
  ; att_mime : string
  ; att_bytes : int
  }
(** A file the row carries, named but not held: the bytes stay in the store.
    The pane's job is to say one is there, which it could not do while this
    reader ignored the field the composer has been writing all along. *)

type row =
  { at : float
      (** Producer wall clock for display and pagination only; never a
          conversation ordering key. *)
  ; structural_id : string option
      (** Stable producer identity plus a projection discriminator when one
          source row expands to reasoning/tool/reply rows. Journal rows derive
          it from their typed revision or exact failed-observation fields. *)
  ; turn_sequence : int option
      (** Absolute Keeper turn from persisted [turn_ref], when present. This
          orders turn groups across direct and autonomous stores. *)
  ; turn_id : string option
      (** Exact producer identity for grouping rows from one turn: the typed
          delivery key for direct turns, otherwise the persisted [turn_ref].
          [None] for old rows and Memory journal entries. *)
  ; kind : kind
  ; text : string
      (** What to draw. Empty for [Tool_calls] and [Reasoning], whose typed
          block or lines carry the content. *)
  ; attachments : attachment_note list
      (** Files this row carries. Empty for every kind but a message that
          arrived with one. *)
  }

type decoded =
  { rows : row list
  ; dropped : int
      (** Rows the decoder could not read. Reported rather than inferred from
          the list's length: folding tool blocks shortens the list for reasons
          that are not losses. *)
  }

val addressed_label : speaker -> Surface.t option -> string
(** The name to draw beside an {!Addressed_to_keeper} row. An unnamed operator
    row is ["you"], the way it always read. A named author is drawn, and a
    surface that is not an operator's own is appended — ["<keeper> · agent"],
    ["<operator> · slack"] — so a fleet broadcast and a direct message do not
    look alike. *)

(** One page of rows older than a cursor, from
    [GET /keepers/<name>/chat/history/page?before=<ts>].

    The envelope differs from the transcript's; the rows inside are the same
    shape, so they decode through the same reader and a page is folded and
    ordered exactly as the first load was. *)
type page =
  { decoded : decoded
  ; has_more : bool
        (** Whether older rows exist beyond this page. False is the top of the
            conversation. *)
  ; next_before : float option
        (** Cursor for the page before this one. [None] on an empty page —
            the server computes it rather than leaving each client to derive
            the rule. *)
  }

val page_of_json : Yojson.Safe.t -> (page, string) result
(** Decode a [/chat/history/page] response. Fails when the envelope is not an
    object or carries no [messages] array; a single unreadable row inside is
    dropped and counted, as in {!rows_of_json}. *)

(** The row's text with one line per file under it. A file posted with no
    caption arrives with empty text, and joining on it anyway puts a blank line
    where a sentence would be (task-552). [format_bytes] is supplied by the
    caller: this module sits below the one that renders sizes. *)
val text_with_attachments :
  format_bytes:(int -> string) ->
  text:string ->
  notes:attachment_note list ->
  string

val rows_of_json : Yojson.Safe.t -> (decoded, string) result
(** Decode a [/chat/history] response.

    Fails only when the response is not an array — a shape this cannot read at
    all. A single unreadable row is dropped instead: one bad row should not
    cost an operator the rest of the transcript. The count comes back in
    [dropped] so the loss is not silent. *)

val memory_rows_of_json : Yojson.Safe.t -> (decoded, string) result
(** Decode [/api/v1/keepers/:name/memory-journal]. Entries retain their
    [recorded_at] timestamp for display and pagination. The caller keeps them
    in the explicit Journal producer lane; the clock grants no chat-order
    authority. *)
