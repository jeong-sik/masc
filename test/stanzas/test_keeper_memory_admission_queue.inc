(test
 (name test_keeper_memory_admission_queue)
 (modules test_keeper_memory_admission_queue)
 (libraries masc_test_deps masc alcotest)
 (deps ../scripts/maintenance/recover-memory-admission.py))

(rule
 (alias runtest)
 (deps test_memory_admission_recovery_tool.py ../scripts/maintenance/recover-memory-admission.py)
 (action (run python3 %{dep:test_memory_admission_recovery_tool.py})))
