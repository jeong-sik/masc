
include
  module type of Tool_call_quality_benchmark_types
    with type case_category = Tool_call_quality_benchmark_types.case_category
     and type json_check = Tool_call_quality_benchmark_types.json_check
     and type arg_check = Tool_call_quality_benchmark_types.arg_check
     and type recovery_policy =
      Tool_call_quality_benchmark_types.recovery_policy
     and type benchmark_case =
      Tool_call_quality_benchmark_types.benchmark_case
     and type tool_call = Tool_call_quality_benchmark_types.tool_call
     and type run_status = Tool_call_quality_benchmark_types.run_status
     and type evidence_run = Tool_call_quality_benchmark_types.evidence_run
     and type case_score = Tool_call_quality_benchmark_types.case_score
     and type summary_view = Tool_call_quality_benchmark_types.summary_view
     and type summary_row = Tool_call_quality_benchmark_types.summary_row
     and type benchmark_summary =
      Tool_call_quality_benchmark_types.benchmark_summary

val default_case_set_path : repo_root:string -> string
val default_evidence_path : repo_root:string -> string

val load_cases_from_file : string -> (benchmark_case list, string) Result.t
val load_runs_from_file : string -> (evidence_run list, string) Result.t

val score_run :
  cases:benchmark_case list -> evidence_run -> case_score option

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
