(** Tool_call_quality_benchmark_render — JSON / CSV rendering for the
    tool-call quality benchmark.

    Five public renderers for the four benchmark types declared in
    {!Tool_call_quality_benchmark_types}: per-case score, per-check
    JSON spec, per-group summary row, and the aggregate benchmark
    summary.  CSV output is one shape per {!summary_view}, sharing the
    same column header set across views.

    The four [..._to_yojson] renderers are the SSOT for the on-disk
    benchmark artefact format — the file emitted by
    [tool_call_quality_benchmark.ml] and consumed by external
    dashboards / spreadsheets must round-trip exactly through these
    functions.  Field names and ordering are part of that contract. *)

val case_score_to_yojson :
  Tool_call_quality_benchmark_types.case_score -> Yojson.Safe.t
(** [case_score_to_yojson score] renders a single benchmark case
    result.  Field set (18 fields, fixed order):

    [case_id] / [provider] / [model] / [keeper_profile] / [passed] /
    [task_pass] / [tool_selection] / [arg_validity] / [recovery] /
    [efficiency] / [unnecessary_tool_rate] / [composite_score] /
    [tool_call_count] / [latency_ms] / [input_tokens] / [output_tokens]
    / [cost_usd] / [prompt_fingerprint] / [tool_sequence].

    Optional fields render as [`Null] when [None] (NOT as the string
    ["null"] or the empty array) — preserving the
    "deliberately absent" vs "deliberately blank" distinction
    consumers rely on.  See cycle 69
    ({!Telemetry_coverage_gap}) for the cross-module convention. *)

val json_check_to_yojson :
  Tool_call_quality_benchmark_types.json_check -> Yojson.Safe.t
(** [json_check_to_yojson check] renders one path-expectation check.
    Field set: [path] / [equals] / [contains] / [min_int] /
    [present].  [equals] retains its original [Yojson.Safe.t] shape
    (any JSON value is permitted as a comparand). *)

val summary_row_to_yojson :
  Tool_call_quality_benchmark_types.summary_row -> Yojson.Safe.t
(** [summary_row_to_yojson row] renders one aggregate row.  22
    fields:

    [provider] / [model] / [keeper_profile] (group key triple) +
    [cases_total] / [cases_passed] (count pair) +
    [task_pass_rate] / [correct_tool_rate] / [arg_valid_rate] /
    [recovery_rate] / [unnecessary_tool_rate] / [avg_tool_calls] /
    [p95_latency_ms] / [avg_input_tokens] / [avg_output_tokens] /
    [avg_cost_usd] / [composite_score] (per-row metrics) +
    [unsupported_runs] / [runtime_unreachable_runs] (failure
    classification) + [stability_score] /
    [tool_sequence_consistency_rate] /
    [prompt_fingerprint_consistency_rate] / [pass_consistency_rate]
    (consistency metrics, optional) + [repeated_case_groups]. *)

val benchmark_summary_to_yojson :
  Tool_call_quality_benchmark_types.benchmark_summary -> Yojson.Safe.t
(** [benchmark_summary_to_yojson summary] renders the top-level
    aggregate.  Field set: 6 scalar counts + 3 grouped lists
    ([grouped_by_provider_model_keeper] / [grouped_by_provider_model]
    / [grouped_by_keeper_profile]). *)

val summary_rows_to_csv :
  view:Tool_call_quality_benchmark_types.summary_view ->
  Tool_call_quality_benchmark_types.benchmark_summary ->
  string
(** [summary_rows_to_csv ~view summary] renders a CSV with a fixed
    23-column header set, regardless of which {!summary_view} is
    selected.  The header row is identical across views so a
    spreadsheet template can be reused.

    {2 CSV escaping}

    Values containing comma, double-quote, or newline are wrapped
    in double quotes with embedded double-quotes doubled (RFC 4180
    minimal subset).  Any other character is passed through.

    {2 Numeric precision (pinned)}

    Operator-visible spreadsheet contracts depend on these widths:

    - rates (task / tool / arg / recovery / unnecessary): [%.4f]
    - tool-call counts (avg): [%.4f]
    - latency / token averages: [%.1f]
    - cost: [%.6f]
    - composite score: [%.2f]
    - optional consistency metrics: [%.4f] when [Some], empty when [None]

    {2 Empty-string vs missing}

    Optional [string]/[float]/[int] columns render as the empty
    string when [None] (NOT as ["null"] or ["NaN"]).  CSV consumers
    that distinguish empty from zero rely on this convention.

    Output is terminated with a final newline. *)
