; RFC-0361 D4 — every completion-authority review outcome, including the ones
; that produce no verdict, survives write and replay with its cause intact.

(test
 (name test_verification_run_registry)
 (modules test_verification_run_registry)
 (libraries masc_test_deps masc.run_registry_core))
