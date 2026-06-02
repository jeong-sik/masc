(** Operator-digest proactive refresh loop for dashboard HTTP core. *)

val start_operator_digest_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit
(** Start the cached operator-digest proactive refresh loop. *)
