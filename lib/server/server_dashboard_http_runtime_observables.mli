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
