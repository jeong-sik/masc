---
status: reference
last_verified: 2026-07-13
code_refs:
  - lib/config/
  - lib/fusion/
  - lib/fusion_core/
  - config/
---

# Configuration

> Part of: [SPEC-INDEX](./SPEC-INDEX.md)

## 1. SSOT and path boundary

Configuration is loaded from the selected `BasePath` and decoded into a typed,
immutable snapshot. There is one canonical key for each setting. Environment
variables do not duplicate ordinary product settings; they are reserved for
process-launch concerns that cannot live in the checked configuration and must
be documented at that boundary.

Unknown keys, invalid variants, unresolved references, and decode errors fail
explicitly. Reload builds and validates a complete new snapshot before an
atomic swap. On failure, the prior snapshot remains active and the error is
observable.

## 2. Boundary ownership

| Configuration | Owner | Rule |
|---|---|---|
| provider/model catalog and call features | OAS | generic; imports no MASC concept |
| runtime id and fallback membership | OAS config, referenced by MASC | MASC stores ids, not vendor branches |
| Keeper persona/world/runtime | MASC Keeper config | one immutable snapshot per Keeper cycle |
| Tool descriptors and schemas | registered tool modules | no parallel policy table |
| Gate mode and judge runtime | MASC Gate config | generic, no product/tool cases |
| Scheduler conditions | MASC Scheduler | explicit time/event expressions |
| Connector bindings | Connector config | typed external space identity |
| Fusion panel/Judge | Fusion config | explicit members and runtime ids |

Checked-in constants are preferred when a value is an invariant rather than an
operator choice. Configurability is not added speculatively.

## 3. Keeper runtime selection

A Keeper names a runtime id resolved through the OAS catalog. Fallbacks are an
explicit ordered runtime membership, not a health tier, score, failure count,
or vendor-specific branch. Provider outcomes are recorded and returned to the
Keeper/LLM; MASC does not turn them into cooldown or admission policy.

Runtime declarations describe capabilities reported by OAS, including text,
tool use, reasoning/thinking, multi-turn, image/audio/voice, streaming, and
structured output. MASC must not guess these features from model-name strings.

## 4. Gate modes

Gate configuration is deliberately small:

```text
mode = Always_allow | Auto_judge | Manual
judge_runtime = <runtime-id>   # required only for Auto_judge
```

- `Always_allow` dispatches after the owning domain's objective invariants.
- `Auto_judge` calls the configured LLM and persists verdict, rationale,
  provenance, and correlation.
- `Manual` persists nonblocking HITL and returns `Deferred`.

Configuration contains no risk hierarchy, risk score, privileged actor,
product-specific credential/repository case, tool-name allowlist, or automatic
Keeper pause/stop. Gate mode is not a second tool catalog.

## 5. Scheduler and Connector

Scheduler entries contain an explicit typed time/event condition, target
Keeper, and stimulus payload. Triggering appends to that Keeper's durable lane.
A busy Keeper keeps the item queued; Scheduler does not skip or pause it based
on an idle score, cooldown, fleet pressure, or recent activity.

Connector entries bind a connector implementation to an explicit external
space and channel identity. Secrets/credentials remain at the connector's
credential boundary. Core MASC configuration does not recognize Discord,
GitHub, or another product in authorization logic.

## 6. Fusion

Fusion configuration declares panel members and a Judge runtime explicitly.
Each member result or failure is durable; the Judge receives the complete
available evidence asynchronously. There is no minimum response quorum,
majority authority, fixed concurrency budget, token budget, or semantic timeout
formula. Completion wakes the originating Keeper lane.

Judge-of-Judges is composition of the same Fusion/Tool boundary, not a new
hierarchy.

## 7. Observability

Every loaded snapshot has a stable revision and source path. Reload success and
failure, runtime resolution, Gate mode, Scheduler trigger, Connector binding,
and Fusion member/Judge selection are recorded with correlation and provenance.
Secrets are redacted at the typed secret boundary, not by substring matching.

## 8. Required invariants

- `INV-CONFIG-001`: one canonical key and one typed owner per setting.
- `INV-CONFIG-002`: all paths derive from `BasePath`.
- `INV-CONFIG-003`: reload is validate-then-atomic-swap.
- `INV-CONFIG-004`: OAS remains free of MASC concepts.
- `INV-CONFIG-005`: Tool descriptors are the tool-surface SSOT.
- `INV-CONFIG-006`: semantic Gate decisions use the configured LLM.
- `INV-CONFIG-007`: no config value automatically pauses/stops a Keeper.
- `INV-CONFIG-008`: Scheduler, Connector, Fusion, and Gate failures are local
  and observable.
