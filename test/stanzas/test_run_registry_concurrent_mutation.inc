; Two fibers on one domain mutating a persisted run registry. The critical
; section suspends on a durable append, so a raw pthread mutex held across it
; is a recursive acquisition on the same OS thread -- the EDEADLK that took
; the server down on 2026-08-12.

(test
 (name test_run_registry_concurrent_mutation)
 (modules test_run_registry_concurrent_mutation)
 (libraries masc_test_deps eio eio_main yojson))
