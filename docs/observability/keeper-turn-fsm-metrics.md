---
status: historical
last_verified: 2026-07-13
---

# Historical Keeper turn-FSM metrics

The former transition vocabulary combined observations with phase gates,
completion contracts, livelock refusal, resource admission, and terminal
dispositions. Those labels and their line-level wiring table are not a current
runtime contract.

Current observability records each turn, OAS attempt, tool call, Gate request,
effect result, and correlation/provenance without deriving Keeper
authorization or lifecycle state. Consult the generated runtime schemas and
`docs/spec/04-turn-lifecycle.md`; do not restore labels from this historical
document.
