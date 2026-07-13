(** Goal tree color, keeper detail, and timeline JSON projections. *)

open Dashboard_goals_types_accessor

val goal_status_color : Goal_store.goal_status -> string
val goal_phase_color : Goal_phase.t -> string
val task_status_color : string -> string

val task_to_tree_json : Masc_domain.task * string -> Yojson.Safe.t
val task_summary_to_json : (Masc_domain.task * string) list -> Yojson.Safe.t

val flatten_tree : tree_node list -> tree_node list -> tree_node list
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

val build_goal_timeline :
  tree_node ->
  goal_detail_keeper list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list
