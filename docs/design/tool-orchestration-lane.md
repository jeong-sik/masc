# Tool Orchestration Lane Design Note

Status: draft design note
Date: 2026-06-19

## Purpose

The tool orchestration lane gives MASC a durable, typed record of tool work before it introduces a scheduler or executor. The first slice only defines the data contract:

- `ToolJob`: an immutable envelope for one intended tool call.
- `ToolEvent`: append-only ledger events for job and batch lifecycle changes.
- Stable schema hashing for replay and compatibility checks.
- Conservative resource metadata that can later drive locking and fanout.

This slice is deliberately not an executor. It does not run tools, schedule batches, or acquire locks.

## Boundary

The lane belongs to MASC, not OAS. It may depend on neutral tool catalog and dispatch metadata, but it must not encode provider, model, transport, or runtime-specific behavior.

The durable ledger is also not a planner. When a tool contract does not provide typed resource keys, the fallback must be conservative:

- read-only tools default to no write resource keys.
- unknown or writer tools default to `write:any`.
- name prefixes are not a resource authority.

## P1 Contract

P1 establishes the following properties:

1. Missing optional fields in old ledger records decode as `None`.
2. Job and event identifiers can be supplied by tests and replay.
3. Fresh generated IDs are replay handles only, not semantic ordering.
4. Unregistered tool schema hashes include the tool name, avoiding empty-object hash collisions.
5. Event helpers enumerate known event variants instead of catch-all matching.

## Later Phases

P2 can add read-only batch execution behind a feature flag. P3 can add resource locks once real tool contracts provide typed resource keys. Replay should consume the ledger contract here rather than infer behavior from free-form tool names.
