# RFC-AC-017: Coordinator-Shape Leak in the Public SDK Surface

| Field | Value |
|---|---|
| Status | Completed |
| Author | jeong-sik |
| Created | 2026-05-12 |
| Updated | 2026-05-25 |
| Target | `agent_sdk` |

## Summary

This RFC tracked accidental coordinator-shaped SDK surface area. The current
SDK keeps runtime protocol and proof surfaces generic and removes the old
domain-specific projection/schema layer from agent_core.

## Current State

- The historical standalone domain module is gone.
- The public runtime protocol no longer exports the old projection event family.
- Runtime output schema catalogs no longer list the removed projection schema.
- Downstream product domains must publish their own domain events instead of
  using agent_core as a shared-state or UI-event substrate.

## Acceptance

The RFC is complete when `lib/`, `test/`, `README.md`, and live schema catalogs
do not expose the retired domain projection API. Historical audit artifacts may
still explain why earlier surfaces were removed.
