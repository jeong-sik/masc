# Librarian 범위 없는 제약 사례 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-11-09T14:10:00+09:00`
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
  GitHub reviews API(#50264·#50269·#50298·#50297·#50293)
- 확인일시: `2026-11-09T10:50:00+09:00` ~ `2026-11-09T14:05:00+09:00`
- 신뢰도: `High` 시각, 문구, 출처 종류. `Medium` 01:47Z 위임이 01:50Z 기억의 직접 원인이라는 해석(시간 순서와 claim 문구로 판단).
- 제한조건: 완료된 operation 은 `input_json` 이 비어서 원문은 raw trace 에서 읽었다. rev 255 는 1건 추가, 1건 제거다.

- 항목: [근거] 잘못된 Draft COMMENT 는 기억보다 먼저 났다. 01:47:25Z 위임을 받은 턴 안에서 01:48:37Z 에 Draft #50264 에 COMMENT 가 게시됐다.
- 출처: GitHub reviews API(#50264, 본문 서명 `code-reviewer-sister`), sister `chat-operations.sqlite3`
- 확인일시: `2026-11-09T14:00:00+09:00`
- 신뢰도: `High` 시각과 Draft 상태(리뷰 본문에 `Draft` 와 head 가 적힘). `Medium` 작성 Keeper(서명은 인증이 아니고 계정을 Keeper 셋이 같이 씀).
- 제한조건: 한 건이다.

- 항목: [근거] 그 기억은 66분 동안 그 Keeper 의 턴에서 읽히지 않았다. 01:47~03:01Z 16턴의 도구 호출은 Execute 79회, artifact 읽기 1회, Board 읽기 1회, Board 댓글 1회이고 기억 검색은 0회다.
  턴 프롬프트의 기억 칸은 본문 없이 개수만 보인다(bodies omitted).
- 출처: sister `raw-traces/turn-*.jsonl`(호출 id 기준 집계), `last-prompt.json`
- 확인일시: `2026-11-09T13:10:00+09:00`
- 신뢰도: `High`
- 제한조건: trace 한 줄이 아니라 호출 id 하나를 한 번으로 셌다.

- 항목: [근거] 리더 위임의 판정 문장이 바뀐 시각. 옛 문장은 01:47:25Z·01:59:27Z·02:02:19Z 에 나왔고 02:02~02:47Z 위임에는 Draft 언급이 없다. 새 문장("Draft는 검토한 범위에 맞는 판정")은 02:52:11Z 에 처음 나왔다.
  sister 는 02:54:41~49Z 에 Draft PR 셋에 APPROVE 했고 GitHub 가 받았다. 01:59Z 위임 대상 #50269 는 그새 Ready 가 돼서 02:00:52Z 에 APPROVE 했다.
- 출처: 리더 `<base-path>/.masc/keepers/code-reviewer/chat-operations.sqlite3`(읽기 전용), GitHub reviews API
- 확인일시: `2026-11-09T13:10:00+09:00` ~ `2026-11-09T14:05:00+09:00`
- 신뢰도: `High` 시각과 문구. 리더가 새 문장을 어디서 가져왔는지는 모른다.
- 제한조건: 리더 턴이 읽은 checkout 에 라우팅 문서 병합이 언제 반영됐는지 확인하지 않았다.

- 항목: [근거] 리더의 5분 순회 예약 메시지에 옛 규칙 "판정: Draft는 검토한 범위에 맞는 COMMENT를 남긴다"가 있었고, 예약이 울릴 때마다 「Scheduled Wake」 절로 리더 턴에 들어갔다(01:22~05:57Z 리더 턴 201개 중 56개).
  05:17Z 부터 리더 위임에 옛 문장이 다시 실렸고, 05:18~05:58Z 에 Draft PR 8개(#50418·#50419·#50433·#50435·#50439·#50440·#50441·#50443)에 판정 대신 COMMENT 가 달렸다. 06:01:06Z 에 운영자 권한으로 예약 메시지에서 그 문장을 지웠다.
- 출처: `<base-path>/.masc/schedules.json`(읽기 전용 조회, 수정은 `POST /api/v1/tools/masc_schedule_update`), 리더 `raw-traces/turn-*.jsonl` 첫 줄 `prompt`, GitHub GraphQL reviews
- 확인일시: `2026-11-09T15:04:00+09:00`
- 신뢰도: `High` 문장 위치와 시각. `Medium` 01:47Z 옛 위임의 출처가 이 메시지라는 해석(그 턴에도 들어 있었다는 사실로 판단).
- 제한조건: 05:17Z 에 옛 문장으로 돌아간 계기는 확인하지 않았다. 수정 뒤 확인은 리더 턴 4개(06:01~06:03Z)뿐이다.

- 항목: [근거] "Draft 면 COMMENT" 절은 라우팅 문서와 샘플 지시문에 있었다. 공유 프롬프트 `keeper.md` 에는 "COMMENT 전담자" 역할 문장만 있었고 Draft 언급은 없었다.
- 출처: 커밋 `3687b61fc2d6`(#50261) diff 의 `config/prompts/pr-review-routing.md`, `config/keepers/code-reviewer.toml`, `config/prompts/keeper.md`
- 확인일시: `2026-11-09T14:00:00+09:00`
- 신뢰도: `High`
- 제한조건: 스킬 2개와 라이브 지시문 9개는 같은 커밋 밖에서 바뀌었다.

- 항목: [근거] 프롬프트는 서버마다 배포 기본값과 운영자 변경으로 정해진다. 라우팅 문서는 턴에 들어가는 경로가 없다.
- 출처: `lib/managed_asset_sync.mli`(prompts·tools·mcp 동기화, `prompt_overrides.json`, Keeper manifest 는 동기화하지 않음),
  `lib`·`bin` 의 `pr-review-routing` 검색 0건,
  리뷰어 7명의 `raw-traces/turn-*.jsonl`(Keeper 당 200~202개, 가장 이른 파일 2026-11-06T14:57Z) 글 검색: 파일 이름이 나온 턴 19개, 그중 #50261·#50271·#50384 가 같이 나온 턴 14개, 나머지 5개는 diff·파일 목록·인용
- 확인일시: `2026-11-09T14:45:00+09:00`
- 신뢰도: `High` 동기화 동작과 코드 검색. `Medium` raw trace 집계(글 검색이고, 남은 턴만 셌다).
- 제한조건: 14개 턴이 그 PR 을 리뷰한 턴인지는 번호가 같이 나온 것으로만 판단했다.

- 항목: [근거] 기억 행에는 적용 범위 칸이 없고, Librarian 이 만든 행의 `origin.trace_id` 는 비어 있다.
  그 이유로 든 주석은 journal 이 정확한 trace 를 가진다고 하지만, 라이브 Keeper 35명의 Librarian journal 항목 51,836개는 Keeper 마다 trace 값이 하나뿐이다.
- 출처: `lib/keeper/keeper_memory_os_types.mli:335`, `lib/keeper/keeper_librarian.ml:560-569`,
  리뷰어 9명의 `memory-current.json` 집계(897행 중 trace_id 있는 행 0, 03:18Z),
  35명의 `memory-journal.jsonl` 집계(`source.kind=librarian` 항목의 서로 다른 `source.trace_id` 수), 이슈 #50412
- 확인일시: `2026-11-09T12:18:00+09:00`, `2026-11-09T13:55:00+09:00`
- 신뢰도: `High`
- 제한조건: 집계는 그 시각의 스냅숏이다. 주 경로의 `turn_ref` 가 어디서 오는지는 끝까지 따라가지 않았다.

- 항목: [근거] Librarian 은 claim 마다 근거 대화 위치를 계산해 흡수 판정에 쓰고, 행에는 남기지 않는다.
- 출처: `lib/keeper/keeper_librarian.ml:94`(`cited`), `lib/keeper/keeper_librarian_runtime.ml:938-953`, `lib/keeper/keeper_memory_os_types.mli:185`·`:295`
- 확인일시: `2026-11-09T12:40:00+09:00`
- 신뢰도: `High` 계산과 쓰임. `Low` 흡수 판정 기록이 커밋 뒤에도 근거 위치를 들고 있는지(확인 안 함).
- 제한조건: 소스 읽기만 했다.

- 항목: [근거] Librarian 입력에는 Keeper 지시문만 들어가고 공유 `keeper.md` 와 라우팅 문서는 없다. 정리 패스는 개수 초과 때만 돈다.
- 출처: 주 경로 `lib/keeper/keeper_librarian_queue_refresh.ml:488`·`:892`, 재캡처 경로 `lib/keeper/keeper_librarian_admission_owner.ml:111`,
  `config/prompts/librarian.md` 의 template_variables(5행), `lib/keeper/keeper_memory_cleanup.mli:1-3`
- 확인일시: `2026-11-09T11:55:00+09:00`, `2026-11-09T14:05:00+09:00`
- 신뢰도: `High` 입력 목록. `Medium` "다른 재검토 계기가 없다"(호출처 전수 조사는 안 함).
- 제한조건: 소스 읽기만 했다. 실행 경로 추적은 안 했다.

- 항목: [근거] 바뀌기 쉬운 분류의 크기는 9명 기억 893개 중 `constraint`+`preference` 127개, 그중 01:30Z 전에 마지막으로 확인된 것 113개다.
- 출처: 리뷰어 9명의 `memory-current.json` 집계
- 확인일시: `2026-11-09T12:05:00+09:00`
- 신뢰도: `High` 개수. `Low` "113개가 다시 검증할 대상"이라는 해석(상한일 뿐 실제 낡은 수는 모름).
- 제한조건: 한 번의 지시에서 온 행이 몇 개인지는 분류하지 않았다.

- 항목: [근거] 기억이 남아 있던 01:50:53Z~02:57:15Z 에 리뷰 계정이 Draft 를 이유로 판정을 미룬 COMMENT 는 0건이다. 같은 기간 COMMENT 1건(#50242)은 다른 Keeper 의 Ready PR 관점 의견이다.
- 출처: GitHub GraphQL, 최근 갱신 PR 100개의 reviews(PR 당 마지막 40개), 계정별·시간 구간별 집계
- 확인일시: `2026-11-09T12:35:00+09:00`
- 신뢰도: `Medium`. 계정을 Keeper 셋이 같이 써서 sister 의 리뷰만 가를 수 없다. PR 100개 밖의 리뷰는 세지 않았다.
- 제한조건: "Draft 를 이유로 미룸"은 본문 앞 300자에 `Draft` 가 있는 COMMENT 로 셌다(측정용 근사). 기억이 생기기 전 01:48:37Z COMMENT 는 이 구간 밖이라 위 항목에 따로 적었다.

- 항목: [근거] 리뷰어 9명의 `constraint` 114개 중 위임·요청 낱말(`위임`, `요청 기준`, `이번 요청`, `의뢰`)이 든 것은 4개이고, 위임 한 번을 정책으로 굳힌 것은 1건이다.
  다른 분류에서 1건이 더 있다. mother 의 `review_delegation` 기억(2026-11-06T03:11Z)은 "Draft 위임은 판정 줄 없이 … COMMENT"를 반복되는 위임 형식으로 적었고 14:05 KST 에도 남아 있다.
- 출처: 리뷰어 9명의 `memory-current.json`
- 확인일시: `2026-11-09T12:35:00+09:00`, `2026-11-09T14:05:00+09:00`
- 신뢰도: `Low`. 낱말로 센 측정용 추정이라 놓친 행이 있을 수 있다.
- 제한조건: 손으로 분류한 표본이 없다.

- 항목: [근거] 선택지 판정은 세 모델이 따로 했다. Sonnet 과 Fable 에는 원자료와 질문만 주고 답을 정한 뒤 분석 문서를 읽게 했다. 세 모델 모두 6.0(정책 정본 하나)을 지금 할 일로, 6.3·6.4 를 하지 않을 일로 골랐다.
- 출처: 이 세션의 하위 에이전트 응답(저장소에 넣지 않음)
- 확인일시: `2026-11-09T12:50:00+09:00`
- 신뢰도: `Medium`. 같은 원자료를 받았으므로 독립 표본이 아니다.
- 제한조건: 이 판정은 근거가 아니라 의견이다.

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
