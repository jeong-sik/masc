; Health-loop pause/restart regression for the OTLP exporter: a mid-run
; collector outage must deactivate the exporter and a returning collector
; must restart it. Loopback listener only; no external service.

(test
 (name test_otel_export_health_pause)
 (modules test_otel_export_health_pause)
 (libraries
  alcotest
  eio
  eio_main
  eio.unix
  masc
  masc.masc_log
  masc.otel_spans
  opentelemetry
  unix))
