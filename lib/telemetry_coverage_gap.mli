(** Telemetry_coverage_gap — durable record of telemetry write-path
    failures.

    A "coverage gap" is a moment when one telemetry lane wrote
    successfully but another did not, leaving the dashboards
    showing stale data even though the producer is healthy.
    {!record} stamps both a Prometheus counter
    ([metric_telemetry_coverage_gap]) and a JSONL row under
    [<masc_root>/telemetry-coverage-gaps/] so unified telemetry
    can surface the gap on its next read.

    Internal helpers (the [store_dir] path joiner and the
    [string_opt_json] None-vs-empty serialiser) are hidden —
    callers consume only the recorder and the reader. *)

val record :
  masc_root:string ->
  source:string ->
  producer:string ->
  durable_store:string ->
  dashboard_surface:string ->
  stale_reason:string ->
  ?keeper_name:string ->
  ?trace_id:string ->
  ?error:string ->
  unit ->
  unit
(** Append one [masc.telemetry_coverage_gap.v1] JSONL row to the
    durable store and bump
    [Prometheus.metric_telemetry_coverage_gap] with the
    ([source] / [producer] / [dashboard_surface] / [stale_reason])
    label tuple.

    [keeper_name] / [trace_id] / [error] are optional contextual
    fields — when omitted (or empty after trim) the JSON value
    is rendered as [`Null] rather than the empty string so
    downstream consumers can distinguish "missing" from
    "deliberately blank". *)

val read_recent :
  masc_root:string ->
  n:int ->
  Yojson.Safe.t list
(** Return the most recent [n] JSON rows from the coverage-gap
    store. Newest-first ordering matches
    [Dated_jsonl.read_recent]. Returns the empty list when
    [n <= 0] or when the store directory does not yet exist
    (no rows have been recorded for this [masc_root]). *)
