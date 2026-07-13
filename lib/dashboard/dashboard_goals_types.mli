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
  last_activity_at : string;
  stagnation_seconds : int option;
  linked_keeper_names : string list;
  pending_approval_count : int;
  linkage_source : string;
  latest_keeper_ref : string option;
  latest_turn_ref : int option;
  activity_observation : string;
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
val receipt_runtime_id : Yojson.Safe.t -> string option
val receipt_runtime_outcome : Yojson.Safe.t -> string option
val receipt_outcome : Yojson.Safe.t -> string option
val receipt_started_at : Yojson.Safe.t -> string option
val receipt_ended_at : Yojson.Safe.t -> string option
val receipt_turn_count : Yojson.Safe.t -> int option

val trust_turn_id : Yojson.Safe.t -> int option
val trust_latest_event : Yojson.Safe.t -> Yojson.Safe.t option
val trust_latest_event_ts : Yojson.Safe.t -> string option
val trust_latest_event_ts_unix : Yojson.Safe.t -> float option
val receipt_has_error : Yojson.Safe.t -> bool

val iso_max : string -> string -> string
val latest_iso : ?fallback:string -> string list -> string option

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
  Goal_store.goal ->
  tree_node ->
  attainment:Yojson.Safe.t ->
  Yojson.Safe.t

(** {1 Approval matching + keeper assignee resolution + goal FSM projection (pure)} *)

val approval_matches_goal : string -> Yojson.Safe.t -> bool

val keeper_name_matches_meta : Keeper_meta_contract.keeper_meta list -> string -> bool

val keeper_name_of_assignee :
  Keeper_meta_contract.keeper_meta list -> string -> string option

val goal_fsm_state_kind : Goal_phase.t -> string

val goal_fsm_next_actions :
  goal_phase:Goal_phase.t -> string list

val goal_fsm_to_json :
  Goal_store.goal ->
  tree_node ->
  Yojson.Safe.t

(** {1 Operator-disposition normalizer (pure)} *)

(** {1 Color helpers + task tree JSON projection (pure)} *)

val goal_status_color : Goal_store.goal_status -> string
val goal_phase_color : Goal_phase.t -> string
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
