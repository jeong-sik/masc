(** Goal attainment metric parsing and JSON projection helpers. *)

open Dashboard_goals_types_accessor

val clamp_float : float -> float -> float -> float
val pct_of_float : float -> int

val attainment_unit_to_string : attainment_unit -> string

val metric_evaluation_to_string : metric_evaluation -> string

(** [metric_evaluation_of_goal goal] is [Metric_unevaluated] when the goal
    declares a metric (no evaluator is wired to measure it) and [Metric_absent]
    otherwise. Exposed for unit testing. *)
val metric_evaluation_of_goal : Goal_store.goal -> metric_evaluation

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
