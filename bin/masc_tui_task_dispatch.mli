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
  | Kept_back of string
      (** The caller's kept-back notice: the workspace guard withdrew the
          creation before it was sent, so it is said as kept back, never as a
          failure of the send (RFC-tui-one-screen-grammar §2). *)
  | Server_error of string
  | Unconfirmed of string
type completion = { ready_at_ns : int64; outcome : outcome }
type progress = Not_started | Reserved | Preparing | Sending | Completed of completion
type t
val create : intent -> t
val intent : t -> intent
val progress : t -> progress
(** Why [prepare] did not hand over a session: its own failure, which becomes
    [Not_sent], or the caller's kept-back notice for a creation the workspace
    guard withdrew, which becomes [Kept_back]. *)
type preparation_failure = Preparation_failed of string | Preparation_kept_back of string
val reject : t -> string -> unit
(** Refuse an unstarted intent. Never replaces another producer or terminal fact. *)
val keep_back : t -> string -> unit
(** Settle an unstarted intent as [Kept_back] with the caller's notice, under
    the same rule as [reject]. *)
val launch :
  t -> prepare:(unit -> (string, preparation_failure) result) ->
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
