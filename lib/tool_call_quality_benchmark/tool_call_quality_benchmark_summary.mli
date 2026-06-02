
(** Tool_call_quality_benchmark_summary — aggregate evidence runs
    + case scores into a {!benchmark_summary}.

    Single external entry: {!summarize}.  All percentile / averaging
    / dedup / grouping helpers are private — the .mli pins the
    output type, not the plumbing.

    {b Family}: complements
    {!Tool_call_quality_benchmark_loader} (raw evidence I/O),
    {!Tool_call_quality_benchmark_scoring} (per-run scoring), and
    {!Tool_call_quality_benchmark} (the facade that wires all
    three together).

    Internal: 19 helpers stay private (\[avg_float\],
    \[avg_int_option\], \[avg_float_option\],
    \[percentile95_int_option\], \[dedupe_keep_order\],
    \[normalize_string_list\], \[model_label\],
    \[normalize_filter_set\], \[keep_run\],
    \[group_scores_by_case\], \[modal_ratio\], \[tool_sequence\],
    \[summary_key_of_run\], \[summary_key_of_score\],
    \[repeated_metrics_for_view\], \[collapse_repeated_metrics\],
    \[build_summary_rows\]). *)

val summarize :
  cases:Tool_call_quality_benchmark_types.benchmark_case list ->
  runs:Tool_call_quality_benchmark_types.evidence_run list ->
  ?model_filters:string list ->
  ?keeper_filters:string list ->
  unit ->
  Tool_call_quality_benchmark_types.benchmark_summary
(** [summarize ~cases ~runs ?model_filters ?keeper_filters ()]
    returns the aggregated summary.

    {b Filter contract}: when [model_filters = Some \[\]] or
    [None], all runs pass the model filter; same for
    [keeper_filters].  Non-empty filters match against:

    - [model_filters]: ["<provider>:<model>"] composite key.
    - [keeper_filters]: keeper profile string.

    Filter strings are normalised (trim + lowercase) before
    comparison.

    {b Status counters} ({!benchmark_summary.unsupported_runs} /
    {!benchmark_summary.runtime_unreachable_runs} /
    {!benchmark_summary.unknown_case_runs}) reflect filtered runs:

    - [unsupported_runs]: [run.status = Run_unsupported].
    - [runtime_unreachable_runs]: [run.status = Run_runtime_unreachable].
    - [unknown_case_runs]: [run.status = Run_ok] AND
      [run.case_id] not in [cases].

    {b Three groupings produced} (always all three, not selectable):

    - [grouped_by_provider_model_keeper] — most-specific
      grouping; one row per ["<provider>:<model>:<keeper>"] tuple.
    - [grouped_by_provider_model] — collapses keeper variations.
    - [grouped_by_keeper_profile] — collapses provider/model
      variations.

    Rows in each list are sorted by descending [composite_score],
    breaking ties by descending [cases_total] (more evidence
    wins). *)
