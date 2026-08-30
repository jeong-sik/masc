
(** Per-tool timing metrics

    Collects duration and success/failure counts from
    {!Tool_result.result} values and computes percentile latencies.

    @since 2.95.0
*)

(** Metrics snapshot for a single tool. *)
type tool_stats = {
  tool_name : string;
  call_count : int;
  success_count : int;
  deferred_count : int;
  failure_count : int;
  p50_ms : float;
  p95_ms : float;
  p99_ms : float;
  mean_ms : float;
}

type disposition =
  | Completed
  | Deferred
  | Failed

type sample = {
  tool_name : string;
  disposition : disposition;
  duration_ms : float;
}

(** [record result] records a tool invocation from a
    {!Tool_result.result}. *)
val record : Tool_result.result -> unit

val replace_samples : ((sample -> unit) -> ('a, 'error) result) -> ('a, 'error) result
(** [replace_samples produce] builds a new metrics snapshot from streamed
    samples and publishes it only when [produce] returns [Ok]. It leaves the
    current snapshot unchanged on [Error]. Call this before installing live
    producers so a concurrent record cannot be overwritten. *)

(** [stats_for tool_name] returns metrics for a specific tool.
    Returns [None] if no calls have been recorded. *)
val stats_for : string -> tool_stats option

(** [all_stats ()] returns an immutable metrics snapshot sorted by call count
    descending. Repeated and concurrent reads reuse the snapshot until
    [record], [replace_samples], or [clear] changes the metrics. *)
val all_stats : unit -> tool_stats list

(** [to_json stats] serializes a [tool_stats] to JSON. *)
val to_json : tool_stats -> Yojson.Safe.t

(** [all_to_json ()] returns all stats as a JSON array. *)
val all_to_json : unit -> Yojson.Safe.t

(** [clear ()] resets all metrics (for testing). *)
val clear : unit -> unit

(** [install ()] registers a dispatch observer that auto-records metrics
    for every dispatched tool call. *)
val install : unit -> unit
