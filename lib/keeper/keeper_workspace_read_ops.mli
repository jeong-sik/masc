(* Keeper_workspace_read_ops — structured read-side Grep operations. *)

val try_handle_with_authority :
  read_authority:Keeper_sandbox_remote_lane.read_authority option ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t -> op:string -> raw_path:string -> Keeper_tool_execution.t option

val try_handle_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  op:string ->
  raw_path:string ->
  Keeper_tool_execution.t option
