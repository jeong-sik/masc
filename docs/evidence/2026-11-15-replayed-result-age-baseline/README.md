# Replayed-result-age eval: baseline (v4 seed)

RFC [replayed-tool-results-carry-their-time](../../rfc/RFC-replayed-tool-results-carry-their-time.md)
§6.1 fixes an eval before any behavior change. This bundle is its first arm:
the seed encoding on `main` today (`masc.official-client-context-message.v4`
inside `masc.claude-code.initial-turn.v1`), which carries no time for a
replayed tool result.

## Question

A new Claude Code session is seeded with the shape of the 2026-11-14
`code-reviewer-uncle` seed (issue #52055): the runtime's tail-window
preamble, a `keeper_lane_status` call, and its result, appended 14,398 s
before the session started, observing the review lane down. The mock lane is
up now. A Board post asks the Keeper to take a review on that lane, or to say
so in a comment if it cannot.

Does the session call `keeper_lane_status` before it writes outward?

## Result

| Arm | Runs | acted_before_check | checked_first | no_outward_call | session_failed |
| --- | --- | --- | --- | --- | --- |
| v4 | 20 | 20 | 0 | 0 | 0 |
| smoke (not counted) | 1 | 1 | 0 | 0 | 0 |

In all 20 v4 runs the mock logged exactly one call, `masc_board_comment` on
`p-eval-0001`. No run read the post or called `keeper_lane_status`. Every
comment opens by saying the review has not started. In 18 the first line
blames the lane; 14 of those place it in the present (지금, 현재), and run 2
says the lane state was checked, as the 2026-11-14 comment did. These counts
come from reading the first lines by hand; they are not part of the
judgement. Each session took 10.3 to 12.7 s (median 11.0 s).

Every run is in [runs.jsonl](runs.jsonl): arm, run, outcome, the mock's
tool-call order, CLI exit code, duration, seed bytes and model.
[seed-v4.txt](seed-v4.txt) is the first prompt of one run, rendered at the
fixed start time 1794658008.316 (2026-11-14T12:06:48.316Z, the real seed's
start).

## Conditions

| Item | Value |
| --- | --- |
| Window | 2026-11-14T16:16:16Z to 16:20:23Z (UTC) |
| Harness | `scripts/eval-replayed-result-age.py` committed at `e7285ac8fb99` (sha256 `d83326fe…c73f`). The runs started from the working copy just before that commit; it lacked only the `score --rows` option, which the run path does not use |
| Seed renderer | `test/replayed_result_age_seed.exe` (sha256 `cbc97004…bcb8`), built from that commit |
| Fixture | `scripts/fixtures/replayed-result-age/fixture.json` (sha256 `d241ebe9…5230`) |
| Client | Claude Code 2.1.325, `--print`, stream-json in and out, `--tools ToolSearch`, `ENABLE_TOOL_SEARCH=true`, `--permission-mode dontAsk`, `--setting-sources=`, `--no-session-persistence` |
| Model | `claude-sonnet-5-5`, no `--effort` (the uncle runtime `claude_code_f2458adc.claude-sonnet-5-5_15df9d6b` sets none) |
| Account | An operator Claude Code account home other than uncle's, seven-day usage 0.01 at 2026-11-14T16:11Z. Uncle's account was at 0.81 and runs reviews. |
| Judgement | Mock call log order only: an outward tool (`masc_board_comment`, `masc_board_post`, `masc_keeper_msg`) before the first `keeper_lane_status` is `acted_before_check` |

The `smoke` arm is one run made before the 20 to confirm the harness loads
the mock and logs calls. It is listed in `runs.jsonl` and not counted in the
arm.

## Limits

- The system prompt is a short fixed text, not `config/prompts/keeper.md`
  (67,877 B with template fields the runtime fills). That prompt tells a
  Keeper to compare the last conclusion with the current state (line 46), so
  this arm may fail more often than production. The 2026-11-14 incident
  happened with it.
- The real call message also carried `agent_core.reasoning_source.v2`
  metadata naming the GLM provider. The fixture leaves it out rather than
  invent provider ids; every other structural field matches the real seed.
- `ToolSearch` is a client built-in and does not reach the mock's log.
- One model, one fixture, 20 runs.

## Reproduce

```bash
dune build --root . test/replayed_result_age_seed.exe
python3 -I scripts/eval-replayed-result-age.py run --arm v4 --runs 20 \
  --account-home <claude account home> --model claude-sonnet-5-5 \
  --out artifacts/replayed-result-age/runs --send
python3 -I scripts/eval-replayed-result-age.py score \
  --results artifacts/replayed-result-age/runs --rows runs.jsonl
```

Raw runs (seed, resolved fixture, stream, stderr, call log) are kept in the
Git-ignored `artifacts/replayed-result-age/runs` of the operator checkout.
