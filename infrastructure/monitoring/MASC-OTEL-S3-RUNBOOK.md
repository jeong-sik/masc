# MASC OTel S3 Runbook — restore metrics after the Prometheus scrape removal

RFC-0217 S4-2 (PR #20082, merged `dc7d067629`) removed `to_prometheus_text` and
the `/metrics` scrape endpoint from masc. Metrics now leave the process **only**
via OTLP push, gated by `MASC_OTEL_ENABLED` (default `false`). Until the steps
below are done, a freshly deployed masc emits **no metrics anywhere** — there is
no scrape fallback. This runbook closes that gap.

The exporter itself is already wired in
`lib/server/server_bootstrap_maintenance.ml:84` (`Otel_spans.setup_exporter`);
no code change is needed. This is purely environment setup.

## Chain

```
masc  ──OTLP/HTTP :4318──▶  otel-collector  ──:8889/metrics──▶  Prometheus server  ──▶  Grafana
        (MASC_OTEL_ENABLED=true)             (prometheus exporter)   (scrape job)        (datasource)
```

## Step 1 — run the collector

```bash
docker run --rm -p 4318:4318 -p 8889:8889 \
  -v "$PWD/infrastructure/monitoring/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml" \
  otel/opentelemetry-collector-contrib:latest
```

Or add it to `docker-compose.yml` next to the `masc` service:

```yaml
  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    container_name: masc-otel-collector
    command: ["--config=/etc/otelcol-contrib/config.yaml"]
    volumes:
      - ./infrastructure/monitoring/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml
    ports:
      - "4318:4318"   # OTLP/HTTP in
      - "8889:8889"   # Prometheus metrics out
```

## Step 2 — enable OTLP export in masc

```bash
export MASC_OTEL_ENABLED=true
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318   # collector host
# optional: export OTEL_SERVICE_NAME=masc   (default is already "masc")
```

If masc runs in the compose network, use the service name:
`OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318`.

## Step 3 — point Prometheus at the collector

The collector exposes the metrics at `:8889/metrics`. Repoint your existing
Prometheus server's scrape target from the old masc `/metrics` to the collector:

```yaml
scrape_configs:
  - job_name: masc
    static_configs:
      - targets: ["localhost:8889"]   # was: masc:<port> /metrics
```

Grafana keeps querying the same Prometheus datasource, so the dashboards in this
directory need no datasource change.

Alternative (no Prometheus server): swap the collector's `prometheus` exporter
for `prometheusremotewrite` pointed at your Prometheus/Mimir remote-write URL.

## Step 4 — verify (do not skip)

```bash
# 1. Collector is receiving and re-exposing masc metrics:
curl -s localhost:8889/metrics | grep -c '^masc_'        # expect > 0

# 2. Names match what the dashboards query (check for drift — counters, suffixes):
curl -s localhost:8889/metrics | grep '^masc_' | head -30
```

Then open a Grafana dashboard and confirm panels render. If a panel is empty,
the likely cause is a metric **name drift** introduced by the OTLP→Prometheus
translation (counter `_total` suffixing, label/namespace changes). The collector
config sets `add_metric_suffixes: false` to minimise this, but the gauge values
that masc previously refreshed lazily during a `/metrics` scrape are now pushed
on the OTel export tick — confirm gauges (FD, pool, uptime) are non-stale.

## Known follow-ups (not blocking S3)

- **Gauge freshness**: the lazy gauge refresh that the scrape used to trigger now
  rides the OTel export tick (`otel_samples`). Confirm FD/pool/uptime gauges
  update at the expected cadence.
- **LANE 3 / S5**: `Prometheus.inc_counter` and the metric store still live in the
  mega lib (dual shim). Extracting a `masc_telemetry` leaf (RFC-0215 LANE 3) is a
  separate refactor — it is the lynchpin that also unblocks the LANE 6 tool_board
  extraction (which depends on mega-resident `Prometheus`).
