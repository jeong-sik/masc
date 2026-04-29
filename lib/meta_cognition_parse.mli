(** Meta_cognition_parse — JSON parsing for summary data.

    Parses the compact summary JSON produced by
    [Meta_cognition_format.summary_json] back into typed OCaml
    records for programmatic interpretation.

    {!Meta_cognition} re-exports {!parse_summary} via
    [include Meta_cognition_parse], so the parent module's .mli
    declares it.  Hiding {!parse_summary} would break the parent
    contract — same calculus as cycle 76 / 89.

    All other helpers (per-sub-summary parsers,
    [`String / `Int / `Float / `Bool / `List` extractors]) stay
    private.  Hiding the extractors specifically is a fence:
    operator-visible JSON parsing must always go through
    {!parse_summary}, never through ad-hoc per-field re-implementations
    that could drift on the empty-string-as-None convention.

    @since God file decomposition — extracted from
    meta_cognition.ml *)

val parse_summary :
  Yojson.Safe.t ->
  (Meta_cognition_types.summary_input, string) result
(** [parse_summary json] decodes the summary JSON object into a
    {!Meta_cognition_types.summary_input}.

    {2 Required fields}

    Top-level integer fields are required; missing or non-integer
    triggers an error:
    - [belief_count] -> ["summary.belief_count missing or invalid"]
    - [contested_belief_count] ->
      ["summary.contested_belief_count missing or invalid"]

    {2 Optional fields}

    [stagnation_score] defaults to [0.0] when absent or non-numeric
    (intentional — older snapshots predate the field).  The three
    sub-summaries ([dominant_belief], [top_tension], [top_desire])
    each accept [`Null] (returns the all-[None] / empty-list
    record) or an [`Assoc _] object; any other shape returns
    [Error] with the per-summary error wording (e.g.
    ["dominant_belief must be an object"]).

    {2 Empty-string-as-None convention}

    Every string field is parsed through a trim-then-empty-check
    pass: an empty string after trimming is read as [None].  This
    matches the cross-module Null-vs-missing pattern (cycle 69
    [telemetry_coverage_gap], cycle 76 [meta_cognition_digest],
    cycle 81 [discovery_cache], cycle 82
    [dashboard_tool_source_freshness]).  A future "let's preserve
    empty strings" change must touch this contract explicitly so
    dashboard consumers stay consistent. *)
