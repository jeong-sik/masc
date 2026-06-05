; OTEL tick loop must stop after Eio.Mutex.Poisoned instead of spamming logs.
; Pure source-text inspection; no MASC_BASE_PATH, no project libs.

(test
 (name test_otel_tick_poison_source)
 (modules test_otel_tick_poison_source)
 (deps ../lib/otel_spans/opentelemetry_client_cohttp_eio.ml))
