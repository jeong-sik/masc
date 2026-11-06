# Keepers list: past, now and next, observation record, 2026-11-06

This is a sanitized observation record for the
[research note](../../../research/2026-11-06-keepers-list-past-now-next.md). The
raw roster and status snapshots, the decision-log reads, the scripts that
derived the counts and the unsanitized preview remain private working output
under `artifacts/keepers-list-past-now-next-20261106/`. They contain Keeper
names, account fragments and workspace paths and are not part of this shared
record. No capture here is a screenshot of the TUI, before or after a change.

## What was read

All reads are from one workspace on one host, against its running MASC server on
the loopback interface. The server's commit was not recorded for these reads.

| Read | Time (UTC) | Source | Content |
| --- | --- | --- | --- |
| A | 2026-11-06 01:26:31 | `masc_keeper_list`, empty arguments, MCP `tools/call` | 40 roster rows with full row JSON |
| C | 2026-11-06 01:38:54 | per-Keeper status for the 15 rows failing in A | `needs_attention`, `attention_reason`, `next_human_action`, `disposition`, `disposition_reason`, receipt disposition, `failing_since` |
| B | 2026-11-06 01:39:13 | `masc_keeper_list`, empty arguments | 40 roster rows |
| D | window 2026-11-05 13:26:31 to 2026-11-06 01:26:31 | the workspace's per-Keeper decision logs, `<base>/.masc/keepers/<name>.decisions.jsonl` | lines with `event` = `turn`, field `outcome` (`error` or `success`), selected by `ts` |
| P | 2026-11-06 04:30:33 | the same list call plus schedule, memory-health and workspace-memory reads | input of the preview |

Counting rules:

- A row is failing when its `health` is `failing`. In A the `phase` was also
  `failing` on the same 15 rows.
- Bucket k holds the turns whose age at A is in [k × 1800 s, (k + 1) × 1800 s)
  for k = 0 to 23. A row's count is the number of buckets with at least one
  `error` turn. The decision logs are read by timestamp, not as "the last N
  turns"; `scripts/pulse_window.py` checks that each file tail reaches the
  window start.
- The ending runtime and the cause come from the typed
  `runtime_lane_observation.evidence.terminal` in the row JSON. No message text
  is parsed. Instance and account suffixes after `_` in runtime ids are dropped
  so this record names no account.

## Observed results

Verbatim output of `scripts/derive.py` over reads A, B and C, and of
`scripts/pulse_window.py` over read D. Neither names a Keeper or an account.

```text
== A: roster.json  file time 2026-11-06T01:26:31.074354+00:00
total 40
health {'failing': 15, 'offline': 18, 'healthy': 7}
phase  {'failing': 15, 'offline': 18, 'running': 7}
failing 15
last_failure.cause {'provider': 15}
next_action        {'probe': 15}
runtime_path_rest  {'resting': 4, 'serving': 11}
fields that could carry a current activity: []
activation_mode    {'on_demand': 1, 'autonomous': 14}
cause groups (ending runtime, cause arm, nested category):
   7  glm-coding.glm-5.3-flash                       provider_rate_limited  -
   4  muse.muse-spark-1.3                            masc                   provider_attempt_effect_fenced
   2  claude_code.claude-sonnet-5-5                  core                   provider
   1  claude_code.claude-sonnet-5-5                  core                   api
   1  antigravity_subscription.claude-sonnet-5-5-low core                   config
failing rows without a terminal cause: 0
attempts walked per failing row (failures list length): [(1, 7), (3, 8)]
retry_after on the terminal cause: {None: 15}
runtime_blocker_signature present on failing rows: 0 of 15

== B: roster2.json  file time 2026-11-06T01:39:13.118460+00:00
total 40 failing 7 recovered since A 8 newly failing 0
recovered rows still carrying last_failure: 0 of 8
minutes between A and B: 12.7

== C: status_rows.json (server-side judgement of the failing rows)
rows 15
{(True, 'provider_runtime_error', 'inspect_provider_runtime_cause', 'Alert', 'unknown_runtime_blocker'): 7, (False, None, None, 'Pass', 'healthy'): 8}
failing_since present 0
```

```text
roster time (UTC) 2026-11-06T01:26:31.074354+00:00 window start 2026-11-05T13:26:31.074354+00:00
outcome vocabulary in window {'error': 917, 'success': 375}
(buckets with an error turn of 24, turns in window, error turns, tail reached window start)
(24, 819, 819, True)
(23, 25, 25, True)
(21, 21, 21, True)
(9, 41, 13, True)
(5, 174, 7, True)
(5, 38, 5, True)
(4, 17, 4, True)
(4, 14, 4, True)
(4, 8, 4, True)
(4, 32, 4, True)
(3, 17, 3, True)
(3, 17, 3, True)
(3, 17, 3, True)
(2, 52, 2, True)
(0, 0, 0, True)
rows with window fully read: 15 of 15
```

Each tuple in the second block is one failing row, in descending order of the
first value. The research note groups them as 21 to 24 buckets (three rows), 9
(one), 2 to 5 (ten) and 0 (one).

## The preview

[`2026-11-06-keepers-list-past-now-next-preview.html`](../../../research/2026-11-06-keepers-list-past-now-next-preview.html)
is a derivative of the page the operator reviewed. It is a design aid on browser
layout, not an executable TUI.

- Input: read P. Its values are a later snapshot than A to D, and several
  sections (Memory, the world pipeline) are outside the research note's counts.
- Sanitizing: the 36 Keeper names became `keeper-NN`, padded with neutral words
  to the original length so truncation and column widths behave the same. Six
  runtime labels that end in an account fragment became `<model>·acct-<letter>`.
  Model and product names stay. The sanitizer, a private script, refuses to write
  the page if any original name, any such label, or any of a short list of
  organization, user and host strings is still present.
- Actions marked `[sim]` change state in the page only. They do not read or
  write a workspace.
- Checks on a byte-identical copy of the committed page: `node --check` passes
  on the single script block. A scripted browser run (headless Chromium,
  Playwright) of 37 checks passed with 0 failures and no console error. The checks cover keys,
  80, 100 and 120 columns, `NO_COLOR`, the simulated actions, and the page's own
  count of redrawn lines. The run happened while the host's load average was
  above 100, so no timing result is claimed. The counts of redrawn lines are
  counts in the page's own renderer, not terminal bytes.

## Digests of the private originals

For private comparison only. These are digests of the unsanitized originals, not
of the committed derivative. A sanitized copy does not match them.

| File (under `artifacts/keepers-list-past-now-next-20261106/`) | SHA-256 |
| --- | --- |
| `raw/roster.json` (A) | `49dfc4b21d41473b8df5eb8746c140286f16e7a9400e8554150f264747857056` |
| `raw/status_rows.json` (C) | `d351a81a43e867d0c8ae025660fe346f20249ad0b8fbb87b8f1d54da0550f3be` |
| `raw/roster2.json` (B) | `c092510ccadd8f7c6880b75939da1752be38053e60677aed2b6ff69f58b4002f` |
| `raw/roster5.json` (P) | `7d3c5528616aab84745712bac81834f8afdea49e9e5cde1c74d00affe0eaf93d` |
| `raw/data.json` (preview data) | `4d6befd01c86a006f068c958c373945b3eaeecb07260f61a068e58ded2d53448` |
| `prototype/keeper-pulse.html` (page as reviewed) | `ed9dcef088b0f9da07ee1a5899af506d878ceac2b67bb8d94248cd73207ea8cb` |
| `derived.txt` | `5899fcee1601474b36fcfc2e9e1b2d331a77388bbca3fcb4a3927859c94512ed` |
| `derived-pulse-window.txt` | `7c47c4e6217b41d3bf44ea7b87a382920df3fb521d78989d705f46ea18ff1e0e` |
| `scripts/derive.py` | `50ffc5e4c346258ad8a0cdf5004ddce0c2a89389f47863afe10a1d547d4dbd2e` |
| `scripts/pulse_window.py` | `ce1ffbde1c87f74a52d321851d608704b7d1df8a146315c077fe0f0df15064cc` |
| `scripts/sanitize_preview.py` | `13df53818fe344731b3b4c58726dc01c90f97fee8baff7f34c128b68a26c582f` |

The committed preview's own SHA-256 is
`a9bcd2547d7af043f9bcade8c72863a834514828c1ede88d20107d4cc0e0f5c9`.

## Not covered

- The reads are a few snapshots of a live, changing fleet, not a longitudinal
  survey. The share of failing rows (15 of 40) is that of one workspace at one
  time.
- The roster has no current-activity field and per-row status reads for the
  15 rows were not kept, so whether any failing row was mid-turn at A is unknown.
- The running server's commit was not recorded. Code coordinates in the research
  note were read on main `e1001bccf3a`, after the reads.
- The web dashboard was not examined. The browser extension was not connected.
- No TUI binary was run. Nothing here shows how a candidate change looks at
  80, 120 or 200 columns.
