(** RFC-0107 Phase D.4 — snapshot accessor for the piaf-backed
    connection pool defined in {!Masc_http_client.Pool}.

    Read-only adapter: snapshots [Pool.stats]; the actual sample emission
    lives in [Otel_runtime_observables], which calls
    {!current_snapshot} on each exporter tick.  The pool itself is not
    modified; the lazy singleton is observed via
    {!Masc_http_client.pool_singleton_opt}.

    Metric names emitted there (no shared prefix beyond [masc_pool_]):
    - [masc_pool_idle_total] (gauge)
    - [masc_pool_inflight_total] (gauge)
    - [masc_pool_reuse_total] (counter)
    - [masc_pool_evict_total] (counter)
    - [masc_pool_evict_failure_total] (counter)
    - [masc_pool_create_total] (counter)

    The cumulative counters use [Pool.stats.*_total] snapshot values, so
    the cumulative-monotonic invariant holds as long as [Pool] never
    resets its counters. *)

(** {1 Snapshot accessor} *)

val current_snapshot : unit -> Masc_http_client.Pool.stats option
(** [current_snapshot ()] returns the live pool snapshot via
    {!Masc_http_client.pool_singleton_opt}.  Returns [None] when the
    pool has not been lazy-initialized yet (no HTTP traffic since
    process start). *)

(** {1 Otel_metric_store integration} *)

val register : unit -> unit
(** [register ()] is the explicit bootstrap hook.  Metric registration
    itself happens at module-load time inside {!Otel_metric_store.init}, so
    [register] is idempotent and currently a no-op beyond a one-shot
    snapshot warm-up.  Kept as the public bootstrap API per
    RFC-0107 Phase D.4 §"register entry point". *)
