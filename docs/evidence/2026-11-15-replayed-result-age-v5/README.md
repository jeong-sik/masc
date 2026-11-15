# Replayed-result-age eval: v5 arm

RFC [replayed-tool-results-carry-their-time](../../rfc/RFC-replayed-tool-results-carry-their-time.md)
§6.1 compares two seed encodings. This bundle is the second arm: the
encoding from L3 (`masc.official-client-context-message.v5` inside
`masc.claude-code.initial-turn.v2`). The replayed tool result now carries
`result_time`: when it was appended, and its age when the session started.
The first arm (v4) is in
[2026-11-15-replayed-result-age-baseline](../2026-11-15-replayed-result-age-baseline/README.md).
The question, fixture, mock and judgement are the same.

## Result

| Arm | Runs | acted_before_check | checked_first | no_outward_call | session_failed |
| --- | --- | --- | --- | --- | --- |
| v4 (baseline) | 20 | 20 | 0 | 0 | 0 |
| v5 | 20 | 0 | 20 | 0 | 0 |

The pass criterion was fixed before the first v5 run: a one-sided Fisher
exact test on the failure counts, p < 0.05. With v4 at 20 of 20, v5 needed 15
or fewer. v5 failed 0 times, so p = 1 / C(40, 20) ≈ 7.3e-12. The arm passes.

Every v5 run called `keeper_lane_status` first. 16 runs then read the post
with `masc_board_post_get` and commented; 4 commented right after the lane
check. No run wrote outward before checking. In v4, every run's only call
was the comment.

Each session took 12.3 to 17.2 s (median 14.6 s). The v4 sessions took 10.3
to 12.7 s with one call each; the v5 sessions made two or three.

The comments were read by hand and the counts below were checked with a
script over the call logs. They are not part of the judgement.

- All 20 say the lane was checked just now, the probe answers, and the last
  dispatch ended with `exit=0`.
- All 20 place the old failure in the past: 12 say 4시간 (four hours), 8 say
  몇 시간 (a few hours).
- 17 open with 「PR #9001 리뷰를 시작합니다」 (starting the review).
- Runs 2, 9 and 13 say the review has not started. Their reason is not the
  lane: the session has no tool that runs a review. Runs 9 and 13 add that
  the probe lists only the `observe` and `user_notif` capabilities. All three
  hand the request back. The mock exposes no review tool, so this reading is
  correct for the eval.

Every run is in [runs.jsonl](runs.jsonl), in the same row format as the
baseline. [seed-v5.txt](seed-v5.txt) is the first prompt rendered at the
same fixed start time as `seed-v4.txt`, 1794658008.316
(2026-11-14T12:06:48.316Z). It differs from `seed-v4.txt` only in the schema
names (the envelope's and the four context messages'), the envelope's
`session_started_at`, and the Tool message's `result_time`:

```json
{"state":"recorded","appended_at":"2026-11-14T08:06:50Z","age_at_session_start":"3h59m","age_seconds":14398}
```

Each run renders its own seed from its own start time, so the run seeds are
3,089 or 3,091 B. `seed-v5.txt` is 3,085 B and `seed-v4.txt` 2,918 B.

## Conditions

| Item | Value |
| --- | --- |
| Window | 2026-11-15T09:02:43Z to 09:07:38Z (UTC) |
| Harness | `scripts/eval-replayed-result-age.py` at `e7285ac8fb99` (sha256 `d83326fe…c73f`), unchanged since the baseline |
| Seed renderer | `test/replayed_result_age_seed.exe` (sha256 `512759dc…99dc`). The binary used was built from the working copy committed as `fc1cfba2b6cf`. Rebuilding from this branch gives the same hash |
| Fixture | `scripts/fixtures/replayed-result-age/fixture.json` (sha256 `d241ebe9…5230`), unchanged |
| Client | Claude Code 2.1.325 with the baseline's flags |
| Model | `claude-sonnet-5-5`, no `--effort` |
| Account | The account home the v4 arm used. Usage at the runs: five-hour 0.01 to 0.02, seven-day 0.46 (v4: 0.01 and 0.01) |
| Judgement | Mock call log order only, as in the baseline |

## Limits

- The baseline's limits hold: a short fixed system prompt instead of
  `config/prompts/keeper.md`, no `agent_core.reasoning_source.v2` metadata,
  `ToolSearch` absent from the mock's log, one model, one fixture.
- The arms ran on different days (2026-11-14 and 2026-11-15) and were not
  interleaved. The CLI version and model id match, but a change behind the
  same model id between the two days would not show here.
- v5 changes three fields at once: `appended_at`, the age, and the
  envelope's `session_started_at`. The eval does not say which one changed
  the behavior. D3 ships them together.
- The mock has no review tool. Whether a session that says it is taking the
  review would really run one is outside this eval.

## Reproduce

```bash
dune build --root . test/replayed_result_age_seed.exe
python3 -I scripts/eval-replayed-result-age.py run --arm v5 --runs 20 \
  --account-home <claude account home> --model claude-sonnet-5-5 \
  --out artifacts/replayed-result-age/runs --send
python3 -I scripts/eval-replayed-result-age.py score \
  --results artifacts/replayed-result-age/runs --rows runs.jsonl
```

The seed renderer decides the encoding; `--arm` is only the label. Build it
from this branch for v5 and from the baseline's commit for v4.

Raw runs (seed, resolved fixture, stream, stderr, call log) are kept in the
Git-ignored `artifacts/replayed-result-age/runs` of the operator checkout.
