(* Keeper_shell_bash — typed Shell IR execution pipeline.

   Private sub-module included by [Keeper_exec_shell]. Only exposes what the
   facade needs. *)

val handle_keeper_shell_ir :
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
  val deterministic_retry_fields_for_process_result :
    classification:Exec_core.classification ->
    status:Unix.process_status ->
    (string * Yojson.Safe.t) list
end
