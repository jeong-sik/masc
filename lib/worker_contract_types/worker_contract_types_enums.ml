(** Shared worker contract types retained after team-session retirement. *)

type execution_scope =
  | Observe_only
  | Limited_code_change
  | Autonomous

type delivery_verdict_status =
  | Delivery_pass
  | Delivery_repair
  | Delivery_fail

type turn_kind =
  | Turn_note
  | Turn_broadcast
  | Turn_portal
  | Turn_task
  | Turn_checkpoint

type worker_class =
  | Worker_manager
  | Worker_executor
  | Worker_scout
  | Worker_librarian
  | Worker_metacog

type task_profile =
  | Profile_extract
  | Profile_normalize
  | Profile_summarize
  | Profile_verify
  | Profile_decide
  | Profile_synthesize

type risk_level =
  | Risk_low
  | Risk_medium
  | Risk_high

type capsule_mode =
  | Capsule_fresh
  | Capsule_inherit
  | Capsule_capsule

type controller_level =
  | Controller_root
  | Controller_lane
  | Controller_submanager
  | Controller_worker

type control_domain =
  | Domain_execution
  | Domain_quality
  | Domain_knowledge
  | Domain_runtime
  | Domain_meta

type planned_worker = {
  spawn_agent : string;
  runtime_actor : string option;
  spawn_role : string option;
  spawn_model : string option;
  execution_scope : execution_scope option;
  thinking_enabled : bool option;
  thinking_budget : int option;
  max_turns : int option;
  timeout_seconds : int option;
  worker_class : worker_class option;
  parent_actor : string option;
  capsule_mode : capsule_mode option;
  runtime_pool : string option;
  lane_id : string option;
  controller_level : controller_level option;
  control_domain : control_domain option;
  supervisor_actor : string option;
  task_profile : task_profile option;
  risk_level : risk_level option;
  routing_confidence : float option;
  routing_reason : string option;
  routing_escalated : bool;
}

type delivery_contract = {
  contract_id : string;
  summary : string;
  acceptance_checks : string list;
  required_artifacts : string list;
  repair_budget : int;
  generator_roles : string list;
  evaluator_role : string option;
  evaluator_cascade : string;
  evidence_refs : string list;
  updated_by : string;
  updated_at_iso : string;
}

type delivery_verdict = {
  contract_id : string;
  status : delivery_verdict_status;
  summary : string;
  evaluator : string;
  evaluator_role : string option;
  evaluator_cascade : string;
  repair_directive : string option;
  evidence_refs : string list;
  generated_at_iso : string;
}

let execution_scope_to_string = function
  | Observe_only -> "observe_only"
  | Limited_code_change -> "limited_code_change"
  | Autonomous -> "autonomous"

(* Issue #8605: previously returned [Limited_code_change] for any
   unknown input — silent privilege miscategorization. Switched to
   Option so the 3 wire names parse explicitly and typos are visible
   to callers. See worker_types.ml for the longer rationale. *)
let execution_scope_of_string_opt = function
  | "observe_only" -> Some Observe_only
  | "limited_code_change" -> Some Limited_code_change
  | "autonomous" -> Some Autonomous
  | _ -> None

let delivery_verdict_status_to_string = function
  | Delivery_pass -> "pass"
  | Delivery_repair -> "repair"
  | Delivery_fail -> "fail"

(* Issue #8605: previously fell through to [Delivery_fail] (fail-closed
   but silent). Switched to Option so callers can distinguish a real
   "fail" verdict from a typo'd input. *)
let delivery_verdict_status_of_string_opt = function
  | "pass" -> Some Delivery_pass
  | "repair" -> Some Delivery_repair
  | "fail" -> Some Delivery_fail
  | _ -> None

let turn_kind_to_string = function
  | Turn_note -> "note"
  | Turn_broadcast -> "broadcast"
  | Turn_portal -> "portal"
  | Turn_task -> "task"
  | Turn_checkpoint -> "checkpoint"

let turn_kind_of_string = function
  | "broadcast" -> Some Turn_broadcast
  | "portal" -> Some Turn_portal
  | "task" -> Some Turn_task
  | "checkpoint" -> Some Turn_checkpoint
  | "note" -> Some Turn_note
  | _ -> None

let worker_class_to_string = function
  | Worker_manager -> "manager"
  | Worker_executor -> "executor"
  | Worker_scout -> "scout"
  | Worker_librarian -> "librarian"
  | Worker_metacog -> "metacog"

let worker_class_of_string = function
  | "manager" -> Some Worker_manager
  | "executor" -> Some Worker_executor
  | "scout" -> Some Worker_scout
  | "librarian" -> Some Worker_librarian
  | "metacog" -> Some Worker_metacog
  | _ -> None

let task_profile_to_string = function
  | Profile_extract -> "extract"
  | Profile_normalize -> "normalize"
  | Profile_summarize -> "summarize"
  | Profile_verify -> "verify"
  | Profile_decide -> "decide"
  | Profile_synthesize -> "synthesize"

let task_profile_of_string = function
  | "extract" -> Some Profile_extract
  | "normalize" -> Some Profile_normalize
  | "summarize" -> Some Profile_summarize
  | "verify" -> Some Profile_verify
  | "decide" -> Some Profile_decide
  | "synthesize" -> Some Profile_synthesize
  | _ -> None

let risk_level_to_string = function
  | Risk_low -> "low"
  | Risk_medium -> "medium"
  | Risk_high -> "high"

let risk_level_of_string = function
  | "low" -> Some Risk_low
  | "medium" -> Some Risk_medium
  | "high" -> Some Risk_high
  | _ -> None

let capsule_mode_to_string = function
  | Capsule_fresh -> "fresh"
  | Capsule_inherit -> "inherit"
  | Capsule_capsule -> "capsule"

let capsule_mode_of_string = function
  | "fresh" -> Some Capsule_fresh
  | "inherit" -> Some Capsule_inherit
  | "capsule" -> Some Capsule_capsule
  | _ -> None

let controller_level_to_string = function
  | Controller_root -> "root"
  | Controller_lane -> "lane"
  | Controller_submanager -> "submanager"
  | Controller_worker -> "worker"

let controller_level_of_string = function
  | "root" -> Some Controller_root
  | "lane" -> Some Controller_lane
  | "submanager" -> Some Controller_submanager
  | "worker" -> Some Controller_worker
  | _ -> None

let control_domain_to_string = function
  | Domain_execution -> "execution"
  | Domain_quality -> "quality"
  | Domain_knowledge -> "knowledge"
  | Domain_runtime -> "runtime"
  | Domain_meta -> "meta"

let control_domain_of_string = function
  | "execution" -> Some Domain_execution
  | "quality" -> Some Domain_quality
  | "knowledge" -> Some Domain_knowledge
  | "runtime" -> Some Domain_runtime
  | "meta" -> Some Domain_meta
  | _ -> None
