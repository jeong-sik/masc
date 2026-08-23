(test
 (name test_telemetry_gate_handler_detection)
 (modules test_telemetry_gate_handler_detection)
 (deps %{workspace_root}/scripts/ci/check-telemetry-coverage.sh)
 (libraries alcotest unix masc.string_util))
