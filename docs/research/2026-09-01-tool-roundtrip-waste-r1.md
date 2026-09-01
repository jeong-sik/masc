# keeper 도구 왕복 낭비 실측과 원인 판정 (r1)

하루치 라이브 tool_calls 로그에서, 같은 턴 안에서 같은 도구를 연속으로 다시
부르는 왕복이 전체 호출의 28%임을 측정하고, 세 가지 원인을 코드와 로그로
판정했다. 판정마다 수정 PR이 붙어 있고, 배포 후 같은 스크립트로 재측정한다.

## 결과

측정: `scripts/measure-tool-roundtrips.py --date 2026-09-01` (2026-09-01 20:00 KST 실행 시점)

| 지표 | 값 |
|---|---:|
| tool_call 행 | 7,515 |
| 턴 | 1,459 |
| 같은-도구 연속 재호출로 낭비된 왕복 | **2,115 (28.1%)** |
| — fanout (독립 인자 순차) | 1,642 |
| — duplicate (동일 인자 재호출) | 292 |
| — probing (인자 모양 더듬기) | 181 |
| unchanged 직후 동일-인자 재호출 쌍 | 211 |
| batch_size=1 비율 | 87.0% |

원인 판정과 수정:

| 유형 | 판정 | 수정 |
|---|---|---|
| duplicate | `keeper_tasks_list`의 `if_revision` 조건부 읽기가 `unchanged`(row 0개)에 snapshot 경로의 row 통계(`returned_count:N, truncated:true`)를 그대로 실어 자기모순 응답이 되고, 모델이 모순을 풀려고 동일 인자로 재호출. 재호출 쌍의 직전 응답은 전부 `success=true`·232바이트(에러도 잘림도 아님) | [#32322](https://github.com/jeong-sik/masc/pull/32322) — row 통계를 `Snapshot` variant 한정 |
| probing | enum 위반이 `wrong type — expected: string, got: string("summary")`로 렌더되어 허용값을 알려주지 않음. `field_error.expected`가 자유 문자열이라 생성 시점에 제약 종류가 소거. 교정 정보를 주는 에러(MISSING required, limit max)는 전부 1회에 수렴하는 것과 대조 | [#32326](https://github.com/jeong-sik/masc/pull/32326) — `expected`를 닫힌 variant로, enum/const는 허용값 렌더 |
| fanout | 병렬 실행기(`agent_tool_batch_plan.ml`의 `Concurrent_batch`)는 완비. keeper 시스템 프롬프트에 병렬/묶기 문구 0건 (wire capture의 system_prompt 검색). duplicate 쌍들도 전부 `execution_mode=concurrent`인데 `batch_size=1` — 모델이 안 묶는 것 | [#32327](https://github.com/jeong-sik/masc/pull/32327) — keeper.md에 "도구 호출 묶기" 계약 |

## exact identity

- 로그: `<base-path>/tool_calls/2026-09/01.jsonl` (측정 시점 7,515 tool_call 행)
- 측정 스크립트: `scripts/measure-tool-roundtrips.py` (이 PR에서 추가)
- repo: `aeaeb8cd76` (측정 시점 origin/main)
- 라이브 서버: `_build/default/bin/main_eio.exe`, 2026-09-01 17:04:24 KST 기동
  (위 세 수정 어느 것도 포함하지 않은 바이너리 — baseline 자격)

## baseline

```
$ scripts/measure-tool-roundtrips.py --date 2026-09-01
- tool_call rows: 7515
- turns: 1459
- avoidable round-trips (same-tool runs): 2115 (28.1% of calls)
| fanout | 1642 | keeper_artifact_read 523, Read 270, keeper_memory_search 178 |
| duplicate | 292 | keeper_tasks_list 195, keeper_artifact_read 23, keeper_spawn_read 22 |
| probing | 181 | keeper_tasks_list 34, github_issue_read 26, github_pull_request_read 20 |
unchanged-recall pairs: keeper_tasks_list 211
probe pairs: 109 (first call failed: 45)
batch_size=1: 6539 (87.0%)
```

주의: 로그 파일은 하루 안에서 계속 자라므로 절대값은 실행 시각에 따라 다르다.
비교는 같은 스크립트를 자정 이후(전일 로그 완결 후) 실행한 값끼리 한다.

## 판정 근거 상세

### duplicate — 응답이 스스로 모순

`keeper_tool_task_runtime.ml`이 `Snapshot_protocol.to_yojson` 결과에
`matching_count`/`returned_count`/`truncated`를 Snapshot/Unchanged 구분 없이
prepend 했다. `Unchanged`는 생성자에 rows 자체가 없는 typed variant인데,
응답에는 "15건이 매칭됐고 잘렸다"가 실렸다. 연속 동일-인자 쌍의 직전 응답을
전수 확인한 결과 에러 0건·로그 잘림 0건 — "모델이 결과를 무시"가 아니라
"결과가 자기모순"이 정확한 판정이다.

같은 모양의 다른 producer: `Snapshot_protocol.respond`를 쓰는 board 계열
도구는 row 통계를 prepend하지 않아 이 모순이 없다 (수정 범위 밖 확인).

### probing — 에러 품질의 이분

2026-09-01 실패 446건(호출의 6.2%)의 에러를 분류하면, 교정 정보를 주는
계열(`until: MISSING (required: string)`, `limit 200 exceeds maximum 100`,
`unsupported field(s): limit; accepted: phase`)은 다음 호출이 1회에
수렴한다. 교정 정보가 없는 계열이 probing을 만든다:

1. enum 위반 — `tool_input_validation.ml`의 `expected_property_type`이
   property의 `type` 키만 읽고 `enum`을 버려서 허용값이 소거됨 (#32326)
2. 인프라 실패(memory snapshot 140건, remote_ssh 74건)가 인자 오류와
   구분되지 않아 인자-변경 재시도를 유발 — `keeper_tool_memory_runtime.ml`이
   인자 실패와 인프라 실패를 전부 `Workflow_rejection` 한 클래스로 내보냄.
   `Dependency_unavailable` variant가 있는데 이 파일에서 사용 0건. **후속
   수정 후보** (이번 PR 묶음 범위 밖)
3. `keeper_tasks_list`에 cursor/offset이 없어(#29101 주석이 자인) 모델이
   limit 200 시도 → max 100 거부 → projection=full(58–126KB blob) →
   재-listing으로 보상 행동. **후속 수정 후보**

### fanout — 하네스가 아니라 프롬프트

한 응답의 복수 tool_use는 `agent_tool_batch_plan.ml`이 연속 Concurrent
계약 구간을 `Concurrent_batch`로 묶어 `Eio.Fiber.List`로 병렬 실행한다.
read 계열 도구 다수가 이미 Concurrent 선언이다. 즉 모델이 한 응답에 여러
호출을 내기만 하면 병렬화는 공짜인데, 그렇게 하라는 문구가 프롬프트 어디에도
없었다. 조사한 하네스 전부가 이 계약을 문구+실행기 세트로 운용한다 (아래).

## 외부 하네스 대조 (2026-09-01, 소스 정독)

Claude Code(로컬 사본)·OpenClaw(로컬 사본)·Codex(openai/codex)·
pi(badlogic/pi-mono→earendil-works/pi)·Hermes(NousResearch/hermes-agent)·
Orca(stablyai/orca) 소스를 읽고 대조했다. 수렴 지점:

| 축 | 수렴된 설계 |
|---|---|
| skill/도구 목록 노출 | 이름+한 줄 설명만 예산 내로(컨텍스트의 1–2%, 항목당 캡), 본문은 호출 시 lazy 로드. 예산 초과 시 이름만으로 강등 |
| 병렬 호출 | 프롬프트 문구("독립이면 한 응답에") + 하네스의 안전 판정 병렬 실행. pi는 아예 기본이 parallel |
| 잘림 | 자르지 말고 파일로 퇴적 + preview + 경로 반환 (Claude Code #21841: truncate가 throw보다 총 토큰이 비쌌다는 revert 실측). 잘렸으면 원본 크기와 다음 호출 인자를 명시 |
| 인자 에러 | 다음 호출을 그대로 받아쓸 수 있는 교정형 문구. Hermes는 스키마 전문을 에러에 동봉 |
| 동일 호출 dedup | Claude Code(Read mtime 스텁)·Hermes(참조 스텁) 일부 존재, Codex·pi는 의도적으로 없음 — masc가 넣는다면 자체 설계 영역 |

상세 조사 원문: 세션 산출물(9-agent survey). 필요 시 이 문서의 후속 개정에서
제품별 파일:라인 근거를 부록으로 옮긴다.

## 재측정 계획

세 PR 머지 + 배포 후 24시간 창에서 같은 명령을 실행한다.

| 수정 | 성공 기준 |
|---|---|
| #32322 | unchanged-recall pairs ≈ 0 |
| #32326 | probe pairs 중 first-call-failed 계열의 enum 몫 소멸 (에러 후 1회 수렴) |
| #32327 | batch_size=1 비율 87% → 하락 (프롬프트 개입이라 폭은 모델별로 다를 것) |

미달 시 원인 분석을 이 문서의 r2로 기록한다.
