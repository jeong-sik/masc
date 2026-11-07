(test
 (name test_runtime_vibe_cli)
 (modules test_runtime_vibe_cli)
 (deps
  fixtures/vibe_headless/entries-first-call.json
  fixtures/vibe_headless/export-deadline.json
  fixtures/vibe_headless/export-finished.json
  fixtures/vibe_headless/export-infrastructure-failure.json
  fixtures/vibe_headless/export-usage-error.json)
 (libraries masc_test_deps))
