(** Read surface for the runtime-observable store cells written by
    [Otel_runtime_observables] (masc#29023). Serves
    [/api/v1/dashboard/runtime-observables]. *)

(** Every store-cell name this endpoint serves. The coverage test asserts
    that every sample the store writer lands appears here, so a new sample
    family cannot ship invisible. *)
val served_metric_names : string list

(** One detached [Otel_metric_store.snapshot] pass re-grouped into typed
    blocks: console sink, transition audit, fd accounting, on-disk store
    sizes, event-bus contracts, HTTP pool, and the last-write freshness
    stamp. Cells the writer has not landed render as [null] — absence stays
    distinguishable from a written zero. *)
val runtime_observables_http_json : unit -> Yojson.Safe.t

(** Short-window pre-encoded HTTP payload + ETag for
    [/api/v1/dashboard/runtime-observables]. Invalidates immediately when the
    writer updates [last_write_unixtime] or after 1 second so [age_seconds]
    and live gauges stay fresh while repeated reads avoid copying the whole
    [Otel_metric_store] or recompressing. *)
val runtime_observables_http_prepared : unit -> Server_cached_read_http.prepared_http
