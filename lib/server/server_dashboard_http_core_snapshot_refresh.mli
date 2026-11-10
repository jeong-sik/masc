(** Operator-snapshot proactive refresh loop for dashboard HTTP core. *)

val start_operator_snapshot_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  unit
(** Source/deadline/failure-only Snapshot reader and scoped canonical publisher.
    Initial input subscription precedes the first Current read. Healthy quiet
    state has no periodic refresh. Completion fanout is deferred outside
    producer callbacks; scope replacement retires the captured owner. *)
