# Anthropic thinking prefix repair

The reported Vincent Sonnet 5.5 failure is reproducible without private Keeper
content. A request-only context block disappeared before the next response was
replayed, so its signed thinking referred to a prefix the next request omitted.

## Direct evidence

- `diagnosis.json` compares glossary-maniac provider-input snapshots
  `trace-1789798320664-00001#2326` and `#2327`: system and tools match; the previous
  context blob is absent from the next request. Its stored SHA-256 was verified.
- `live-probe.jsonl` uses the Vincent credential with a fresh arithmetic
  conversation. Preserving context returns 200 with no transformations.
  Removing it returns 400. The same edited request with the official binding
  control returns 200 and reports `prefix_binding_mismatch`, both synchronously
  and in a stream that reaches `message_stop`.
- `probe.py` reproduces the API experiment. It prints only status, block types,
  and transformation paths/reasons. No key, thinking text or signature is stored.
  An earlier 2,048-token sample produced no complete thinking/tool pair and was
  inconclusive; the recorded run uses 8,192 output tokens.

These API experiments establish the provider contract; they do not execute the
modified OCaml runtime. The observed runtime binary was
`6eb08ef187f64edcc1e3ae36637fb11879d2d843`.

## Change and boundaries

Anthropic collection now retains the fresh context actually returned by the
caller projection, atomically with the assistant response. Its historical
provenance distinguishes it from the next request's current context. Removed
or redacted context cannot reappear through persistence. Historical carriers
remain ordinary windowable history and do not double-count current prompt
metrics. Other providers keep their current request-only injection policy.

Adaptive Sonnet/Haiku 5.5 completion requests enable the official
`thinking-binding-controls-2026-08-01` beta and `drop_block`. This handles
intentional prefix changes, such as context-window movement, tool-result
demotion and tool-schema changes, using the provider's actual signature check.
It does not make lost reasoning available again. Provider transformation
records are logged without reasoning contents. `between_tools`, disabled,
implicit thinking, Kimi and count requests do not acquire this control.
The separately frozen exact-output generation headers include the beta;
its derived count request excludes the completion-only binding control.

This is a bounded incident repair. It does not implement RFC-AC-041's complete
client prefix ledger, server-side compaction, or typed discrimination of
non-size 400 responses. Issues #42636 and #42632 therefore remain open. Unlike
using `drop_block` alone, preserving context fixes the edit in ordinary tool
rounds; intentional edits still have an observable reasoning-loss boundary.

## Verification

OCaml parsing and `git diff --check` passed. Added/extended behavioral cases
cover projected context retention, removal/redaction, checkpoint message
roundtrip, historical context metrics/window behavior, completion headers,
count exclusions and frozen exact-output dispatch. These require CI execution;
local Dune builds/tests were not run under the repository execution protocol.

Official provider contract, read 2026-10-13:
- https://platform.claude.com/docs/en/build-with-claude/preserved-thinking
- https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting

Rollback is a revert of this change. No runtime state or credential settings
were manually rewritten during the investigation.
