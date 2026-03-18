# TRPG MVP Scenarios

This directory contains machine-readable scenario templates and API contract examples for the TRPG runtime.

## Files

### Social Experiments (Game Theory)
- `scenarios/negotiation-v1.json` — Triple-faction ceasefire negotiation
- `scenarios/rumor-propagation-v1.json` — Cathedral rumor diffusion
- `scenarios/trust-public-goods-v1.json` — Sanctioned commons game

### Narrative / Character
- `scenarios/grimland-prologue-v1.json` — Fantasy RPG baseline (uses existing viewer assets)
- `scenarios/identity-erosion-v1.json` — Extreme archetype dinner party, trait drift measurement
- `scenarios/conformity-pressure-v1.json` — Asch conformity paradigm with AI agents

### Mystery
- `scenarios/the-room-v1.json` — Locked room exploration

### Contracts
- `openapi.yaml` (runtime-aligned API + MCP parity contract)

## Scenario Schema (MVP)

Each scenario file follows this shape:

```json
{
  "id": "scenario-id",
  "title": "Human readable title",
  "type": "negotiation|rumor|trust",
  "roles": [],
  "runtime": {},
  "state_machine": [],
  "metrics": [],
  "viewer": {},
  "stop_conditions": []
}
```

## Notes

- Scenarios are engine-level assets; they do not modify MASC core behavior.
- Viewer should render from event/state responses, not scenario files directly.
- Keep scenario JSON deterministic (fixed seed) for reproducible experiments.
- OpenAPI request fields use `snake_case` and match MCP tool schemas in `lib/tool_trpg.ml`:
  - `masc_trpg_dice_roll` <-> `POST /api/v1/trpg/dice/roll`
  - `masc_trpg_turn_advance` <-> `POST /api/v1/trpg/turns/advance`
  - `masc_trpg_stream` <-> `GET /api/v1/trpg/stream`
  - `masc_trpg_round_run` <-> `POST /api/v1/trpg/rounds/run`
