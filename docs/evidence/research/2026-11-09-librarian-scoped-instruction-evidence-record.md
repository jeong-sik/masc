# Librarian 범위 없는 제약 사례 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-11-09T12:20:00+09:00`
- 작성자: `Claude Code (Opus 5.5)`
- 결정 ID: `librarian-scoped-instruction-stale-constraint-r1`
- 적용 대상: `MASC_BASE_PATH=~/me` 의 `.masc`, main `95c0fb274d4d`
- 결정 상태: `추적 필요`
- 분석: [2026-11-09-librarian-scoped-instruction-stale-constraint-r1](../../research/2026-11-09-librarian-scoped-instruction-stale-constraint-r1.md)

## 근거

- 항목: [근거] 리뷰어 Keeper 하나가 01:47:25Z 위임 한 번의 지시를 01:50:53Z 에 상시 `constraint` 로 저장했다.
  이 제약은 02:57:15Z 에 이유와 함께 `dropped` 됐다.
- 출처: `<base-path>/.masc/config/keepers/code-reviewer-sister.memory-journal.jsonl` 의 rev 249·255·259 항목(`source.kind=librarian`),
  `<base-path>/.masc/keepers/code-reviewer-sister/chat-operations.sqlite3` 의 `operations`(읽기 전용 조회),
  같은 Keeper 의 `raw-traces/turn-1794188846492-369d-000471.jsonl`,
  GitHub reviews API(#50298·#50297·#50293)
- 확인일시: `2026-11-09T10:50:00+09:00` ~ `2026-11-09T12:10:00+09:00`
- 신뢰도: `High` 시각, 문구, 출처 종류. `Medium` 01:47Z 위임이 01:50Z 기억의 직접 원인이라는 해석(시간 순서와 claim 문구로 판단).
- 제한조건: 한 Keeper, 한 사례. 완료된 operation 은 `input_json` 이 비어서 원문은 raw trace 에서 읽었다.

- 항목: [근거] 기억 행에는 적용 범위 칸이 없고, Librarian 이 만든 행의 `origin.trace_id` 는 비어 있다.
- 출처: `lib/keeper/keeper_memory_os_types.mli:335`, `lib/keeper/keeper_librarian.ml:569`,
  리뷰어 9명의 `memory-current.json` 집계(897행 중 trace_id 있는 행 0, 03:18Z)
- 확인일시: `2026-11-09T12:18:00+09:00`
- 신뢰도: `High`
- 제한조건: 집계는 그 시각의 스냅숏이다. 행 수는 턴마다 바뀐다.

- 항목: [근거] Librarian 입력에는 Keeper 지시문만 들어가고 공유 `keeper.md` 는 없다. 정리 패스는 개수 초과 때만 돈다.
- 출처: `lib/keeper/keeper_librarian_admission_owner.ml:111`, `config/prompts/librarian.md` 의 template_variables(5행),
  `lib/keeper/keeper_memory_cleanup.mli:1-3`
- 확인일시: `2026-11-09T11:55:00+09:00`
- 신뢰도: `High` 입력 목록. `Medium` "다른 재검토 계기가 없다"(호출처 전수 조사는 안 함).
- 제한조건: 소스 읽기만 했다. 실행 경로 추적은 안 했다.

- 항목: [근거] 바뀌기 쉬운 분류의 크기는 9명 기억 893개 중 `constraint`+`preference` 127개, 그중 01:30Z 전에 마지막으로 확인된 것 113개다.
- 출처: 리뷰어 9명의 `memory-current.json` 집계
- 확인일시: `2026-11-09T12:05:00+09:00`
- 신뢰도: `High` 개수. `Low` "113개가 다시 검증할 대상"이라는 해석(상한일 뿐 실제 낡은 수는 모름).
- 제한조건: 한 번의 지시에서 온 행이 몇 개인지는 분류하지 않았다.

- 항목: [근거] 그 기억이 남아 있던 01:50:53Z~02:57:15Z 에 리뷰 계정이 Draft 를 이유로 판정을 미룬 COMMENT 는 0건이다. 같은 기간 COMMENT 1건(#50242)은 다른 Keeper 의 Ready PR 관점 의견이다.
- 출처: GitHub GraphQL, 최근 갱신 PR 100개의 reviews(PR 당 마지막 40개), 계정별·시간 구간별 집계
- 확인일시: `2026-11-09T12:35:00+09:00`
- 신뢰도: `Medium`. 계정을 Keeper 셋이 같이 써서 sister 의 리뷰만 가를 수 없다. PR 100개 밖의 리뷰는 세지 않았다.
- 제한조건: "Draft 를 이유로 미룸"은 본문 앞 300자에 `Draft` 가 있는 COMMENT 로 셌다(측정용 근사).

- 항목: [근거] 리뷰어 9명의 `constraint` 114개 중 위임·요청 낱말(`위임`, `요청 기준`, `이번 요청`, `의뢰`)이 든 것은 4개이고, 위임 한 번을 정책으로 굳힌 것은 1건이다.
- 출처: 리뷰어 9명의 `memory-current.json`
- 확인일시: `2026-11-09T12:35:00+09:00`
- 신뢰도: `Low`. 낱말로 센 측정용 추정이라 놓친 행이 있을 수 있다.
- 제한조건: 손으로 분류한 표본이 없다.

## 외부 자료

읽은 방법을 세 가지로 나눴다.
- 직접: 본문 텍스트를 받아 `rg` 로 문구를 확인했다.
- 본문: 하위 에이전트가 arXiv HTML 본문을 열어 읽었다.
- 요약: 요약 도구나 GeekNews 요약만 거쳤다.

수치는 표·절 번호와 함께 분석 문서에 옮겼다.
본문 사본은 세션 scratchpad 에 있었고 저장소에는 넣지 않았다(저작권과 크기 때문).

| 자료 | 읽은 방법 | 직접 확인한 문구·수치 | 신뢰도 |
|---|---|---|---|
| Anthropic, components of agent memory | 요약(원문 페이지) | "The transcript gave Claude a ground truth…", Fig. 5 오른쪽 −0.234/−0.150/−0.020 | Medium |
| GeekNews 36775·36856·36733·36823 (Ramp, DoorDash, Murat) | 요약(GeekNews) | — | Low |
| STALE arXiv 2605.06527 | 본문 + 직접 | "visibility does not imply authority", 77.5% | High(직접 문구), Medium(나머지) |
| Supersede 2606.27472 | 본문 | — | Medium |
| TEPA 2608.07429 | 본문 + 직접 | "append-only and last-write-wins both 0.210, no memory 0.309, TEPA 0.950" | High |
| When Stale Constraints Go Unchecked 2608.25553 | 본문 + 직접 | "34/150 to 145/150", "reads as settled, and is wrong" | High |
| StateAuditor 2608.01619 | 본문 | — | Medium |
| Don't Ask the LLM to Track Freshness 2606.01435 v1·v2 | 본문 + 직접 | v2 "changing only the final policy executor contributes 2.0 pp on average and 0 pp at 262K" | High |
| Zep 2501.13956 | 본문 | — | Medium |
| TOKI 2606.06240 | 본문 | — | Medium |
| MemStrata 2606.26511 | 본문 + 직접 | AUROC 0.5926 | High |
| Misattribution Gap 2605.22842 | 본문 + 직접 | "summary-mediated laundering" | High |
| From Untrusted Input to Trusted Memory 2606.04329 | 본문 | — | Medium |
| MemLineage 2605.14421 | 본문 | — | Medium |
| Memory Trust Gap 2609.01852 | 본문 + 직접 | Table 7 원 정확도 0.49/0.43/0.37/0.41, 표식 0.79/0.72/0.90/0.95, 충돌 해소 0.95/1.00/1.00/1.00 | High |
| Sleep-time Compute 2504.13171 | 요약(본문 페이지) | — | Medium |
| Mem0 2504.19413 | 요약(본문 페이지) | — | Medium |
| Memory-R1 2508.19828 | 요약(본문 페이지) | — | Medium |
| A-MEM 2502.12110 | 요약(본문 페이지) | — | Medium |
| LongMemEval 2410.10813 | 직접 | KU 판정 기준 문구, Table 6·7 | High |
| Instruction Hierarchy 2404.13208 | 직접 | system > user > tool 순서, "never follow instructions during browsing or tool use" | High |

- 확인일시: `2026-11-09T11:30:00+09:00` ~ `2026-11-09T12:15:00+09:00`
- 제한조건: arXiv 날짜가 2026 년인 논문 다수는 프리프린트다. 동료 심사 여부는 확인하지 않았다. 한 저자 논문이 여럿이다(Supersede, TOKI, MemStrata, 2608.25553).
