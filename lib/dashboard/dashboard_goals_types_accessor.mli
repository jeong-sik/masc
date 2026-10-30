(** Accessor layer for dashboard goal-tree projections. *)

type tree_node = {
  goal : Goal_store.goal;
  children : tree_node list;
  tasks : Masc_domain.task list;
  last_activity_at : string;
  stagnation_seconds : int option;
  linked_keeper_names : string list;
  pending_approval_count : int;
  latest_keeper_ref : string option;
  latest_turn_ref : int option;
  activity_observation : string;
}

type goal_detail_keeper = {
  meta : Keeper_meta_contract.keeper_meta;
  latest_receipt : Yojson.Safe.t option;
  runtime_trust : Yojson.Safe.t;
}

(** [Some ()] when the link table places this Task under this Goal. Replaces
    [task_linkage_source_opt], which returned a constant "explicit" and made
    three unreachable linkage kinds look like real cases. *)
val task_is_linked_opt :
  ?goal_task_index:(string, string list) Hashtbl.t ->
  Masc_domain.task -> string -> unit option

val task_is_linked_to_goal :
  ?goal_task_index:(string, string list) Hashtbl.t -> Masc_domain.task -> string -> bool
val task_assignee : Masc_domain.task -> string option
val task_is_terminal : Masc_domain.task -> bool
val task_is_done : Masc_domain.task -> bool
val task_updated_at : Masc_domain.task -> string

val dedupe_sort : string list -> string list

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
