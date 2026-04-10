(** Team session types for long-running collaborative orchestration. *)


type session_status =
  | Running
  | Paused
  | Completed
  | Interrupted
  | Failed
  | Cancelled

type execution_scope =
  | Observe_only
  | Limited_code_change
  | Autonomous

type wait_mode =
  | Wait_background
  | Wait_blocking

type orchestration_mode =
  | Manual
  | Assist
  | Auto

type communication_mode =
  | Comm_off
  | Comm_broadcast
  | Comm_portal
  | Comm_hybrid

type session_origin_kind =
  | Origin_human
  | Origin_system

type scale_profile =
  | Scale_standard
  | Scale_local64

type control_profile =
  | Control_flat
  | Control_hierarchical_quality_v1

type fallback_policy =
  | Fallback_none
  | Fallback_cascade_then_task
  | Fallback_task_only

type instruction_profile =
  | Profile_standard
  | Profile_strict

type alert_channel =
  | Alert_broadcast
  | Alert_board
  | Alert_both

type report_format =
  | Markdown
  | Json

type proof_level =
  | Proof_standard
  | Proof_strong

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

type decomposability =
  | Decomposability_high
  | Decomposability_medium
  | Decomposability_low

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

type session = {
  session_id : string;
  goal : string;
  created_by : string;
  origin_kind : session_origin_kind;
  room_id : string;
  operation_id : string option;
  status : session_status;
  duration_seconds : int;
  execution_scope : execution_scope;
  checkpoint_interval_sec : int;
  min_agents : int;
  scale_profile : scale_profile;
  control_profile : control_profile;
  orchestration_mode : orchestration_mode;
  communication_mode : communication_mode;
  model_cascade : string list;
  fallback_policy : fallback_policy;
  instruction_profile : instruction_profile;
  alert_channel : alert_channel;
  auto_resume : bool;
  report_formats : report_format list;
  turn_count : int;
  agent_names : string list;
  planned_workers : planned_worker list;
  broadcast_count : int;
  portal_count : int;
  cascade_attempted : int;
  cascade_success : int;
  cascade_failed : int;
  fallback_task_created : int;
  min_agents_violation_streak : int;
  policy_violations : string list;
  baseline_done_counts : (string * int) list;
  final_done_delta_total : int option;
  final_done_delta_by_agent : (string * int) list option;
  started_at : float;
  planned_end_at : float;
  stopped_at : float option;
  last_checkpoint_at : float option;
  last_event_at : float option;
  last_turn_at : float option;
  stop_reason : string option;
  generated_report : bool;
  delivery_contract : delivery_contract option;
  latest_delivery_verdict : delivery_verdict option;
  artifacts_dir : string;
  created_at_iso : string;
  updated_at_iso : string;
}

type event_entry = {
  ts : float;
  ts_iso : string;
  event_type : string;
  detail : Yojson.Safe.t;
}

type checkpoint = {
  ts : float;
  ts_iso : string;
  status : session_status;
  elapsed_sec : int;
  remaining_sec : int;
  progress_pct : float;
  done_delta_total : int;
  done_delta_by_agent : (string * int) list;
  active_agents : string list;
}

let status_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Completed -> "completed"
  | Interrupted -> "interrupted"
  | Failed -> "failed"
  | Cancelled -> "cancelled"

let enum_error kind value =
  Printf.sprintf "unknown %s: %s" kind value

let status_of_string = function
  | "running" -> Running
  | "paused" -> Paused
  | "completed" -> Completed
  | "interrupted" -> Interrupted
  | "failed" -> Failed
  | "cancelled" -> Cancelled
  | _ -> Failed

let status_of_string_result = function
  | "running" -> Ok Running
  | "paused" -> Ok Paused
  | "completed" -> Ok Completed
  | "interrupted" -> Ok Interrupted
  | "failed" -> Ok Failed
  | "cancelled" -> Ok Cancelled
  | value -> Error (enum_error "session status" value)

let execution_scope_to_string = function
  | Observe_only -> "observe_only"
  | Limited_code_change -> "limited_code_change"
  | Autonomous -> "autonomous"

let execution_scope_of_string = function
  | "observe_only" -> Observe_only
  | "autonomous" -> Autonomous
  | _ -> Limited_code_change

let execution_scope_of_string_result = function
  | "observe_only" -> Ok Observe_only
  | "limited_code_change" -> Ok Limited_code_change
  | "autonomous" -> Ok Autonomous
  | value -> Error (enum_error "execution scope" value)

let wait_mode_to_string = function
  | Wait_background -> "background"
  | Wait_blocking -> "blocking"

let wait_mode_of_string = function
  | "blocking" -> Wait_blocking
  | _ -> Wait_background

let orchestration_mode_to_string = function
  | Manual -> "manual"
  | Assist -> "assist"
  | Auto -> "auto"

let orchestration_mode_of_string = function
  | "manual" -> Manual
  | "auto" -> Auto
  | _ -> Assist

let orchestration_mode_of_string_result = function
  | "manual" -> Ok Manual
  | "assist" -> Ok Assist
  | "auto" -> Ok Auto
  | value -> Error (enum_error "orchestration mode" value)

let communication_mode_to_string = function
  | Comm_off -> "off"
  | Comm_broadcast -> "broadcast"
  | Comm_portal -> "portal"
  | Comm_hybrid -> "hybrid"

let communication_mode_of_string = function
  | "off" -> Comm_off
  | "portal" -> Comm_portal
  | "hybrid" -> Comm_hybrid
  | _ -> Comm_broadcast

let communication_mode_of_string_result = function
  | "off" -> Ok Comm_off
  | "broadcast" -> Ok Comm_broadcast
  | "portal" -> Ok Comm_portal
  | "hybrid" -> Ok Comm_hybrid
  | value -> Error (enum_error "communication mode" value)

let session_origin_kind_to_string = function
  | Origin_human -> "human"
  | Origin_system -> "system"

let session_origin_kind_of_string = function
  | "system" -> Origin_system
  | _ -> Origin_human

let session_origin_kind_of_string_result = function
  | "human" -> Ok Origin_human
  | "system" -> Ok Origin_system
  | value -> Error (enum_error "session origin kind" value)

let scale_profile_to_string = function
  | Scale_standard -> "standard"
  | Scale_local64 -> "local64"

let scale_profile_of_string = function
  | "local64" -> Scale_local64
  | _ -> Scale_standard

let scale_profile_of_string_result = function
  | "standard" -> Ok Scale_standard
  | "local64" -> Ok Scale_local64
  | value -> Error (enum_error "scale profile" value)

let control_profile_to_string = function
  | Control_flat -> "flat"
  | Control_hierarchical_quality_v1 -> "hierarchical_quality_v1"

let control_profile_of_string = function
  | "hierarchical_quality_v1" -> Control_hierarchical_quality_v1
  | _ -> Control_flat

let control_profile_of_string_result = function
  | "flat" -> Ok Control_flat
  | "hierarchical_quality_v1" -> Ok Control_hierarchical_quality_v1
  | value -> Error (enum_error "control profile" value)

let fallback_policy_to_string = function
  | Fallback_none -> "none"
  | Fallback_cascade_then_task -> "cascade_then_task"
  | Fallback_task_only -> "task_only"

let fallback_policy_of_string = function
  | "none" -> Fallback_none
  | "task_only" -> Fallback_task_only
  | _ -> Fallback_cascade_then_task

let fallback_policy_of_string_result = function
  | "none" -> Ok Fallback_none
  | "cascade_then_task" -> Ok Fallback_cascade_then_task
  | "task_only" -> Ok Fallback_task_only
  | value -> Error (enum_error "fallback policy" value)

let instruction_profile_to_string = function
  | Profile_standard -> "standard"
  | Profile_strict -> "strict"

let instruction_profile_of_string = function
  | "strict" -> Profile_strict
  | _ -> Profile_standard

let instruction_profile_of_string_result = function
  | "standard" -> Ok Profile_standard
  | "strict" -> Ok Profile_strict
  | value -> Error (enum_error "instruction profile" value)

let alert_channel_to_string = function
  | Alert_broadcast -> "broadcast"
  | Alert_board -> "board"
  | Alert_both -> "both"

let alert_channel_of_string = function
  | "broadcast" -> Alert_broadcast
  | "board" -> Alert_board
  | _ -> Alert_both

let alert_channel_of_string_result = function
  | "broadcast" -> Ok Alert_broadcast
  | "board" -> Ok Alert_board
  | "both" -> Ok Alert_both
  | value -> Error (enum_error "alert channel" value)

let report_format_to_string = function
  | Markdown -> "markdown"
  | Json -> "json"

let report_format_of_string = function
  | "markdown" -> Some Markdown
  | "json" -> Some Json
  | _ -> None

let report_format_of_string_result = function
  | "markdown" -> Ok Markdown
  | "json" -> Ok Json
  | value -> Error (enum_error "report format" value)

let report_formats_of_strings xs =
  let rec dedup acc = function
    | [] -> List.rev acc
    | x :: rest ->
        if List.mem x acc then dedup acc rest else dedup (x :: acc) rest
  in
  xs
  |> List.filter_map (fun s -> report_format_of_string (String.lowercase_ascii (String.trim s)))
  |> dedup []

let proof_level_to_string = function
  | Proof_standard -> "standard"
  | Proof_strong -> "strong"

let proof_level_of_string = function
  | "strong" -> Proof_strong
  | _ -> Proof_standard

let delivery_verdict_status_to_string = function
  | Delivery_pass -> "pass"
  | Delivery_repair -> "repair"
  | Delivery_fail -> "fail"

let delivery_verdict_status_of_string = function
  | "pass" -> Delivery_pass
  | "repair" -> Delivery_repair
  | "fail" -> Delivery_fail
  | _ -> Delivery_fail

let delivery_verdict_status_of_string_result = function
  | "pass" -> Ok Delivery_pass
  | "repair" -> Ok Delivery_repair
  | "fail" -> Ok Delivery_fail
  | value -> Error (enum_error "delivery verdict status" value)

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

let worker_class_of_string_result = function
  | "manager" -> Ok Worker_manager
  | "executor" -> Ok Worker_executor
  | "scout" -> Ok Worker_scout
  | "librarian" -> Ok Worker_librarian
  | "metacog" -> Ok Worker_metacog
  | value -> Error (enum_error "worker class" value)

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

let task_profile_of_string_result = function
  | "extract" -> Ok Profile_extract
  | "normalize" -> Ok Profile_normalize
  | "summarize" -> Ok Profile_summarize
  | "verify" -> Ok Profile_verify
  | "decide" -> Ok Profile_decide
  | "synthesize" -> Ok Profile_synthesize
  | value -> Error (enum_error "task profile" value)

let risk_level_to_string = function
  | Risk_low -> "low"
  | Risk_medium -> "medium"
  | Risk_high -> "high"

let risk_level_of_string = function
  | "low" -> Some Risk_low
  | "medium" -> Some Risk_medium
  | "high" -> Some Risk_high
  | _ -> None

let risk_level_of_string_result = function
  | "low" -> Ok Risk_low
  | "medium" -> Ok Risk_medium
  | "high" -> Ok Risk_high
  | value -> Error (enum_error "risk level" value)

let capsule_mode_to_string = function
  | Capsule_fresh -> "fresh"
  | Capsule_inherit -> "inherit"
  | Capsule_capsule -> "capsule"

let capsule_mode_of_string = function
  | "fresh" -> Some Capsule_fresh
  | "inherit" -> Some Capsule_inherit
  | "capsule" -> Some Capsule_capsule
  | _ -> None

let capsule_mode_of_string_result = function
  | "fresh" -> Ok Capsule_fresh
  | "inherit" -> Ok Capsule_inherit
  | "capsule" -> Ok Capsule_capsule
  | value -> Error (enum_error "capsule mode" value)

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

let controller_level_of_string_result = function
  | "root" -> Ok Controller_root
  | "lane" -> Ok Controller_lane
  | "submanager" -> Ok Controller_submanager
  | "worker" -> Ok Controller_worker
  | value -> Error (enum_error "controller level" value)

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

let control_domain_of_string_result = function
  | "execution" -> Ok Domain_execution
  | "quality" -> Ok Domain_quality
  | "knowledge" -> Ok Domain_knowledge
  | "runtime" -> Ok Domain_runtime
  | "meta" -> Ok Domain_meta
  | value -> Error (enum_error "control domain" value)

let decomposability_to_string = function
  | Decomposability_high -> "high"
  | Decomposability_medium -> "medium"
  | Decomposability_low -> "low"

let decomposability_of_string = function
  | "high" -> Decomposability_high
  | "low" -> Decomposability_low
  | _ -> Decomposability_medium
