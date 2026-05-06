; #11929/#10395 OAS worker cleanup must re-raise cancellation.
; Pure source-text inspection; no MASC_BASE_PATH, no project libs.

(test
 (name test_oas_worker_exec_close_cancel_source)
 (modules test_oas_worker_exec_close_cancel_source)
 (deps ../lib/oas_worker_exec.ml))
