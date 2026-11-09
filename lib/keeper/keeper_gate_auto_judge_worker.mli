(** Running an Auto Judge: the worker spawner seam, the start reservation a
    pending approval takes before its worker exists, the claim, spawn and
    retry chain for one entry, and the drain of one owner and of a workspace.
    [Keeper_gate] includes this module. *)

open Keeper_gate_auto_judge_queue

type hitl_worker_spawner =
  sw:Eio.Switch.t ->
  entry:Keeper_approval_queue_rules_types.pending_approval ->
  on_summary:(Keeper_approval_queue_rules_types.hitl_context_summary -> unit) ->
  on_finish:(Hitl_summary_worker.finish_outcome -> unit) ->
  unit ->
  (Hitl_summary_worker.spawn_outcome, string) result

val mark_pre_worker_unavailable :
  Keeper_approval_queue_rules_types.pending_approval ->
  reason_code:Keeper_approval_queue_rules_types.summary_attempt_pre_worker_unavailable_code ->
  operator_detail:string ->
  (bool, Keeper_approval_queue_result.exact_attempt_error) result

val spawn_claimed_auto_judge_entry_detached_with :
  spawn_worker:hitl_worker_spawner ->
  Keeper_approval_queue_rules_types.pending_approval ->
  (auto_judge_start_outcome, string)
  result

val spawn_auto_judge_entry_with :
  spawn_worker:hitl_worker_spawner ->
  Keeper_approval_queue_rules_types.pending_approval ->
  (auto_judge_start_outcome, string)
  result

val retry_auto_judge_entry :
  requested_by:string ->
  expected_input_hash:string ->
  expected_sequence:int ->
  expected_exact_attempt:Keeper_approval_queue_rules_types.exact_attempt_state ->
  expected_disposition:Keeper_approval_queue_rules_types.summary_attempt_disposition ->
  Keeper_approval_queue_rules_types.pending_approval ->
  (auto_judge_retry_outcome,
   auto_judge_retry_error)
  result

val start_auto_judge_entry :
  Keeper_approval_queue_rules_types.pending_approval ->
  (auto_judge_start_outcome, string)
  result

val drain_auto_judge_owner :
  ?reserved_id:string ->
  base_path:string ->
  keeper_name:string ->
  unit ->
  (auto_judge_drain_outcome, string)
  result

val drain_auto_judges :
  base_path:string ->
  (auto_judge_workspace_drain_report,
   string)
  result
