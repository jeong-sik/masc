# Librarian lag measurements, 2026-11-17

Counts behind
[RFC librarian-read-waits-and-shrinks-no-further-than-the-refusal-says](../../rfc/RFC-librarian-read-waits-and-shrinks-no-further-than-the-refusal-says.md).
`collect.py` is the script that produced them. It reads Keeper boundary logs,
Librarian read positions, Add-on owner records, request bodies and server logs,
and prints keeper names, counts, byte sizes and durations. It prints no request
body and no conversation text, and writes nothing under the workspace.

## Environment

| Item | Value |
|---|---|
| Workspace | one operator workspace on macOS; the running server answered `/health` as ready |
| Server binary | `masc` v0.73.0, built 2026-11-16 22:18 KST |
| Installed Add-on package | `keeper-librarian-0.2.3-oversize-b584e032`, `max_reply_bytes = 4194304`, `max_exact_in_flight = 3` |
| Source read for the RFC | `origin/main` `db84e1677d90` |
| Run by | a Claude Code session, read-only |

## Commands and observed results

`WORKSPACE` is the directory that holds `.masc`. Output went to the git-ignored
`artifacts/librarian-lag-20261117/`.

| Command | Result |
|---|---|
| `collect.py unread --base WORKSPACE` at 00:09 KST | atom 1,399 + official 6,632 = 8,031 unread turns |
| same at 00:38 KST | atom 1,411 + official 6,633 = 8,044 |
| `collect.py arrivals --base WORKSPACE --since 2026-11-16T00:01+09:00 --until 2026-11-17T00:01+09:00` | atom 680 + official 1,488 = 2,168 turns, 90.3 per hour; five keepers above 120: 351, 267, 201, 167, 156 |
| `collect.py attempts --log system_log_2026-11-16.jsonl --to-ts 2026-11-16T13:23` | `keeper-librarian` durable `answered` n=65, p50 717.5 s, p90 951.0 s, max 1,280.2 s; admission `answered` n=19, p50 664.3 s; durable `record_failed` n=12,076, admission `record_failed` n=2,198; `running_at_start` 0, 1 or 2 |
| `collect.py failures --log system_log_2026-11-15.jsonl --log system_log_2026-11-16.jsonl` | range not consumed: 356 reports, all `Original history publication is blocked` (156 installation state, 136 not attached, 61 request fields, 3 other); pass not committed: 4 reports, all `request_body_refused` |
| `collect.py originals --base WORKSPACE` at 00:15 KST | 27 records, estimated requests 37,737,913 B = 9.0 frames; no record at or above 987,955 B had been admitted |
| same at 00:38 KST | 27 records, 25,148,409 B = 6.0 frames; the 12.7 MB `all_unread` record of one keeper was gone and a `first_cut` record of 264,138 B stood admitted in its place |

The 00:09 and 00:15 runs used an earlier copy of the same counting rules; the
00:38 runs used this file.

## Limits

- `unread` is not the server's own count. The dashboard API needs credentials
  that this session did not use, so the value was not compared with the TUI.
  A keeper without a read-position file counts as zero on that side.
- `originals` estimates the Exact request from the stored prompt input. It
  approximates how the Librarian renders messages and is not the canonical
  byte count the worker measures. The placeholder sizes in the script are the
  script's own.
- `failures` counts log reports. The server logs a repeated problem once per
  change of text, so occurrences are at least this many. The split reads log
  text and is for this measurement only.
- Files were not read atomically while the server was running.
- The `attempts` window ends at 13:23Z, the time of its first measurement. Later
  hours of that day were not added.
- No runtime effect of the RFC is measured here. Nothing was installed.
