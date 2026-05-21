(* Keeper_shell_bash — bash execution pipeline for keeper_bash tool.

   Private sub-module included by [Keeper_exec_shell]. Only exposes what the
   facade needs. *)

val handle_keeper_bash :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  turn_sandbox_factory_git:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  unit ->
  string

module For_testing : sig
  val elapsed_duration_ms : start_time:float -> end_time:float -> int
end
