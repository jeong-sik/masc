---
rfc: "0379"
status: Draft
---

# RFC-0379 — Keeper Monitor: 조건 전이가 Keeper 를 깨운다 (Event-Driven Wake)

- Status: draft
- Author: dashboard-admin (Claude)
- Origin: Fusion run `kmsg-27be397a51c68df14db74dfef17f0c36` (rondo, trio/refine, 2026-08-14)

## 1. 문제

Keeper 의 wake 소스는 시간뿐이다 (`masc_schedule_*`: one_shot / interval / daily / cron).
런타임 조건의 **전이** — 서버 프로세스 재기동, 파일 변경, 포트 개통, HTTP 응답 회복 — 를 기다렸다가
깨어나는 방법이 없다. 그래서 keeper 는 조건을 기다리려면 짧은 interval schedule 로 폴링 턴을
소모하거나 (턴 낭비 + noop 판정 오염), 아예 포기한다.

실측 동기: 2026-08-14 dashboard-admin 이 "서버 정지 감시 → purge → 부팅 감시 → 검증 배터리"
흐름을 세션 외부 Monitor 로 수행했다. rondo 가 이 패턴을 관찰하고 fusion 으로 설계를 요청했다
(run 위). 같은 날 keeper 관점의 결핍 사례: 재기동 후 새 빌드 검증을 keeper 가 스스로 이어받을
방법이 없다.

## 2. 설계 (v1)

### 2.1 Trigger — 조건이 아니라 전이

```
type trigger =
  | Port_up of { host : string; port : int }
  | Port_down of { host : string; port : int }
  | File_changed of { path : string }          (* mtime 또는 inode 변화 *)
```

- **Edge-triggered**: 발화는 관측된 상태 전이에서만 일어난다. 최초 관측은 baseline 설정이며
  발화하지 않는다 (부팅 직후 monitor 전체가 일제히 발화하는 boot-storm 을 구조적으로 차단).
- 근거: "대기자 확인 없는 알림은 무조건 발화가 된다" — 2026-08 keeper 턴율 13.3배 사고의 교훈.
  level-triggered 는 v1 에 존재하지 않는다.

### 2.2 수명 — 기본은 one-shot

- `max_fires` 기본 1. 발화 즉시 monitor 레코드 삭제 (죽은 행을 남기지 않는다).
- `expires_at` 필수. 만료 시 sweep 이 삭제한다. 미발화 만료는 wake 없이 조용히 사라진다.
- keeper 당 활성 monitor 상한 (상수, `max_active_monitors_per_keeper`).

### 2.3 Wake — 기존 파이프라인 재사용

발화는 schedule 과 동일한 wake 경로로 들어간다: 새 stimulus class `monitor_fired`,
payload 는 keeper 가 create 시 넣은 opaque 값 그대로 + monitor id + 관측된 전이
(`{ from; to; observed_at }`). 새 배달 경로·큐·계약을 만들지 않는다.

### 2.4 Engine — 데몬이 아니라 서버 fiber

masc 서버 자체가 sandbox 밖 상주 프로세스다. `Monitor_runner` 는 schedule runner 와 같은
자리(server bootstrap)에서 도는 Eio fiber 하나이며, 적응형 인터벌로 관측한다
(조건 미충족 시 2s, 충족 상태 유지 시 10s — fusion 패널 합의값). inotify/kqueue/pidfd 같은
OS 이벤트 프리미티브는 v1 에서 쓰지 않는다 (macOS/Linux 이식성, 관측 대상 수가 작음).

### 2.5 Store

`<base-path>/.masc/monitors/` 아래 schedule store 와 같은 방식의 typed 저장.
서버 재기동 시 리로드하되 **last_state 는 리로드하지 않는다** — 재기동 후 최초 관측이 새
baseline 이다 (재기동 동안의 전이를 소급 발화하지 않는다; 그 시맨틱이 필요한 keeper 는
one_shot schedule 로 즉시 확인 턴을 함께 건다).

### 2.6 Tools

`masc_monitor_create` / `masc_monitor_list` / `masc_monitor_cancel` — schedule 도구와 같은
catalog/schema/dispatch 결. create 입력: trigger, payload(opaque), expires_at, (max_fires).
반환: monitor id + 수락된 trigger 의 정규화 형태.

## 3. 비범위 (fusion 패널 제안 중 기각)

| 제안 | 기각 근거 |
| --- | --- |
| 별도 monitor 데몬 | masc 서버가 이미 그 데몬이다. 새 프로세스 = 새 운영 표면 |
| capability token / allowlist / audit | single-user; 게이트는 목표 달성 후 (운영 원칙) |
| `arm`/`disarm`, `history`, versioned API | v1 수명이 one-shot 중심이라 상태 기계가 없다 |
| `log_pattern` trigger | tail+regex 는 string 분류기 축 재개방. 로그가 아니라 상태를 관측한다 |
| `Http_ok` trigger | v1.1 유예: 저장소에 Eio HTTP 클라이언트 실사용 선례가 없고, TCP 도달성으로 2xx 를 흉내내면 트리거 이름이 거짓말이 된다 |
| process(pidfd) trigger | v1 대상 사례(서버 재기동)는 Port_up/Port_down 으로 충분 |
| cooldown | max_fires=1 이 대체한다. 반복 monitor 는 v2 에서 전이 시맨틱과 함께 |

## 4. 구현 계획

1. `lib/monitor/`: `monitor_domain.ml(i)` (trigger/record/전이 판정 순수 함수),
   `monitor_store.ml(i)`, `monitor_runner.ml(i)`
2. tool schemas + catalog dispatch arms + surfaces 등록 (schedule 미러)
3. server bootstrap 에 runner 기동 1줄
4. `keeper_event_queue` 에 `monitor_fired` class 추가 (continuation 아님 — 자율 wake)

## 5. 검증

- 전이 판정 순수 함수 테스트: baseline 무발화, Up→Down/Down→Up 발화, 동일 상태 무발화,
  만료 삭제, max_fires 소진 삭제 (suite 는 CI focused allowlist 에 배선)
- 라이브: keeper 가 `Port_down(:8935)`+`Port_up(:8935)` monitor 를 걸고 서버 재기동을
  관측해 검증 턴을 스스로 실행하는 것 — rondo 의 원 시나리오 재현이 완료 기준

## 6. 측정 수요 — GitHub 실행이 끝나기를 기다리는 호출 (2026-11-05)

v1 트리거(`Port_up`, `Port_down`, `File_changed`)는 §1 의 서버 재기동 사례를 겨냥한다. 이 세 트리거의 수요는 재지 않았다. 도구 호출 원장에서 Keeper 가 오래 기다리는 대상을 재 보니 GitHub 쪽 상태(Actions 실행)를 기다리는 것으로 보이는 호출이 가장 컸다.

`docs/evidence/execute-waits-2026-11/measure_execute_waits.py` 로 11-01T00:00Z ~ 11-05T05:00Z 를 쟀다. 정의와 한계는 그 폴더의 README 에 있다. 턴 시간은 같은 창의 Keeper trace 파일로 센 값이다. 읽는 코드는 `docs/evidence/lane-time-2026-11/measure_lane_time.py` 의 것을 같이 쓰고, 그 폴더의 `result-2026-11-01_11-05.json` 과 같은 값이 나온다. `Execute` 117.15시간 중 26.16시간(22.3%)은 호출한 Keeper 의 턴 구간에 들지 않는다. 그중 24.72시간은 trace 파일이 없는 턴의 호출이다(`result-2026-11-01_11-05.json` 의 `turn_time.calls_without_trace_file`). 그래서 턴 시간에 대한 비율은 구간 안의 시간으로만 센다.

| 측정 | 값 |
|---|---|
| `Execute` 호출 | 75,471건, 117.15시간 |
| 같은 창의 Keeper 턴 시간 (Keeper 28명의 합) | 792.17시간. `Execute` 중 턴 구간 안은 90.98시간 (턴 시간의 11.5%) |
| 60초 이상 걸린 호출 | 729건, 56.52시간 (`Execute` 시간의 48.2%). 턴 구간 안은 47.24시간 (턴 시간의 6.0%) |
| 60초 이상 호출 중 실행 번호가 있거나 `gh` 를 쓰는 호출 | 450건, 39.46시간 (60초 이상 호출 시간의 69.8%). 턴 구간 안은 35.52시간 (턴 시간의 4.5%). 실행 번호가 있는 호출만 246건, 27.58시간 (48.8%) |
| 60초 이상 호출 중 빌드·시험 도구를 쓴 호출 | 84건, 4.58시간 (60초 이상 호출 시간의 8.1%) |
| 60초 이상 호출 중 그 밖 | 195건, 12.48시간 (22.1%). 무엇을 기다리는지 가리지 못했다 |
| 60초 이상 호출 중 `sleep` 든 호출 | 378건, 36.77시간. 이 시간 중 실행 번호가 있거나 `gh` 를 쓰는 호출이 35.16시간 (95.6%), 실행 번호가 있는 호출만 27.23시간 (74.0%). 번호를 변수로 넘기는 호출은 번호를 못 읽어서 실행 번호 쪽 비율은 하한이다 |
| 실행 기다림 (Keeper 하나와 실행 번호 하나) | 188개. 폴링 277번, 막힌 시간 27.41시간 (`Execute` 시간의 23.4%). 턴 구간 안은 24.75시간 (턴 시간의 3.1%). 기다림당 중앙값 7.1분·p90 17.0분·최대 46.7분 |
| 기다림이 걸린 저장소 (명령에 이름이 보이는 156개) | `jeong-sik/masc` 95개(11.83시간), `jeong-sik/wkbl` 61개(11.07시간). 나머지 32개(4.52시간)는 명령에 저장소 이름이 없다 |
| 실행 번호가 든 일정 (`masc_schedule_create`, Keeper 가 자기를 깨움) | 81건 (자기를 깨우는 240건 중). Keeper 와 실행 번호 쌍으로 68개. `due_in_sec` 중앙값 1,500초 |

- 호출 종류는 명령 문자열로 붙인 이름이다. `gh` 를 쓴다고 GitHub 를 기다렸다는 증거는 아니다. `sleep` 했다가 `gh` 로 상태를 보는 명령이라서 GitHub 쪽 상태를 기다린 것으로 읽었다(추정). 위 450건 중 `sleep` 이 없는 호출은 4.30시간이고, 이 시간은 기다림의 증거가 아니다.
- Keeper 다섯 명(`wkbl-data`, `masc-productor-owner`, `sangsu`, `wkbl-front`, `e-masc-the-leader`)이 `sleep` 으로 기다리는 방법과 일정으로 깨우는 방법을 둘 다 썼다. 같은 실행에 둘 다 썼다는 뜻은 아니다.
- `masc_schedule_create` 도 `defer_loading = true` 인데 같은 기간 기록된 결과가 성공인 호출이 326건이다. 지연 로딩만으로 도구가 안 쓰이지는 않는다. 같은 설정인 `keeper_job_*` 는 0호출이다(`docs/reports/2026-11-05-tool-efficiency.md` §6).
- 일정은 시각으로만 깨운다. 일정 시각과 실제로 실행이 끝난 시각의 차이는 재지 않았다.
- `lib/` 에서 GitHub 실행의 완료를 보고 Keeper 를 깨우는 코드는 찾지 못했다(`workflow_run`, `check_run`, `check_suite`, `actions/runs`, `x-github-event` 를 `rg` 로 찾았고 걸린 것은 이름만 비슷한 `check_runtime_*` 뿐이다). `RFC-keeper-world-state-shows-open-work` §1.1 도 GitHub 이벤트 유입이 없다고 적는다.

### 6.1 제안 — 트리거 하나 더 (결정이 아니다)

```
type trigger =
  | (* §2.1 의 셋 *)
  | Github_run_completed of { repo : Github_repo.t; run_id : int; run_attempt : int }
```

- 입력은 타입으로 받는다. `Github_repo.t` 는 새로 만들 타입이고, `owner` 와 `name` 을 따로 검증해 만든다(영문·숫자·`_`·`.`·`-` 만 허용하고 `.` 과 `..` 는 거절한다). `run_id` 와 `run_attempt` 는 양의 정수다. Keeper 가 준 문자열이 URL 경로에 그대로 들어가지 않는다.
- 판정은 순수 함수다. 시도 조회(`GET /repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt_number}`) 응답의 `status` 가 `completed` 이면 `Completed of conclusion option`, 다른 문자열이면 `Not_completed` 로 읽는다. 모르는 `status` 문자열도 `Not_completed` 다. 종료를 뜻하는 새 값이 생기면 만료로만 드러나므로, §6.2 4번의 마지막 읽기 결과 표시가 그 단서가 된다. `status` 가 `null` 이거나 문자열이 아니면 읽기 오류로 두고 발화하지 않는다. `status` 가 `completed` 인데 `conclusion` 이 `null` 이면 `Completed None`, 처음 보는 값이면 `Completed (Some (Unrecognized 문자열))` 로 읽고 둘 다 발화한다. `conclusion` 은 `Unrecognized of string` 가지를 가진 닫힌 variant 다. GitHub 공식 문서(`https://docs.github.com/en/rest/actions/workflow-runs`, 2026-11-05 확인)는 응답의 `status` 와 `conclusion` 을 "string or null" 로 적고, 응답에 오는 값의 목록은 적지 않는다. 질의 필터의 값 목록에는 `completed` 가 있다. 2026-11-05 에 진행 중인 실행을 `gh api` 로 읽어 `status` 가 `in_progress`, `conclusion` 이 `null` 인 것을 확인했다.
- 만들 때 한 번 읽는다. 읽기가 실패하면(404·403·429, 네트워크 오류, 응답을 해석하지 못함) monitor 를 만들지 않고 도구 오류로 돌려준다. 읽지 못한 채 만들면 §2.2 의 조용한 만료로 가서 Keeper 가 영영 모른다. 읽기에는 시간 제한을 둔다(`lib/server/server_repository_pulls.ml` 의 `curl_timeout_sec` 이 20초이고 프로세스는 5초를 더 준다). 이미 `Completed` 면 monitor 를 만들지 않고 그 결과를 도구 응답으로 돌려준다. `Not_completed` 면 monitor 를 만들고, 이후 처음 보는 `Completed` 를 전이로 본다.
- §2.1 의 baseline 규칙은 이 트리거에서 맞지 않는다. 최초 관측을 baseline 으로 받으면, 건 시점에 이미 끝난 실행은 baseline 이 `Completed` 라서 영영 울리지 않는다. 서버가 재시작한 동안 끝난 실행도 같다(§2.5). 위 규칙은 last_state 를 저장하지 않으므로 재시작 뒤에도 같고, 재시작 중에 끝난 실행은 재시작 뒤 첫 관측에서 울린다. 이 규칙은 한 시도의 `status` 가 `Not_completed` 에서 `Completed` 로 한 방향으로만 바뀐다는 가정 위에 있다. 공식 문서에서 확인하지 못한 가정이라 구현 시험에서 실제 실행으로 확인한다.
- 시도 번호를 트리거에 넣어 한 시도의 완료만 본다. 공식 문서는 시도 조회가 실행 조회와 같은 응답 모양이라고 적는다. GitHub REST 스키마(`github/rest-api-description`, 2026-11-05 확인)는 `run_attempt` 를 "첫 시도는 1, 재실행하면 더 큰 값"이라고 적는다. 재실행(`Re-run a workflow`, `Re-run failed jobs`)이 이전 시도의 `status` 를 되돌리는지는 문서가 적지 않고 시험하지 않았다. 시도로 고정하면 재실행이 이전 시도의 기록을 바꾸지 않는 한 이 monitor 의 대상은 바뀌지 않는다. 다음 시도를 기다리려면 새 monitor 를 건다. `gh run rerun` 은 CI 를 다시 돌리므로 이 문서를 쓰면서 시험하지 않았다.
- §2.4 의 인터벌(미충족 2초, 충족 유지 10초)은 로컬 포트와 파일에 맞춘 값이다. GitHub 를 2초마다 읽으면 기다림 188개의 폴링 시간을 기다림별로 더한 28.76시간 동안 5만 번이 넘는다. 이 트리거는 따로 인터벌을 가진다. 아래 계산은 30초로 가정한다.
- 전송은 `lib/server/server_repository_pulls.ml` 의 `default_http_post`(`:165`)가 선례다. curl 서브프로세스로 보내고 속도 제한 헤더를 읽는다. 이 함수는 POST(GraphQL)라서 시도 조회에는 GET 전송이 하나 더 필요하다.
- 발화는 §2.3 의 `monitor_fired` 로 간다. payload 는 Keeper 가 넣은 값에 `conclusion` 과 실행 주소를 더한다. 로그나 산출물은 Keeper 가 도구로 따로 읽는다.
- 호출 수는 계산값이다. 30초마다 한 번 읽는다고 가정하면, 기다림 188개의 폴링 시간을 기다림별로 더한 28.76시간(1,726분) 동안 3,451번이고 창 101시간으로 나누면 시간당 34번이다. 같은 실행을 둘이 기다려도 따로 센 값이고, 폴링 시간은 monitor 가 걸려 있을 시간의 대용이다. 잰 값이 아니다.

### 6.2 정해야 하는 것 (사용자가 정한다)

1. 어느 신원으로 읽는가. PR 스냅숏을 읽는 계정은 `RFC-keeper-world-state-shows-open-work` D6(2026-09-28)이 지금 계정(`pr_reader` Keeper 가 쓰는 anyang-keepers 계정. 그 RFC 는 이 계정을 Keeper 12명이 `gh` 로 같이 쓴다고 적었다)으로 유지하기로 했고, 속도 제한은 기존 `Rate_limited` 경로가 받는다고 했다. `server_repository_pulls.ml` 은 `Keeper_github_login_lane.stored_token` 으로 그 계정의 토큰을 읽는다. 이 트리거도 같은 계정으로 읽는 것을 기본으로 제안한다. 정할 것은 그 결정을 실행 조회까지 넓히는지다. Keeper 별 GitHub 신원은 `RFC-keeper-github-apps` 가 다루고 D7 이 신원 전환을 그 RFC 에서 따로 정하기로 했다. `RFC-per-keeper-github-cli-identity` 도 별도의 Draft 이다.
2. 저장소가 둘이고 공개 여부가 다르다. `gh repo view` 로 `jeong-sik/masc` 는 PUBLIC, `jeong-sik/wkbl` 은 PRIVATE 임을 확인했다(2026-11-05). 읽는 계정의 토큰이 `wkbl` 의 Actions 를 읽을 수 있는지는 시험하지 않았다(Keeper 의 토큰을 꺼내 쓰지 않았다). 공식 문서는 실행 조회와 시도 조회를 "Anyone with read access to the repository" 가 쓸 수 있고, 비공개 저장소에서는 OAuth 앱 토큰과 classic 개인 토큰에 `repo` scope 가 필요하다고 적는다. fine-grained 개인 토큰과 GitHub App 토큰(user, installation)은 "Actions" 저장소 권한(read)이 있으면 되고, 공개 자원만 읽을 때는 인증이 없어도 된다고 적는다. 그래서 읽는 신원의 토큰에는 Actions 읽기 권한이 필요하고, `pr_reader` 의 토큰이 그 권한을 갖는지는 모른다. `wkbl` 을 읽을 수 없으면 이 제안이 닿는 기다림에서 61개(11.07시간, 막힌 시간의 40%)가 빠진다. 이름이 안 보인 기다림 32개가 어느 저장소인지도 모른다.
3. v1 세 트리거보다 먼저 하는가. 이 측정은 v1 쪽 수요를 재지 않았다.
4. 지워지는 기다림을 Keeper 에게 어떻게 알리는가. §2.2 는 미발화 만료를 조용히 지운다. 이 트리거에서는 만든 뒤에 읽기가 계속 실패해서 만료되는 경우와, 실행이 끝나지 않은 채 기다림이 만료보다 길어져 만료되는 경우가 모두 Keeper 가 모르는 채 지워진다. 만들 때 읽기 실패는 위 규칙대로 도구 오류가 되므로 여기서 남는 것은 만든 뒤의 실패와 만료다. 마지막 읽기 결과(`status`, 읽기 오류)를 `masc_monitor_list` 에 보일지, 만료 때 `monitor_fired` 와 같은 길로 "끝나지 않고 만료됨" 과 "읽지 못하고 만료됨" 을 알릴지 정해야 한다.
5. 재실행. 시도 번호로 고정하면 대상은 정해진다. 정할 것은 Keeper 가 재실행 뒤 다음 시도를 기다릴 때 새 monitor 를 걸게 하는지, 도구에 "최신 시도" 모드를 따로 두는지다.

### 6.3 다른 RFC 와 겹치는 곳

`RFC-keeper-world-state-shows-open-work`(Draft)가 GitHub 쪽 깨우기를 따로 제안한다. 그 RFC 는 웹훅 대신 서버가 60초마다 읽는 PR 스냅숏(RFC-0465)을 쓰고(§3.1), PR 을 커밋한 Keeper 한 명만 자기 PR 의 checks 실패·변경 요청·충돌 세 상태에서 깨운다(§5). 켤지는 S4 만 배포된 7일의 측정(M3)을 본 뒤에 정하고, 그때까지 깨우기(S8)는 열지 않는다(D4).

이 §6 의 트리거와 다른 점은 셋이다.

- 그 RFC 는 PR 의 상태에서 깨우고, 이 트리거는 Keeper 가 지정한 실행 하나의 완료에서 한 번 깨운다. 성공으로 끝난 실행에도 깨운다.
- 그 RFC 는 PR 에 붙은 checks 만 본다. 이 측정은 기다린 실행이 PR 의 checks 인지 PR 에 붙지 않은 실행인지 가르지 못했다.
- 그 RFC 는 켜면 서버가 계속 도는 규칙이고, 이 트리거는 Keeper 가 만든 monitor 가 발화하거나 만료되면 사라진다.

겹치는 곳은 자기 PR 의 checks 가 실패로 끝난 경우 하나다. 이 크기는 재지 않았다. 이 측정은 실행의 결과(성공·실패)를 보지 않는다.
둘이 GitHub 읽기를 따로 만들면 신원, 토큰 읽기, 속도 제한 처리가 둘로 갈라진다. 어느 쪽이 먼저 구현되든 읽는 계정은 하나를 쓰도록 제안한다.
속도 제한 처리는 다시 쓸 것이 아직 없고 이 제안이 새로 정해야 한다. `Rate_limited` 는 PR 스냅숏 읽기의 실패 가지 하나이고(`lib/server/server_repository_pulls.ml` 의 `failure`), `held_answer` 는 그 스냅숏의 답을 GitHub 가 알려 준 `reset_at` 까지 쥘 뿐이다. 계정 단위로 남은 한도를 나누는 상태가 아니다. 시도 조회(REST GET)가 429 나 한도 소진을 만났을 때 monitor 가 어떻게 하는지(다음 인터벌에 다시 읽기, 알려 준 시각까지 쉬기)는 새로 정한다.

### 6.4 줄이는 크기의 한계와 확인 방법

- 줄이는 것은 Keeper 가 한 턴을 붙잡고 기다리는 시간(27.41시간, 턴 구간 안은 24.75시간으로 턴 시간의 3.1%)과 폴링 호출(277번)이다. 그 시간에 다른 작업이 밀려 있던 비율은 측정한 두 대기열에서 작다. 같은 창에서 위임·채팅 작업의 대기(6,703.7분) 중 같은 Keeper 가 60초 이상 `Execute` 를 돌던 시간과 겹친 것은 216.8분(3.2%)이고, 일정 깨움의 대기(482.2시간) 중에서는 21.6시간(4.5%)이었다(`docs/evidence/lane-time-2026-11/result-2026-11-01_11-05.json`). Board 멘션으로 깨운 턴의 대기와 완료 순간에 바로 이어 받는 이득은 재지 못했다.
- 같은 기다림을 체크아웃의 감시 프로세스로 푸는 길도 있다(`RFC-keeper-async-fleet-continuity` §8 의 3·4층). 이 제안은 체크아웃의 프로세스가 필요 없는 대신 서버가 GitHub 를 읽는 신원이 필요하다. 이 측정은 두 길 중 어느 쪽이 나은지 가르지 못한다.
- 구현 뒤에는 같은 하네스를 같은 일수로 돌린다. 기준선은 `run_waits.waits` 188개, `blocked_hours` 27.41시간, `schedule_wakes.self_wakes_naming_a_run` 81건이다. 날마다 값이 많이 달라서(`sleep` 든 오래 걸린 호출은 11-01 이 0.44시간, 11-02 ~ 11-04 가 8 ~ 13시간) 총량만 비교하면 효과와 날의 차이를 가르지 못한다. 그래서 (Keeper, 실행 번호) 쌍 단위로 본다. 새 도구로 monitor 를 건 쌍이 `sleep` 폴링에도 나오는지(나오면 폴링 시간이 0에 가까워야 한다) 쌍마다 센다.
- 값이 줄지 않았을 때는 이 순서로 원인을 좁힌다. (1) monitor 가 실제로 만들어졌는지(도구 호출 수와 만들 때의 읽기 오류). (2) 만든 monitor 의 결과(발화·만료·읽기 오류)와 저장소별 읽기 성공률(`wkbl` 포함). (3) 발화한 뒤 Keeper 가 깨어나기까지의 시간. (4) 깨어난 뒤에도 같은 실행을 `sleep` 으로 다시 기다리는지. 지금 하네스에는 새 도구 호출과 monitor 결과를 세는 필드가 없어서 구현과 함께 더해야 한다.

### 6.5 구현한 것 — 일정에 거는 실행 감시 (2026-11-05)

§6.1 의 monitor 트리거는 만들지 않았다. monitor 도구와 저장소(§2.5, §2.6)가 코드에 없어서 트리거 하나를 먼저 만들 자리가 없다. 같은 수요를 이미 있는 일정(`masc_schedule_create`)에 얹어서 풀었다.

- 도구: `masc_schedule_create` 와 `masc_schedule_update` 에 `until_github_run`(GitHub 실행 URL) 인자를 더했다. 일정의 due 는 그대로 남는다. 실행이 끝나면 그 일정이 그 순간 due 가 되고, 이후는 일정이 하는 일이다(runner 가 Keeper 를 깨운다). 목록·취소·재시작·전달은 일정의 것이다. `masc_schedule_update` 는 일정의 정의 전체를 바꾸므로 감시를 남기려면 update 에도 `until_github_run` 을 다시 줘야 한다. 빼면 감시가 지워지고 일정은 due 에만 깨운다. TUI 의 일정 수정 폼은 감시가 있는 일정이면 실행 URL 을 `until_github_run` 으로 같이 싣는다. 폼을 저장해도 감시가 지워지지 않는다.
- 저장: `masc.keeper_wake` payload body 의 `until_github_run: {repo, run_id, run_attempt?}`. 별도 저장소도 새 stimulus 종류도 새 도구도 없다. 일정 행이 감시의 유일한 기록이라서 서버가 재시작해도 잃는 것이 없다. URL 은 도구에서 한 번 읽어 `repo`·`run_id`·`run_attempt` 로 바꾸고, 그 뒤로 Keeper 가 준 문자열이 그대로 URL 경로에 들어가지 않는다(`repo` 는 §6.1 의 규칙대로 `.` 과 `..` 를 거절한다).
- 서버: `Server_schedule_run_watch` 가 30초마다 한 번 돈다. `Scheduled` 인 one-shot Keeper wake 중 감시가 달린 것을 모아 실행마다 한 번 읽는다(`GET https://api.github.com/repos/{owner}/{repo}/actions/runs/{id}`, URL 에 시도가 있으면 `/attempts/{n}`). 읽는 신원은 §6.2 1번 기본값대로 `[repositories] pr_reader` 의 계정이고, 호출마다 다시 정한다. 토큰은 curl 의 stdin 으로 넘긴다. `status` 가 `completed` 이면 그 일정의 due 를 현재 초로 당기고(이미 그보다 이르면 그대로 둔다), 메시지 앞에 결과와 URL 을 붙이고, 감시 필드를 지운다. 감시 필드가 지워지므로 같은 일정을 두 번 깨우지 않는다. `completed` 가 아닌 다른 `status` 문자열은 아직 도는 것으로 보고 기다린다. `status` 가 없거나 문자열이 아니면 응답 해석 실패다. 깨우는 쓰기는 훑을 때 읽은 행의 instance id 를 `expected_instance_id` 로 넘긴다. 읽는 사이에 Keeper 가 일정을 고쳤으면 store 가 락 안에서 `Stale_instance` 로 거절하고 Keeper 의 수정이 남는다. 읽는 사이에 일정이 `Running` 이 됐거나 끝났으면 store 가 수정을 거절한다(`Schedule_domain.modify_allowed`). 두 경우 모두 깨우지 않고 다음 순서에 그 행을 다시 훑는다.
- 읽기 실패는 둘로 나눈다. 같은 답이 다시 올 것은 일정을 첫 순서에 한 번 일찍 깨운다. 404, 401, 한도와 무관한 403, 응답 해석 실패, 408·425 를 뺀 4xx 와 3xx, 읽는 계정이 선언되지 않았거나 선언된 Keeper 가 없거나 github.com 이 아닌 호스트를 읽는 경우가 여기에 든다. 읽는 계정 쪽 이유는 고정 문장이고 Keeper 이름이나 파일 경로를 적지 않는다. 그 문장이 깨움 메시지로 Keeper 에게 간다. 메시지는 `[github_run_watch] could not read <실행> (<이유>). This wake came early; check the run yourself.` (영어)로 시작한다. 다시 읽으면 달라질 것은 아무것도 바꾸지 않고 다음 순서에 다시 읽는다. 5xx, 408, 425, 전송 실패, 429, 한도를 다 쓴 403, 그리고 읽는 계정의 선언이나 토큰을 지금 읽지 못한 경우(파일을 쓰는 중이거나 파일 기술자가 모자랄 때 생길 수 있다)가 여기에 든다. 한도에 걸리면 GitHub 가 준 시각까지 쉬고, 그 시각이 한 시간보다 멀면 한 시간만 쉰다. 시각을 주지 않았으면 30초를 쉰다. 쉬는 동안 모든 감시를 읽지 않는다. 일시적인 실패는 일정의 due 가 폴백이라서 늦어도 due 에 깨어난다. 같은 답이 다시 올 실패는 첫 순서에 깨우고 끝나므로 원래 due 에는 다시 깨우지 않는다. §6.2 4번의 조용한 만료는 없다. 다만 일정에 `expires_at_unix` 가 있고 그 시각이 깨움보다 먼저 오면 일정은 깨우지 않고 만료된다(일정의 기존 동작이다).
- §6.2 의 나머지는 제안 기본값을 따랐다. 3번(v1 트리거와의 순서)은 이 구현이 monitor 를 거치지 않아서 걸리지 않는다. 5번(재실행)은 URL 에 `/attempts/N` 이 있으면 그 시도의 완료만 본다. 없으면 폴링마다 실행의 최신 시도를 읽으므로, 폴링 사이에 재실행이 시작되면 새 시도의 완료를 기다리고 깨움 메시지에 시도 번호가 없다. 재실행 뒤 GitHub 가 어느 시도를 돌려주는지는 확인하지 않았다.
- §6.1 과 다른 점은 셋이다. 첫째, 만들 때 읽지 않는다. 이미 끝난 실행은 다음 순서(보통 30초 안)에 깨운다. 만들 때 읽어서 거절하면 읽는 계정이 `wkbl`(비공개)을 볼 수 있는지 모르는 채로 `wkbl` 의 감시를 전부 막을 수 있다(§6.2 2번). 그 경우 지금 구현에서는 `wkbl` 감시가 첫 순서에서 "읽지 못했다"는 이유와 함께 일찍 깨운다. Keeper 가 읽지 못하는 감시를 바로 안다. 둘째, 시도 번호는 선택이다. 셋째, `status` 가 없거나 문자열이 아닌 응답을 §6.1 은 읽기 오류로 두고 발화하지 않는다고 했지만, 여기서는 같은 답이 다시 올 실패로 보고 일찍 깨운다.
- 닿지 않는 곳. Lane action 일정(스키마가 인자를 거절한다), 반복 일정(도구가 거절한다. 반복 일정은 첫 발생 뒤에 새 due 를 갖는다), github.com 밖의 호스트(github.com 이 아닌 URL 은 도구가 만들 때 거절한다. 읽는 계정이 다른 호스트로 선언돼 있으면 github.com URL 도 모두 읽는 계정 없음으로 보고 첫 순서에 일찍 깨운다. REST 주소를 GraphQL 주소에서 계산하지 않는다), 웹훅(30초 폴링이다).
- 알아 둘 것. 감시는 `Scheduled` 인 one-shot 일정만 훑는다. due 가 실행의 끝보다 먼저 오면 일정이 원래 메시지로 한 번 깨우고 감시는 끝난다. 그 깨움에는 `[github_run_watch]` 머리말이 없으므로, 머리말이 없는 것이 감시가 일하지 못했다는 유일한 단서다. 저장소 허용 목록은 없다. 어느 Keeper 든 아무 `owner/repo` 를 적을 수 있고, 읽는 계정이 볼 수 있는지가 읽히는지를 정한다. 읽는 계정이 볼 수 있는 비공개 저장소의 실행 결과도 그 일정을 만든 Keeper 의 깨움 메시지로 간다. Keeper 12명이 같은 계정을 `gh` 로 쓴다는 §6.2 1번의 서술이 맞다면 새로 열리는 읽기 범위는 없다. 그 서술이 지금 설정과 맞는지는 확인하지 않았다. 읽지 못하는 상태가 이어지면 서버 로그에 감시 하나당 30초마다 경고가 한 줄씩 남는다. 시도 번호를 준 URL 로 재실행 직후의 시도를 읽으면 GitHub 가 무엇을 주는지 확인하지 않았다. 404 를 주면 감시는 일찍 깨운다. `masc_schedule_update` 가 감시를 붙이는 호출이면 반복 종류를 확인한 행의 instance id 도 저장소에 넘긴다. 그 사이에 다른 호출이 일정을 바꾸면 저장소가 락 안에서 `Stale_instance` 로 거절하고 그 수정은 남긴다. 감시가 없는 일반 수정은 생략한 반복 종류와 due 를 최신 저장 행에서 유지한다.
- 끝난 실행을 깨우기까지는 보통 폴링 30초와 일정 runner 간격(기본 15초)을 더한 45초 안이다. 폴링은 한 순서를 끝낸 뒤 30초를 쉬고 읽기는 차례로 하며 읽기마다 curl 제한이 20초라서, 읽기가 느리거나 속도 제한으로 쉬는 동안은 더 걸린다. 그 뒤 Keeper 의 큐에서 턴이 시작되기까지는 일정 깨움의 기존 대기를 따른다(보고서 §6 "기다리는 동안 다른 일이 쌓였는지"의 측정: 중앙값 3.6초, p90 494초).
- 읽기 한도. GitHub REST 는 인증된 개인 요청에 시간당 5,000건을 허용한다(https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api, 2026-11-05 확인). 서로 다른 실행 하나를 30초마다 읽으면 시간당 120건이라서, 서로 다른 실행 40개쯤을 한꺼번에 기다리면 이 루프만으로 5,000건을 다 쓴다. 읽는 계정은 여럿이 같이 쓰는 계정이다(§6.2 1번). 같은 실행을 기다리는 일정이 여럿이어도 한 순서에 한 번만 읽는다.
- 효과 측정. Keeper 가 일정으로 자기를 깨우며 메시지에 실행 번호를 적은 81건(11-01~11-05T05:00Z) 가운데 번호가 하나이고 시도가 하나인 63건을 그 실행의 실제 끝과 비교했다(`docs/reports/2026-11-05-tool-efficiency.md` §6 "일정이 실행의 끝을 놓친 크기", `docs/evidence/execute-waits-2026-11/measure_schedule_slack.py`). 일정을 만들 때 실행이 돌던 53건 중 41건은 due 가 실행이 끝난 뒤였고 합계 15.21시간(중앙값 15.5분) 늦었다. 12건은 due 가 끝보다 앞이었고 합계 6.43시간 일렀다. 이 구현이 줄이는 것은 앞쪽 41건이다. 인자를 쓰면 깨움은 끝난 뒤 폴링 간격과 runner 간격을 더한 45초 안에 오므로, 속도 제한과 느린 읽기가 없으면 합계는 많아야 0.51시간(41 × 45초)이다. 뒤쪽 12건은 Keeper 가 due 를 안전망으로 길게 잡아야 줄어든다. 효과는 배포 뒤에 같은 스크립트의 `verdicts.watched`(쓰는 몫)와 서버 로그로 센다. 로그는 `schedule_run_watch: woke <일정 id>, ` 로 시작하고 `completed` 가 든 줄이 실행이 끝나서 깨운 것이고, `woke <일정 id> early` 로 시작하는 줄은 읽지 못해 일찍 깨운 것이다.

### 6.6 측정 수요 — PR 의 head 가 바뀌기를 기다리는 호출 (2026-11-08)

§6.5 의 `until_github_run` 은 실행 하나의 완료를 받는다. Keeper 가 PR 의 head 가 바뀌기를 기다리며 같은 명령을 계속 돌리는 호출은 이 인자가 받지 못한다.

`docs/evidence/tool-efficiency-before-after-2026-11/idle_repeats.py`(PR #50021)로 11-06T00:00Z ~ 11-08T19:00Z 를 쟀다. 정의와 한계는 그 폴더의 README 에 있다. 같은 Keeper 가 같은 명령을 직전 실행이 끝난 뒤 30분 안에 다시 돌려 같은 결과(`execution_time_ms` 제외)를 받은 Execute 호출을 되풀이로 센다.

| 측정 | 값 |
|---|---|
| `Execute` 호출 | 20,396건 |
| 되풀이 | 4,241건 (20.8%), Keeper 13명 |
| 되풀이 중 `context-reviewer` 의 열린 PR 목록·감시 PR head 읽기 | 2,346건 (55.3%) |
| 11-08 00:00Z ~ 10:40Z 의 `context-reviewer` `Execute` | 1,628건 중 1,573건이 같은 명령 하나(`runs`)이고 그중 1,565건이 되풀이(`repeats`). 되풀이 간격 중앙값 13.9초, p90 34.6초(`repeat_interval_p50_s`, `repeat_interval_p90_s`) |
| 그 명령 | 열린 PR 12개의 번호·draft·head·갱신 시각·제목을 읽고, 감시 중인 PR 넷의 head 를 따로 읽는다. 한 번에 `gh api` 다섯 번, 결과 1 KB 쯤 |
| 그 명령이 부른 `gh api` | 1,573 × 5 = 7,865번. 10.7시간 평균 시간당 740번이고, §6.5 가 적은 시간당 5,000건의 15%다(읽는 계정을 여럿이 같이 쓴다면) |
| 같은 창의 모델 요청 | 1,667번. 요청을 기록한 Keeper 전체 입력 토큰의 85.3% |
| `until_github_run` 을 단 일정 | 58건 (11-05T00:00Z ~ 11-08T19:00Z, `masc_schedule_create`·`masc_schedule_update` 의 `input` 글자 검색, Keeper 8명) |

- 이 명령이 기다리는 것은 감시 PR 의 head 가 바뀌는 것(새 커밋)과 열린 PR 목록의 변화로 읽었다. 명령이 읽는 두 부분이 이 둘에 맞는다는 것이 근거이고, Keeper 가 무엇을 기다렸는지 직접 본 것은 아니다(추정).
- 이 창에서 `context-reviewer` 가 모든 명령으로 되풀이한 1,574건(위 명령 1,565건과 다른 명령 9건) 중 1,519건(96.5%)은 직전 실행과 같은 턴 안에서 일어났다(`repeat_same_turn_calls`). 첫 창 전체로는 4,241건 중 4,095건(96.6%)이다. 이 Keeper 는 턴 하나를 연 채 같은 명령을 돌렸다.
- 되풀이가 턴을 붙든 시간은 3.36시간으로 작다. 값은 호출마다 모델 요청이 한 번 나간다는 데 있다. 1,573번이 곧 1,573번의 모델 요청은 아니다. 요청 하나가 호출을 여러 개 낼 수 있다.
- 일정으로 깨운 뒤 첫 요청은 식은 캐시를 읽을 수 있어서 입력 토큰이 줄어든다고 가정하지 않는다. 줄어드는 것은 모델 요청 수, `Execute` 호출 수, GitHub 읽기 수, 턴이 열려 있는 시간이다.
- 이 Keeper 의 되풀이는 11-08 09:13:35Z 에 멈췄다. 알려진 부팅 시각(11-07 18:24Z, 11-08 11:04Z, 14:40Z)과 맞지 않고, 멈춘 이유는 가리지 못했다.
- 이 PR 의 리뷰에서 `context-reviewer` 가 밝힌 바로는 이 명령은 운영자가 만든 5분 간격 반복 일정의 순찰 턴에서 나온다. 같은 일정의 note(`masc_schedule_note_add`)에 「순찰 이어짐 … 턴 종결」이 이어지는 것은 원장에서 봤다. 일정 행의 종류와 간격은 직접 확인하지 못했다. 순찰은 새 PR 을 찾는 일도 하므로, 되풀이에는 head 를 기다리는 폴링과 목록을 훑는 폴링이 섞여 있다.

#### 6.6.1 제안 — `until_github_run` 옆에 인자 하나 더 (결정이 아니다)

```
type github_watch =
  | Run of { repo : Github_repo.t; run_id : int; run_attempt : int option }   (* §6.5 *)
  | Pull_heads of { repo : Github_repo.t; pulls : pull_head list }            (* 새로 *)
and pull_head = { number : int; head : Git_sha_prefix.t }
```

- 인자: `masc_schedule_create`·`masc_schedule_update` 에 `until_github_pr_heads: {repo, pulls: [{number, head}]}` 를 더한다. 일정의 due 는 그대로 남고, 감시 PR 중 하나의 head 가 준 값과 다르거나 PR 이 닫히거나 병합되면 그 일정이 그 순간 due 가 된다(§6.5 와 같은 길).
- `head` 는 Keeper 가 준다. 리뷰하는 Keeper 는 마지막으로 본 head 를 안다(지금 명령도 `#번호 head=앞 8자리` 를 찍는다). 서버가 건 시점에 baseline 을 읽지 않으므로 건 뒤 첫 읽기 전에 push 가 있어도 놓치지 않고, 건 시점 읽기 실패도 없다. `Git_sha_prefix.t` 는 새로 만들 타입이고 7~40자리 16진수만 받는다. 현재 head 가 그 값으로 시작하면 같은 head 로 본다.
- 서버: `Server_schedule_run_watch` 와 같은 순서(30초마다)에서 감시가 달린 `Scheduled` one-shot Keeper wake 를 모은다. 같은 PR 을 기다리는 일정이 여럿이어도 한 순서에 한 번만 읽는다. 읽는 신원은 §6.2 1번 기본값(`[repositories] pr_reader`)이다.
- 읽기 실패는 §6.5 와 같이 둘로 나눈다. 같은 답이 다시 올 것은 일정을 첫 순서에 한 번 일찍 깨우고, 다시 읽으면 달라질 것은 다음 순서에 다시 읽는다.
- 깨움 메시지는 `[github_pr_watch] #<번호> head <준 값> -> <현재 앞 8자리>` 또는 `... closed`, `... merged` 를 감시 PR 마다 한 줄씩 적는다. 머리말은 `[github_run_watch]` 처럼 고정 영어 문장이다.
- 수명: 깨울 때 감시 필드 전체를 지운다(§6.5 와 같다). 같은 순서에 PR 이 둘 이상 바뀌면 바뀐 PR 만 한 줄씩 적고, 바뀌지 않은 PR 의 감시도 함께 지워진다. Keeper 는 새 head 로 다시 건다. `masc_schedule_update` 는 일정의 정의 전체를 바꾸므로 이 인자를 다시 주지 않으면 감시가 지워진다(§6.5 의 `until_github_run` 과 같다). 저장은 `masc.keeper_wake` payload body 의 `until_github_pr_heads: {repo, pulls: [{number, head}]}` 이고, 일정 행이 유일한 기록이라서 서버가 재시작해도 이어진다.
- 상한: 일정 하나에 PR 8개. 근거는 지금 명령이 읽는 4개의 두 배라는 것뿐이다.
- 닿지 않는 곳은 §6.5 와 같다(Lane action 일정, 반복 일정, github.com 밖의 호스트). 순찰이 반복 일정이면 그 일정에는 이 인자를 달 수 없다. 쓰려면 Keeper 가 기다릴 때마다 별도 one-shot 일정을 만들어 이 인자를 건다. 순찰 일정은 그대로 남아 새 PR 을 찾는다.

#### 6.6.2 정해야 하는 것 (사용자가 정한다)

1. 읽는 방법. PR 마다 REST 단건 조회(`GET /repos/{owner}/{repo}/pulls/{number}` 의 `head.sha`, `state`, `merged`)와 저장소마다 GraphQL 한 번 중 고른다. REST 는 감시 PR N개를 30초마다 읽으면 시간당 120N건이다. 넷이면 480건으로 지금 루프의 평균 740건보다 작지만 크게 작지는 않다. GraphQL 한 번이면 저장소당 시간당 120건이다. GraphQL 의 한도 계산은 REST 와 달라서 확인이 필요하다. 서버가 60초마다 읽는 PR 스냅숏(`server_repository_pulls.ml`)을 재사용하면 읽기가 늘지 않지만, 그 `pull_request` 레코드는 `repo_slug`·번호·`draft`·`checks`·`review`·`mergeable`·`author` 뿐이고 head 가 없다. 질의와 레코드에 칸을 더해야 하고 반응이 60초 이상 늦다.
2. 신원과 비공개 저장소. §6.2 1·2번과 같다. 지금 명령이 읽는 `jeong-sik/masc` 는 공개 저장소다.
3. 감시 PR 상한. 위 8개를 바꿀지.
4. 닫힘·병합에도 깨우는가. 제안은 깨운다. 리뷰하는 Keeper 는 닫힌 PR 의 head 를 더 기다릴 이유가 없다.
5. 열린 PR 목록에 새 PR 이 생기는 것을 기다리는 수요(위 명령의 첫 절반)를 같은 인자에 넣는지 따로 두는지. 이 제안은 받지 않는다. 한 명령 안에 두 수요가 섞여 있어서 Keeper 가 둘 중 무엇을 기다렸는지 가르지 못했다.
6. `RFC-keeper-world-state-shows-open-work` 와의 겹침. 그 RFC 의 S8 은 PR 을 커밋한 Keeper 한 명을 깨운다. 리뷰하는 Keeper 는 닿지 않는다. 읽는 계정과 읽기는 하나를 쓰도록 §6.3 의 제안을 따른다.
7. Draft 에서 Ready 로 바뀌는 것에도 깨우는가. 리뷰하는 Keeper 는 새 커밋뿐 아니라 Ready 로 바뀌는 것도 기다린다(Ready 가 돼야 판정을 낸다). 이 제안은 head 변경·닫힘·병합만 받는다. 전환을 받으려면 Keeper 가 건 시점의 `draft` 도 줘야 한다. 서버가 건 시점에 읽지 않기 때문이다. REST 단건 조회는 `draft` 를 이미 돌려주므로 읽기는 늘지 않는다.
8. 순찰이 반복 일정일 때. 이 인자는 반복 일정에 달 수 없다. (가) Keeper 가 기다릴 때마다 별도 one-shot 을 건다(제안). 순찰 일정은 새 PR 을 찾는 폴링을 계속하므로 `repeat_calls` 가 얼마나 줄지는 Keeper 가 기다림을 one-shot 으로 옮기는 몫에 달렸다. (나) 반복 일정에도 감시를 허용한다. §6.5 가 반복 일정을 거절한 이유(반복 일정은 첫 발생 뒤에 새 due 를 갖는다)와 감시의 한 번 깨움 규칙을 다시 정해야 한다.

#### 6.6.3 한계와 확인 방법

- 이 수요는 한 Keeper 의 한 명령이다. 결과가 매번 달라지는 명령으로 기다리는 다른 Keeper 는 되풀이로 잡히지 않고, 이 측정은 그것을 재지 않았다.
- 같은 모양의 호출이 `date` 시계 읽기(`Execute` 호출의 12.4%, `wkbl-front`·`kidsnote-incoming-dd-manager` 가 거의 전부)에도 있다. 기다리는 대상이 정해져 있지 않아서 이 제안은 닿지 않는다.
- Keeper 가 이 인자를 쓸지는 모른다. `until_github_run` 은 쓰였다(58건). 이 Keeper 가 쓸지는 배포 뒤에 센다.
- 줄어드는 몫을 약속하지 않는다. 순찰이 새 PR 을 찾는 폴링은 이 인자로 대신하지 못한다. 줄어드는 것은 head 변경을 기다리며 턴을 열어 둔 폴링뿐이고, 그 몫이 1,573번 가운데 얼마인지는 이 측정으로 가르지 못했다.
- 구현 PR 이 시험으로 고정할 동작: head 가 그대로면 깨우지 않는다. 바뀌면 한 번만 깨운다. 닫힘·병합에서 깨운다. 건 시점에 이미 다른 head 면 첫 순서에 깨운다. 읽기 실패 두 가지(§6.5)를 처리한다. 같은 PR 을 여럿이 감시해도 한 순서에 한 번만 읽는다. update 가 이 인자를 안 주면 감시를 지우고 주면 남긴다.
- 구현 뒤에는 같은 스크립트를 같은 길이의 창에 돌린다. 기준선은 위 표다. `context-reviewer` 의 `repeat_calls` 와 `hourly`, 인자를 단 일정 수, 깨움이 실제 head 변경 시각과 맞는지(깨움 시각 대 커밋 시각)를 본다. 값이 줄지 않았을 때는 §6.4 의 순서(만들어졌는지, 발화·만료·읽기 오류, 깨어나기까지의 시간, 깨어난 뒤에도 다시 폴링하는지)로 좁힌다.
