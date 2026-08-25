(** Keeper_workspace_ops — owner of structured workspace dispatch for Grep. *)

val handle_tool_search_files :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_tool_search_files_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
