# task-214 Design: Typed Provenance Relation for `evidence_refs`

## Problem

Recent task submissions (task-209 ~ task-212) were rejected with `artifact_unreadable` because the reviewer sandbox lacks a `repos/masc` checkout. The current verification gate can detect *that* an artifact is missing, but it cannot tell *why* the artifact was needed. This makes it impossible for the gate to classify failures as:

- **agent-remediable**: the keeper submitted a wrong path or forgot to commit a file.
- **infrastructure**: the reviewer sandbox simply cannot see the producer sandbox.

Without this classification, keepers get stuck in a `reject → release → reclaim → resubmit` loop even when the root cause is outside their control.

## Goal

Allow task producers to attach a lightweight **provenance relation** to each `evidence_refs` entry, so reviewers can see the intended purpose of each artifact/note and use it as a classification hint.

## Proposed Syntax (backward-compatible)

Keep `evidence_refs` as a `string list`. Extend the existing `artifact:` and `note:` reference forms with an optional `:<relation>:<context>` suffix.

```text
artifact:path/to/file.ml
artifact:path/to/file.ml:depend-on:task-211-grandchild-reach
note:this is a note
note:this is a note:explains:why-no-commit-hash
```

Rules:
- `artifact:` prefix is mandatory.
- The path is the first colon-delimited segment after `artifact:`.
- If two more colon-delimited segments follow, they are `<relation>` and `<context>`.
- Any other shape is `invalid_reference` (existing behavior).
- `note:` follows the same pattern; the note body is the first segment.

Rationale for colon delimiter:
- `evidence_refs` is already a string list with `artifact:` / `note:` prefixes.
- Colons are rare in Unix paths, so practical ambiguity is low.
- No type or schema change is needed in `keeper_task_done` / `masc_transition`, keeping the blast radius small.

## Relation Vocabulary (minimal)

Start with two relations:

| Relation | Meaning | Example context |
|----------|---------|-----------------|
| `depend-on` | Artifact is required to evaluate the task claim. | `task-211-grandchild-reach` |
| `explains` | Note explains a decision or blocker. | `verification-blocked-by-runtime` |

Future relations can be added without schema changes: `support`, `derive`, `contradict`, etc.

## Data Model Changes

In `lib/workspace/workspace_verification_store.ml`:

```ocaml
type evidence_relation = {
  relation : string;
  context : string;
}

type submitted_evidence_item =
  | Evidence_note of
      { note : string
      ; provenance : evidence_relation option
      }
  | Evidence_artifact of
      { reference : string
      ; path : string
      ; provenance : evidence_relation option
      ; content : string
      ; bytes : int
      ; truncated : bool
      }
  | Evidence_invalid_reference
  | Evidence_artifact_unreadable of
      { reference : string
      ; path : string
      ; provenance : evidence_relation option
      ; reason : evidence_read_failure
      }
```

- `reference` keeps the original raw string for audit/debugging.
- `path` keeps the parsed producer-relative path (for `artifact:`) or body (for `note:`).
- `provenance` carries the optional relation/context pair.

## Parsing

Add a helper:

```ocaml
let parse_reference raw ~prefix ~extract_path =
  (* strip prefix, then split first segment from optional relation/context *)
```

Implementation sketch:

```ocaml
let split_reference raw prefix_len =
  let rest = String.sub raw prefix_len (String.length raw - prefix_len) in
  match String.split_on_char ':' rest with
  | [ path ] -> (path, None)
  | [ path; relation; context ] -> (path, Some { relation; context })
  | _ -> invalid
```

For `note:`, the first segment is the note body; the same suffix logic applies.

## Wire Format Changes

Update `submitted_evidence_item_to_yojson` / `of_yojson` to include optional `relation` and `context` fields.

Example JSON:

```json
{
  "kind": "artifact",
  "reference": "artifact:lib/process/bg_task.ml:depend-on:task-211-grandchild-reach",
  "path": "lib/process/bg_task.ml",
  "relation": "depend-on",
  "context": "task-211-grandchild-reach",
  "content": "...",
  "bytes": 1234,
  "truncated": false
}
```

If `relation` is absent, old consumers treat it as implicit `depend-on`.

## Verification Gate Usage

The completion authority prompt can now include provenance. Example addition to the review prompt:

```
Evidence provenance:
- lib/process/bg_task.ml (depend-on: task-211-grandchild-reach) — UNREADABLE: missing
```

This lets the authority decide:
- If the artifact is `depend-on` the core claim and unreadable, reject.
- If the artifact is `explains` a blocker and unreadable, the task may still be classifiable as infrastructure-blocked.

Out of scope for this task: automatic classification. The relation is only a **hint**.

## Backward Compatibility

1. Producers can still submit plain `artifact:path` and `note:text`; they are interpreted as implicit `depend-on` for artifacts and `explains` for notes.
2. The `evidence_refs` field in `task_handoff_context` remains `string list`.
3. Existing verification snapshots without `relation`/`context` decode as `None`.
4. No MCP tool schema changes are required.

## Test Plan

1. Unit tests for `split_reference` covering:
   - plain `artifact:path`
   - `artifact:path:relation:context`
   - `note:text:explains:context`
   - invalid shapes (too many/few segments)
2. Round-trip test for `submitted_evidence_item_to_yojson` / `of_yojson`.
3. End-to-end test verifying that a task submitted with provenance-bearing refs produces a verification snapshot containing the relation fields.
4. Backward-compat test: old `artifact:path` refs still produce the same snapshot shape when relation is absent.

## Files to Touch

- `lib/workspace/workspace_verification_store.ml` — core parser, types, JSON.
- `lib/completion_authority_agent.ml` — include provenance in review prompt / notes.
- `lib/tool_surface/tool_shard_types_schemas_taskboard.ml` — update help text/examples for `evidence_refs`.
- `test/test_workspace_verification_store.ml` (or new test file) — parser + round-trip tests.

## Open Questions

1. Should relation/context be required for new submissions after a transition period? Probably not until a future breaking change.
2. Should the context be free-form text or a structured ID (task-id, post-id, etc.)? Start free-form; validation can be added later.
3. How does this interact with cross-verifier lane artifact path resolution? The relation does not change path resolution; it only adds metadata.

## Status

Design complete. Implementation blocked until `oas_discovery_unavailable` runtime outage and code-reviewer sandbox `repos/masc` checkout issue (task-213) are resolved.
