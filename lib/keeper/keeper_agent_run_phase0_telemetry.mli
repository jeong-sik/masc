(** Phase-0 wake payload telemetry for [Keeper_agent_run.run_turn]. *)

val record :
  meta:Keeper_meta_contract.keeper_meta ->
  turn_system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  history_messages:Agent_sdk.Types.message list ->
  user_message:string ->
  start_turn_count:int ->
  max_context:int ->
  pre_dispatch_compacted:bool ->
  unit
(** Record wake-time payload sizing before every keeper model dispatch.

    The telemetry path is best-effort: cancellation is re-raised, while other
    exceptions are logged and do not abort the LLM call. *)
