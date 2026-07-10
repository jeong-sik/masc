(** Dashboard_goals_types — pure types + task helpers extracted from
    Dashboard_goals (1998 LoC godfile).

    Holds the goal-tree node record + companion projection types + the
    pure task-status helpers used by the goal-tree builder. State-touching
    forest construction stays in Dashboard_goals. Re-included by it so
    existing callers continue to use [Dashboard_goals.tree_node] etc.
    unchanged. *)

type tree_node = {
  goal : Goal_store.goal;
  children : tree_node list;
  tasks : (Masc_domain.task * string) list;
  convergence : float;
  health : string;
  badges : string list;
  last_activity_at : string;
  stagnation_seconds : int;
  linked_keeper_names : string list;
  pending_approval_count : int;
  infra_risk_count : int;
  linkage_source : string;
  linkage_warning_count : int;
  status_reason : string;
  blocking_source : string;
  blocking_reason : string;
  latest_keeper_ref : string option;
  latest_turn_ref : int option;
  stalled_since : string option;
  activity_observation : string;
  stagnation_status : string;
}
(** Per-goal projection node returned by [build_forest]. *)

type goal_detail_keeper = {
  meta : Keeper_meta_contract.keeper_meta;
  latest_receipt : Yojson.Safe.t option;
  runtime_trust : Yojson.Safe.t;
}

type attainment_unit =
  | Percent
  | Count
  | Unknown

(** {1 Pure task-status helpers} *)

val task_is_linked_to_goal :
  ?goal_task_index:(string, string list) Hashtbl.t -> Masc_domain.task -> string -> bool
val task_linkage_source_opt :
  ?goal_task_index:(string, string list) Hashtbl.t -> Masc_domain.task -> string -> string option
val task_assignee : Masc_domain.task -> string option
val task_status_label : Masc_domain.task -> string
val task_is_terminal : Masc_domain.task -> bool
val task_is_done : Masc_domain.task -> bool
val task_updated_at : Masc_domain.task -> string

(** {1 Pure list utilities} *)

val dedupe_sort : string list -> string list
val link_source_of_values : string list -> string

(** {1 Receipt / trust JSON inspectors + duration helpers} *)

val receipt_error_kind : Yojson.Safe.t -> string option
val receipt_error_message : Yojson.Safe.t -> string option
val receipt_sandbox_kind : Yojson.Safe.t -> string option
val receipt_runtime_id : Yojson.Safe.t -> string option
val receipt_runtime_outcome : Yojson.Safe.t -> string option
val receipt_runtime_fallback_applied : Yojson.Safe.t -> bool
val receipt_outcome : Yojson.Safe.t -> string option
val receipt_started_at : Yojson.Safe.t -> string option
val receipt_ended_at : Yojson.Safe.t -> string option
val receipt_turn_count : Yojson.Safe.t -> int option

val trust_disposition : Yojson.Safe.t -> string option
val trust_disposition_reason : Yojson.Safe.t -> string option
val trust_attention_reason : Yojson.Safe.t -> string option
val trust_needs_attention : Yojson.Safe.t -> bool
val trust_snapshot_unavailable : Yojson.Safe.t -> bool
val trust_turn_id : Yojson.Safe.t -> int option
val trust_latest_event : Yojson.Safe.t -> Yojson.Safe.t option
val trust_latest_event_ts : Yojson.Safe.t -> string option
val trust_latest_event_ts_unix : Yojson.Safe.t -> float option
val trust_sandbox_risk : Yojson.Safe.t -> bool
val trust_runtime_risk : Yojson.Safe.t -> bool

val receipt_has_error : Yojson.Safe.t -> bool
val receipt_has_sandbox_risk : Yojson.Safe.t -> bool
val receipt_has_runtime_risk : Yojson.Safe.t -> bool

val iso_max : string -> string -> string
val latest_iso : ?fallback:string -> string list -> string option

val stagnation_threshold_seconds : int
(** RFC-0294: single policy constant (1 day) after the per-horizon table was
    removed with the workspace-goal horizon. *)

val human_duration : int -> string

(** {1 Metric parsing utilities — pure tokenizer + percent/count inference} *)

val clamp_float : float -> float -> float -> float
val pct_of_float : float -> int

val attainment_unit_to_string : attainment_unit -> string

val contains_ci : string -> string -> bool

val metric_word_tokens : string -> string list
val metric_word_implies_percent : string -> bool
val metric_implies_percent : string option -> bool

val metric_count_token : string -> bool
val metric_has_pull_request_phrase : string list -> bool
val metric_supports_count_target : string option -> bool

val target_value_implies_percent : string -> bool

val strip_number_group_separators : string -> string
val parse_first_float : string -> float option

val parsed_target_unit : string option -> string -> attainment_unit

(** {1 Goal attainment JSON projection — pure tree → JSON converter} *)

val build_attainment_json :
  state:string ->
  basis:string ->
  task_done_count:int ->
  task_count:int ->
  target_parse_status:string ->
  unit:attainment_unit ->
  observed_value:float option ->
  target_numeric:float option ->
  attainment_pct:int option ->
  note:string ->
  Goal_store.goal ->
  Yojson.Safe.t

val goal_attainment_pct_help : string
val goal_attainment_measured_help : string

val goal_attainment_to_json :
  Goal_store.goal -> tree_node -> Yojson.Safe.t

val goal_completion_to_json :
  effective_policy:'a option ->
  open_request:'b option ->
  Goal_store.goal ->
  tree_node ->
  attainment:Yojson.Safe.t ->
  Yojson.Safe.t

(** {1 Goal phase health + reason + tree badges (pure)} *)

val goal_phase_to_health : Goal_phase.t -> string option

val goal_health_reason :
  goal_phase:Goal_phase.t ->
  blocked_by_receipt:bool ->
  child_blocked:bool ->
  pending_approvals:int ->
  sandbox_risk:bool ->
  runtime_risk:bool ->
  verification_pending:bool ->
  stalled:bool ->
  stagnation_seconds:int ->
  child_at_risk:bool ->
  linkage_warning_reason:string option ->
  activity_observation:string ->
  stagnation_status:string ->
  string

val tree_health :
  goal_phase:Goal_phase.t ->
  blocked_by_receipt:bool ->
  child_blocked:bool ->
  at_risk:bool ->
  string

val tree_badges :
  pending_approvals:int ->
  sandbox_risk:bool ->
  runtime_risk:bool ->
  verification_pending:bool ->
  stalled:bool ->
  activity_unobserved:bool ->
  string list

(** {1 Approval matching + keeper assignee resolution + goal FSM projection (pure)} *)

val approval_matches_goal : string -> Yojson.Safe.t -> bool

val keeper_name_matches_meta : Keeper_meta_contract.keeper_meta list -> string -> bool

val keeper_name_of_assignee :
  Keeper_meta_contract.keeper_meta list -> string -> string option

val goal_fsm_state_kind : Goal_phase.t -> string

val goal_fsm_next_actions :
  goal_phase:Goal_phase.t ->
  has_effective_verifier_policy:bool ->
  require_completion_approval:bool ->
  string list

val goal_fsm_to_json :
  effective_policy:'a option ->
  Goal_store.goal ->
  tree_node ->
  Yojson.Safe.t

(** {1 Operator-disposition normalizer (pure)} *)

(** [display_disposition_of_receipt_json receipt] returns
    [(disposition, reason, raw_disposition, raw_reason)] where [disposition]
    is one of "Pass" | "Blocked" | "Alert". Legacy "Pause" payloads are
    still accepted by downstream readers. *)
val display_disposition_of_receipt_json :
  Yojson.Safe.t -> string * string * string * string

(** {1 Color helpers + task tree JSON projection (pure)} *)

val goal_status_color : Goal_store.goal_status -> string
val goal_phase_color : Goal_phase.t -> string
val goal_health_color : string -> string
val task_status_color : string -> string

val task_to_tree_json : Masc_domain.task * string -> Yojson.Safe.t
val task_summary_to_json : (Masc_domain.task * string) list -> Yojson.Safe.t

(** {1 Tree flatten + goal-detail JSON + timeline projection (pure)} *)

val flatten_tree : tree_node list -> tree_node list -> tree_node list
(** Pre-order tree walk; [acc] is the reverse-accumulating list. Pass
    [\[\]] as initial [acc]. *)

val goal_detail_keeper_json : goal_detail_keeper -> Yojson.Safe.t

val timeline_event_json :
  ts:string ->
  kind:string ->
  lane:string ->
  title:string ->
  summary:string ->
  severity:string ->
  Yojson.Safe.t

val json_member_or_null : string -> Yojson.Safe.t -> Yojson.Safe.t

val goal_event_timeline_json : Yojson.Safe.t -> Yojson.Safe.t

(** {1 Convergence + verification policy node helpers (pure)} *)

val compute_convergence :
  Goal_store.goal ->
  (Masc_domain.task * string) list ->
  tree_node list ->
  float
(** Pure: weighted average of linked task completion ratio and child
    convergence ratios. Returns 1.0 when goal is Completed and no tasks
    or children exist. *)

val goal_policy_nodes :
  Goal_store.goal list -> Goal_verification.goal_policy_node list
(** Pure: project Goal_store.goal records into Goal_verification policy
    nodes for use with [Goal_verification.effective_policy_for_nodes]. *)

(** {1 Runtime blocker event projection (clock read; no state)} *)

(** Build a JSON event from runtime blocker fields read from
    [Keeper_status_bridge]. Returns [None] when both
    [runtime_blocker_class] and [runtime_blocker_summary] are absent or
    empty. Reads wall-clock for [ts] / [observed_at]. *)
val runtime_blocker_event_from_meta :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  Yojson.Safe.t option

(** {1 Runtime trust fallback projection from execution receipt} *)

(** Compose disposition + receipt accessors + runtime blocker event into
    a 19-key runtime_trust JSON record. Used when the upstream
    [Keeper_runtime_trust_snapshot.snapshot_json] is unavailable. *)
val runtime_trust_from_receipt_fallback :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  Yojson.Safe.t ->
  Yojson.Safe.t

(** {1 Goal timeline composition} *)

(** Compose the task/approval/keeper/goal event lists into a single
    timeline sorted by [ts] descending (newest first). Reads wall-clock
    only as fallback when a keeper event lacks an [ts] field. *)
val build_goal_timeline :
  tree_node ->
  goal_detail_keeper list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list

(** {1 Goal tree builder — recursive pure projection over context} *)

type build_context = {
  now_ts : float;
  all_tasks : Masc_domain.task list;
  pending_approvals : Yojson.Safe.t list;
  keeper_metas : Keeper_meta_contract.keeper_meta list;
  latest_receipts : (string * Yojson.Safe.t) list;
  latest_runtime_trusts : (string * Yojson.Safe.t) list;
  goal_task_index : (string, string list) Hashtbl.t;
}

(** Recursive pure projection: given a [build_context] snapshot, build
    the [tree_node] for [goal] and all descendants found in [goals]. *)
val build_tree : build_context -> Goal_store.goal list -> Goal_store.goal -> tree_node
