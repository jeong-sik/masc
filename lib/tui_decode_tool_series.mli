(** The tool-call series that [GET /api/v1/tool-metrics/series] answers, read
    for the Usage view's Calls section.

    The server sends every bucket between the window's edges, oldest first and
    one step apart. An answer that breaks that is an error, not a shorter
    chart. A bucket in which no call ran carries no latency, so it cannot be
    mistaken for one whose calls took zero milliseconds. No network, clock or
    UI dependency. *)

type tool_series_width =
  | Series_hour
  | Series_day

val series_width_seconds : tool_series_width -> int
(** The step between two buckets: 3600 for [Series_hour], 86400 for
    [Series_day]. The answer's [bucket_seconds] must equal it. *)

(** A bucket in which at least one call ran. *)
type tool_series_calls = {
  tsc_calls : int;
      (** Completed, deferred and failed calls together; at least 1. *)
  tsc_failures : int;
  tsc_deferred : int;
      (** [tsc_failures + tsc_deferred] is at most [tsc_calls]. *)
  tsc_p95_ms : float;
      (** Over every call of the bucket, deferred and failed ones included. *)
}

type tool_series_activity =
  | Series_idle  (** No call ran in the bucket. *)
  | Series_active of tool_series_calls

type tool_series_bucket = {
  tsb_start : float;  (** Epoch seconds of the bucket's first second. *)
  tsb_activity : tool_series_activity;
}

type tool_series = {
  tsr_generated_at : float;
      (** Epoch seconds at which the server read the series: the window's end. *)
  tsr_width : tool_series_width;
  tsr_utc_offset_min : int;
      (** Minutes east of UTC that the bucket edges follow. *)
  tsr_buckets : tool_series_bucket list;
      (** Oldest first, one {!series_width_seconds} apart, never empty. *)
}

val decode_tool_series : Yojson.Safe.t -> (tool_series, string) result
(** A bucket width the server has not announced, a [bucket_seconds] that is not
    the width's step, buckets that are out of order or not one step apart, a
    bucket with calls and no p95 (or the reverse), and counts that do not add
    up all fail. *)
