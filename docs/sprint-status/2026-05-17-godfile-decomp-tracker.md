# Godfile Decomposition Sprint Status — 2026-05-17

Companion to RFC-0056 (incremental leaf extraction) and RFC-0086
(bulk namespace promotion). This note captures the state of two
parallel split tracks after winner squashes absorbed their sibling PRs.

## Tracks closed by winner absorption

### `server_dashboard_http_keeper_api_types` track
Winner: #15595 (commit `de21b7dccc`, "keeper name validation
helpers → server_dashboard_http_keeper_api_types").

Absorbed split (closed): #15593 (`server-dashboard-keeper-api-types-split`).

Diff measurement: PR's added lines vs `origin/main` after winner
merge → `unique-vs-main=0` across all 4 files.

### `tool_shard_types` track
Winners: #15605 (commit `f2899c97f6`, "split enum SSOT mirrors +
shard type") and #15611 (commit `84385078a2`,
"coding_keeper_bridge_tools → tool_shard_types").

Absorbed splits (closed): #15606, #15607, #15608, #15609, #15610
(`tool-shard-types-split-2` through `-6`).

Diff measurement: PR's added lines vs `origin/main` → `unique-vs-main=0`
across `lib/tool_shard.ml`, `lib/tool_shard_types.ml`,
`lib/tool_shard_types.mli`.

## Remaining godfile decomposition surface

After this absorption sweep, `tool_shard.ml` sits at 1164 lines and
`server_dashboard_http_keeper_api.ml` at 3022 lines. Further splits
follow the same winner-squash pattern: a single PR moves a coherent
group of helpers/types to `*_types.ml`, after which any incremental
split PRs targeting the same destination file collide as add/add
semantic conflicts.

## Operational note for future splits

When a winner merges into `main` and absorbs its sibling PRs:

1. Run an absorption check (per-file `pr_added_lines` not in main).
2. If `unique-vs-main=0` across all touched files, close siblings
   with a comment referencing the winner commit.
3. Avoid manual rebase of siblings — the rebase will produce only
   noise (lines already present in main) and `git rebase` may flag
   line-level conflicts where the winner already moved the same code.

This pattern lets a sprint progress without leaving stale CONFLICTING
PRs in the queue.
