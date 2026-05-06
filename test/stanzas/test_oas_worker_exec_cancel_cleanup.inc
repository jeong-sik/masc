; #11929 OAS worker cancellation cleanup regression guard.
; Pure source-text inspection — no MASC_BASE_PATH, no project libs.

(test
 (name test_oas_worker_exec_cancel_cleanup)
 (modules test_oas_worker_exec_cancel_cleanup)
 (deps ../lib/oas_worker_exec.ml))
