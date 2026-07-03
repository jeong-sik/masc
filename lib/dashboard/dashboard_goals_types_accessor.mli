(** Accessor layer for dashboard goal-tree projections. *)

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

type goal_detail_keeper = {
  meta : Keeper_meta_contract.keeper_meta;
  latest_receipt : Yojson.Safe.t option;
  runtime_trust : Yojson.Safe.t;
}

type attainment_unit =
  | Percent
  | Count
  | Unknown

(** Whether a goal's declared metric has actually been evaluated (task-1743).
    [Metric_unevaluated] means [goal.metric] is set but no evaluator produced
    a value (the convergence evaluator has no caller); attainment percentages
    are task-derived, not metric-derived. [Metric_absent] means the goal
    declares no metric. Lets consumers distinguish an unmeasured metric from
    a genuine measured zero. *)
type metric_evaluation =
  | Metric_unevaluated
  | Metric_absent

val task_is_linked_to_goal :
  ?goal_task_index:(string, string list) Hashtbl.t -> Masc_domain.task -> string -> bool
val task_linkage_source_opt :
  ?goal_task_index:(string, string list) Hashtbl.t -> Masc_domain.task -> string -> string option
val task_assignee : Masc_domain.task -> string option
val task_status_label : Masc_domain.task -> string
val task_is_terminal : Masc_domain.task -> bool
val task_is_done : Masc_domain.task -> bool
val task_updated_at : Masc_domain.task -> string

val dedupe_sort : string list -> string list
val link_source_of_values : string list -> string

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
