# Usage measurement boundaries

AgentCore `Types.usage_stats` holds known subtotals over processed provider
responses. `api_calls` counts those responses, including responses with no usage
payload; it is not an all-attempt dispatch counter. `missing_usage_responses`
counts absent whole payloads independently of the first `pricing_gap`.

A reported zero and an absent payload are different observations. Missing usage
preserves all existing subtotals, increments the missing count and records
`Usage_not_reported` when no earlier pricing diagnostic exists. A later priced
response does not erase that gap. Cost telemetry must be read with both missing
coverage and pricing diagnostics; the amount alone is not a complete bill.

`PreToolUse.usage` carries the actual aggregate as `Some`. An official-client
host without an aggregate observation sends `None`, rather than a zero-cost
number. This is the same state available through Agent state and checkpoint
serialization, not a second independent spend tracker.

Payload presence does not establish per-field reporting. The integer per-response
API can still contain parser defaults. Partial-field absence, reported-versus-
estimated charge provenance, Keeper cumulative intervals and journal/UI coverage
remain separate required repairs. Keeper fleet/spend aggregates have their own
reading and attempt identities; these SDK counters do not replace them.

## Checkpoint format

The current exact format is v13. Usage metadata is required and must satisfy
`0 <= missing_usage_responses <= api_calls`; an absent payload requires a cost-gap
diagnostic. Missing metadata is refused, never backfilled as historically
complete reporting. Full snapshots and usage delta replacements share validation.

This is an unreleased-format cut under the constitution, with no converter or
implicit historical approval. Existing Keeper version-mismatch behavior treats
an older checkpoint as superseded, starts without its saved history, and permits
a subsequent save to rewrite the canonical file
`<base-path>/.masc/traces/<trace_id>/<trace_id>.json` with fresh v13 state. No manual
deletion is required. Therefore installing this
format can discontinue an existing continuation. Source publication and focused
tests do not authorize or prove an operational rollout; preserve that distinction
when selecting an installed candidate. This change performs no live reset,
checkpoint replacement, installation or server restart.
