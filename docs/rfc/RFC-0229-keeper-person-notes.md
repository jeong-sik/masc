---
rfc: "0229"
title: "Keeper person notes: deliberate per-speaker memory beyond the log window"
status: Draft
created: 2026-06-11
updated: 2026-06-11
author: vincent
supersedes: []
superseded_by: null
related: ["0223", "0226", "0228"]
implementation_prs: []
---

# RFC-0229: Keeper person notes

Status: Draft · Re-entry of RFC-0223 §5 "person-note memory (roster v2)" · Keeper-authored, fold-at-read, no background writer
Drafted by: Claude Fable 5 (v2 follow-up session, 2026-06-11).

## §1 Problem

The roster a keeper sees is derived purely from retained chat rows —
"No store of its own — the chat log is the only source, so the roster
ages out with log retention" (`lib/keeper/keeper_surface_read.mli:5-6`).
The fold keeps id, latest display name, and last-seen
(`lib/keeper/keeper_surface_read.ml:54`):

```ocaml
let roster (lane : Store.chat_message list) : participant list =
  (* Hashtbl by speaker_id; latest non-empty name wins. *)
```

Two losses follow from "log window = identity memory":

1. A person the keeper talked to three weeks ago disappears from the
   roster when their rows age out of the window
   (`lib/keeper/keeper_chat_store.ml:297` caps retained primaries at
   100) — the "아는 사람 명부" forgets exactly the people one would
   keep a note about.
2. There is nowhere to put a fact *about* a person ("스토어 배포
   담당", "한국어 선호") — speaker rows carry only
   `{speaker_id; speaker_name; speaker_authority}`
   (`lib/keeper/keeper_chat_store.mli:50`), and RFC-0223 §5 explicitly
   deferred person-note memory to v2.

## §2 Principles

1. **Notes are deliberate keeper acts.** A note exists only because
   the keeper called a tool in a turn. No automatic extraction, no
   background enrichment — writing a note is the same class of action
   as posting a message (owner constraint: no standing machinery).
2. **Fold-at-read, append-only.** Storage is an append-only JSONL per
   keeper; the current note for a speaker is the last row, computed at
   read time — the same latest-wins fold the roster already uses. No
   in-place updates, no index.
3. **Notes attach to `speaker_id`,** the stable pseudonym (Discord
   snowflake / dashboard owner), never to display names — names change,
   ids don't (RFC-0223 P1).
4. **Keeper-private.** Notes surface only on the keeper's own pull
   tool and its dashboard transcript pane. They are not broadcast, not
   shared across keepers, and never echoed to external channels by the
   infrastructure (whether the keeper chooses to say what it knows is
   prompt/policy territory, RFC-0226 §5).

## §3 Design

### 3.1 Store

`.masc/keeper_person_notes/<keeper>.jsonl`, rows:

```json
{"speaker_id": "98791450001", "note": "스토어 배포 담당", "ts": 1781400000.0}
```

- `append_person_note ~base_dir ~keeper_name ~speaker_id ~note ()` returns a
  typed result. Write and decode failures remain observable to the calling
  Keeper turn; cancellation is re-raised unchanged.
- Empty `note` row = tombstone: fold yields "no note" (deletion
  without a delete operation).
- Read: latest-wins fold; file is keeper-scoped and grows with
  deliberate writes only, so a tail-bound like RFC-0226 P2 is not
  needed at v1 volume (revisit if measured otherwise).

### 3.2 Tools

- `keeper_person_note_set { speaker_id, note }` — write/overwrite
  (blank note clears). This is an ordinary Keeper-owned state mutation; this
  module assigns no risk class and owns no authorization policy.
- Read has **no new tool**: `keeper_surface_read` roster entries gain
  an optional `note` field, and participants with a note are included
  in the roster even when their chat rows aged out (union of
  log-derived roster and noted speakers — this is what fixes §1.1).

### 3.3 Dashboard

Roster pane shows the note text next to the participant (read-only,
v1). Editing from the dashboard is out of scope.

## §4 Phases

| Phase | Scope | Ships alone? |
|---|---|---|
| P1 | store + `keeper_person_note_set` + roster `note` field/union | yes |
| P2 | dashboard roster display | yes — render-only |

## §5 Non-goals

| Out | Why |
|---|---|
| Automatic note extraction from conversation | background non-determinism; violates principle 1 |
| Cross-keeper shared people directory | scope + privacy boundary; a keeper's notes are its own |
| Note history UI / versioning | append-only file already preserves history; surfacing it is not needed for v1 |
| Real-world identity resolution | `speaker_id` is a persistent pseudonym by design (RFC-0223) |

## §6 Workaround self-check (CLAUDE.md signatures)

- Telemetry-as-fix: no.
- String classifier: no — ids are opaque keys, no content matching.
- N-of-M: no.
- Cap/cooldown/dedup/repair: none; tombstone-by-blank reuses the
  append-only fold instead of adding a delete path.
