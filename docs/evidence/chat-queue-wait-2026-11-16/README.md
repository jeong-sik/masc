# Chat operation queue wait, 2026-11-10 ~ 11-16

Retained records for `docs/rfc/RFC-a-keeper-takes-every-waiting-message-in-one-turn.md`.

## Source and environment

- Runtime data: the operator's `<base-path>/.masc` on 2026-11-16, read at 03:56Z.
- Server logs: `<base-path>/.masc/logs/masc-start-*.log`. Their timestamps are KST (UTC+9).
- Every read opens SQLite with `mode=ro` or reads JSONL files. Nothing was written to the runtime.

## Windows

| Name | UTC | Epoch |
|---|---|---|
| Earlier | 2026-11-10T00:48:28Z ~ 11-13T00:48:28Z | 1794271708 ~ 1794530908 |
| Later | 2026-11-13T00:48:28Z ~ 11-16T00:48:28Z | 1794530908 ~ 1794790108 |

## Files

| File | What |
|---|---|
| `chat_queue_split.py` | Per Keeper: received, waited, executions, wait, queued, idle, turn overlap, gaps. Definitions in its docstring. |
| `gap_causes.py` | Splits the gaps by cause windows given on the command line. |
| `runtime_by_window.py` | Direct turns per `runtime_profile` from the tool-call ledger. |
| `result-split-all-*.json` | `chat_queue_split.py` over every Keeper with a chat operation store. |
| `result-split-*.json` | The same over the seven review Keepers. |
| `gaps-2026-11-13..16.jsonl` | Every later-window idle interval that overlaps no turn, from `--gaps-out`. |
| `result-gap-causes-2026-11-13..16.json` | `gap_causes.py` over the later gaps. |
| `result-runtime-by-window.json` | `runtime_by_window.py` over the seven review Keepers. |

## Commands

```bash
cd docs/evidence/chat-queue-wait-2026-11-16
R="context-reviewer code-reviewer-uncle code-reviewer-father code-reviewer code-reviewer-sister code-reviewer-brother code-reviewer-mother"
ALL=$(cd ~/me/.masc/keepers && for d in */; do [ -f "$d/chat-operations.sqlite3" ] && echo "${d%/}"; done)

python3 chat_queue_split.py --base-path ~/me --since 1794530908 --end 1794790108 \
  --gaps-out gaps-2026-11-13..16.jsonl $R > result-split-2026-11-13..16.json
python3 chat_queue_split.py --base-path ~/me --since 1794271708 --end 1794530908 $R > result-split-2026-11-10..13.json
python3 chat_queue_split.py --base-path ~/me --since 1794530908 --end 1794790108 $ALL > result-split-all-2026-11-13..16.json
python3 chat_queue_split.py --base-path ~/me --since 1794271708 --end 1794530908 $ALL > result-split-all-2026-11-10..13.json

python3 gap_causes.py gaps-2026-11-13..16.jsonl \
  --cause disk_full_and_server_down '*' 2026-11-15T13:43:51Z 2026-11-15T17:06:02Z \
  --cause deploy_restart_cut_turns code-reviewer-brother,code-reviewer,context-reviewer,code-reviewer-uncle,code-reviewer-sister \
    2026-11-13T05:08:18Z 2026-11-13T06:31:04Z > result-gap-causes-2026-11-13..16.json

python3 runtime_by_window.py --base-path ~/me --since 1794271708 --mid 1794530908 --end 1794790108 $R \
  > result-runtime-by-window.json
```

In zsh, write `${=R}` and `${=ALL}` so the lists split into words.

## Results

All Keepers (`result-split-all-*.json`, `sum`):

| Window | Received | Wait h |
|---|---|---|
| Earlier | 765 | 14.2 |
| Later | 891 | 1,032.5 |

The seven review Keepers (`result-split-*.json`):

| Keeper | Received earlier → later | Started by read time / executions | Later wait h | Mean run min earlier → later |
|---|---|---|---|---|
| context-reviewer | 17 → 123 | 123 / 108 | 355.0 | 6.1 → 15.8 |
| code-reviewer-uncle | 320 → 111 | 102 / 96 | 226.9 | 2.7 → 11.0 |
| code-reviewer-father | 52 → 138 | 138 / 114 | 128.9 | 2.6 → 13.9 |
| code-reviewer | 155 → 115 | 115 / 101 | 121.9 | 3.0 → 13.0 |
| code-reviewer-sister | 60 → 93 | 92 / 79 | 98.6 | 2.6 → 18.7 |
| code-reviewer-brother | 42 → 117 | 116 / 107 | 38.9 | 1.8 → 12.7 |
| code-reviewer-mother | 42 → 87 | 87 / 82 | 24.9 | 2.3 → 17.4 |
| Sum | 688 → 784 | 773 / 687 | 995.1 | |

Later window, the seven review Keepers together:

| | Hours |
|---|---|
| Queued with no chat operation running (`idle_h`) | 81.0 |
| ... overlapping an autonomous turn | 31.1 |
| ... overlapping a direct turn | 32.6 |
| ... overlapping no turn (`idle_without_turn_h`) | 17.3 |

Turns: autonomous 1,183 / 155.6 h, direct 699 / 179.8 h. 86 of the 773 started operations ran inside another
operation's execution.

The 17.3 hours with no turn, by cause (`result-gap-causes-2026-11-13..16.json`):

| Cause | Hours | Log evidence |
|---|---|---|
| Disk full, then server down | 11.2 | `masc-start-20261115T103255Z.log`: `ENOSPC` at 22:43:51 KST (13:43:51Z), last line 00:42:29 KST (15:42:29Z). The next server starts at 17:00:53Z and 17:06:02Z. |
| Turns cut by the 11-13 deploy restart | 3.7 | `masc-start-20261113T004828Z.log` ends at 06:30:04Z and the next server starts at 06:30:03Z. Inside each of the five gaps the Keeper logs `checkpoint_save` 6 to 45 times. No turn record and no raw trace covers these turns. |
| Not separated | 2.4 | 676 intervals, 13 seconds on average. |

"Started" counts operations whose wait overlaps the window and that had a `started_at` at read time
(`waited_started`), so it includes operations that started after the window end. Mean run minutes are
`completed_at - started_at` over those that completed; `started_at` is the last segment start.
`code-reviewer-mother` ran its direct turns mostly on `glm-coding.glm-5.3-flash` in both windows (330 and 283
turns in `result-runtime-by-window.json`), and its mean run still grew 7.7 times (17.392 / 2.272).

## Limits

- `wait_h` reads `started_at`, which a requeued continuation clears and writes again. For a continuation it also
  counts earlier run segments.
- `first_claim_wait_h` uses `semantic_executions.created_at`. Those records start on 2026-11-13 11:29Z, so most
  operations of the earlier window and 151 of the later window have none (`operations_without_execution`). The RFC
  does not use this field.
- An operation still waiting at read time counts until the window end. A later read gives a larger or equal sum.
- `idle_h` treats only `started_at..completed_at` as running, so it is an upper bound. Most of the time that
  overlaps a direct turn is this gap: a code-reviewer-uncle direct turn ran from 2026-11-15T17:08Z to
  2026-11-16T01:00:26Z, and its operation later rewrote `started_at` to 02:10:48Z.
- A turn spans from the millisecond stamp in its raw-trace file name to its turn record `ts`. Delivery and Owner
  settlement after the record are not in the span. Turn records start on 2026-11-13, so the earlier window has
  no turn split.
- `runtime_by_window.py` counts only turns that called a tool, because a turn without a tool call has no ledger
  record.
