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
