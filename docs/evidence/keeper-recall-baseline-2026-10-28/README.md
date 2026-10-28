# Keeper memory recall baseline, 2026-10-28

How much Keeper memory recall is used, measured on the live runtime before any
change. [RFC-keeper-recall-reaches-the-turn](../../rfc/RFC-keeper-recall-reaches-the-turn.md)
cites these numbers and re-runs the same script after each layer.

## What this is

[report.txt](report.txt) is the output of `scripts/keeper-recall-baseline.py`
at base commit `de5599529145`, run on 2026-10-28 09:17 KST against the
operator's live base path:

```bash
python3 -I scripts/keeper-recall-baseline.py <base-path>/.masc/keepers \
  --memory-dir <base-path>/.masc/config/keepers --since 2026-10-02 \
  --exclude lab-sangsu --exclude taskmaster --exclude microvm-probe-829
```

`--since 2026-10-02` starts after the change that removed memory bodies from the
prompt (#40473 on 10-01, #40782 on 10-02). The three excluded names are
probe and lab Keepers from 08-29 to 09-01.

## What it shows

- A `keeper_memory_search` call is 0.80% of all tool calls. Skill tools are 0.60%
  and wiki tools 0.09%. `keeper_memory_write` is 1.75%, so Keepers write more than
  twice as often as they search.
- Per 100 turns that used a tool, the turns that searched range from 1.5
  (`claude_code`) to 12.9 (`antigravity`) among providers with at least 300
  tool-using turns.
- Among official-client runs of one model, runs whose prompt text carried the
  Memory OS Recall notice searched more often than runs that did not for
  `muse-spark-1.3` (13.7% against 2.2%) and `muse-spark-1.3-contributor` (59.0%
  against 3.0%). `claude-sonnet-5-5` searched in none of 39 runs that carried it.
  `gpt-6-luna` and `gpt-6.1-sol` show no difference.
- On the 8 UTC days from 10-12 to 10-22 with more than 1,000 Librarian commits,
  searches were 1/13 to 1/39 of the commits. The Librarian slowed on 10-24 and
  10-25 (69 and 28 commits), so the gap is not constant.
- 28.3% of searches found nothing.
- 84.5% of Retrieved events point at a memory id that is no longer a current
  fact, because a memory id is the hash of its claim and 11,693 revisions gave
  those facts new ids.

## Limits

- The decision logs rotate at 10 MB and the raw traces keep about 200 runs per
  Keeper, so each Keeper's window differs and every count is a lower bound for
  the period.
- A search that finds nothing can be a correct answer. The no-match share bounds
  recall quality; it does not measure it.
- Role and model are mixed with runtime. The per-model table compares runs of
  one model, which removes the model but not the Keeper's job.
- API lanes send the notice outside `run_started.prompt`, so the notice table has
  no comparable row for them. That they receive it on every first round comes
  from reading the code, not from this measurement.
- Counts of tool calls come from `tool_exec` decision events. A record that could
  not be parsed is skipped.
- Retrieved events existed before this snapshot. An orphaned event is evidence of
  lost history, not of a fact that was never read.
