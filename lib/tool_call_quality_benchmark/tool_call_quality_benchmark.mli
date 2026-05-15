
include module type of Tool_call_quality_benchmark_types

val default_case_set_path : repo_root:string -> string
val default_evidence_path : repo_root:string -> string

val load_cases_from_file : string -> (benchmark_case list, string) Result.t
val load_runs_from_file : string -> (evidence_run list, string) Result.t

val score_run :
  cases:benchmark_case list -> evidence_run -> case_score option

val to_reward_advice :
  agent_name:string ->
  ?task_id:string ->
  case_score ->
  Reward_advice_artifact.reward_advice_artifact

val summarize :
     cases:benchmark_case list
  -> runs:evidence_run list
  -> ?model_filters:string list
  -> ?keeper_filters:string list
  -> unit
  -> benchmark_summary

val json_check_to_yojson : json_check -> Yojson.Safe.t
val case_score_to_yojson : case_score -> Yojson.Safe.t
val summary_row_to_yojson : summary_row -> Yojson.Safe.t
val benchmark_summary_to_yojson : benchmark_summary -> Yojson.Safe.t
val summary_rows_to_csv : view:summary_view -> benchmark_summary -> string
