(* Keeper_shell_ops — structured shell op dispatch for keeper_shell tool.

   Private sub-module included by [Keeper_exec_shell]. Only exposes what the
   facade needs. *)

val handle_keeper_shell :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
