; Requested Apple guest identity, strict inspect facts and the actual Boot
; projection. Does not enable adoption across server processes.
(test
 (name test_keeper_microvm_boot_plan)
 (modules test_keeper_microvm_boot_plan)
 (deps fixtures/apple-container-1.6.1-agent-guest-inspect.json)
 (libraries masc_test_deps))
