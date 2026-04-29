(** Tool_call_quality_benchmark_scoring — score a single
    {!Tool_call_quality_benchmark_types.evidence_run} against
    its declared {!Tool_call_quality_benchmark_types.benchmark_case}.

    Single public entry point ({!score_run}) — all 15 sub-scoring
    helpers (path navigation, per-axis scoring, recovery
    detection) are private.  The composite score formula and
    pass criteria are pinned at the contract seam. *)

val score_run :
  cases:Tool_call_quality_benchmark_types.benchmark_case list ->
  Tool_call_quality_benchmark_types.evidence_run ->
  Tool_call_quality_benchmark_types.case_score option
(** [score_run ~cases run] looks up the case matching
    [run.case_id] and computes the per-run score record.

    {2 Skip conditions}

    Returns [None] when:
    - [run.status <> Run_ok] (failed runs are not scored).
    - [run.case_id] is not present in [cases].
    - [run.keeper_profile] is not in the case's
      [keeper_profiles] (a run on the wrong profile is
      structurally invalid).

    {2 Composite score formula (pinned)}

    {[
      composite =
          40 * task_pass
        + 25 * tool_selection
        + 15 * arg_validity
        + 10 * recovery
        + 10 * efficiency
    ]}

    Range: [0.0..100.0].  Operator dashboards key off this
    weighting — a future "rebalance the weights" PR must touch
    this contract explicitly so the historical comparison
    table stays valid.

    {2 passed criterion (pinned)}

    [passed = true] iff every axis equals [1.0] (binary AND),
    not the composite >= some threshold.  Strict-pass is
    intentional: partial credit on the composite is for trend
    analysis, not for "did this run succeed".

    {2 Per-axis semantics}

    | Axis | Definition |
    |---|---|
    | `task_pass` | reported [task_success = true] AND every [success_check] passes against [final_result] |
    | `tool_selection` | [0.0] if any forbidden tool used; otherwise mean of "required tools used" indicators (or [1.0] for [Tool_forbidden] case with no calls) |
    | `arg_validity` | [1.0] if no `arg_checks`; otherwise mean of per-check pass rate (each check passes iff at least one matching tool call satisfies it) |
    | `recovery` | [1.0] for cases without [recovery_policy.required = true]; otherwise [1.0] iff [task_pass = 1.0] AND a successful call exists after at least one failure AND the failure count is within [max_failures_before_success] |
    | `efficiency` | [Tool_forbidden]: [1.0] if zero calls else [0.0]. Otherwise: [1.0 - (over_limit / max_tool_calls)], floored at [0.0]; [max_tool_calls <= 0] forces zero-call requirement |

    {2 Side metric — unnecessary_tool_rate}

    Not part of the composite (separate dashboard column).
    [(forbidden_count + over_limit) / call_count], capped at
    [1.0].  Zero calls -> [0.0].  [Tool_forbidden] case -> [1.0]
    when any call exists. *)
