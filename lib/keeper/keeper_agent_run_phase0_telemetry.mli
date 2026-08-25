(** Wake payload observation for [Keeper_agent_run.run_turn]. *)

val record :
  meta:Keeper_meta_contract.keeper_meta ->
  turn_system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  history_messages:Agent_core.Types.message list ->
  ?user_blocks:Agent_core.Types.content_block list ->
  user_message:string ->
  start_turn_count:int ->
  max_context:int ->
  unit ->
  unit
(** Record exact wake-time component bytes on every turn.

    The observation path is best-effort: cancellation is re-raised, while other
    exceptions are logged and do not abort the LLM call. *)
