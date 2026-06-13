(** RFC-0107 Phase D.4 — Otel_metric_store exporter for [Masc_http_client.Pool].

    Read-only adapter: owns the metric name constants and exposes a
    snapshot accessor over [Masc_http_client.all_domain_pools].  The
    actual Otel_metric_store [set_gauge] calls live in {!Otel_metric_store} (see
    [update_pool_metrics_gauges] there) to avoid a Otel_metric_store ↔
    Pool_metrics module cycle.

    Aggregation: sums integer counters across all OCaml Domains so the
    exported gauges reflect process-wide totals.  [idle_per_host] from
    each domain pool is concatenated so the per-host breakdown remains
    available. *)

let metric_idle_total = "masc_pool_idle_total"
let metric_inflight_total = "masc_pool_inflight_total"
let metric_reuse_total = "masc_pool_reuse_total"
let metric_evict_total = "masc_pool_evict_total"
let metric_evict_failure_total = "masc_pool_evict_failure_total"
let metric_create_total = "masc_pool_create_total"

let current_snapshot () =
  let pools = Masc_http_client.all_domain_pools () in
  match pools with
  | [] -> None
  | first :: rest ->
    let init = Masc_http_client.Pool.stats (snd first) in
    let sums = List.fold_left (fun acc (_did, pool) ->
      let s = Masc_http_client.Pool.stats pool in
      { Masc_http_client.Pool.idle_per_host = acc.Masc_http_client.Pool.idle_per_host @ s.Masc_http_client.Pool.idle_per_host
      ; Masc_http_client.Pool.total_idle = acc.Masc_http_client.Pool.total_idle + s.Masc_http_client.Pool.total_idle
      ; Masc_http_client.Pool.total_inflight = acc.Masc_http_client.Pool.total_inflight + s.Masc_http_client.Pool.total_inflight
      ; Masc_http_client.Pool.reuse_count_total = acc.Masc_http_client.Pool.reuse_count_total + s.Masc_http_client.Pool.reuse_count_total
      ; Masc_http_client.Pool.evict_count_total = acc.Masc_http_client.Pool.evict_count_total + s.Masc_http_client.Pool.evict_count_total
      ; Masc_http_client.Pool.evict_failure_count_total = acc.Masc_http_client.Pool.evict_failure_count_total + s.Masc_http_client.Pool.evict_failure_count_total
      ; Masc_http_client.Pool.create_count_total = acc.Masc_http_client.Pool.create_count_total + s.Masc_http_client.Pool.create_count_total
      }
    ) init rest in
    Some sums

let register () =
  (* Idempotent: metric registration happens in [Otel_metric_store.init].
     This entry point exists so bootstrap can express the dependency
     order explicitly; we touch the snapshot once so a misconfigured
     pool surfaces during startup instead of at first export. *)
  let _ : Masc_http_client.Pool.stats option = current_snapshot () in
  ()
