(** One-shot completion-contract retry for [Keeper_agent_run.run_turn]. *)

val run_with_single_retry :
  keeper_name:string ->
  acc:Keeper_run_tools.hook_accumulator ->
  has_current_task:bool ->
  turn_affordances:string list ->
  history_messages:Agent_sdk.Types.message list ->
  call_run_named:
    (initial_messages:Agent_sdk.Types.message list ->
     ('a, Agent_sdk.Error.sdk_error) result) ->
  ('a, Agent_sdk.Error.sdk_error) result
(** Run the first attempt and, for one completion-contract violation per turn,
    append structured feedback and retry once. *)
