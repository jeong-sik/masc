# Repeated tool rounds, 2026-11-10 ~ 11-16

Retained records for `docs/rfc/RFC-a-turn-closes-at-a-typed-end.md`.

## Source

- Runtime data: the operator's `<base-path>/.masc/keepers/*/raw-traces/turn-*.jsonl`, read on 2026-11-16.
- Window: 2026-11-10T00:48:28Z ~ 11-16T00:48:28Z (epoch 1794271708 ~ 1794790108), by the stamp in the file name.
- Reads only. Nothing was written to the runtime.

## Command

```bash
python3 -I -B docs/evidence/repeated-tool-rounds-2026-11-16/repeated_tool_rounds.py \
  --base-path ~/me --since 1794271708 --end 1794790108 --min-rounds 10 \
  > docs/evidence/repeated-tool-rounds-2026-11-16/result-2026-11-10..16.json
```

Raw traces rotate oldest first, so a later run reads fewer files.

## Definition

A repeat round is a model response that holds exactly one tool call whose name and input equal the single call
of the response before it. Results are not compared. This differs from
`docs/evidence/repeated-calls-2026-11/`, which also compares results: a status read such as
`keeper_lane_status` returns a new observation time on every call, so that script does not count the loop this
RFC is about. `--min-rounds 10` only cuts the report.

## Results

41 runs, 4,708 repeat rounds, 50.7 hours from the first to the last call of each stretch. Every run was an
Agent Core run:

| Runtime | Runs | Rounds | Hours |
|---|---:|---:|---:|
| `glm-coding.glm-5.3-flash` | 36 | 3,107 | 47.7 |
| `kimi_coding.kimi-k3-1-pro` | 5 | 1,601 | 3.0 |

The longest stretches, with what the model wrote in those rounds (read by hand from the same traces):

| Keeper | Tool and input | Rounds | Hours | Text in the rounds |
|---|---|---:|---:|---|
| ocaml-agent-ic | `Execute {"command":"true"}` | 175 | 6.6 | "순찰 B 종료 — … 이 턴 종료 후 자체 턴으로" |
| code-reviewer-uncle | `keeper_lane_status {}` | 177 | 6.6 | "이 턴 종료(도구 호출 없음) — 큐된 순찰 wake가 다음 턴에서…" |
| msx-retro-mania | `keeper_capability_search {"query":"masc_dos"}` | 96 | 3.3 | "이번 턴도 복구 감지 probe 한 번만 수행한다." |
| sangsu | `keeper_artifact_read` (same sha, offset 0) | 106 | 2.3 | none |
| wkbl-web-leader | `masc_keeper_delegate_status_many` (one operation) | 1,000 | 2.0 | progress reports |
| wkbl-web-leader | `masc_schedule_note_add` (same body "…이번 턴 종료…") | 62 | 1.9 | "이번 턴을 종료합니다." |
| code-reviewer-sister | `keeper_lane_status {}` | 744 | 1.4 | "레인 상태 재확인 — 살아 있으면 …, 죽어 있으면 조용히 대기할게요." |

## The code-reviewer-uncle run

`code-reviewer-uncle/raw-traces/turn-1794762495928-88eb-000000.jsonl`:

- The first attempt on `claude_code` failed on its quota. The run moved to Agent Core on `glm-5.3-flash`.
- The last calls that did work: `Execute` eight times and `masc_schedule_note_add` once, the last at 18:06:46Z.
- 18:11:09Z ~ 00:44:50Z: 177 responses, 134 seconds apart on average. Each held one text that starts with
  "이 턴 종료" (166 and 11 of two openings, 84 distinct texts in all) and one `keeper_lane_status({})` call.
  The results differ only in `probe.observed_at_unix` and `last_dispatch.at_unix`.
- The trace's last error is an admission queue timeout at 00:59:51Z. The turn record is at 01:00:26Z.

## Limits

- A response with two or more calls breaks a stretch, so a loop that adds a second call is not counted.
- The table's text column is a hand reading of samples. No count in this directory classifies text.
- The provider's raw `finish_reason` is not in the raw trace, so whether the model sent `stop` with the tool
  call is unknown.
