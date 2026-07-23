type recommendation = {
  keeper_profile : string;
  model_label : string;
  composite_score : float;
  task_pass_rate : float;
  stability_score : float option;
  cases_total : int;
  cases_passed : int;
}

type manifest = {
  version : int;
  generated_at : string;
  source_summary_path : string option;
  recommendations : recommendation list;
}

val build_manifest :
     ?source_summary_path:string
  -> Tool_call_quality_benchmark.benchmark_summary
  -> manifest

val recommendation_to_yojson : recommendation -> Yojson.Safe.t
val manifest_to_yojson : manifest -> Yojson.Safe.t
