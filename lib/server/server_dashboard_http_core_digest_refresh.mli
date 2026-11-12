(** Operator-digest proactive refresh loop for dashboard HTTP core. *)

val start_operator_digest_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  unit
(** Subscribe before the initial current read, then observe original source
    changes and exact semantic deadlines. Healthy idle has no refresh clock.
    Default HTTP completions share the captured owner and publish canonical
    [operator_digest] directly to that workspace's Observer instance. Actual
    failures retain the existing typed compute/retry policy. *)
