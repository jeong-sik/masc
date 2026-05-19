---
rfc: "0093"
title: "Board persistence — path unification (snapshot vs append)"
status: Draft
created: 2026-05-17
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0077", "0042", "0062"]
implementation_prs: [15711]
---

# RFC-0093 — Board persistence: path unification

Status: Draft
Author: jeong-sik (vincent)
Date: 2026-05-17
Related: RFC-0077 (write-side silent failure typed propagation — caller side), RFC-0042 (closed sum), RFC-0062 (typed `Tool_result.t`).

## 0. Background

This RFC closes the **A1+D1 P0** that the 2026-05-16 board-repetition taxonomy left as "RFC 필요" (`~/me/knowledge/research/2026-05-16-masc-board-repetition-taxonomy.md`, iter 1–9). H1-A model attribution was merged (PR #15578), but A1 — duplicate JSONL appends in `board_posts.jsonl` — was deferred pending an architectural decision this RFC makes.

Production measurement that triggered this RFC (2026-05-17):

- `<base-path>/.masc/board_posts.jsonl`: most-recent 100 posts contain 13 unique ids with duplication counts up to 5× (5/5/4/3/3/3/2/2/2/2).
- `<base-path>/.masc/board_comments.jsonl`: 1844 lines (+355 over 24 h).
- Repetition pattern persists despite content-dedup logic at `board_core.ml:640-714` (`Dedup_hit` path).

## 1. Problem

`lib/board_core.ml` and `lib/board_votes.ml` together implement **two persistence paths for `board_posts.jsonl`** with no architectural decision recorded for which is canonical:

| Path | Location | Semantics |
|---|---|---|
| **P1: Append-on-mutation** | `board_votes.ml:923-925` `List.iter append_post posts` inside the dirty-flush closure | Each vote/mutation appends the *latest* post body again. JSONL grows one line per mutation per post, all sharing the same `.id`. |
| **P2: Snapshot rewrite** | `board_votes.ml:840-848` `save_jsonl_snapshot ~where:"rewrite_posts"` driven by `board_core.ml:413` `posts_jsonl_unlocked` + `:423` `save_posts_jsonl` | Writes the entire in-memory store as JSONL, atomically replacing the file. |

`append_post` itself (`board_core.ml:488-496`) is a single-line file append with no idempotency check; correctness relies on **all** callers having done dedup beforehand. The content-dedup at `board_core.ml:640-714` only guards the *create* path. The mutation/vote flush (`board_votes.ml:923-925`) calls `append_post` directly, bypassing dedup, on every flush window.

Concrete consequence: a post receiving 5 votes ends up in `board_posts.jsonl` as 5 lines with the same id, growing the file linearly in mutation count, distorting any line-count metric, and forcing readers to deduplicate by id at load time.

## 2. Root cause (architectural)

The repository has never decided what `board_posts.jsonl` *is*:

- If it is a **snapshot file** (latest state, one line per post), P1 violates the invariant.
- If it is an **event log** (each line = create/mutation event, latest wins on read), P2 erases history.

Both behaviors are present in the codebase. Each individual path is internally consistent; the system as a whole is not. This is exactly the class of fault the CLAUDE.md *워크어라운드 거부 기준* §3 ("Abstraction 부재 admits N-of-M") tracks — two implementations of the same concept admitted side by side.

## 3. Options considered

### Option A — Idempotent `append_post` (read last N lines, skip on id match)

Add a duplicate-id check inside `append_post`. **Rejected**: O(N) per write, race-prone, and treats the symptom (dup writes) instead of the architectural question (which path is canonical).

### Option B — Define `board_posts.jsonl` as an event log

P1 becomes canonical; readers fold by id taking the latest line. **Rejected**: file size grows unbounded with mutation traffic (the very vote/mutation pattern measured above), and snapshot tooling (`save_jsonl_snapshot`) is already in production and used by restart-load (`board_votes.ml:863, 878`) which assumes one-line-per-post semantics.

### Option C — Split into `posts.jsonl` (create-only) + `post_mutations.jsonl` (event log)

Event sourcing proper. Cleanest semantically. **Rejected for scope reasons**: requires reader-side merge, schema migration of `<base-path>/.masc/`, and contracts for every existing tool that reads the file. Outside what a single architectural-decision RFC should ship.

### Option D — Snapshot rewrite is canonical; `append_post` becomes internal-only

`save_jsonl_snapshot` / `posts_jsonl_unlocked` are already the durable-load source (`board_votes.ml:863, 878` `load_persisted_posts`). Make them the single writer. `append_post`:

- Stays as an internal helper for the *initial create* path (`board_core.ml:728 with_persist_lock (fun () -> append_post post)`) where the post is genuinely new and the dedup gate above guarantees uniqueness.
- The mutation/vote flush (`board_votes.ml:923-925`) switches from `List.iter append_post posts` to a single `save_jsonl_snapshot` of the full store. One flush = one full rewrite.

**Recommended.** Smallest delta, reuses code already in production, eliminates the dup vector at its source.

## 4. Recommendation

Adopt **Option D**. `board_posts.jsonl` is a snapshot file. `save_jsonl_snapshot` is the canonical writer for state changes. `append_post` is retained as a low-overhead fast-path for genuinely-new posts only.

### Invariants after adoption

1. Every line in `board_posts.jsonl` corresponds to a unique `post.id`.
2. Mutations (vote, edit, reply count) produce zero new lines; they trigger a full snapshot rewrite on the next flush window.
3. `load_persisted_posts` may continue to assume one-line-per-id and stop deduplicating defensively (separate cleanup, not part of this RFC).

## 5. Migration

Single PR, no schema change to existing JSONL files (readers tolerant of duplicates today).

| Step | Change | File |
|---|---|---|
| 1 | Replace `List.iter append_post posts` with `save_jsonl_snapshot ~where:"flush_posts" ~path:(persist_path ()) (posts_jsonl_snapshot store)` | `board_votes.ml:923-925` |
| 2 | Mirror for `comments` if same pattern exists (verify; current grep shows `append_comment` once, same line) | `board_votes.ml:925` |
| 3 | Add doc comment on `append_post` (`board_core.ml:488`) stating *"create-only fast path; vote/mutation flushes MUST use `save_jsonl_snapshot`"* | `board_core.ml` |
| 4 | One-shot cleanup: rewrite existing `<base-path>/.masc/board_posts.jsonl` once via the same snapshot path at server startup if duplicate ids detected. Behind a flag `MASC_BOARD_DEDUP_ON_LOAD=1`. | `board_votes.ml` `load_persisted_posts` |

Test plan:
- Inline: vote-storm scenario — N votes on one post → assert `wc -l board_posts.jsonl` does not grow.
- Restart: existing dup file loads cleanly, single rewrite normalizes.

## 6. Evidence

- Code:
  - `lib/board_core.ml:488-496` — `append_post` (single append, no idempotency)
  - `lib/board_core.ml:413, 423, 435` — snapshot generators
  - `lib/board_core.ml:640-714` — content-dedup (create path only)
  - `lib/board_votes.ml:462-486` — `load_persisted_posts`
  - `lib/board_votes.ml:751` — `posts_jsonl_snapshot`
  - `lib/board_votes.ml:840-848` — `save_jsonl_snapshot ~where:"rewrite_posts"` (Path P2 already implemented)
  - `lib/board_votes.ml:923-925` — **dirty-flush dup vector (Path P1)**
- Data:
  - `<base-path>/.masc/board_posts.jsonl` 2026-05-17 04:23 measurement (13 unique ids in last 100 posts, max 5×)
- Prior analysis: `~/me/knowledge/research/2026-05-16-masc-board-repetition-taxonomy.md` (worktree `~/me/.worktrees/masc-board-taxonomy`, 9 iter, A1+D1 marked "RFC 필요" — this RFC).

## 7. Risks

- Snapshot rewrite is O(post_count) per flush window. Current store size measured at ≤ 200 posts; rewrite cost negligible. Re-evaluate if post_count exceeds 10k.
- Atomic rename behavior of `save_jsonl_snapshot` must be verified (currently uses temp file + rename; assumed atomic on POSIX, separately).
- Reader code in dashboards that does its own dedup-by-id can be relaxed in a follow-up; not blocking.

## 8. Related work

- RFC-0077 (Draft) — write-side silent failure typed propagation. Adjacent but distinct: RFC-0077 forces callers to *receive* write failures; RFC-0093 ensures there is *one* write path to receive failures from.
- RFC-0042 — closed sum / typed variants.
- CLAUDE.md *워크어라운드 거부 기준* §3 (Abstraction 부재 admits) — this RFC closes one such admission.
