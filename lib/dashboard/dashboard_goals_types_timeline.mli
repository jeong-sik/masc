(** Goal tree color, keeper detail, and timeline JSON projections. *)

open Dashboard_goals_types_accessor

val goal_phase_color : Goal_phase.t -> string
val task_status_color : Masc_domain.task_status -> string

val task_to_tree_json : Masc_domain.task -> Yojson.Safe.t
val task_summary_to_json : Masc_domain.task list -> Yojson.Safe.t

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

(** Compose the task/approval/keeper/goal event lists into a single
    timeline sorted by [ts] descending (newest first). Reads wall-clock
    only as fallback when a keeper event lacks an [ts] field. *)
val build_goal_timeline :
  tree_node ->
  goal_detail_keeper list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list
