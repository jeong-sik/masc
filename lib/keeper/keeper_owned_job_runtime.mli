(** Actual descriptor-backed isolated job producer. Launch/start intent is
    durable before effects; status reconciles the exact saved backend handle.
    Published output references retain their typed artifacts and a durable
    manifest, with the job result available under the existing inline ceiling. *)
val handle :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  source_context:Keeper_tool_call_log_context.turn_context option ->
  tool_use_id:string option -> turn_ref:Ids.Turn_ref.t option -> trace_id:string option ->
  name:string -> args:Yojson.Safe.t -> Keeper_tool_execution.t
