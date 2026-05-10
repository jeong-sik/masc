; PR-C2: cancel boundary property test.
; Asserts that lib/masc_oas_bridge.ml always re-raises Eio.Cancel.Cancelled
; (never swallows it), preserves backtrace, emits Prometheus counter + WARN log,
; and classifies wall-time into buckets before re-raising.
; Regression guard: a refactor that drops the reraise breaks Eio structured
; concurrency and can leave parent fibers waiting forever.

(test
 (name test_masc_oas_bridge_cancel_boundary)
 (modules test_masc_oas_bridge_cancel_boundary)
 (libraries masc_test_deps)
 (deps ../lib/masc_oas_bridge.ml))
