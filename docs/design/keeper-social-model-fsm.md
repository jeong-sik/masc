# Keeper Social Model FSM

**Status**: Draft  
**Date**: 2026-04-15  
**Scope**: Keeper social-model abstraction and implementation contract  
**One sentence**: Promote `social_model` from a runtime tag into a real model-specific FSM dispatch surface.

## Why This Exists

Today `social_model` is persisted in keeper runtime state and appears in social headers and dashboard views, but production behavior is still effectively hard-wired to the `bdi_speech_v1` path. That makes `social_model` look like a configurable axis without giving it a true implementation boundary.

This document freezes the intended contract before further implementation work.

Related issue:

- `#7362` — Architect keeper `social_model` as model-specific FSM implementations

## Current State

### What is real today

- keeper creation persists `social_model` into keeper runtime state
- unified turn paths propagate `SOCIAL_MODEL`, `BELIEF_SUMMARY`, `ACTIVE_DESIRE`, `CURRENT_INTENTION`, `BLOCKER`, `NEED`, `SPEECH_ACT`, and `DELIVERY_SURFACE`
- the active baseline is `bdi_speech_v1`
- a first-class `social_model -> implementation` registry dispatches between production modules
- `magentic_ledger_v1` now exists as a second implementation path to validate the abstraction

### What is not real yet

- `social_model` ownership is still runtime-centric rather than persona-default + override + snapshot
- richer per-model state typing is still hidden behind the shared adapter surface

## Terminology

- `social_model`
  - Which social-state machine a keeper uses.
- `social input`
  - The normalized observation bundle that drives a social-model transition.
- `social state`
  - The model-specific state carried across turns.
- `social output`
  - The outward routing decision produced by a transition.
- `speech_act`
  - A typed component of social output.
- `delivery_surface`
  - Where that social output should be routed.

## Contract

Each social model must implement the same high-level contract:

```ocaml
type input
type state
type output

val transition : state -> input -> state * output
```

The exact types do not need to be identical across implementations at the internal OCaml level, but the registry boundary must make these concepts explicit.

## Minimum Input Surface

Every social model must be able to reason over a normalized observation bundle that can include:

- pending mentions
- board and room activity
- task availability / assigned task state
- blocker signals
- recent visible tool evidence
- quiet-room / idle context
- worktree or file-change hints when relevant

Models may ignore fields they do not use, but the adapter layer should expose a stable superset.

## Minimum Output Surface

Every social model must be able to emit:

- `speech_act`
- `delivery_surface`

It may also emit:

- belief summary fields
- accountability / explanation metadata
- fallback reason
- transition reason

## Registry Rule

`social_model` must select a concrete implementation through a single registry or adapter layer.

Allowed behavior:

- known value -> dispatch to the matching implementation
- unknown value -> explicit fail-fast or explicit fallback to `bdi_speech_v1`

Disallowed behavior:

- silently treating any unknown value as "same as current default" without recording why
- bypassing the registry and directly calling model-specific logic from random turn code

## Baseline Model

### `bdi_speech_v1`

`bdi_speech_v1` is the current baseline and the first model that must be extracted behind the FSM contract.

Its state is expected to at least cover:

- belief
- active desire
- current intention
- blocker
- need

Its output is expected to at least cover:

- `speech_act`
- `delivery_surface`

Existing heuristics currently spread across keeper social-state parsing / formatting code should move behind this implementation boundary.

## Ownership

Current reality:

- `social_model` is stored in keeper runtime state

Open design question:

- should `social_model` remain runtime-only
- or become persona default + keeper override + runtime snapshot

Constraint:

- until multiple production implementations exist, `social_model` should not be treated as a rich user-facing tuning axis

## Roadmap

### Phase 0 — Freeze the contract

- define this document as the social-model contract SSOT
- update inventory docs to distinguish active baseline vs documented candidates

### Phase 1 — Extract interface and registry

- create a dedicated social-model module boundary
- move dispatch behind a single registry
- codify unknown-model behavior

### Phase 2 — Extract `bdi_speech_v1`

- move current heuristics into a first-class implementation
- keep adapter compatibility for existing header surfaces

### Phase 3 — Align ownership and observability

- decide canonical owner for `social_model`
- expose active model + recent transition reason in dashboard/status APIs

### Phase 4 — Add a second implementation

- recommended first candidate: `magentic_ledger_v1`
- alternative: `reaction_identity_v2`

### Phase 5 — Prove the abstraction

- unit tests for per-model transitions
- integration tests for unified turn dispatch
- explicit unknown-model tests

## Acceptance Criteria

- `social_model` selects a real implementation path
- `bdi_speech_v1` exists as an isolated implementation module
- at least one second implementation exists in production code
- unknown-model behavior is explicit in code, tests, and docs
- dashboard/status surfaces can show active social model and recent transition context
