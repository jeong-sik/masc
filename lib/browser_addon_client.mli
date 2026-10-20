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
    command's own wait window for Issue/Poll. Private Retire and Model_wait wait
    for lifecycle completion/state change rather than the quick-control timeout; caller
    cancellation still propagates. Model-backed Issue calls also wait for their
    owner rather than the quick transport clock. Owned Chrome Session_open also
    retains its original startup owner and resource-readiness bounds.
    Cancellation after writing invokes
    the owner's callback under cancellation protection, then propagates. *)
val revoke : t -> unit
(** Admission only. Caller still owns worker termination and resource cleanup. *)
val transfer_download : t -> id:string -> actor:string -> route:Browser_lane.route ->
  verb:Browser_lane.verb ->
  publish:(Browser_addon_downloads.descriptor -> (Yojson.Safe.t, string) result) ->
  (Yojson.Safe.t, string) result
(** Claim once, import once and acknowledge the durable artifact. Always settle
    this original grant on failure or cancellation. Only Commit/Release may use
    its captured private endpoint after revocation; new claims remain fenced.
    Cancellation propagates. Neither transport failure nor import failure replays
    a browser command. *)
val notice_poll_state : t -> state_id:string -> bool
(** Coalesce notifications for this original connection. Returns true on the
    first successfully received poll state, or a different worker snapshot.
    A lost or cancelled reply cannot consume a notification. *)
