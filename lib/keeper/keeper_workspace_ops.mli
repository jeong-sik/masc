(* Keeper_workspace_ops — structured shell op dispatch for SearchFiles.

   Private sub-module included by [Agent_tool_command_runtime]. Only exposes what the
   facade needs. *)

val handle_tool_search_files :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
