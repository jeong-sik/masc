(** Heuristic_metrics diagnostics — instrumentation-theatre guard (#7718).

    Pure functions over a list of JSONL records. Computes coverage
    (per-site counts), value-tuple variance (unique
    [(raw_value, threshold, triggered)] tuples per site), and flags
    degenerate sites where a site has accumulated records but produced
    no variance in the gated inputs/outputs.

    Background: #7718 reopen showed 51 consecutive records of the
    identical tuple [("post_tool_use_failure", 1.0, 0.0, true)]. The
    predicate [1.0 > 0.0] is a tautology — a metric that only emits
    [triggered=true] on a trivially-satisfied threshold is not
    observing a heuristic, it is counting invocations.

    This module makes that condition detectable without changing the
    record/write path. SRE reference: Prometheus
    [absent_over_time]/[changes()] idiom — "presence of a series is
    not health; change over time is". *)

(** JSON ["site"] field of a record. *)
type site = string

type tuple_key = private
  { raw_value : float
  ; threshold : float
  ; triggered : bool
  }

(** Constructor used by tests and callers that want to query
    [per_site_unique_tuples] directly. *)
val make_tuple_key : raw_value:float -> threshold:float -> triggered:bool -> tuple_key

type site_stat =
  { site : site
  ; count : int
  ; unique_tuples : int (** Count of distinct [tuple_key] values seen at this site. *)
  ; latest_timestamp : float option
    (** Max [timestamp] across this site's records, or [None] when no
      record carried a parseable timestamp. *)
  ; triggered_true_count : int
  ; triggered_false_count : int
  }

type report =
  { total_records : int
  ; sites : site_stat list
  ; degenerate_sites : site list
    (** Sites with [count >= degenerate_min_records] and
      [unique_tuples <= 1] — the "instrumentation theatre" signature:
      enough volume to be meaningful, zero variance across the
      threshold-gated fields. *)
  ; one_sided_sites : site list
    (** Sites where every record has [triggered=true] OR every record has
      [triggered=false] and [count >= degenerate_min_records].
      [triggered=true] saturation is the #7718 symptom directly;
      [triggered=false] saturation is the unreachable-branch case. *)
  }

(** Minimum [count] at which a site is eligible to be flagged as
    degenerate. Below this threshold a site is treated as
    [insufficient_data] and omitted from flags. *)
val degenerate_min_records : int

(** Run diagnostics over a list of raw JSON records produced by
    {!Heuristic_metrics.recent}. Records missing required fields are
    ignored silently (they can be malformed past records; the live
    writer emits the full shape). *)
val analyze : Yojson.Safe.t list -> report

(** One-line-per-site human-readable summary intended for logs and
    boot-time health output. *)
val pretty_summary : report -> string
