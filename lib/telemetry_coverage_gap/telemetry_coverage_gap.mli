(** Telemetry_coverage_gap — durable record of telemetry write-path
    failures.

    A "coverage gap" is a moment when one telemetry lane wrote
    successfully but another did not, leaving the dashboards
    showing stale data even though the producer is healthy.
    {!record} stamps a JSONL row under
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
  ?exn:exn ->
  unit ->
  unit
(** Append one [masc.telemetry_coverage_gap.v1] JSONL row to the
    durable store.

    [keeper_name] / [trace_id] / [error] are optional contextual
    fields — when omitted (or empty after trim) the JSON value
    is rendered as [`Null] rather than the empty string so
    downstream consumers can distinguish "missing" from
    "deliberately blank".

    [exn] is the RFC-0154 typed path: when present, [record] calls
    [System_error_class.classify_exn] internally to derive
    [error_class] (errno match → typed variant) and uses
    [Printexc.to_string exn] as the raw [error] string unless an
    explicit [error] argument is also supplied. When [exn] is absent
    but [error] is present, [classify_string] runs over [error] for
    the typed tag. When both are absent, [error_class] is [`Null].

    The wire row carries an [error_class] field alongside the existing
    [error] field — readers should prefer the typed tag and fall back
    to substring matching on [error] (RFC-0154 §4 backward compat
    window). *)

val record_result :
  masc_root:string ->
  source:string ->
  producer:string ->
  durable_store:string ->
  dashboard_surface:string ->
  stale_reason:string ->
  ?keeper_name:string ->
  ?trace_id:string ->
  ?error:string ->
  ?exn:exn ->
  unit ->
  (unit, string) result
(** Result-returning variant of {!record}. *)

val read_recent :
  masc_root:string ->
  n:int ->
  Yojson.Safe.t list
(** Return the most recent [n] JSON rows from the coverage-gap
    store. Newest-first ordering matches
    [Dated_jsonl.read_recent]. Returns the empty list when
    [n <= 0] or when the store directory does not yet exist
    (no rows have been recorded for this [masc_root]). *)

val read_recent_with_read_errors :
  masc_root:string ->
  n:int ->
  Yojson.Safe.t list * Yojson.Safe.t list
(** Read the same recent coverage-gap rows as {!read_recent}, plus
    row-indexed read errors for malformed coverage-gap JSONL rows. *)
