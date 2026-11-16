# Chat operation queue wait, 2026-11-10 ~ 11-16

Retained records for `docs/rfc/RFC-a-keeper-takes-every-waiting-message-in-one-turn.md`.

## Source and environment

- Runtime data: the operator's `<base-path>/.masc` on 2026-11-16, read between 02:10Z and 02:40Z.
- Source head when reading: `706704b625a5`.
- Every read opens SQLite with `mode=ro` or reads JSONL files. Nothing was written to the runtime.

## Windows

| Name | UTC |
|---|---|
| Earlier | 2026-11-10T00:48:28Z ~ 11-13T00:48:28Z |
| Later | 2026-11-13T00:48:28Z ~ 11-16T00:48:28Z |

## Commands

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/queue_wait_overlap.py \
  --base-path ~/me --since 2026-11-13T00:48:28 --end 2026-11-16T00:48:28 \
  --json-out result-queue-wait-overlap-2026-11-13T00-48-28Z_11-16T00-48-28Z.json

python3 docs/evidence/chat-queue-wait-2026-11-16/chat_queue_split.py \
  --base-path ~/me --since 1794530908 --end 1794790108 \
  context-reviewer code-reviewer-father code-reviewer code-reviewer-uncle \
  code-reviewer-brother code-reviewer-sister code-reviewer-mother \
  > result-split-2026-11-13T00-48-28Z_11-16T00-48-28Z.json
```

The earlier window uses `--since 2026-11-10T00:48:28 --end 2026-11-13T00:48:28` and
`--since 1794271708 --end 1794530908`.

## Results

All Keepers, `queue_wait_overlap.py` (sum of `created_at -> started_at`):

| Window | Operations | Wait hours |
|---|---|---|
| Earlier | 765 | 14.2 |
| Later | 875 | 934.8 |

The seven review Keepers in the later window, `chat_queue_split.py`:

| Keeper | Operations | Executions | Wait h | Idle h | Idle under an autonomous turn h | Autonomous turns / h | Direct turns / h |
|---|---|---|---|---|---|---|---|
| context-reviewer | 123 | 108 | 355.0 | 13.6 | 5.2 | 128 / 26.6 | 111 / 32.7 |
| code-reviewer-father | 138 | 114 | 128.9 | 11.8 | 3.6 | 172 / 25.4 | 121 / 30.1 |
| code-reviewer | 115 | 101 | 121.9 | 9.6 | 3.8 | 330 / 23.6 | 102 / 24.0 |
| code-reviewer-uncle | 101 | 95 | 130.2 | 17.6 | 3.7 | 247 / 16.9 | 93 / 10.7 |
| code-reviewer-brother | 116 | 107 | 38.8 | 13.5 | 6.0 | 69 / 14.6 | 108 / 23.0 |
| code-reviewer-sister | 92 | 79 | 98.3 | 43.5 | 31.3 | 169 / 33.7 | 78 / 26.2 |
| code-reviewer-mother | 87 | 82 | 24.9 | 7.5 | 3.3 | 67 / 14.3 | 83 / 25.0 |
| Sum | 772 | 686 | 898.0 | 117.1 | 56.9 | 1,182 / 155.1 | 696 / 171.7 |

Mean run minutes per completed chat operation, for each window `[a, b)`:

```sql
SELECT count(*), avg(completed_at - started_at) / 60.0 FROM operations
WHERE completed_at IS NOT NULL AND started_at < b AND completed_at > a;
```

| Keeper | Earlier | Later |
|---|---|---|
| context-reviewer | 6.1 | 15.9 |
| code-reviewer-father | 2.6 | 13.9 |
| code-reviewer | 3.0 | 13.0 |
| code-reviewer-uncle | 2.7 | 10.4 |
| code-reviewer-brother | 1.8 | 12.7 |
| code-reviewer-sister | 2.6 | 18.9 |
| code-reviewer-mother | 2.3 | 17.4 |

## Limits

- `wait_h` reads `started_at`, which a requeued continuation clears and writes again. It also
  counts earlier run segments of the same operation. `first_call_wait_h` in the result files is the
  lower bound (context-reviewer 346.1 against 355.0).
- The sum depends on when it is read. Operations that were still queued at the window end count
  only after they start. A read at 01:50Z gave 921.6 hours and 873 operations for the same window.
- `idle_h` treats only `started_at..completed_at` as running, so it is an upper bound.
- Turn spans start at the millisecond stamp in the raw-trace file name. Turn records start on
  2026-11-13, so the earlier window has no turn split.
- 35.5 of the 117.1 idle hours overlap no recorded turn. Admission pauses, provider rests and
  restarts are not separated here.
- The longer runs coincide with a runtime change. In the tool-call ledger, direct turns of these
  Keepers in the earlier window ran mostly on deepseek-v4-1-flash, gpt-6.1 and sonnet-5-5 profiles,
  and in the later window mostly on glm-5.3-flash profiles. Neither the cause of the change nor
  its effect on run time is established.
