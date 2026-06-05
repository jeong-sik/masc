(** RFC-0107 Phase D.4 — Otel_metric_store exporter for [Masc_http_client.Pool].

    Read-only adapter: owns the metric name constants and exposes a
    snapshot accessor over [Masc_http_client.pool_singleton_opt].  The
    actual Otel_metric_store [set_gauge] calls live in {!Otel_metric_store} (see
    [update_pool_metrics_gauges] there) to avoid a Otel_metric_store ↔
    Pool_metrics module cycle. *)

let metric_idle_total = "masc_pool_idle_total"
let metric_inflight_total = "masc_pool_inflight_total"
let metric_reuse_total = "masc_pool_reuse_total"
let metric_evict_total = "masc_pool_evict_total"
let metric_evict_failure_total = "masc_pool_evict_failure_total"
let metric_create_total = "masc_pool_create_total"

let current_snapshot () =
  match Masc_http_client.pool_singleton_opt () with
  | None -> None
  | Some pool -> Some (Masc_http_client.Pool.stats pool)

let register () =
  (* Idempotent: metric registration happens in [Otel_metric_store.init].
     This entry point exists so bootstrap can express the dependency
     order explicitly; we touch the snapshot once so a misconfigured
     pool surfaces during startup instead of at first scrape. *)
  let _ : Masc_http_client.Pool.stats option = current_snapshot () in
  ()
