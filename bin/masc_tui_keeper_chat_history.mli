(** Reads the keeper's durable transcript into rows the chat pane can draw.

    The pane's scrollback was session-local: everything a keeper and an
    operator said was held in memory and gone on the next start, even though
    the server keeps the transcript and serves it at
    [GET /api/v1/keepers/<name>/chat/history].

    {2 What the server sends}

    An array of rows, each with [role] ("user" / "assistant" / "tool"),
    [content], and [ts]. An assistant row carrying
    [kind: "transport_failure"] is a delivery that failed rather than
    something the keeper said. A tool row's [content] is the call's arguments
    and [tool_call_name] is the tool — the same pair the live view names a call
    from, so a turn watched live and the same turn scrolled back read
    identically.

    Consecutive tool rows are folded into one block, the way a live turn draws
    its calls, rather than becoming a row each.

    {2 Ordering}

    Rows come back in the order the server appended them, and the server's own
    note says a client sorts by [ts] and breaks ties by original position —
    rows persisted without a [ts] must keep their relative order rather than be
    moved by a sort. [rows_of_json] returns them already in that order, so
    callers do not repeat the rule. *)

(** The surface a row arrived on, mirrored from [Surface_ref.t] in the server.
    This library carries no [masc] dependency, so it cannot name that type;
    [test_tui_chat_surface_mirror] holds the two in step. *)
module Surface : sig
  type t =
    | Dashboard
    | Discord
    | Slack
    | Webhook of string  (** the [source] the hook goes by *)
    | Agent
    | Broadcast
    | Gate of string  (** the connector's channel label *)
end

(** Who put a [role: "user"] row in front of the keeper.

    Not always the operator. On one live keeper 92 of 128 rows carried that
    role and 23 distinct speakers: taskmaster, an MCP client, the exact-lane
    verifier, the dashboard, a dozen canary keepers. Drawing them all as "you"
    told the operator they had said things they had never seen. *)
type speaker =
  | Operator
      (** The row named no author, which is a person typing at an operator
          surface: this pane or the dashboard. *)
  | Named of string  (** The author the server named. *)

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
  | Delivery_failed
      (** An assistant row the server marked [transport_failure]: the reply
          did not reach its destination. Not keeper speech. *)
  | Tool_calls of string list
      (** One block of finished calls, already formatted as rows. *)

type row =
  { at : float  (** The server's [ts], the sort key. *)
  ; kind : kind
  ; text : string
      (** What to draw. Empty for [Tool_calls], whose rows carry the text. *)
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
    surface that is not an operator's own is appended — ["taskmaster · agent"],
    ["vincent · slack"] — so a fleet broadcast and a direct message do not look
    alike. *)

val rows_of_json : Yojson.Safe.t -> (decoded, string) result
(** Decode a [/chat/history] response.

    Fails only when the response is not an array — a shape this cannot read at
    all. A single unreadable row is dropped instead: one bad row should not
    cost an operator the rest of the transcript. The count comes back in
    [dropped] so the loss is not silent. *)
