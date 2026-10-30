# Keeper temporal continuity observation evidence

## 공통 헤더

- 날짜(ISO8601): 2026-10-30T17:57:30+09:00
- 작성자: Codex implementation session
- 결정 ID: keeper-temporal-continuity-20261030
- 적용 대상: scripts/harness/workload/keeper_temporal_continuity.py; dedicated Docker Keeper
- 결정 상태: 추적 필요

## 근거 (Evidence)

- 항목: A dedicated Keeper completed twelve message turns and one retained lane stop/start; its final shutdown was observed.
- 출처: private `artifacts/temporal-continuity-20261030/live-1727/report.json`, exact MCP/HTTP exports and [selected measurement summary](measurement-summary.json).
- 확인일시: 2026-10-30T08:53:54.434329+00:00
- 신뢰도: High for recorded operation/turn joins; semantic quality and causal attribution remain separate.
- 제한조건: installed main binary `bac52cac7934ce3f75c315d474cc23f2561268c9`; one Docker Keeper, network none, no production-server restart. This does not execute the unmerged #46926 candidate.

The live capture used harness snapshot `cc9dfd5b8b12cf94c92eb06c6fc420ef14121115882aaee910d5fcad647be9b9`.
Its final report SHA-256 is `9252ecbee9c4b78094fd7bf3f52efbc026b1ad995bf0ac56d8b4e0d6046394b5`. It ran from
2026-10-30T08:27:18.937438+00:00 to 2026-10-30T08:53:54.434329+00:00; this interval includes
capture, dedicated-Keeper shutdown and the initial judge calls.

The current-source offline assessment used snapshot
`d4ddb63982307b9ec0da7c89afccc382bba2c48a539f22087a526ffb2ae4d761`, matching implementation commit
`1b7ec21e01f25897cbd0b2ee1c80916224fe00cc`'s harness. It ran from 2026-10-30T08:54:45.792079+00:00 to
2026-10-30T08:55:27.849771+00:00. Its report SHA-256 is `c68425f21a87bde7bef8e2f159c25abf25bdba1c7bd695fdefbf5ecd5f8c3c76`.
It revalidated the original source/raw digests, ordered submissions, restart
observations, health identity and owner joins without contacting MASC or
replaying Keeper operations. The original capture remained unchanged. The old
prototype's retained judge request objects shared a mutable reference list;
only this fresh assessment is used below. Its captured Keeper observations
were independently rejoined to the original raw responses.

- 항목: TypeSafe Noul returns a model's probability for a proposition.
- 출처: [official Noul documentation](https://docs.typesafe.ai/primitives/noul); actual `https://api.typesafe.ai/v1/systemone` responses retained in the private assessment.
- 확인일시: 2026-10-30T17:58:00+09:00
- 신뢰도: High for response protocol and actual model identity; this is not semantic ground truth.
- 제한조건: requested alias `jev-latest`, actual response model `jev-1.14.0`; no threshold, binary pass, or retention percentage is derived.

## 검증 (Verification)

- 1차: Reviewed current owner contracts for chat operations, original completed replies, canonical input parts, exact turn records and transcripts; reviewed the official Noul request/response contract.
- 2차: `/health?full=1` recorded binary version `0.66.0`, binary SHA `bac52cac7934ce3f75c315d474cc23f2561268c9`, executable SHA `21067bda7e1d38de044567a60a3575d7dfee80161ba34630742a4000828aa391` and runtime instance `01a18bc6-19f4-7000-be2c-d9f7a0ade50c`. Effective base path was `/Users/dancer/me` and MASC root `/Users/dancer/me/.masc`.
- 3차: `python3 -m unittest discover -s scripts/tests -p test_keeper_temporal_continuity.py -v` passed all eight tests, including rejected owner/turn/digest evidence and tampered assessment joins. `pyright --outputjson` reported zero errors for both Python files; Ruff lint and format checks and `git diff --check` passed. These are protocol fixtures, not real-model tests.
- 재현 결과: Twelve exact successful operations linked to trace `trace-1793348839581-00000` turns 1–12, plus a retained Keeper shutdown/start and final observed shutdown. Two recorded `keeper_context_status` invocations occurred at turns 2 and 11. No Apple service, guest or volume operation was performed.

The first five prepared requests contained no structurally tagged W message.
Turns 6–12 each contained one. This is presence in the last prepared request,
not evidence of remote provider receipt or correct semantic content.

Manual inspection of the captured evidence found a useful discrepancy:

| Checkpoint | Captured answer | Captured W |
|---|---|---|
| Turn 7, return after topic changes | Continues the pending reconnect event-order investigation | Still describes both cache and reconnect as unresolved candidates, referring to the earlier turn-1 state |
| Turn 8, after lane restart | Preserves read-only authority and resumes the pending investigation; revalidates stale context with history and Recall | Present, with older investigation state |
| Turns 11–12, after the second correction | Rejects reconnect cost and continues notification-order investigation, leaving causality unresolved | Still describes reconnect as the major unconfirmed candidate and waits for the earlier reconnect event evidence |

Thus late answers followed the corrections while W lagged behind them. The
answer also identified stale derived working-context entries that still called
answered questions pending. Those observations are against installed main;
they do not establish whether the pending batch implementation fixes them.
No runtime state was repaired to improve this trial's results.

The fresh semantic assessment retained these raw probabilities:

| Checkpoint / proposition | Scope | Raw Noul |
|---|---|---:|
| Return / continue unfinished work | reply | 0.93 |
| Return / cache rejection preserved | W | 0.54 |
| Resume / continue intent | reply | 0.85 |
| Resume / preserve read-only authority | reply | 0.77 |
| Resume / preserve authority in state | W | 0.88 |
| Decision reason survives | reply | 0.95 |
| Actual own-context read recorded | tool calls | 0.81 |
| Follow second correction | reply | 0.90 |
| Late unresolved investigation | reply | 0.93 |
| Late authority and unfinished work | W | 0.86 |

These values are retained without a pass rule. The W propositions do not yet
cover every latest correction, and a judge's probability does not replace
inspection of the scoped W text. Future experiments need negative controls and
stronger correction/freshness propositions before calibrated semantic verdicts.

Two separate source-review/review-response agents read the collector, scenario,
tests and API contracts. Missing imported joins, scenario/restart linkage and
unchecked binary identity were fixed. The final response found no remaining
P0–P2 for source SHA `d4ddb63982307b9ec0da7c89afccc382bba2c48a539f22087a526ffb2ae4d761`. This is same-model
session-separated review, not cross-model review or formal GitHub approval.
They did not execute the real Keeper or the tests.

## 불확실성 (Uncertainty)

- 미확인 항목: The unmerged implementation candidate, all provider attempts, body-level response binding, causal contribution of Librarian, forced history retirement, long-duration operation, server-process restart and other runtimes.
- 영향: Raw history or Recall can preserve a correct answer despite stale W. One trial does not demonstrate overflow prevention or continuity after the original history becomes unavailable.
- 추가 확인 필요: Repeat the identical captured scenario against an explicitly identified candidate binary; compare W correction/freshness and source coverage; add isolated history/Memory/W treatments and judge controls. Track the installed-main stale-W/context finding in [#46955](https://github.com/jeong-sik/masc/issues/46955).

## 적용범위 (Scope)

- 영향 받는 영역: An external observation harness, fixture scenario, collector tests and a common private report format with a readable Markdown projection.
- 제약/배제: No runtime scheduling policy, keyword verdict, probability threshold, compulsory per-turn Librarian trigger, new TUI screen, existing `/measurement` schema claim, deployment or merge.
- 롤백 조건: A mismatched identity, missing original reply, corrupt part/event digest, missing owner record or malformed judge response leaves the observation incomplete. Unknown operations are retained without replay or cancellation.
