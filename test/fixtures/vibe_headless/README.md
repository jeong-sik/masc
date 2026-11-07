# Vibe headless fixtures

Copies of the sanitized Vibe 3.1.0 captures in
`docs/evidence/vibe-official-client-lane-20261107/fixtures/` (see that README for
the commands, the environment and what was replaced). They are derivatives, not
the bytes Vibe wrote.

| fixture | evidence run |
|---|---|
| entries-first-call.json | m0-first-call/stdout.json |
| entries-tool-completed.json | m8-ask-tool-refusal/stdout |
| entries-tool-denied.json | m10-ask-write/stdout |
| streaming-first-call.ndjson | m1-streaming/stdout |
| export-finished.json | m0-first-call/export.json |
| export-usage-error.json | m3-unknown-model/export.json |
| export-infrastructure-failure.json | m4-env-api-key/export.json |
| export-deadline.json | m5-time-limit/export.json |
| export-token-limit.json | m7-max-tokens/export.json |
| export-turn-limit.json | m9-whoami/export.json |
