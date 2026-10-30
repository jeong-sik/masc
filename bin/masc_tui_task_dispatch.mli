(** Original Task creation intent and its session-owned protocol outcome.
    A created Task outlives workspace observations; no operation is replayed.
    UI consumers may retain completed intents for read-only inspection.
    [Created] does not authorize input recovery or another dispatch. *)
type intent = {
  request_id : string;
  keeper : string;
  title : string;
  body : string;
  original : string;
  workspace : Masc.Tui_decode.server_identity option;
}
type outcome =
  | Created of { task_id : string; workspace : Masc.Tui_decode.server_identity }
  | Not_sent of string
  | Server_error of string
  | Unconfirmed of string
type completion = { ready_at_ns : int64; outcome : outcome }
type progress = Not_started | Reserved | Preparing | Sending | Completed of completion
type t
val create : intent -> t
val intent : t -> intent
val progress : t -> progress
val reject : t -> string -> unit
(** Refuse an unstarted intent. Never replaces another producer or terminal fact. *)
val launch :
  t -> prepare:(unit -> (string, string) result) ->
  send:(session_id:string -> request_id:string -> arguments:(string * Yojson.Safe.t) list ->
    (Masc_tui_mcp.outcome, string) result) -> unit
(** Claim the original intent once, prepare/validate its original MCP session,
    mark entry to the send callback, and publish its original outcome without
    waiting for shared notification capacity. Uses the original current Eio
    switch, without a workspace cancellation registration or a new/root switch.

    Only pre-send failures are [Not_sent]. A tool error is [Server_error], not
    proof that no resource exists. Transport/decoding/exception/cancellation
    after send entry is [Unconfirmed]. Cancellation retains that observed fact
    then propagates. No automatic retry, deduplication or remote outcome proof.
    Caller owns prepare checks; send entry is not physical network-write proof.
    The UI must admit the original receipt separately from fresh follow-up work. *)
