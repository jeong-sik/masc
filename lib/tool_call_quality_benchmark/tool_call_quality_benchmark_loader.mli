
(** Tool_call_quality_benchmark_loader — JSON loaders for the
    benchmark case set and the evidence-runs file.

    Two paired loaders ({!load_cases_from_file},
    {!load_runs_from_file}) and the canonical default paths.  The
    paired structure mirrors the benchmark pipeline: cases (the
    test plan) + runs (recorded evidence to score against).

    All file-format internals (JSON extractors, sub-parsers,
    Result-monad plumbing) stay private — operator-visible
    surface is the four entry points + the four runtime types
    re-exported from {!Tool_call_quality_benchmark_types}. *)

val default_case_set_path : repo_root:string -> string
(** [default_case_set_path ~repo_root] returns
    [<repo_root>/benchmarks/data/tool_call_quality_cases.json].
    Pinned at the contract seam — operator runbooks reference
    the exact relative path; a future case-set move requires
    synchronized runbook + benchmark-runner updates. *)

val default_evidence_path : repo_root:string -> string
(** [default_evidence_path ~repo_root] returns
    [<repo_root>/test/fixtures/tool_call_quality_benchmark/evidence_runs.json].
    Pinned for the same reason as
    {!default_case_set_path}. *)

val load_cases_from_file :
  string ->
  (Tool_call_quality_benchmark_types.benchmark_case list, string)
  Result.t
(** [load_cases_from_file path] reads an object with a required
    [cases] list.

    {2 Per-case validation}

    Each case must declare:
    - [id] (non-empty trimmed string)
    - [keeper_profiles] (non-empty list)
    - [success_checks] (non-empty list)
    - [prompt] (non-empty trimmed string)
    - [max_tool_calls] >= 0

    Plus optional fields with documented defaults:
    - [category] defaults to [["tool_use"]] when absent;
      unknown categories return [Error "unknown tool-call-quality
      category: <other>"]
    - [forbidden_tools] / [forbidden_selectors] /
      [required_selectors] / [arg_checks] default to empty lists.
      Every [arg_checks] entry requires a structured [selector]
      using the same schema as [required_selectors].
    - [recovery_policy] defaults to [None] (case has no recovery
      requirement)

    Validation errors are returned as the first failure
    encountered (fail-fast through {!Result.Syntax}, not
    collect-all). *)

val load_runs_from_file :
  string ->
  (Tool_call_quality_benchmark_types.evidence_run list, string)
  Result.t
(** [load_runs_from_file path] reads an object with a required
    [runs] list.

    {2 Per-run required fields}

    [case_id] / [provider] / [model] / [keeper_profile] (all
    non-empty trimmed strings).

    {2 Status contract}

    [status] is required and must be exactly one of [["ok"]],
    [["executed_failed"]], or [["runtime_unreachable"]]. Missing,
    non-string, empty, normalized, and unknown values are rejected.

    {2 Optional fields with defaults}

    | Field | Default |
    |---|---|
    | [run_id] / [repeat_index] / [prompt_fingerprint] | [None] |
    | [task_success] / [final_output] / [final_result] | [None] |
    | [latency_ms] / [input_tokens] / [output_tokens] / [cost_usd] | [None] |
    | [tool_calls] | empty list, then per-call defaults |

    {2 Per-tool-call defaults}

    | Field | Default |
    |---|---|
    | [tool_name] | required non-empty string |
    | [success] | [false] |
    | [input] | [`Assoc []] |
    | [output] | [None] |
    | [route_evidence] | [None] |
    | [duration_ms] | [None] | *)
