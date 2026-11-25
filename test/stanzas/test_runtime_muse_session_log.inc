(test
 (name test_runtime_muse_session_log)
 (modules test_runtime_muse_session_log)
 (deps fixtures/muse/muse-acp-1.4.25-two-runs.jsonl)
 (libraries alcotest masc.runtime unix yojson))
