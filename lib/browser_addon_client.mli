(** Host-owned concurrent connection to one original browser worker. No endpoint
    or incarnation may come from browser tool arguments. There is no retry. *)
type t
type error = Unavailable of string | Outcome_unknown of string
val create : socket_path:string -> incarnation:string -> max_message_bytes:int ->
  control_timeout_sec:float -> available:(unit -> bool) -> (t, string) result
val call : t -> on_cancel_after_dispatch:(unit -> unit) -> Browser_addon_wire.command ->
  (Browser_addon_wire.reply, error) result
(** Uses a fresh socket per request, never the serialized MCP connection. Before
    writing, failure proves no request was sent; after writing begins, transport
    loss is unknown. Transport uses the existing host control timeout, plus the
    command's own wait window for Issue/Poll. Private Retire waits for the
    backend's cleanup completion rather than the quick-control timeout; caller
    cancellation still propagates. Cancellation after writing invokes
    the owner's callback under cancellation protection, then propagates. *)
val revoke : t -> unit
(** Admission only. Caller still owns worker termination and resource cleanup. *)
val notice_poll_state : t -> state_id:string -> bool
(** Coalesce notifications for this original connection. Returns true on the
    first successfully received poll state, or a different worker snapshot.
    A lost or cancelled reply cannot consume a notification. *)
