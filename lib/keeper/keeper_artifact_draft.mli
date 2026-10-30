val handle : ?runner:Artifact_document_engine.runner ->
  scope:Keeper_artifact_draft_scope.t -> base_path:string -> keeper:string ->
  turn_ref:Ids.Turn_ref.t -> args:Yojson.Safe.t -> unit -> Keeper_tool_execution.t
