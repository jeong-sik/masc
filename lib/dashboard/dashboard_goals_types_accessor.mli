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
  meta : Keeper_types.keeper_meta;
  latest_receipt : Yojson.Safe.t option;
  runtime_trust : Yojson.Safe.t;
}

type attainment_unit =
  | Percent
  | Count
  | Unknown

val task_is_linked_to_goal : Masc_domain.task -> string -> bool
val task_linkage_source_opt : Masc_domain.task -> string -> string option
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
val receipt_approval_profile : Yojson.Safe.t -> string option
val receipt_cascade_name : Yojson.Safe.t -> string option
val receipt_cascade_outcome : Yojson.Safe.t -> string option
val receipt_cascade_fallback_applied : Yojson.Safe.t -> bool
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
val trust_cascade_risk : Yojson.Safe.t -> bool

val receipt_has_error : Yojson.Safe.t -> bool
val receipt_has_sandbox_risk : Yojson.Safe.t -> bool
val receipt_has_cascade_risk : Yojson.Safe.t -> bool

val iso_max : string -> string -> string
val latest_iso : ?fallback:string -> string list -> string option

val stagnation_threshold_seconds : Goal_store.horizon -> int
val human_duration : int -> string
