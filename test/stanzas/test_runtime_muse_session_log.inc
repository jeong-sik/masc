(test
 (name test_runtime_muse_session_log)
 (modules test_runtime_muse_session_log)
 (deps
  fixtures/muse/muse-acp-1.4.25-two-runs.jsonl
  fixtures/muse/muse-acp-1.4.25-observers-parent.jsonl
  fixtures/muse/muse-acp-1.4.25-observer-child-completed-a.jsonl
  fixtures/muse/muse-acp-1.4.25-observer-child-completed-b.jsonl
  fixtures/muse/muse-acp-1.4.25-observer-child-cancelled.jsonl)
 (libraries alcotest masc.runtime unix yojson))
