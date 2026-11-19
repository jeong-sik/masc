---
rfc: "tui-idle-wait"
title: "쉬는 TUI 의 루프는 깨울 일이 있을 때만 돈다"
status: Draft
created: 2026-11-19
updated: 2026-11-20
author: claude
related: ["tui-one-screen-grammar", "an-idle-tui-receives-only-changes-it-draws", "0429", "0480"]
---

# 쉬는 TUI 의 루프는 깨울 일이 있을 때만 돈다

- 코드 좌표는 `origin/main` `ee69c080a31c` 에서 읽었다.
- 화면을 다시 그리는 규칙은 [한 화면 문법 §8](RFC-tui-one-screen-grammar.md) 이 정한다.
  이 글은 그 앞 단계, 메인 루프가 언제 깨어나는지만 정한다.

## 0. 결정

- 메인 루프는 세 가지 중 하나가 일어날 때까지 잔다.
  - 키·붙여넣기·마우스 바이트가 터미널에 들어온다.
  - 상태를 바꾸는 일이 생긴다. 비동기 답, 작업 결과, 시그널, 콘솔 쓰기가 그렇다.
  - 화면이나 루프가 기다리는 가장 이른 시각이 온다.
- 깨우는 쪽은 닫힌 합타입 `Masc_tui_wake.source` 의 생성자 하나로 종을 친다.
  깨울 시각은 `Masc_tui_wake.deadline_reason` 과 시각의 짝이다.
- 16 ms 상한(`maximum_input_wait_seconds`)은 지운다. 키는 지금처럼 바로 읽는다.

## 1. 지금

- `bin/masc_tui.ml:300` `maximum_input_wait_seconds = 0.016` 이 입력 대기의 상한이다.
  그릴 프레임이 없으면 `Render_schedule.input_timeout_seconds` 가 이 상한을 돌려준다.
- 그래서 아무도 키를 누르지 않아도 루프는 한 바퀴를 돈다. 바퀴마다 아래 표의 확인을 모두 한다.
- 기다림은 `Masc_tui_input_reader.terminal_has_bytes` 의 `Eio.Fiber.first` 다.
  `await_readable stdin` 과 `Eio.Time.sleep` 가 겨룬다.
- 측정(200x60, frozen 재생 서버 127.0.0.1:18990, 키 입력 없이 180 초, 2026-11-19):

  | 화면 | 루프 바퀴/초 | 문맥 전환/초 (`top` CSW) | CPU 초/분 |
  |---|---|---|---|
  | overview | 56.8 | 303 | 0.57 |
  | keepers | 56.5 | 328 | 0.75 |

  바퀴 수는 커밋하지 않은 임시 계수기로 셌다. 한 바퀴가 17.6 ms 다. 16 ms 대기에 일과 타이머 지연 1.6 ms 가 붙는다.

## 2. 무엇이 루프를 깨워야 하나

바퀴마다 입력과 상관없이 도는 확인을 셋으로 나눴다.
(a) 깨울 사건이 있다. (b) 시각을 계산할 수 있다. (c) 정말 주기적으로 봐야 한다.

### 2.1 (a) 사건: 쓰는 쪽이 종을 친다

| `source` | 쓰는 곳 | 루프가 읽는 곳 |
|---|---|---|
| `Mailbox` | `Masc_tui_async_protocol.mail` (`enqueue_async`). HTTP 읽기, observer stream 묶음, 재연결 타이머 등 모든 작업 fiber | `drain_async_messages` |
| `Workspace_result` | `Masc_tui_workspace_result` 발행 | `Workspace_result.take_ready` |
| `Preference_written` | `Masc_tui_preference_writer.publish` | `drain_preference_completions` |
| `Keeper_preference_written` | `Masc_tui_config.publish_preference` | `drain_keeper_preference_completions` |
| `Refresh_progress` | `start_http_refresh` 의 `on_progress` | `Masc_tui_types.drain_http_progress` |
| `Settings_reread` | `react_to_server_contact` 의 `fork_promise` | drain 의 `Eio.Promise.peek` |
| `Credential_prepared` | `Masc_tui_credential_preparation.start` 의 `publish` | `take_completed` |
| `History_read` | `Keeper_history_read.publish`, `publish_page` | `collect_owned_results` |
| `Ask_answer_receipt` | `Ask_answer_receipt.publish` | `collect_owned_results` |
| `Ask_answer_completion` | `Ask_answer_completion.publish` | `collect_owned_results` |
| `Runtime_assignment_saved` | `ras_observation` CAS | `pending_runtime_assignment_receipts` |
| `Keeper_settings_saved` | `ksv_observation` CAS | `pending_keeper_settings_save_receipts` |
| `Runtime_form_saved` | `rfs_observation` CAS | `pending_runtime_form_save_receipts` |
| `Keeper_creation_observed` | `kcr_observation` CAS | `pending_keeper_creation_receipts` |
| `Task_dispatched` | `Masc_tui_task_dispatch.complete`, `settle_unstarted` | `pending_task_dispatch_completions` |
| `Console_write` | `Terminal_write_repair.note`. `Console_sink` 쓰기 뒤 observer 와 OSC 52 복사가 부른다 | `request_console_write_repair`, `consume_damage` |
| `Terminal_write_lost` | 터미널 writer thread 의 쓰기 실패 | `Masc_tui_terminal_out.take_lost` |
| `Resize_signal` | SIGWINCH, SIGCONT handler | `consume_resize_request` |
| `Interrupt_signal` | SIGINT handler | `Masc_tui_exit_signals.poll` |
| `Terminate_signal` | SIGTERM, SIGHUP, SIGQUIT handler | `Masc_tui_exit_signals.poll` |

- 시작 probe 의 promise 는 지금도 기다림 안에서 겨룬다(`prepare_terminal_probe` 의 `wait`). 종이 필요 없다.
- `Code_results.take_ready_*`, observer 재연결, 엔진 표본 읽기의 답은 모두 `Mailbox` 로 온다.

### 2.2 (b) 시각: 판단하는 쪽이 그 시각을 적는다

| `deadline_reason` | 시각이 있는 곳 | 시계 |
|---|---|---|
| `Frame_slot` | `Render_schedule` 이 미룬 프레임의 간격 끝 | 단조 |
| `After_frame` | 프레임을 낸 바퀴의 다음 바퀴(§3.4) | 단조 |
| `Time_text` | 마지막 프레임의 `Redraw.next_change` (`time_redraw_due`) | 벽 |
| `Owed_read_retry` | `Masc_tui_owed_read.Waiting.retry_at`. 모든 `launch_owed_*`, roster, fusion, memory world 가 이 판단을 쓴다 | 단조 |
| `Refresh_retry` | `Masc_tui_refresh_pace.Failing.retry_at` | 단조 |
| `Roster_row_scheduled` | `Masc_tui_roster_owed` 의 `scheduled` | 단조 |
| `Engine_sample` | `Masc_tui_engine_samples` 의 다음 slot | 단조 |
| `Play_room_read` | `Masc_tui_play_room` 의 `next_read` | 단조 |
| `Tool_series_reread` | `state.tool_series_reread_at` | 단조 |
| `Provider_history_day` | `state.provider_history_reread_at` | 벽 |
| `Harness_stale` | `state.harness_stale_at` | 벽 |
| `Identity_attempt_deadline` | `identity_login_expectations` 의 `ile_expires_at` | 벽 |
| `Identity_login_expiry` | `identity_logins` 의 `ils_expires_at` | 벽 |
| `Quit_notice_expiry` | 걸어 둔 종료 확인의 알림 시각 + `last_action_window_s` | 벽 |
| `Emblem_step` | About 촛불의 다음 걸음 (`motion_step_ns`) | 단조 |
| `Paste_quiet` | 끝 표지 없이 멈춘 붙여넣기의 마지막 바이트 + `paste_quiet_seconds` (`paste_is_quiet`). 지나면 "Ctrl-C 로 되살린다" 안내가 뜬다 | 단조 |
| `Drain_budget_spent` | drain 이 바퀴 예산을 다 써서 남긴 일. 지금 바로 | 단조 |

- 입력 decoder 의 ESC 뒤 대기(`sequence_byte_wait_seconds`)는 읽기 안의 대기다. 종이 끊지 않는다.
  끊으면 화살표 하나가 ESC 와 두 글자로 갈라진다.

### 2.3 (c) 주기

| 이름 | 이유 |
|---|---|
| `Machine_view_cadence` | MSX 게임을 보는 동안 0.3 초마다 깬다(`machine_input_timeout_s`). 기계 화면은 observer stream 으로 오고 대화창은 `Play_room_read` 로 깬다. 이 주기가 따로 지키는 것을 코드에서 찾지 못했다. 게임을 연 동안에만 돌고, 확인할 때까지 이름을 붙여 남긴다(§6). |

## 3. 설계

### 3.1 종

- `Masc_tui_wake.bell` 은 `int Atomic.t` 비트 집합과 `Eio.Condition.t` 다.
  생성자마다 비트 하나다. 비트 번호는 `match` 로 정하고 `_` 갈래를 두지 않는다.
- `ring bell source` 는 비트를 세우고 `Eio.Condition.broadcast` 한다.
  broadcast 는 signal handler, 다른 domain, system thread 에서 불러도 된다(eio README "Example: Signal handlers").
- `await bell` 은 `Eio.Condition.loop_no_mutex` 로 비트가 하나라도 서 있을 때까지 잔다.
  먼저 등록하고 나서 비트를 보므로, 보고 잠드는 사이에 친 종을 놓치지 않는다.
- `take bell` 은 비트를 모두 지우고 친 source 목록을 돌려준다. 루프는 기다림이 끝난 바로 뒤에 부른다.
  그 뒤 바퀴 도중에 친 종은 다음 기다림을 바로 끝낸다. 그래서 바퀴 앞쪽 drain 이 적용한 답도
  뒤쪽 launcher 까지 반드시 간다.
- 쓰는 쪽은 한 프로세스에 하나인 `Masc_tui_wake.loop` 종을 친다. 시험은 자기 종을 만든다.

### 3.2 시각

- 시간을 비교하는 판단은 `Masc_tui_wake.reached reason ~now ~at` 을 쓴다. 단조 ns 로 비교하면 `reached_ns` 다.
  `now >= at` 을 돌려주고, 아직이면 `at` 을 이번 바퀴의 시각으로 적는다. `at` 이 무한이나 nan 이면 적지 않는다.
  `Redraw.holds` 가 화면 글자에 하는 일을 루프 판단에 한다.
- 적는 창은 기다림이 끝난 뒤부터 다음 기다림 전까지다(`Pass.begin_pass`).
  바퀴마다 모든 판단이 다시 돌므로 지난 바퀴의 시각은 버린다.
- 루프만 아는 시각(`Frame_slot`, `After_frame`, `Machine_view_cadence`)은 `Masc_tui_wake.next_deadline` 이 만든다.
  `Frame_slot` 은 `Render_schedule.frame_due_ns` 다. 이 함수가 `input_timeout_seconds` 를 대신한다.
  `next_deadline` 은 이 셋과 이번 바퀴에 적힌 시각 가운데 가장 이른 하나를 고른다.
- `Time_text`, `Quit_notice_expiry`, `Emblem_step` 은 루프 꼬리의 판단이 `reached` 로 적는다.
- 벽시계 시각은 적을 때 단조 시각으로 바꾼다. 남은 시간만 옮기므로 벽시계가 움직여도 다음 바퀴가
  다시 적는다.

### 3.3 기다림

- `read_input` 은 `Masc_tui_wake.wait` 를 받는다. 시각이 없으면 상한 없이 잔다.
- `terminal_has_bytes` 는 먼저 커널에 기다리지 않고 묻는다. 바이트가 이미 있으면 바로 읽는다.
  울린 채로 남은 종이 기다리던 키를 이기면, 바퀴마다 종이 울리는 동안 키를 영영 못 읽는다.
- 바이트가 없으면 `Eio.Fiber.any` 로 셋을 겨룬다. stdin 이 읽힐 때, 시각이 올 때, 종이 울릴 때다.
  읽기 자체는 지금처럼 겨룸 밖에 둔다. 읽기를 취소하지 않는다.
- 종이 이기면 그 읽기는 이벤트 없이 끝난다. decoder 에는 시간이 지났다고 알리지 않는다.
  ESC 접두는 원래대로 자기 대기를 채운다.

### 3.4 프레임 뒤 한 바퀴

- launcher 가운데 몇은 프레임이 그린 것을 읽는다. 그린 목록, 그린 읽기, 그린 화면의 필요 데이터가 그렇다.
  프레임은 바퀴 끝에 그려지므로, 그 결과를 읽는 launcher 는 다음 바퀴에야 돈다.
- 16 ms 상한이 있을 때는 그 다음 바퀴가 곧 왔다. 이제는 프레임을 낸 바퀴 뒤에 한 바퀴를 바로 돈다(`After_frame`).
  프레임이 없으면 이 바퀴도 없다.

### 3.5 느린 바퀴 기록

- `main loop: N ms between two iterations` 는 두 바퀴 사이 시간을 쟀다. 이제는 기다림이 길다.
  기다림이 끝난 때부터 다음 기다림 전까지, 루프가 일한 시간만 잰다.

## 4. 시험

- `test_tui_wake` 는 `source` 와 `deadline_reason` 마다 빠짐없는 `match` 로 번호를 붙인다.
  생성자를 더하면 시험이 컴파일되지 않고, 번호를 붙이면 아래 확인이 그 생성자를 요구한다.
  - 각 `source` 를 치면 기다리던 fiber 가 깨고, `take` 가 그 source 하나를 돌려준다.
  - 종을 치지 않으면 기다림은 계속 잔다.
  - `earliest` 는 이유와 상관없이 가장 이른 시각을 고른다.
  - `reached` 는 아직일 때만 적고, 벽시계 시각을 남은 시간만큼의 단조 시각으로 적는다.
  - `next_deadline` 은 프레임 간격, 프레임 뒤 한 바퀴, 게임 주기, 적힌 시각 가운데 가장 이른 것을 고른다.
  - `Masc_tui_owed_read.due`, `Masc_tui_refresh_pace.due`, `Masc_tui_roster_owed.release_scheduled`,
    `Masc_tui_engine_samples.tick`, `Masc_tui_play_room.poll` 은 아직일 때 자기 이유로 시각을 적는다.
  - 터미널 읽기는 종이 울리면 이벤트 없이 끝난다. 이미 온 바이트는 울린 종보다 먼저 읽는다.
    ESC 뒤 대기는 종이 울려도 끊기지 않아 화살표가 한 키로 남는다.
- `test_tui_wake_writers` 는 `mail`, Task 전송 완료, 콘솔 쓰기가 프로세스의 종을 치는지 본다.
- 변이 확인. 아래를 하나씩 되돌리면 시험이 실패한다.
  - `mail` 에서 종 치기를 뺀다.
  - `terminal_has_bytes` 의 겨룸에서 종을 뺀다.
  - `reached` 에서 적기를 뺀다.
  - `next_deadline` 에서 적힌 시각을 뺀다.
  - `terminal_has_bytes` 의 커널 먼저 묻기를 뺀다.
  - ESC 뒤 대기에 종을 넣는다.

## 5. 측정

조건은 §1 과 같다. 200x60, frozen 재생 서버 127.0.0.1:18990, 키 없이 180 초, 2026-11-19.
새 빌드는 `dcdec6ee` 다. 바퀴 수는 커밋하지 않은 임시 기록으로 셌다. 기록은 바퀴마다 깬 까닭을 한 줄씩 남겼다.

| 화면 | 빌드 | 루프 바퀴/초 | 문맥 전환/초 | CPU 초/분 | 프레임 | 터미널 바이트 |
|---|---|---|---|---|---|---|
| overview | main | 56.8 | 303 | 0.57 | 6 | 1566 |
| overview | 새 빌드 | 0.13 | 59 | 0.025 | 9 | 1566 |
| keepers | main | 56.5 | 328 | 0.75 | 33 | 11434 |
| keepers | 새 빌드 | 0.58 | 61 | 0.031 | 44 | 14434 |

- 남은 문맥 전환 약 60/초는 루프 밖이다. 터미널 writer thread, HTTP domain, Eio 가 낸다.
- keepers 의 바퀴 104 개를 깬 까닭으로 나누면 `Time_text` 45, `After_frame` 36, `Drain_budget_spent` 9,
  `Owed_read_retry` 7, `Mailbox` 7 이다.
- 시간 글자: keepers 의 나이 글자는 `19s` 부터 매초 바뀌어 `3m` 까지 43 번 바뀌었다.
  zone 1 시계는 분마다 3 번 바뀌었다. main 은 같은 줄이 `29s` 부터 `3m` 까지 33 번이었다.
  첫 글자가 달라서 바뀐 횟수가 다르다. overview 는 두 빌드 모두 시계만 3 번 바뀌었고 바이트가 같다.
- 키 지연: overview, 120x40. Down 과 Up 을 번갈아 33 ms 마다 450 번 누르고, 다음 키 전에 온 첫 바이트까지 잰다.
  main 과 번갈아 4 회 돌렸다.

  | 빌드 | 답한 키 | p50 | p90 | p99 | 최대 |
  |---|---|---|---|---|---|
  | main | 1795 / 1800 | 0.78 ms | 2.48 ms | 16.92 ms | 30.58 ms |
  | 새 빌드 | 1799 / 1800 | 0.80 ms | 1.51 ms | 9.80 ms | 25.59 ms |

- 스트림: frozen 서버는 새 사건을 밀어 주지 않는다. 그래서 `Mailbox` 종은 읽기 답(위 7 번)과
  `test_tui_wake_writers` 로만 확인했다. 스피너는 이 두 화면에 없었다.

## 6. 열린 것

- `Machine_view_cadence` 가 지키는 것이 남았는지 MSX 게임을 열고 확인한다. 없으면 지운다.
- 벽시계 시각은 적을 때의 남은 시간으로 단조 시계에 옮긴다. 기계가 잠든 사이 벽시계만 갔다면,
  깨어난 뒤 시계·나이 글자는 그 남은 시간(대개 1 분 안)만큼 늦게 바뀐다. 다른 종이 울리면 그때 다시 적는다.
- 따로 찾은 것: `Masc_tui_identity_updates.providers_loaded` 는 `Unix.gettimeofday` 를
  `Masc_tui_owed_read.failed ~now` 에 넘긴다. `due` 는 단조 시계로 묻는다. 그래서 실패한 로그인 읽기의
  재시도 시각이 단조 시계로 수십 년 뒤가 되어 다시 읽지 않는다. 이 RFC 범위 밖이다.
