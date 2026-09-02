# keeper 도구 왕복 낭비 재측정과 새 원인 판정 (r2)

r1(2026-09-01)의 수정 3건이 병합된 다음 날, 같은 라이브 로그를 다시 재서 r1 의
판정이 맞았는지 확인하고, r1 이 못 본 더 큰 낭비 하나와 드러나지 않던 결함
둘을 판정했다. 판정마다 수정 PR 이 붙어 있고, 배포 후 같은 방법으로 재측정한다.

## 결과 (`tool_calls/2026-09/01.jsonl` 하루 전체, 09-02 는 10:30 KST 까지)

| 지표 | 09-01 | 09-02 (부분) |
|---|---:|---:|
| tool_call 행 | 17,244 | 1,078 |
| 턴 | 2,597 | — |
| 같은 keeper 의 연속 동일-인자 재호출 쌍 | 2,468 | 247 |
| — `keeper_time_now` | **1,389 (56%)** | 148 |
| — `keeper_tasks_list` | 320 | 1 |
| — `atlassian_searchJiraIssuesUsingJql` | 348 | 48 |
| — `masc_board_post_get` | 100 | 48 |
| tasks_list 재호출 중 직전 응답이 `unchanged` | 314 | **0** |
| 실패 호출 | 790 | 38 |
| 실패 뒤 같은 도구를 다른 인자로 재호출 | 317 | 11 |

r1 의 세 수정은 착지했다. `unchanged` 직후 동일-인자 재호출은 09-02 에 0 이다
(#32322 + #32339 가 라이브). enum 오류 렌더(#32343)와 묶기 문구(#32327)도 main 에
있다. 그런데 연속 재호출 1위는 r1 이 세지 않았던 `keeper_time_now` 였다.

## 판정

| 유형 | 판정 | 수정 |
|---|---|---|
| `keeper_time_now` 폴링 | 기다림을 도구 루프로 표현한다. `edgar.a.poe`(glm-5.3) 가 한 턴(turn 1166) 안에서 18:45:18Z→19:29:52Z 동안 시계를 327번 순차로 읽었다(2,675초, 실행 id 327개, batch 1). 지시문에 "45분마다"가 있고, 그 keeper 는 정확히 45분을 기다렸다. 시각은 이미 매 도구 결과 뒤 `[Temporal] time=` 로 주입되고(#32199), 기상 원시연산 `masc_schedule_create` → `Schedule_due` 도 있으며 이 keeper 는 schedule 을 212건 만든 적이 있다. 없는 것은 "다음 할 일이 나중이면 턴을 끝내라" 는 계약이다. `keeper_time_now` 설명은 "check elapsed time" 을 권했고, `masc_schedule_create` 는 deferred 라 80바이트 요약만 보였다 | [#32472](https://github.com/jeong-sik/masc/pull/32472) — keeper.md 기다림 절, 두 도구 설명, 골든·핀. OCaml 0줄 |
| 실패 등급이 모델에 안 닿음 | `Tool_result.tool_failure_class` 는 producer 가 찍지만 `lib/tool_bridge.ml` 에서 agent_core `error_class` 로 접히고, provider wire 직렬화기는 그 필드를 내지 않는다. 모델은 content + is_error 만 본다. 의존성 실패(memory 스냅샷, remote_ssh)와 인자 오류가 산문으로만 구분됐다 | [#32476](https://github.com/jeong-sik/masc/pull/32476) — bridge `Failed` arm 에 `failure_class=<class> — <다음 행동>` 렌더, 문장은 `config/prompts/tool_failure.<class>.md` |
| producer 가 등급을 뭉갬 | memory write/retract 는 모든 실패를 `Workflow_rejection` 으로 찍었다(09-01 write 실패 92건 중 58건이 `persistence_failed`). memory search 는 스냅샷을 못 읽으면 `failwith` 로 던져 모델이 `Failure("…invalid current Memory OS snapshot…")` 원문을 받았다(79건, 65건은 lab-sangsu 파일) | [#32480](https://github.com/jeong-sik/masc/pull/32480) — typed error_kind 에서 등급 유도, search 는 Result |
| 반복 감지기 미발화 | `keeper_agent_run.ml:156-216` 은 입력+출력 지문이 모두 같아야 발화한다. 시계는 출력이 매번 달라 327회에도 걸리지 않는다. 상한을 두는 것은 헌법 `budget_gate` 위반이라 하지 않는다 | 없음(원인 쪽 수정으로 대체) |
| 묶음률은 모델 속성 | concurrent 가능 호출 중 batch≥2 비율을 #32327 병합(10:45Z) 전/후로 나누면 sonnet 79→91%, deepseek 54→43%, glm-5.3 18→4%, codex gpt-5.6 0→0%, gemini-3-7-flash 0→3%. 문구는 sonnet 에만 닿았다. `[C;S;C]` 조각남은 995개 다중-concurrent 응답 중 21개로 무시 가능. OpenAI 계열 wire 는 기본이 병렬이고(`backend_openai_serialize.ml:896-901` 은 끌 때만 필드를 냄) Gemini/Ollama 는 플래그가 없다. CLI 런타임(codex, agy)은 masc 통제 밖 | 없음(코드 레버 없음). 공식 문서 evidence 없이는 capability 행도 바꾸지 않는다 |
| `keeper_tasks_list` cursor 부재 | limit 1..100, 라이브 backlog 491 vs page 50. `truncated:true` 만 주고 나머지에 닿을 길이 없다. polisher 는 매 턴 board 검색으로 우회한다(`polisher.memory-current.json`) | 후속: 키셋 cursor `(priority, created_at, id)` |
| "warming" 오진 | `masc_keeper_status` 는 이미 typed "keeper not found" 를 낸다(`keeper_status_detail.ml:259`). 잔여는 `/api/v1/dashboard/tools` 콜드 캐시가 부재 keeper 에도 1회 warming placeholder 를 시드하는 것(`server_dashboard_http_runtime_info.ml:2523-2525`) | 후속: 시드 전 meta 존재 확인 |

## 이전 보고서 항목의 정정

- "스크립트 제출형 합성 RFC 필요" — `RFC-tools-as-shell-commands`(Draft) 가 그 자리에 있고 PR-1 이 #32427/#32436/#32441 로 착지 중이다. `keeper_plan_execute` 는 #31617 에서 삭제됐다.
- "keeper_time_now 는 없던 항목" — r1 의 3분류(fanout/duplicate/probing)는 `keeper_time_now` 를 duplicate 로 세었어야 하나 r1 표에는 `keeper_tasks_list 195` 만 올랐다. r1 측정 시각(18:37, 6,738행)이 edgar 의 18:45 이후 폴링을 아직 못 본 것이다.

## 같은 모양의 다른 루프 (이번 범위 밖)

`atlassian_searchJiraIssuesUsingJql` 348쌍(kidsnote-pr-jira-checker)과 `masc_board_post_get`
100쌍은 시간 대기가 아니라 관찰 폴링이다. `docs/audits/keeper-fleet-waiting-audit-20260902.md`
§3 과 `RFC-observe-by-waking-not-polling`(Draft) 영역이다.

## 재측정 계획

| 수정 | 성공 기준 | 방법 |
|---|---|---|
| #32472 | `keeper_time_now` 연속 중복 쌍/일 1,389 → 100 미만, 턴당 최대 327 → 3 이하, edgar 이벤트 큐에 `Schedule_due` 유입 | 아래 집계 + `keepers/edgar.a.poe/event-queue-transitions-*.jsonl` |
| #32476 + #32480 | 실패 뒤 인자변경 재시도 317 을 `failure_class` 로 분해했을 때 `dependency_unavailable` 몫 → 0 근처 | `tool_calls` 행의 새 `failure_class` 열 |
| 후속 cursor | tasks_list 연속 동일 쌍 320 → 0 근처, `truncated:true` 뒤 cursor 없는 호출 → 0 | 같은 집계 |

측정 로직과 원본 수치는 `2026-09-02-tool-roundtrip-waste-evidence-record.md` 에 있다.
