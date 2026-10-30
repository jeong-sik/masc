; End-to-end OTel metric-store -> Metrics_callbacks -> OTLP HTTP/protobuf
; exporter regression guard. Uses a local fake collector; no external service.

(test
 (name test_otel_otlp_export_e2e)
 (modules test_otel_otlp_export_e2e)
 (libraries
  alcotest
  eio
  eio_main
  masc
  masc.otel_spans
  opentelemetry
  pbrt
  unix))
