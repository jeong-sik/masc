(** Keeper_chat_store — JSONL-based persistence for keeper direct
    messages.

    Each keeper owns an append-only file at
    [<base_dir>/.masc/keeper_chat/<sanitized-name>.jsonl]. Lines are
    JSON objects of the form
    {v {"role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call lines persisted between a turn's user and assistant lines
    additionally carry [tool_call_id] / [tool_call_name]; every line of
    a turn may carry the originating connector in [source]
    (e.g. "dashboard", "discord", "slack", "agent"). Connector rows may
    also carry [conversation_id] / [external_message_id], opaque route
    coordinates used by dashboards to group platform channels/threads
    without giving this store platform-specific knowledge.

    @since 2.145.0 *)

(** {1 Types} *)

type attachment = {
  id : string;
  att_type : string;
  name : string;
  size : int;
  mime_type : string;
  data : string;
}

(** One executed tool call within a turn. [args] holds the accumulated
    argument JSON; empty arguments are persisted as ["{}"]. *)
type tool_call = {
  call_id : string;
  call_name : string;
  args : string;
}

(** Lane line role as a closed sum (RFC-0232 P1). Parsed once at the
    read boundary; a line whose persisted label is none of
    ["user"] / ["assistant"] / ["tool"] is reported as a persistence
    read drop and excluded — it can participate in no lane semantics
    (watermark, pending, rendering). On-disk labels are unchanged. *)
module Role : sig
  type t =
    | User
    | Assistant
    | Tool

  val to_label : t -> string
  val of_label : string -> t option
  val equal : t -> t -> bool
end

(** What an assistant line {e is}, declared by the writer at append.
    [Utterance] is something the keeper actually said.
    [Transport_failure] is the server persisting a failed request
    terminal (["Keeper request failed: ..."]) so the operator still sees
    the failure after a reload — it is {e not} a self reply: it does not
    advance the lane watermark, so the user line it failed to answer
    stays pending until the keeper's next real utterance, and
    observation never quotes it back as the keeper's own words.
    Persisted as ["kind"]; the field is absent for utterances, so rows
    written before it existed read unchanged. *)
module Row_kind : sig
  type t =
    | Utterance
    | Transport_failure

  val to_label : t -> string
  val of_label : string -> t option
  val equal : t -> t -> bool
end

(** Closed, durable names for AG-UI lifecycle events recorded by the direct
    Keeper chat stream. This is server lifecycle provenance, not a
    client-delivery receipt. *)
type stream_lifecycle_event =
  | Run_started
  | Text_message_start
  | Text_message_end
  | Run_finished
  | Run_error

type append_once_result =
  | Appended of { row_id : string }
  | Already_present of { row_id : string }

(** Authority class of the human (or agent) whose message opened a
    turn. Derived structurally from the arrival route, never from
    message content: the authenticated dashboard route is [Owner];
    anything carrying connector context is [External]. Persisted as
    ["owner"] / ["external"] in [speaker_authority] (RFC-0223 §3). *)
type speaker_authority =
  | Owner
  | External

val authority_label : speaker_authority -> string
val authority_of_label : string -> speaker_authority option

(** Rich chat block produced by the backend parser. Mirrors the dashboard's
    [ChatBlock] union so the server can own parsing and the dashboard can
    render server-provided blocks verbatim. *)
type chat_block = Keeper_chat_blocks.chat_block

(** Identity of the user-line author. [speaker_id] / [speaker_name] are
    absent when the route supplies none (the dashboard is a single
    authenticated operator and carries no per-user identity). *)
type audio_clip = {
  token : string;
  audio_url : string option;
  mime : string;
  duration_sec : float option;
  message_text : string;
  device_id : string option;
  expired : bool;
}
(** Persistable audio clip (RFC-0235 P1). Written on an assistant line
    when the keeper synthesized a voice utterance; [token] is the
    [/api/v1/voice/audio/:token] capability, [message_text] doubles as
    the caption. [audio_url] and [device_id] carry transport routing hints
    so the dashboard can fetch and route the clip. [expired] is true when
    the underlying MP3 has been reaped; the history endpoint stamps it by
    checking the audio directory. Same shape as
    {!Keeper_chat_broadcast}'s SSE payload so the two never drift. *)

type speaker = {
  speaker_id : string option;
  speaker_name : string option;
  speaker_authority : speaker_authority;
}

type chat_message = {
  id : string;
      (** R3: producer-assigned stable message id, minted once at append by
          the sole writer ({!encode_line}) and read back verbatim, so the
          dashboard keys off a server identity rather than synthesising an
          index-derived id at render.  Rows written before R3 carry no
          persisted id and are given a deterministic one at the read
          boundary, so the field is total. *)
  role : Role.t;
  content : string;
  ts : float option;
  attachments : attachment list option;
  tool_call_id : string option;
  tool_call_name : string option;
  source : string option;
      (** Legacy lane label.  Since RFC-0232 P5 it is derived from
          [surface] at write ({!Surface_ref.lane_label}); pre-P5 rows
          carry their original label verbatim. *)
  surface : Surface_ref.t option;
      (** The typed surface (RFC-0232 §3.6).  [None] on rows written
          before P5 and on rows whose persisted surface payload fails
          to decode (reported as a persistence read drop, row kept). *)
  conversation_id : string option;
  external_message_id : string option;
  speaker : speaker option;
      (** Present on user lines written since RFC-0223 P1; [None] on
          older lines, tool/assistant lines, and lines whose persisted
          [speaker_authority] label fails to parse (reported as a
          persistence read drop, row otherwise kept). *)
  audio : audio_clip option;
      (** RFC-0235 P1: present when this assistant line was a synthesized
          voice utterance (keeper_voice_speak). [None] on every other
          line and on rows written before voice transport; the dashboard
          renders a play button when present. *)
  blocks : chat_block list option;
      (** RFC-0235 P3: rich chat blocks parsed from assistant reply text.
          Persisted server-side so the dashboard can prefer backend blocks
          over its local parser. [None] on rows written before this field
          and on non-assistant rows. *)
  mentions : Keeper_identity.Keeper_id.t list;
      (** RFC-0232 §3.3: mention ids parsed once at append from the
          persisted user content (plus connector-supplied explicit
          mentions).  [[]] on tool/assistant lines, mention-free lines,
          and rows written before P4 (the offline backfill tool stamps
          those).  Malformed persisted entries are reported as
          persistence read drops and skipped; the row stays valid. *)
  kind : Row_kind.t;
      (** Declared by the writer at append.  Absent persisted field
          (every row written before it existed) reads as [Utterance];
          an unknown label is reported as a persistence read drop and
          reads as [Utterance] — the conservative arm: the row renders
          and advances the watermark like any reply. *)
  turn_ref : Ids.Turn_ref.t option;
      (** RFC-0233 §7: ["<trace_id>#<absolute_turn>"] join key for the turn
          that produced this row.  Stamped by {!append_turn} /
          {!append_assistant_message} when the caller supplies it; [None]
          on inbound user lines (no turn yet) and rows written before §7.
          A malformed persisted value is reported as a persistence read
          drop and reads as [None]; the row stays valid. *)
  stream_lifecycle : stream_lifecycle_event list option;
      (** K1f: durable server lifecycle replay for the chat stream response
          represented by this row. [None] means the row predates this field or
          the writer could not prove lifecycle events. Malformed persisted
          values are reported as persistence read drops and read as [None];
          the row stays valid. *)
}

(** {1 I/O} *)

(** [append_turn ~base_dir ~keeper_name ~user_content ~user_attachments
    ?tool_calls ?source ?conversation_id ?external_message_id ?speaker
    ~assistant_content ()] appends one
    completed turn as consecutive lines — user, one line per tool call,
    assistant — sharing a single timestamp, in one write. [speaker]
    identifies the user-line author and is written on the user line
    only. [conversation_id] identifies the external conversation/thread
    coordinate and is written on all lines of the turn; [external_message_id]
    belongs to the inbound user line only. [assistant_kind] declares what
    the assistant line is (default [Utterance]); the failed-request
    persistence path passes [Transport_failure]. Failures are logged but
    never raised except for {!Eio.Cancel.Cancelled}. *)
(** [append_turn_result] is {!append_turn} with an explicit persistence
    result. Queue consumers use it so a durable delivery receipt cannot become
    [Delivered] after the transcript write actually failed. *)
val append_turn_result :
  base_dir:string ->
  keeper_name:string ->
  user_content:string ->
  user_attachments:attachment list ->
  ?tool_calls:tool_call list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?speaker:speaker ->
  ?extra_mentions:Keeper_identity.Keeper_id.t list ->
  ?assistant_kind:Row_kind.t ->
  ?blocks:chat_block list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  assistant_content:string ->
  unit ->
  (unit, string) result

val append_turn :
  base_dir:string ->
  keeper_name:string ->
  user_content:string ->
  user_attachments:attachment list ->
  ?tool_calls:tool_call list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?speaker:speaker ->
  ?extra_mentions:Keeper_identity.Keeper_id.t list ->
  ?assistant_kind:Row_kind.t ->
  ?blocks:chat_block list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  assistant_content:string ->
  unit ->
  unit

(** [append_assistant_message_result] is {!append_assistant_message} that
    returns [Error msg] on a write failure instead of swallowing it (the failure
    is still counted + warn-logged). For callers whose own contract requires
    surfacing a chat-append failure — e.g. {!Fusion_sink.emit}. *)
val append_assistant_message_result :
  base_dir:string ->
  keeper_name:string ->
  content:string ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?audio:audio_clip ->
  ?blocks:chat_block list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  unit ->
  (unit, string) result

val append_delivery_assistant_message_result :
  base_dir:string ->
  keeper_name:string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  content:string ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?assistant_kind:Row_kind.t ->
  ?blocks:chat_block list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  unit ->
  (string, string) result
(** O(suffix) normal-path terminal append for a newly transitioned delivery
    journal. Returns the persisted row id. Restart recovery must use
    {!append_assistant_message_once}, whose O(history) lookup is reserved for
    the ambiguous crash window. *)

(** Idempotent terminal assistant append. The per-Keeper lookup and append are
    serialized, so callback re-entry and restart recovery converge on one row
    for the exact typed delivery slot. A malformed persisted provenance row is
    an explicit [Error], never treated as absence. *)
val append_assistant_message_once :
  base_dir:string ->
  keeper_name:string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  content:string ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?assistant_kind:Row_kind.t ->
  ?blocks:chat_block list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  unit ->
  (append_once_result, string) result

(** [append_assistant_message ~base_dir ~keeper_name ~content ?source
    ?conversation_id ()]
    appends one keeper-initiated assistant line with no paired user
    turn (RFC-0223 P4 [keeper_surface_post]). Same failure policy as
    {!append_turn} (failure is counted + logged, not raised). *)
val append_assistant_message :
  base_dir:string ->
  keeper_name:string ->
  content:string ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?audio:audio_clip ->
  ?blocks:chat_block list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  unit ->
  unit

(** [append_user_message ~base_dir ~keeper_name ~content ?attachments
    ?surface ?conversation_id ?external_message_id ?speaker ()] appends one
    inbound user line with no paired assistant turn (RFC-0226). Written at delivery time by the inbound
    recorder — the Discord gateway's ambient arm and the gate dispatch
    boundary — so the line lands whether or not a turn starts or
    replies. Same failure policy as {!append_turn}. *)
val append_user_message :
  base_dir:string ->
  keeper_name:string ->
  content:string ->
  ?attachments:attachment list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?speaker:speaker ->
  ?extra_mentions:Keeper_identity.Keeper_id.t list ->
  unit ->
  unit

val append_user_message_result :
  base_dir:string ->
  keeper_name:string ->
  content:string ->
  ?attachments:attachment list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?speaker:speaker ->
  ?extra_mentions:Keeper_identity.Keeper_id.t list ->
  unit ->
  (unit, string) result
(** Result-returning inbound recorder for connector and admission boundaries.
    A caller must not broadcast or dispatch the message unless this returns
    [Ok ()]. *)

val append_delivery_user_message_result :
  base_dir:string ->
  keeper_name:string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  content:string ->
  ?attachments:attachment list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?speaker:speaker ->
  ?extra_mentions:Keeper_identity.Keeper_id.t list ->
  unit ->
  (string, string) result
(** O(suffix) normal-path accepted-user append for a newly prepared delivery
    journal. Returns the persisted row id. Restart recovery retains the exact
    append-once scan for crash reconciliation. *)

(** Idempotent accepted-user append for a direct/queued delivery identity. *)
val append_user_message_once :
  base_dir:string ->
  keeper_name:string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  content:string ->
  ?attachments:attachment list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?speaker:speaker ->
  ?extra_mentions:Keeper_identity.Keeper_id.t list ->
  unit ->
  (append_once_result, string) result

(** [load ~base_dir ~keeper_name] returns the most recent messages in
    chronological order: the last 100 user/assistant messages plus the
    tool lines belonging to them (absolute bound 400 lines). Missing
    files return [[]]. Unparseable lines are skipped. *)
val load :
  base_dir:string -> keeper_name:string -> chat_message list

type page = { messages : chat_message list; has_more : bool }

(** [load_page ~base_dir ~keeper_name ?before ()] is the paged form of
    {!load} (RFC-0228 P1): with [before] (a message [ts]) it returns
    the window of messages strictly older than that stamp; without it,
    the tail window. [has_more] reports whether rows older than the
    returned window remain — walk backward by passing the oldest
    returned [ts] as the next [before]. Bounded I/O per call:
    binary-search probes plus one window slice, never a full scan.
    Legacy rows without [ts] are unreachable through paging (the tail
    window still serves them). *)
val load_page :
  base_dir:string -> keeper_name:string -> ?before:float -> unit -> page

(** {1 Serialisation} *)

(** JSON array of messages. Entries without a timestamp omit the
    [ts] field; [tool_call_id] / [tool_call_name] / [source] /
    [conversation_id] / [external_message_id] /
    [speaker_id] / [speaker_name] / [speaker_authority] appear only
    when present. When [base_dir] is supplied, the history endpoint marks
    audio clips as [expired] when the underlying MP3 file is gone. *)
val to_json_array :
  ?base_dir:string ->
  ?trace_block_by_turn_ref:(Ids.Turn_ref.t -> chat_block option) ->
  chat_message list ->
  Yojson.Safe.t

(** {1 Turn transcript (RFC-0233 §7)} *)

(** A keeper turn's transcript, derived by an exact join on the persisted
    [turn_ref]. [user] holds the operator request line(s) that opened the
    turn; [assistant] holds the keeper response line(s) (utterance and
    typed transport-failure markers). Tool rows are excluded — their full
    I/O is surfaced by the tool-call store keyed on [execution_id]. Both
    lists are empty when no persisted row carries the requested
    [turn_ref] (old rows, redacted, or outside the retained window). *)
type turn_transcript = {
  user : chat_message list;
  assistant : chat_message list;
}

val transcript_of_messages :
  chat_message list -> turn_ref:Ids.Turn_ref.t -> turn_transcript
(** [transcript_of_messages msgs ~turn_ref] partitions the rows whose
    persisted [turn_ref] equals [turn_ref] into operator [user] lines and
    keeper [assistant] lines, preserving input order. A row with a
    different or absent [turn_ref] is excluded — exact-key join only, no
    timestamp-window fuzzing (RFC-0233 §7 "no fuzzy attribution"). Pass
    {!load}-produced messages so the content is already the redacted view
    (RFC-0132); this function does not re-redact. *)

val turn_transcript_to_json :
  keeper:string ->
  turn_ref:Ids.Turn_ref.t ->
  turn_transcript ->
  Yojson.Safe.t
(** [turn_transcript_to_json ~keeper ~turn_ref t] renders the dashboard
    turn-transcript payload: [keeper], [turn_ref], [found] (false when
    both line lists are empty), [source], and the [user]/[assistant]
    line arrays. Each line carries [role]/[content]/[ts] and, for
    non-utterance assistant rows, the writer-declared [kind]. *)
