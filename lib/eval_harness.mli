(** Eval_harness — scenario-based behavioural evaluation for Keeper
    agents.

    Defines scenario / grader / metric types, plus the runner +
    summary helpers used by the eval CLI and dashboard. METR Task
    Standard / OpenAI Harness inspired.

    Internal helpers (the [match_mode_to_string] /
    [grader_result_to_json] / [eval_run_to_json] /
    [eval_result_to_json] / [suite_result_to_json] /
    [scenario_to_json] write-side encoders that callers consume only
    via {!report_to_string} / {!write_results_jsonl}, and the
    [score_std_dev] / [weighted_score] internal aggregators) are
    hidden — callers consume the typed records, the deterministic
    grader / tool-expectation runners, the pass@k / summary
    builders, and the IO entry points only.

    @since 2.73.0 *)

(** {1 Grader types} *)

type match_mode =
  | Exact
  | Contains
  | Regex of string
  | NotContains

type deterministic_grader = {
  field : string;
  expected : string;
  mode : match_mode;
  weight : float;
  description : string;
}

type model_grader = {
  prompt_template : string;
  rubric : string;
  weight : float;
  description : string;
}

type grader =
  | Deterministic of deterministic_grader
  | ModelBased of model_grader

(** {1 Scenario types} *)

type tool_expectation = {
  tool_name : string;
  required : bool;
  max_calls : int option;
  args_contain : string option;
}

type scenario = {
  id : string;
  name : string;
  description : string;
  category : string;
  goal : string;
  setup_messages : string list;
  expected_outcome : string;
  tool_expectations : tool_expectation list;
  graders : grader list;
  max_turns : int;
  max_cost_usd : float;
  tags : string list;
}

(** {1 Result types} *)

type grader_result = {
  grader_desc : string;
  score : float;
  weight : float;
  passed : bool;
  detail : string;
}

type eval_run = {
  scenario_id : string;
  run_index : int;
  trace_id : string;
  scores : grader_result list;
  weighted_score : float;
  passed : bool;
  tool_calls_made : string list;
  total_turns : int;
  total_cost_usd : float;
  duration_ms : int;
  outcome : Trajectory.trajectory_outcome;
  error : string option;
}

type eval_result = {
  scenario : scenario;
  runs : eval_run list;
  pass_at_k : float;
  mean_score : float;
  consistency : float;
  total_cost_usd : float;
}

type eval_suite_result = {
  suite_name : string;
  started_at : float;
  ended_at : float;
  results : eval_result list;
  overall_pass_rate : float;
  total_cost_usd : float;
  total_runs : int;
}

(** {1 Grading runners} *)

val apply_deterministic_grader :
  deterministic_grader -> string -> grader_result
(** Score [value] against the deterministic grader. Returns a
    binary 0.0 / 1.0 score in [grader_result.score]. *)

val check_tool_expectations :
  tool_expectation list ->
  string list ->
  grader_result list
(** Run every tool expectation against the actual tool-call name
    list and return one [grader_result] per expectation. *)

(** {1 Pass@k + summary} *)

val compute_pass_at_k : k:int -> n:int -> c:int -> float
(** Probability of at least one pass in [k] independent runs given
    [c] successes out of [n] total. The unbiased estimator from the
    Codex / METR papers. *)

val summarize_runs :
  scenario:scenario -> k:int -> eval_run list -> eval_result
(** Aggregate the runs of a single scenario into an
    {!eval_result} (pass@k, mean score, consistency, total cost). *)

(** {1 Scenario IO} *)

val scenario_of_json : Yojson.Safe.t -> (scenario, string) result

val load_scenarios_from_file :
  string -> (scenario list, string) result
(** Decode every JSON object in [path] into a {!scenario}; surfaces
    Yojson / Sys errors as [Error msg]. *)

(** {1 Reporting} *)

val report_to_string : eval_suite_result -> string
(** Pretty-print a suite result as a human-readable report
    (overall pass rate, per-scenario score breakdown). *)

val write_results_jsonl :
  path:string -> eval_suite_result -> unit
(** Append each {!eval_run} to [path] as one JSON object per line. *)
