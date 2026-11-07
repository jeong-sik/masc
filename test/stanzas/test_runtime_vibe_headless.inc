(test
 (name test_runtime_vibe_headless)
 (modules test_runtime_vibe_headless)
 (deps
  fixtures/vibe_headless/entries-first-call.json
  fixtures/vibe_headless/entries-tool-completed.json
  fixtures/vibe_headless/entries-tool-denied.json
  fixtures/vibe_headless/export-deadline.json
  fixtures/vibe_headless/export-finished.json
  fixtures/vibe_headless/export-infrastructure-failure.json
  fixtures/vibe_headless/export-token-limit.json
  fixtures/vibe_headless/export-turn-limit.json
  fixtures/vibe_headless/export-usage-error.json
  fixtures/vibe_headless/streaming-first-call.ndjson)
 (libraries masc_test_deps))
