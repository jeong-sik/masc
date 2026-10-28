# Keeper memory recall baseline, 2026-10-28

How much Keeper memory recall is used, and what state the memory store is in,
measured on the live runtime before any change.
[RFC-keeper-recall-reaches-the-turn](../../rfc/RFC-keeper-recall-reaches-the-turn.md)
cites these numbers and re-runs the same scripts after each layer.

## What this is

Two reports, both run on 2026-10-28 around 04:01Z against the operator's live
base path with the scripts in this pull request. The live files keep growing,
so a re-run gives slightly larger counts.

[report.txt](report.txt) is the output of `scripts/keeper-recall-baseline.py`:
how much recall is used, what happened to retrieved ids, and how many turns a
per-turn judgment would cover.

```bash
python3 -I scripts/keeper-recall-baseline.py <base-path>/.masc/keepers \
  --memory-dir <base-path>/.masc/config/keepers --since 2026-10-02 \
  --exclude lab-sangsu --exclude taskmaster --exclude microvm-probe-829
```

[store-report.txt](store-report.txt) is the output of `scripts/keeper-recall-store.py`:
what the store holds, what happened to what Keepers wrote, how facts leave the
store, how often the Librarian failed, what was already sent to Jev, and how
long the exact-output lanes took.

```bash
python3 -I scripts/keeper-recall-store.py <base-path>/.masc/config/keepers \
  --since 2026-10-02 --now 2026-10-28T04:01:08Z \
  --keepers-dir <base-path>/.masc/keepers \
  --lane-runs <base-path>/.masc/exact-lane-runs-v7.jsonl \
  --exclude lab-sangsu --exclude taskmaster --exclude microvm-probe-829
```

`--since 2026-10-02` starts after the change that removed memory bodies from the
prompt (#40473 on 10-01, #40782 on 10-02). The three excluded names are
probe and lab Keepers from 08-29 to 09-01. Counts that include them are not
comparable with these. Every number below covers the other 40 Keepers.

## What it shows

Usage (report.txt):

- A `keeper_memory_search` call is 0.80% of all tool calls (2,201 of 276,804).
  `keeper_memory_write` is 1.73%, so Keepers write more than twice as often as
  they search. Wiki read tools are 0.06% (177) and wiki maintenance tools 0.03%
  (71). `keeper_memory_select` was called once. Skill authoring tools (`keeper_skill_validate`, `keeper_skill_publish`)
  are 0.60% (1,657). Skill use tools (`keeper_skill`, `keeper_compose_*`) were
  called 0 times, so the log says nothing about whether a listed Skill gets used.
- Per 100 turns that used a tool, the turns that searched range from 1.45
  (`claude_code`) to 12.91 (`antigravity`) among providers with at least 300
  tool-using turns.
- Among official-client runs of one model, runs whose prompt text carried the
  Memory OS Recall notice searched more often than runs that did not for
  `muse-spark-1.3` (13.3% against 2.3%) and `muse-spark-1.3-contributor` (56.1%
  against 5.4%). `claude-sonnet-5-5` searched in none of 56 runs that carried it.
  `gpt-6-luna` and `gpt-6.1-sol` show no difference.
- On the 14 UTC days since 10-02 with more than 1,000 Librarian commits,
  searches were 1/11 to 1/39 of the commits. The Librarian slowed on 10-24 and
  10-25 (69 and 28 commits), so the gap is not constant.
- 28.3% of searches found nothing (622 of 2,198).
- Of 19,234 Retrieved events, 15.5% point at a current fact. The claim hash
  changes when the Librarian rewrites a claim, but revised records alone lead
  to a current fact for only 2.0%. Another 23.3% lead to a current fact through
  an absorption. 21.9% lead to an id that is also gone and 1.8% were
  retracted. 32.5% have no such record, but a committed journal row removed
  that fact. 3.0% appear in no file.
- Turns per UTC day rose from 64 on 10-02 to 3,793 on 10-27, taken by 29
  Keepers. Judging every current fact on every turn would read an average of
  about 100 KB of claim text per turn on the busiest days (96 to 117 KB on
  10-23 to 10-28).

Store (store-report.txt):

- 2,338 current facts in 40 Keepers. 2,309 were written by the Librarian
  (`origin` injected) and 29 by Keepers (authored). 24.0% carry a Board post as
  their source coordinate. `last_seen` is a median 7.2 days old, a p90 21.5 days,
  and 20.7% are older than 14 days. A Keeper holds a median 55 facts (max 121)
  and 66 KB of claim text (p90 148 KB, max 182 KB). `constraint` is 466 facts. Claims bound to a source file live in a separate
  store: 148 claims, 185 KB, in 24 Keepers. All 34 admission queues were empty.
- Since 10-02 the journal committed 4,765 facts that Keepers wrote. 3,110 of
  them came from one run of one Keeper (`sangsu`, trace
  `trace-1788310783624-00004`, mostly on 10-05) and were almost all gone or
  retracted later. Without that run, 1,655 facts from 30 Keepers remain: 52.2%
  were rewritten, 8.1% were absorbed into another fact, 38.5% left the current
  set with no revised, retracted or absorbed record, 1.1% are still current as
  written. These are commits made before the queue took over: 3,182 on 10-05 and
  0 to 2 a day from 10-13. Direct commits fell from hundreds a
  day to about 0 after 10-11. The admission queue module was added on 10-09
  (`89779779b4b`); the day the live path switched to it is not confirmed.
- Since 10-02 the Librarian made 33,789 commits and its lane failed 21,967 times
  (39.4% of attempts). Failures cluster: 84% on 10-11, 89% on 10-15, 43% on
  10-22, and 1 to 3% since 10-26.
- Facts leave the store through several paths. Since 10-02: 7,178 absorptions
  into another fact, 3,353 revised events, 361 retracted events, 19,572 facts
  removed by committed journal rows, and 8,940 facts the Librarian dropped with
  a written reason (another 729 were dropped as `superseded_by`). The counts
  overlap: a rewritten or absorbed fact also appears as removed in the journal
  row that committed it. The Librarian already deletes facts it judges out of
  date.
- Jev has already received 1,623 memory judgment requests, all from the
  successor path of `keeper_memory_search` (`purpose` is
  `successor_memory_recall`), all to `api.typesafe.ai`, from 20 Keepers. One
  Keeper (`msx-retro-mania`) sent 1,184. `kidsnote-incoming-dd-manager` sent 49
  and `kidsnote-job-manager` sent 4. Each request carries one question. The
  state is a median 7.6 KB (max 43.0 KB) and the answer took a median 0.24 s
  (p90 0.48 s, max 14.51 s). 6 of 1,623 failed. Input tokens were a median
  4,658 (max 17,979), about 2.0 bytes per token (minimum 1.56).
- Exact-output lane runs: `librarian_exact` took a median 10.8 s, p90 32.1 s, p99
  368.4 s for a median 33 KB input (p90 215 KB). `board_attention_exact` took a
  median 169.0 s for a 2 KB input, so the elapsed time includes waiting for a
  permit, not only model time.

## Limits

- The decision logs rotate at 10 MB and the raw traces keep about 200 runs per
  Keeper, so each Keeper's window differs and every count is a lower bound for
  the period. The Retrieved-event table and the facts-left table read whole
  event and journal files, so their windows differ from `--since`.
- A search that finds nothing can be a correct answer. The no-match share bounds
  recall quality; it does not measure it.
- Role and model are mixed with runtime. The per-model table compares runs of
  one model, which removes the model but not the Keeper's job.
- API lanes send the notice outside `run_started.prompt`, so the notice table has
  no comparable row for them. That they receive it on every first round comes
  from reading the code, not from this measurement.
- Counts of tool calls come from `tool_exec` decision events. A record that could
  not be parsed is skipped.
- The Retrieved-event table follows `revised` and `absorbed` records and then
  looks the fact up in committed journal rows (`change.removed`). A removed fact
  can be one that a rewrite replaced, so "removed by a journal row" is not the
  same as "deleted for being out of date".
- The write table matches facts by claim hash. A fact the Librarian reworded
  counts as gone, and a fact a Keeper replaced with its own later snapshot also
  counts as gone, so "gone" is not the same as "lost".
- The turns table applies each Keeper's current fact bytes to every past day.
  It is only as accurate as the Keeper's fact count was stable.
- The Jev request table covers only the successor path, one question per
  request. A request with dozens of questions and a larger state has never been
  sent, so its size, latency and refusal rate are not measured.
- `elapsed_s` in the lane runs includes queue wait. It is not model time.
- A run counts as carrying the Memory OS Recall notice when its prompt text does.
  Such runs start a session or change the notice, so the table also compares new
  sessions with resumed ones, not only notice with no notice.
- The bytes-per-token ratio comes from requests of which 73% belong to one Keeper
  (`msx-retro-mania`), and the byte count includes the English question text, so
  a claim-only ratio is lower.
