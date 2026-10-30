(test
 (name test_keeper_memory_admission_export)
 (modules test_keeper_memory_admission_export)
 (libraries masc_test_deps exact_output_fixture masc masc.runtime
  masc.masc_eio_context agent_core eio_main))

(rule
 (alias runtest-test_collect_admission_exports)
 (deps test_collect_admission_exports.py ../scripts/experiments/collect-admission-exports.py)
 (action (run python3 %{dep:test_collect_admission_exports.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_collect_admission_exports)))
