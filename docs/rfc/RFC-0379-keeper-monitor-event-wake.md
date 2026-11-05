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

v1 트리거(`Port_up`, `Port_down`, `File_changed`)는 §1 의 서버 재기동 사례를 겨냥한다. 이 세 트리거의 수요는 재지 않았다. 도구 호출 원장에서 Keeper 가 오래 기다리는 대상을 재 보니 GitHub Actions 실행이 가장 컸다.

`docs/evidence/execute-waits-2026-11/measure_execute_waits.py` 로 11-01T00:00Z ~ 11-05T05:00Z 를 쟀다. 정의와 한계는 그 폴더의 README 에 있다.

| 측정 | 값 |
|---|---|
| `Execute` 호출 | 75,471건, 117.15시간 |
| 60초 이상 걸린 호출 | 729건, 56.52시간 (`Execute` 시간의 48.2%) |
| 그중 `sleep` 든 호출 | 378건, 36.77시간 |
| 그 시간 중 실행 번호가 있거나 `gh` 를 쓰는 호출 | 35.16시간 (95.6%). 실행 번호가 있는 호출만 27.23시간 (74.0%). 번호를 변수로 넘기는 호출은 번호를 못 읽어서 이 몫은 하한이다 |
| 빌드·시험 도구를 쓴 60초 이상 호출 | 84건, 4.58시간 (`Execute` 시간의 3.9%) |
| 실행 기다림 (Keeper 하나와 실행 번호 하나) | 188개. 폴링 277번, 막힌 시간 27.41시간 (`Execute` 시간의 23.4%), 기다림당 중앙값 7.1분·p90 17.0분·최대 46.7분 |
| 기다림이 닿는 저장소 (명령에 이름이 보이는 156개) | `jeong-sik/masc` 95개(11.83시간), `jeong-sik/wkbl` 61개(11.07시간). 나머지 32개(4.52시간)는 명령에 저장소 이름이 없다 |
| 실행 번호가 든 일정 (`masc_schedule_create`, Keeper 가 자기를 깨움) | 81건 (자기를 깨우는 240건 중). Keeper 와 실행 번호 쌍으로 68개. `due_in_sec` 중앙값 1,500초 |

- 호출 종류는 명령 글자로 붙인 이름이다. `gh` 를 쓴다고 GitHub 를 기다렸다는 증거는 아니다. `sleep` 했다가 `gh` 로 상태를 보는 명령이라서 GitHub 쪽 상태를 기다린 것으로 읽었다(추정).
- Keeper 다섯 명(`wkbl-data`, `masc-productor-owner`, `sangsu`, `wkbl-front`, `e-masc-the-leader`)이 `sleep` 으로 기다리는 방법과 일정으로 깨우는 방법을 둘 다 썼다. 같은 실행에 둘 다 썼다는 뜻은 아니다.
- `masc_schedule_create` 도 `defer_loading = true` 인데 같은 기간 기록된 결과가 성공인 호출이 326건이다. 지연 로딩만으로 도구가 안 쓰이지는 않는다. 같은 설정인 `keeper_job_*` 는 0호출이다(`docs/reports/2026-11-05-tool-efficiency.md` §6).
- 일정은 시각으로만 깨운다. 일정 시각과 실제로 실행이 끝난 시각의 차이는 재지 않았다.
- `lib/` 에서 GitHub 실행의 완료를 보고 Keeper 를 깨우는 코드는 찾지 못했다(`workflow_run`, `check_run`, `check_suite`, `actions/runs`, `x-github-event` 를 `rg` 로 찾았고 걸린 것은 이름만 비슷한 `check_runtime_*` 뿐이다). `RFC-keeper-world-state-shows-open-work` §1.1 도 GitHub 이벤트 유입이 없다고 적는다.

### 6.1 제안 — 트리거 하나 더 (결정이 아니다)

```
type trigger =
  | (* §2.1 의 셋 *)
  | Github_run_completed of { repo : string; run_id : int }
```

- 판정은 순수 함수다. 실행 조회(`GET /repos/{owner}/{repo}/actions/runs/{run_id}`) 응답의 `status` 가 `completed` 이면 `Completed of conclusion`, 아니면 `Not_completed` 로 읽는다. `status` 가 없거나 글이 아니면 읽기 오류로 두고 발화하지 않는다. 2026-11-05 에 진행 중인 실행을 `gh api` 로 읽어 `status` 가 `in_progress`, `conclusion` 이 `null` 인 것을 확인했다.
- §2.1 의 baseline 규칙은 이 트리거에서 맞지 않는다. 최초 관측을 baseline 으로 받으면, 건 시점에 이미 끝난 실행은 baseline 이 `Completed` 라서 영영 울리지 않는다. 서버가 재시작한 동안 끝난 실행도 같다(§2.5). 한 시도 안에서 `status` 는 `Not_completed` 에서 `Completed` 로 한 방향으로만 바뀐다. 그래서 만들 때 한 번 읽는다. 이미 `Completed` 면 monitor 를 만들지 않고 그 결과를 도구 응답으로 돌려준다. `Not_completed` 면 monitor 를 만들고, 이후 처음 보는 `Completed` 를 전이로 본다. last_state 를 저장하지 않으므로 재시작 뒤에도 같은 규칙이고, 재시작 중에 끝난 실행은 재시작 뒤 첫 관측에서 울린다.
- §2.4 의 인터벌(미충족 2초, 충족 유지 10초)은 로컬 포트와 파일에 맞춘 값이다. GitHub 를 2초마다 읽으면 기다림 188개의 폴링 시간을 기다림별로 더한 28.76시간 동안 5만 번이 넘는다. 이 트리거는 따로 인터벌을 가진다. 아래 계산은 30초로 가정한다.
- 전송은 `lib/server/server_repository_pulls.ml` 의 `default_http_post`(`:165`)가 선례다. curl 서브프로세스로 보내고 속도 제한 헤더를 읽는다. 이 함수는 POST(GraphQL)라서 실행 조회에는 GET 전송이 하나 더 필요하다.
- 발화는 §2.3 의 `monitor_fired` 로 간다. payload 는 Keeper 가 넣은 값에 `conclusion` 과 실행 주소를 더한다. 로그나 산출물은 Keeper 가 도구로 따로 읽는다.
- 호출 수는 계산값이다. 30초마다 한 번 읽는다고 가정하면, 기다림 188개의 폴링 시간을 기다림별로 더한 28.76시간(1,726분) 동안 3,451번이고 창 101시간으로 나누면 시간당 34번이다. 같은 실행을 둘이 기다려도 따로 센 값이고, 폴링 시간은 monitor 가 걸려 있을 시간의 대용이다. 잰 값이 아니다.

### 6.2 정해야 하는 것 (사용자 몫)

1. 어느 신원으로 읽는가. PR 스냅숏을 읽는 계정은 `RFC-keeper-world-state-shows-open-work` D6(2026-09-28)이 지금 계정(`pr_reader` Keeper, 곧 Keeper 12명이 `gh` 로 같이 쓰는 anyang-keepers 계정)으로 유지하기로 했고, 속도 제한은 기존 `Rate_limited` 경로가 받는다. `server_repository_pulls.ml` 은 `Keeper_github_login_lane.stored_token` 으로 그 계정의 토큰을 읽는다. 이 트리거도 같은 계정으로 읽는 것을 기본으로 제안한다. 정할 것은 그 결정을 실행 조회까지 넓히는지다. Keeper 별 GitHub 신원(`RFC-keeper-github-apps`, `RFC-per-keeper-github-cli-identity`)은 둘 다 Draft 이고 D7 이 따로 정하기로 했다.
2. 저장소가 둘이고 공개 여부가 다르다. `gh repo view` 로 `jeong-sik/masc` 는 PUBLIC, `jeong-sik/wkbl` 은 PRIVATE 임을 확인했다(2026-11-05). 읽는 계정의 토큰이 `wkbl` 의 Actions 를 읽을 수 있는지는 시험하지 않았다. 이름이 안 보인 기다림 32개가 어느 저장소인지도 모른다.
3. v1 세 트리거보다 먼저 하는가. 이 측정은 v1 쪽 수요를 재지 않았다.
4. 읽기가 계속 실패하면 어떻게 보이는가. 404·403·429 나 네트워크 오류가 이어지면 monitor 는 울리지 않고 만료까지 간다. §2.2 는 미발화 만료를 조용히 지운다. 마지막 읽기 결과를 `masc_monitor_list` 에 보일지, 만료 때 마지막 읽기가 오류였으면 알릴지 정해야 한다.
5. 재실행. `gh run rerun` 이 같은 실행 번호에서 `run_attempt` 만 올리고 `status` 를 되돌리는지 확인하지 않았다(응답에 `run_attempt` 필드는 있다). 되돌린다면 만든 시점의 `run_attempt` 를 기억해 그 시도의 완료만 볼지 정해야 한다.

### 6.3 다른 RFC 와 겹치는 곳

`RFC-keeper-world-state-shows-open-work`(Draft)가 GitHub 쪽 깨우기를 따로 제안한다. 그 RFC 는 웹훅 대신 서버가 60초마다 읽는 PR 스냅숏(RFC-0465)을 쓰고(§3.1), PR 을 커밋한 Keeper 한 명만 자기 PR 의 checks 실패·변경 요청·충돌 세 상태에서 깨운다(§5). 켤지는 S4 만 배포된 7일의 측정(M3)을 본 뒤에 정하고, 그때까지 깨우기(S8)는 열지 않는다(D4).

이 §6 의 트리거와 다른 점은 셋이다.

- 그 RFC 는 PR 의 상태에서 깨우고, 이 트리거는 Keeper 가 지정한 실행 하나의 완료에서 한 번 깨운다. 성공으로 끝난 실행에도 깨운다.
- 그 RFC 는 PR 에 붙은 checks 만 본다. 이 측정은 기다린 실행이 PR 의 checks 인지 PR 에 붙지 않은 실행인지 가르지 못했다.
- 그 RFC 는 켜면 서버가 계속 도는 규칙이고, 이 트리거는 Keeper 가 만든 monitor 가 발화하거나 만료되면 사라진다.

겹치는 곳은 자기 PR 의 checks 가 실패로 끝난 경우 하나다. 이 크기는 재지 않았다. 이 측정은 실행의 결과(성공·실패)를 보지 않는다.
둘이 GitHub 읽기를 따로 만들면 신원, 속도 제한 처리, 토큰 읽기가 둘로 갈라진다. 어느 쪽이 먼저 구현되든 읽는 계정과 속도 제한 처리(`Rate_limited`)는 하나를 쓰도록 제안한다.

### 6.4 줄이는 크기의 한계와 확인 방법

- 줄이는 것은 Keeper 가 한 턴을 붙잡고 기다리는 시간(27.41시간)과 폴링 호출(277번)이다. 그 시간에 다른 작업이 밀려 있던 몫은 측정한 두 대기열에서 작다. 위임·채팅 작업의 대기 중 같은 Keeper 가 60초 이상 `Execute` 를 돌던 시간과 겹친 것은 1.9%, 일정 깨움의 대기 중에서는 3.8%였다(`docs/reports/2026-11-05-tool-efficiency.md` §6, 창은 11-01~11-04T19:10Z). Board 멘션으로 깨운 턴의 대기와 완료 순간에 바로 이어 받는 이득은 재지 못했다.
- 같은 기다림을 체크아웃의 감시 프로세스로 푸는 길도 있다(`RFC-keeper-async-fleet-continuity` §8 의 3·4층). 이 제안은 체크아웃의 프로세스가 필요 없는 대신 서버가 GitHub 를 읽는 신원이 필요하다. 이 측정은 두 길 중 어느 쪽이 나은지 가르지 못한다.
- 구현 뒤에는 같은 하네스를 같은 일수로 돌린다. `run_waits.waits`·`blocked_hours` 와 `schedule_wakes.self_wakes_naming_a_run` 이 기준선(188개, 27.41시간, 81건)보다 줄어야 한다. 줄지 않으면 Keeper 가 새 도구를 안 쓰는 것이다. 날마다 값이 많이 달라서(`sleep` 든 오래 걸린 호출은 11-01 이 0.44시간, 11-02 ~ 11-04 가 8 ~ 13시간) `execute.by_day` 로 날짜별로 비교한다.
