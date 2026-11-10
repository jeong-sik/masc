(test
 (name test_server_observation_refresh)
 (modules test_server_observation_refresh)
 (libraries masc masc_server masc_test_deps masc.keeper_approval masc.telemetry_coverage_gap
  masc.telemetry_unified_source masc.dated_jsonl masc.fs_compat masc.masc_core
  masc.tool_types masc.sse_event alcotest yojson eio eio.mock eio_main))
