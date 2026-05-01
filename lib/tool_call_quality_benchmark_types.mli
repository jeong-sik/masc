open Base

type case_category =
  | Tool_required
  | Tool_forbidden
  | Recovery_required
  | Multi_step

type json_check = {
  path : string;
  equals : Yojson.Safe.t option;
  contains : string option;
  min_int : int option;
  present : bool option;
}

type arg_check = {
  tool_name : string;
  path : string;
  equals : Yojson.Safe.t option;
  contains : string option;
  min_int : int option;
  present : bool option;
}

type recovery_policy = {
  required : bool;
  success_after_failure : bool;
  max_failures_before_success : int option;
}

type benchmark_case = {
  id : string;
  prompt : string;
  category : case_category;
  keeper_profiles : string list;
  required_tools : string list;
  forbidden_tools : string list;
  max_tool_calls : int;
  success_checks : json_check list;
  arg_checks : arg_check list;
  recovery_policy : recovery_policy option;
}

type tool_call = {
  tool_name : string;
  success : bool;
  input : Yojson.Safe.t;
  output : Yojson.Safe.t option;
  duration_ms : float option;
}

type run_status =
  | Run_ok
  | Run_unsupported
  | Run_runtime_unreachable
  | Run_other of string

type evidence_run = {
  case_id : string;
  provider : string;
  model : string;
  keeper_profile : string;
  run_id : string option;
  repeat_index : int option;
  prompt_fingerprint : string option;
  task_success : bool option;
  final_output : string option;
  final_result : Yojson.Safe.t option;
  latency_ms : int option;
  input_tokens : int option;
  output_tokens : int option;
  cost_usd : float option;
  status : run_status;
  tool_calls : tool_call list;
}

type case_score = {
  case_id : string;
  provider : string;
  model : string;
  keeper_profile : string;
  passed : bool;
  task_pass : float;
  tool_selection : float;
  arg_validity : float;
  recovery : float;
  efficiency : float;
  unnecessary_tool_rate : float;
  composite_score : float;
  tool_call_count : int;
  latency_ms : int option;
  input_tokens : int option;
  output_tokens : int option;
  cost_usd : float option;
  prompt_fingerprint : string option;
  tool_sequence : string list;
}

type summary_view =
  | By_provider_model_keeper
  | By_provider_model
  | By_keeper_profile

type summary_row = {
  provider : string option;
  model : string option;
  keeper_profile : string option;
  cases_total : int;
  cases_passed : int;
  task_pass_rate : float;
  correct_tool_rate : float;
  arg_valid_rate : float;
  recovery_rate : float;
  unnecessary_tool_rate : float;
  avg_tool_calls : float;
  p95_latency_ms : float;
  avg_input_tokens : float;
  avg_output_tokens : float;
  avg_cost_usd : float;
  composite_score : float;
  unsupported_runs : int;
  runtime_unreachable_runs : int;
  stability_score : float option;
  tool_sequence_consistency_rate : float option;
  prompt_fingerprint_consistency_rate : float option;
  pass_consistency_rate : float option;
  repeated_case_groups : int;
}

type benchmark_summary = {
  cases_total : int;
  runs_total : int;
  scored_runs : int;
  unsupported_runs : int;
  runtime_unreachable_runs : int;
  unknown_case_runs : int;
  grouped_by_provider_model_keeper : summary_row list;
  grouped_by_provider_model : summary_row list;
  grouped_by_keeper_profile : summary_row list;
}
