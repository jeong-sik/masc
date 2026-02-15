# TRPG MVP Scenarios

This directory contains machine-readable scenario templates for the external TRPG Engine.

## Files

- `scenarios/negotiation-v1.json`
- `scenarios/rumor-propagation-v1.json`
- `scenarios/trust-public-goods-v1.json`
- `openapi.yaml` (engine API contract draft)

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
- DM can run in `keeper` or `human` control mode (`dmControl` in room create API).
