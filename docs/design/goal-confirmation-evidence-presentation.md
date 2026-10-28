---
status: draft
---

# Goal Confirmation Evidence Presentation

> Status: Draft — opinions requested on the MASC board
> Date: 2026-10-28
> PRs: #46508 (step 1)
> Tasks: task-2792

## The decision the screen serves

To confirm a proven completion, the operator needs five answers:

1. **Cause** — why this goal exists, what it set out to change
2. **Contract** — what was agreed to count as success (metric, target)
3. **Work** — what was actually done
4. **Evidence** — what the verifier was shown, and what it answered
5. **Presentation** — whether contents, links, images and diagrams reach the
   operator legibly

## Current state, measured against those five

| Question | Data model | On the confirmation screen |
|---|---|---|
| Cause | No field. The goal record is `title/metric/target/due/priority` (`lib/goal/goal_store.mli:33`). | Absent |
| Contract | `metric` + `target_value` at declaration. No declared evidence kind. | The `Target` row (since #46508) |
| Work | Linked task/lane events (goal timeline), actual measurement. | Summary rows (`RELATED ACTIVITY`), `Actual` |
| Evidence | Two layers: the verdict paragraph (`verdict.evidence : string`) and the submitted originals (`submitted_evidence_item`). | Verdict paragraph only. The originals are on the wire and dropped by the TUI decode |
| Presentation | Binary originals carry `format/sha256/bytes` metadata only. | URLs render as plain text; inline images/diagrams are not a terminal capability |

## The originals are one decode away

The confirmation read (`GET /api/v1/goals/confirmation`, `server_routes_http_routes_verification.ml:216`) returns `record_to_yojson_for_goal`, whose `submitted_evidence` is the metadata projection (`workspace_verification_snapshot.ml:419`):

- `collaboration` → reference, sha256, bytes, `content_omitted: true`
- `note` → bytes (no content)
- `artifact` → reference, bytes, truncated
- `artifact_binary` → reference, bytes, sha256, format
- `artifact_unreadable` / invalid → reference, reason

`Masc_tui_planning_detail.decode_confirmation` reads only `completion` from that object. `masc.masc_workspace` — which owns the item decoder — is already inside the stanza's dependency closure through `masc.masc_goal`, so reading the list adds no new library weight.

## Steps

1. **Done — #46508.** Readability of what already arrives: instruction /
   promise / binding / evidence layers, three tones, aligned labels; while a
   proof waits, the timeline moves behind the goal summary.
2. **Submitted originals list.** Decode the metadata list already on the wire
   and render it under the evidence paragraph (`artifact run.log · 12.4 KB ·
   truncated`, `binary screen.png · png · 1.2 MB · sha256 ab12cd34…`,
   `collaboration board:1234 · sha256 ab12cd34…`). The list goes after the
   evidence paragraph so the presented-frame receipt keeps meaning "the end of
   the block". An empty list draws nothing. No server change.
3. **Reach the original.** An open action on artifact rows through the
   existing artifact channels, an open action for URLs, integrity meta
   (sha256 prefix, bytes, truncated) always visible. Inline image or diagram
   rendering is not a terminal capability; "rich" here is defined as *the
   original is one action away, with its identity shown*.
4. **RFC — goal intent.** A `why` field on the goal record. This is a schema
   decision (hard cut vs. migration) and a question of who writes the
   sentence at creation, so it is an RFC, not a PR.

## Questions asked on the board

1. Step 2 renders metadata only because that is what the wire carries. Are
   content previews (first line of a note/artifact) wanted enough to justify
   the server change?
2. sha256 display: full value, or the first 8–12 cells with the full value
   one action away?
3. Is the intent RFC (step 4) wanted? If yes, who writes the why at goal
   creation — the requesting operator, the keeper that files the goal, or
   both?
4. Does "one action to the original" satisfy what you need, or do you need a
   dashboard/HTML view for image-heavy evidence?

## Verification per step

- Step 2: decode tests over every metadata variant (including
  `artifact_unreadable` and invalid references), render rows per kind, and
  the receipt test updated so the last row of the block is the last submitted
  original when the list is non-empty.
- Step 3: same, plus action wiring tests; no behavior change on
  non-confirmation surfaces.
