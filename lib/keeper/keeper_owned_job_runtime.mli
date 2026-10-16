(** Actual descriptor-backed isolated job producer. Launch/start intent is
    durable before effects; status reconciles the exact saved backend handle.
    With complete original invocation identity, repeated starts reconcile the
    already-bound job instead of preparing or launching a replacement.
    Published output references retain their typed artifacts and a durable
    manifest, with the job result available under the existing inline ceiling. *)
val handle :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  owned_job_replay:Keeper_owned_job_invocation.replay option ->
  source_context:Keeper_tool_call_log_context.turn_context option ->
  continuation_channel:Keeper_continuation_channel.t option ->
  tool_use_id:string option -> turn_ref:Ids.Turn_ref.t option -> trace_id:string option ->
  name:string -> args:Yojson.Safe.t -> Keeper_tool_execution.t

val reconcile : Keeper_owned_job_store.record ->
  (Keeper_owned_job_store.record, Keeper_owned_job_store.error) result
(** Uses only the original frozen backend and durable intents. A completion
    recovery pulse has no authority to prepare a replacement or replay launch. *)
