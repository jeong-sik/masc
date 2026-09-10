val reference : Yojson.Safe.t -> (Tool_output.artifact_ref, string) result
val fetch : config:Workspace.config -> Tool_output.artifact_ref -> (string, string) result
val handle :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  write:(Yojson.Safe.t -> Keeper_tool_execution.t) -> args:Yojson.Safe.t -> Keeper_tool_execution.t
