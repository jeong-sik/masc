(** Shared worker contract types retained after team-session retirement.

    All [_of_string] variants are strict (Option-returning) per issue
    #8605 — unknown wire values must NOT silently map to a valid
    constructor. Callers handle [None] explicitly. *)

(** {1 Enum variants} *)

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

(** {1 Planned worker record} *)

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

(** {1 Delivery contract + verdict} *)

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

(** {1 String conversions}

    All [_of_string] / [_of_string_opt] are strict — unknown input
    returns [None] rather than defaulting to a valid constructor. *)

val execution_scope_to_string : execution_scope -> string

val execution_scope_of_string_opt : string -> execution_scope option

val delivery_verdict_status_to_string : delivery_verdict_status -> string

val delivery_verdict_status_of_string_opt :
  string -> delivery_verdict_status option

val turn_kind_to_string : turn_kind -> string

val turn_kind_of_string : string -> turn_kind option

val worker_class_to_string : worker_class -> string

val worker_class_of_string : string -> worker_class option

val task_profile_to_string : task_profile -> string

val task_profile_of_string : string -> task_profile option

val risk_level_to_string : risk_level -> string

val risk_level_of_string : string -> risk_level option

val capsule_mode_to_string : capsule_mode -> string

val capsule_mode_of_string : string -> capsule_mode option

val controller_level_to_string : controller_level -> string

val controller_level_of_string : string -> controller_level option

val control_domain_to_string : control_domain -> string

val control_domain_of_string : string -> control_domain option
