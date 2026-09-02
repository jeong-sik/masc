# 스케줄러 리얼월드 실측 — 2026-09-02

라이브 서버 `127.0.0.1:8935` (0.28.0, `0f517caf79`, 02:17 KST 기동) 에 프로브 스케줄을 걸고
due → wake → keeper_event_queue → reaction ledger → 게시판까지 한 줄로 추적했다.
시각은 전부 UTC. 원본은 이 디렉터리의 `probe-monitor.log` (10초 간격 폴링) 와 `lookup-*.json`
(`GET /api/v1/dashboard/scheduled-automation?schedule_id=…`).

## 프로브와 결과

| 프로브 | 정의 | 결과 |
|---|---|---|
| 없는 keeper 대상 생성 | `masc_schedule_create keeper_name=no-such-keeper-probe` | 생성 거부 (`has no durable metadata`) |
| one-shot | rondo, due 00:36:00, "게시판에 UTC 시각과 schedule_id 를 적은 글 하나" | 00:36:55 게시글 `p-fd322e1736b43cc37cd2a3845eab6cb2` (`current_utc=00:36:49Z`) |
| interval | lane-smith, 00:35:00 부터 300s, expires 00:55:00 | 4회 발화, 4회 턴, 00:55:00 에 `expired` (5회째 발화 없음) |
| cancel | rondo, due 00:44:00, 00:39:48 취소 | wake 기록 0, 게시글 0 |
| 같은 분 두 스케줄 | edgar.a.poe interval 2700s + cron `45 8-23 * * *` KST, 둘 다 00:45:00 | stimulus 2건이 턴 1개에서 소비되고 둘 다 ack |

### one-shot 체인 (rondo)

| 단계 | 시각 | 근거 |
|---|---|---|
| due | 00:36:00 | store `due_at` |
| wake `started_at` | 00:36:01 | store wake (tick 시각 복사) |
| store 가 본 Running | 00:36:08 | 모니터가 `status=running` 관측 |
| 소비자 acceptance | 00:36:15 | reaction ledger stimulus `recorded_at` |
| turn_started | 00:36:18 | reaction ledger |
| 게시글 생성 | 00:36:55 | `board_posts.jsonl` |
| turn_finished `completed` · queue ack | 00:37:02 | reaction ledger |

wake 기록의 `finished_at` 은 `started_at` 과 같은 값(00:36:01)이라 소요 시간이 0.0s 로 적혔다.
실제 dispatch 는 14초 걸렸다. → PR #32455.

### interval 체인 (lane-smith)

| 회차 | due | wake lag | stimulus | turn_started (대기) | turn_finished |
|---|---|---|---|---|---|
| 1 | 00:35:00 | 0.7s | 00:35:00 | 00:35:01 (1s) | 00:37:02 `checkpointed` |
| 2 | 00:40:00 | – | – | – | 00:41:50 `checkpointed` |
| 3 | 00:45:00 | 1.0s | 00:45:01 | 00:45:01 (0s) | 00:45:52 `checkpointed` |
| 4 | 00:50:00 | 6.4s | 00:50:08 | 00:52:31 (143s) | 00:53:45 `checkpointed` |

네 턴 모두 게시글을 남기지 않았다. 00:36:57 로그: `yielding repeated exact tool loop tool=masc_board_post_get count=3`.
스케줄 표면은 "wake succeeded · turn finished" 까지만 말하고 턴이 무엇을 남겼는지는 말하지 못한다
(RFC-schedule-history-and-outcome D4 영역). 후속 이슈로 기록.

## 라이브 상태에서 찾은 결함

| # | 증상 | 근거 | 조치 |
|---|---|---|---|
| 1 | 삭제된 keeper `taskmaster` 의 매일 09:00 KST wake 가 `succeeded` | `lookup-orphan-taskmaster.json`: `activation_reason=owner_unknown`, detail `Keeper owner not found: taskmaster`; reaction ledger `pending-cancel:owner-absent-drain` 00:00:54 (dispatch 40초 뒤) | #32464 (`owner_absent` typed), #32466 (달력 칩 "취소됨", KPI "큐 취소") |
| 2 | wake 실패 30건이 fleet 페이지에 없음 ("실패한 실행 없음") | `schedules.json` wakes: failed 30 (27건은 09-01 07:21:48~07:25:25, sangsu reaction-ledger 디렉터리 부재 `Sys_error … No such file or directory`, zero-base 재기동 중) | #32464 `wake_counts`, #32466 KPI "wake 실패" |
| 3 | 달력 행 주체가 예약자(`codex-mcp-client`) | `dashboard-live-0f517caf79-schedule.png` | #32466 (대상 keeper 로) |
| 4 | 드레인 분류기가 `matched_terminal_cancelled`·`matched_turn_finished` 를 "확인 불가"로 | `queue-drain-status.ts` REACTED 집합 | #32466 |
| 5 | wake→turn 대기 시간이 어디에도 없음 | analyst 00:14:48 stimulus → 00:22:29 turn_started (461s, 대화 턴 뒤) | #32466 reaction 블록 "wake→turn wait" |
| 6 | runner `/health` 의 dispatch 실패가 다음 tick 에 사라짐 | `last_counts` 만 존재 | #32455 `totals` |
| 7 | 09-01 07:32 sangsu wake 의 ledger 행이 복원본에 없음 → 달력 "누락 ⚠" | ledger 첫 행 00:14Z, v7 디렉터리 07:56Z 재생성 | 운영 조작(zero-base 재기동) 흔적. 분류기의 "누락" 판정은 정직함. 조치 없음 |

## 러너 실측

- cadence 15s (`MASC_SCHEDULE_RUNNER_INTERVAL_SEC` 기본), stale 60s. 00:24Z `/health`: tick 1704 / 실패 0 / 크래시 0 / 마지막 tick 0.017s.
- edgar 두 스케줄의 최근 66 wake 의 due→wake lag: 정상 0.7~14.7s (tick 간격 안). 이상치 65s·137s·281s·300s·734s·3886s 는 전부 서버 재기동 또는 keeper 재구성 창이고, 다운타임 뒤 한 회차만 발화한다(catch-up 1회).

## 스크린샷

- `dashboard-live-0f517caf79-schedule.png` — 배포본. 주체가 예약자, 실패 없음 표시, taskmaster 행에 아무 칩 없음.
- `dashboard-pr32466-schedule.png` — #32466 브랜치를 vite dev(proxy→8935)로 띄워 같은 라이브 데이터로 찍음. 주체가 keeper, "큐 취소 1", taskmaster 행 "취소됨".
- `dashboard-pr32466-orphan-detail.png` — 같은 브랜치의 taskmaster 상세. 서버가 #32464 이전이라 `owner_unknown` + detail 문자열이 그대로 보인다.

캡처 명령: `Google Chrome --headless=new --window-size=1600,1500 --virtual-time-budget=20000 --screenshot=… "<url>#schedule?schedule_id=…"` 를 `timeout 55` 로 감쌈 (SSE 때문에 Chrome 이 스스로 안 죽음).
