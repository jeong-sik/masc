val reference : Yojson.Safe.t -> (Keeper_peer_artifact_ref.t, string) result
val fetch : config:Workspace.config -> Keeper_peer_artifact_ref.t -> (string, string) result
val handle :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  write:(Yojson.Safe.t -> Keeper_tool_execution.t) -> args:Yojson.Safe.t -> Keeper_tool_execution.t
