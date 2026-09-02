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

## r2 — 배포 후 첫 창 (2026-09-02 02:17~09:35 KST, 부분)

배포 경계: 서버 재기동 2026-09-02 02:17:06 KST (`main_eio.exe`, cwd 는 repo root, 그 시점 main 은 #32322·#32326·#32327·#32412·#32424 를 모두 포함). 재기동 뒤 첫 keeper 활동은 09:00 KST 부터라 창이 짧다. 462행·59턴은 하루 창(7,515행)의 6% 라서 아래 수치는 방향만 본다. 확정은 r3(하루 창)에서 한다.

측정: `MASC_BASE_PATH=<base-path> scripts/measure-tool-roundtrips.py --date 2026-09-02` (09:35 KST 실행)

r1 표의 수치는 09-01 20:00 KST 시점(7,515행)이었다. 전일 전체는 그 두 배가 넘는다 — 저녁·밤에 9,700행이 더 쌓였다. 아래 표는 세 창을 나란히 둔다.

| 지표 | 09-01 ~20:00 (r1 시점) | 09-01 전일 | 09-02 02:17~09:35 (r2) |
|---|---:|---:|---:|
| tool_call 행 / 턴 | 7,515 / 1,459 | 17,244 / 2,597 | 462 / 59 |
| 낭비된 왕복 | 2,115 (28.1%) | 7,734 (44.9%) | 259 (56.1%) |
| — fanout | 1,642 | 5,505 | 145 |
| — duplicate | 292 | 1,787 | 97 |
| — probing | 181 | 442 | 17 |
| unchanged 직후 동일-인자 재호출 쌍 | 211 | 211 | 0 |
| batch_size=1 비율 | 87.0% | 79.5% | 88.7% |
| artifact_read: blob / 호출 | 477 / 1,581 | 908 / 3,541 | 19 / 58 |
| artifact_read: 페이지 산수 초과 호출 | 968 | 2,418 | 38 |
| artifact_read: 65536 미만 명시 조각 | 96.5% | 94.8% | 89.7% |

전일 낭비 7,734 를 keeper 로 가르면(meter 의 `### by keeper` 표, 이 PR 에서 추가) 다섯 keeper 가 6,261 이다:

| keeper | 낭비 왕복 | 거의 전부인 도구 |
|---|---:|---|
| code-reviewer | 2,145 | keeper_artifact_read 2,016 |
| edgar.a.poe | 1,412 | keeper_time_now 1,367 |
| kidsnote-pr-jira-checker | 1,385 | atlassian_searchJiraIssuesUsingJql 1,345 |
| polisher | 732 | keeper_artifact_read 270, Read 207, keeper_spawn_read 160 |
| analyst | 587 | keeper_artifact_read 448 |

수정별 판정:

| 수정 | r2 결과 | 판정 |
|---|---|---|
| #32322 unchanged 자기모순 | r2 창에는 `if_revision` 호출이 없다. 대신 09-01 20:21·20:45 KST 의 `unchanged` 응답 2건이 이미 새 모양(5키, row 통계 없음)이고 둘 다 재호출이 없다. 전일 쌍 211 은 20:00 시점과 같은 수 — 그 뒤 새 쌍 0 | n=2 로 확인. 20:00~20:21 사이에 재기동이 있었다 |
| #32326 enum 허용값 렌더 | probe 쌍 5, 전부 첫 호출 실패. 실패 원인은 remote_ssh 도달 불가 5, 잘못된 post_id 3, `masc_board_vote` 인자 1 — enum 위반 0 | 미검증 — enum 경로가 안 탔다 |
| #32327 도구 호출 묶기 | batch_size=1 88.7%, 변화 없음. batch_size 7·8·16 은 전부 한 blob 을 조각내어 병렬로 읽은 것 | 효과 없음(이 창). 조각 병렬은 이 프롬프트 탓이 아니다 — 아래 |
| #32412 artifact_read 설명 | polisher(deepseek flash): blob 4개 전부 1회 통째 읽기(eof=true). analyst(같은 lane): blob 1개에 25회. code-reviewer(sonnet-4-6): blob 5개에 27회 | lane 이 아니라 턴/keeper 단위로 갈린다 — 아래 |

초과 호출 38회의 실체 (raw trace 판독):

- analyst 24회: 기본값 호출이 64,674B 를 통째로 돌려줬는데, 모델이 그것을 "nested blob" 으로 오독하고 지어낸 sha 를 읽으려다 실패한 뒤, "인라인 한계" 라는 거짓 이론으로 30000→6000→2000→512 를 탐색하고 512B 조각 7개를 병렬로 읽었다. 첫 페이지 65,537B 에는 blob 마커도 그 sha 도 없다. → [#32451](https://github.com/jeong-sik/masc/issues/32451)
- code-reviewer 14회: 9,766B blob 을 650B × 16 병렬 조각으로 읽었다. 같은 keeper 가 04:24 KST 턴에서 984,852B WebFetch 전문 artifact 를 650B 간격 탐침으로 알파벳 스캔하던 방식(`test_bash*` 존재 여부 찾기)을 작은 blob 에도 그대로 썼다. 9-01 에도 00~08시에 시간당 100~224회, batch>1 96~100% 로 있었으니 #32327(19:45 KST 머지)보다 앞선다. 근본은 blob 안을 검색할 도구가 없다는 것. → [#32449](https://github.com/jeong-sik/masc/issues/32449)

즉 r1 의 968회는 두 keeper 의 두 가지 행동이 대부분이고, 설명 문구는 polisher 처럼 "설명대로 하는" 턴에만 닿는다. r1 에서 code-reviewer 한 keeper 가 artifact_read 2,288회(76%)였다.

새로 보인 것:

- duplicate 97 중 89가 `keeper_time_now`. edgar.a.poe 가 할 일 없는 자율 턴에서 다음 scheduled wake 까지 5초마다 시계를 폴링한다(한 턴 306회·29분, 9-01 에도 턴당 150~327회). → [#32452](https://github.com/jeong-sik/masc/issues/32452)
- fanout 145 중 90이 `atlassian_searchJiraIssuesUsingJql`(kidsnote-pr-jira-checker, 110회 전부 batch_size=1). 전일로는 1,345회다. 다른 keeper, 다른 원인이라 기록만 한다.
- 실패 호출 중 post_id 가 깨진 것 2건(`p-d threshold-placeholder`, `…b043b sha256=`) — #32451 과 같은 부류(긴 id 복사 오류).

r3 계획: 2026-09-03 하루 창에서 같은 명령. 판정은 keeper 별로 본다 — meter 가 분류와 artifact paging 둘 다 keeper 표를 내도록 이 PR 에서 보강했다(keeper 별 합이 전체와 같은지 assert 로 확인).
