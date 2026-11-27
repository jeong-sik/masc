val handle : ?runner:Artifact_document_engine.runner ->
  base_path:string -> keeper:string -> args:Yojson.Safe.t -> unit -> Keeper_tool_execution.t
