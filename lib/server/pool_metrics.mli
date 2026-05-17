(** RFC-0107 Phase D.4 — Prometheus exporter for the piaf-backed
    connection pool defined in {!Masc_http_client.Pool}.

    Read-only adapter: snapshots [Pool.stats] and pushes 5 metric
    families to the Prometheus registry on each scrape.  The pool
    itself is not modified; the lazy singleton is observed via
    {!Masc_http_client.pool_singleton_opt}.

    Metric names (no shared prefix beyond [masc_pool_]):
    - [masc_pool_idle_total] (gauge, label [host="scheme://host:port"])
    - [masc_pool_inflight_total] (gauge)
    - [masc_pool_reuse_total] (counter)
    - [masc_pool_evict_total] (counter)
    - [masc_pool_create_total] (counter)

    The cumulative counters use [Pool.stats.*_total] snapshot values
    written directly via [Prometheus.set_gauge] on Counter-typed
    metrics; the metric_type registered in {!Prometheus.init} controls
    text-format rendering (TYPE counter), so the cumulative-monotonic
    invariant holds as long as [Pool] never resets its counters. *)

(** {1 Metric name constants} *)

val metric_idle_total : string
(** [masc_pool_idle_total] — gauge labelled by host. *)

val metric_inflight_total : string
(** [masc_pool_inflight_total] — gauge, single time series. *)

val metric_reuse_total : string
(** [masc_pool_reuse_total] — counter, single time series. *)

val metric_evict_total : string
(** [masc_pool_evict_total] — counter, single time series. *)

val metric_create_total : string
(** [masc_pool_create_total] — counter, single time series. *)

(** {1 Snapshot accessor} *)

val current_snapshot : unit -> Masc_http_client.Pool.stats option
(** [current_snapshot ()] returns the live pool snapshot via
    {!Masc_http_client.pool_singleton_opt}.  Returns [None] when the
    pool has not been lazy-initialized yet (no HTTP traffic since
    process start). *)

(** {1 Prometheus integration} *)

val register : unit -> unit
(** [register ()] is the explicit bootstrap hook.  Metric registration
    itself happens at module-load time inside {!Prometheus.init}, so
    [register] is idempotent and currently a no-op beyond a one-shot
    snapshot warm-up.  Kept as the public bootstrap API per
    RFC-0107 Phase D.4 §"register entry point". *)
