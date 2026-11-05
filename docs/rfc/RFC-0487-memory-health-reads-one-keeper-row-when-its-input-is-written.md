---
rfc: "0487"
title: "Memory health 는 입력을 쓰는 곳에서 그 Keeper 를 알리고, TUI 는 그 Keeper 행 하나만 읽는다"
status: Draft
created: 2026-11-05
updated: 2026-11-05
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0480", "0481", "0483"]
---

# RFC-0487 — Memory health 는 그 Keeper 행 하나만 읽는다

## 0. 요약

TUI 의 Memory 화면은 2초마다 fleet 전체 Memory health(`GET /api/v1/dashboard/keeper-memory-health`)를 읽는다. 서버는 요청마다 모든 Keeper 의 행을 다시 계산하고, 60초 캐시 뒤에 둔다.

이 RFC 는 이 읽기를 RFC-0481 과 같은 방식으로 바꾼다.

1. 서버는 health 행의 입력을 쓰는 곳에서 그 Keeper 를 알린다(`workspace_dataset_changed`, dataset `memory_health`, `keeper`). 서버가 주기로 다시 계산해 비교하지 않는다.
2. TUI 는 알림이 이름 대는 Keeper 의 행 하나만 읽는다(`GET /api/v1/dashboard/keeper-memory-health?keeper=<k>`). fleet 합계와 경보 요약은 TUI 가 행들로 다시 계산한다. 계산은 서버와 같은 모듈 하나를 쓴다.
3. 화면에 들어올 때, 재확인할 때, 읽기가 실패해 다시 시도할 때는 지금처럼 fleet 전체를 읽는다.

운영자 결정(2026-11-05):
- 근본 개선만 한다. TUI 에 주기 읽기 안전망을 두지 않는다. 서버 주기 비교도 두지 않는다.
- 입력이 자주 바뀌어도 알림마다 Keeper 행 하나만 읽게 한다.

## 1. 지금 상태

조사 기준: main `13ee7bab5c8`, 하위 에이전트 조사와 직독(2026-11-05). 줄 번호 대신 함수 이름을 적는다.

### 1.1 읽는 쪽

- TUI: Memory 화면은 주기 블록에서 `launch_memory_health_load` 를 부른다("Fleet memory health is a reading, so the tick refreshes it"). Metrics(Usage)는 도착할 때만 읽는다. `r` 키 새로고침도 읽는다.
- Memory 화면의 입력 창(선택한 Keeper 의 turn record)은 health 읽기가 끝날 때(`Memory_loaded`) 같이 다시 읽힌다. 그래서 지금은 2초마다 갱신된다.
- 서버: `keeper_memory_health_http_json ~base_path` 가 `health_keeper_ids` 의 Keeper 마다 `keeper_health` 로 행을 만들고, `totals` 와 `alert_summary` 는 그 행들을 접어 만든다. `execution` 과 `generated_at` 은 fleet 값이다.

### 1.2 행의 입력 13가지

| # | 입력 | 쓰는 곳 | 이미 나가는 알림 |
|---|---|---|---|
| 1 | 메모리 스냅샷 `C/<k>.memory-current.json` | `Keeper_memory_os_current.update_locked_with_output` 하나로 모임(공개 함수 10개, 호출 15곳) | `keeper_memory_journal_appended`(모든 커밋·격리가 저널 줄을 씀). workspace 를 싣지 않는 전역 방송 |
| 2 | continuity 스냅샷 `R/<k>/librarian-continuity.json` | `Keeper_librarian_continuity.save_snapshot`(호출 2곳) | 없음 |
| 3 | unread 원장 `C/<k>.librarian-unread.json` | `Keeper_librarian_unread_ledger.archive`(경로 3개) | 없음 |
| 4 | source 스냅샷 `C/<k>.memory-source-current.json` | `Keeper_memory_source_current.update_locked`·`save_snapshot`(호출 5곳) | 프로세스 안 알림만 |
| 5 | 메모리 저널 `C/<k>.memory-journal.jsonl` | `append_journal_line_strict` 하나로 모임 | `keeper_memory_journal_appended` |
| 6 | Librarian 진행 기록 `R/<k>/librarian-progress.json` | `Keeper_librarian_progress.write`(호출 4곳) | 없음 |
| 7 | drain 측정값(메모리 안) | `Keeper_librarian_queue_refresh.publish_measurement`, `forget_measurement` | 없음 |
| 8 | continuity 관측(메모리 안) | `Keeper_continuity_observation.record`(provider 요청마다), `record_synthesis`(Librarian 한 바퀴에 약 30번), `forget` | 없음 |
| 9 | Keeper meta | `Keeper_owner.commit` 을 거친 registry 쓰기 | `keeper_row_changed` |
| 10 | turn 경계 `R/<k>/turn-boundaries.jsonl` | `Keeper_turn_boundaries.append`(호출 3곳) | 전역 `keeper_turn_complete` 만 |
| 11 | turn record | `Keeper_turn_record_writer.write`, 보관 기간 정리 `prune_shared_jsonl_stores` | `chat_appended`(자율 turn 만) |
| 12 | Otel 카운터(메모리 안) | Librarian 실패 `inc_counter`, vision `record_eviction` | 없음 |
| 13 | keepers.toml `C/*.toml` | `commit_configuration`, `apply_rollback`, 삭제, 운영자 손 편집 | 없음 |

`C` 는 `Config_dir_resolver.keepers_dir_for_base_path`, `R` 은 `Workspace.keepers_runtime_dir` 이다.

### 1.3 시간만 지나서 바뀌는 값

행 안에는 없다. 행의 모든 시각(`measured_at`, `prepared_at`, `observed_at`, `recorded_at`, `updated_at`)은 쓸 때 정해진다. 지금 시각과 비교하는 필드나 오래됨 기준이 없다. "몇 초 전" 표시는 TUI 가 자기 시계로 그린다.

시간이 일으키는 변화는 둘뿐이다.
- 24시간마다 도는 보관 기간 정리가 오래된 turn record 를 지운다(입력 11).
- 서버가 다시 시작하면 메모리 안 입력(7, 8, 12)이 빈다. TUI 는 서버 identity 가 바뀐 것을 재확인으로 받아 fleet 전체를 읽는다.

### 1.4 알림 하나에 fleet 전체를 읽으면 생기는 일

입력 8 은 provider 요청마다, Librarian 한 바퀴에도 약 30번 바뀐다. 알림마다 fleet 전체를 읽으면, Keeper 가 일하는 동안 Memory 화면은 쉬지 않고 모든 행을 다시 읽는다. 서버도 그때마다 모든 Keeper 의 행을 계산한다.

## 2. 결정

1. **알림은 저장소 쓰기 함수에서 낸다.** 호출 위치마다 달지 않는다. 저장소마다 쓰기가 모이는 함수 하나에 observer 를 둔다(`Repo_store.install_written_observer` 와 같은 모양). 호출 위치에 다는 방식은 새 호출 위치가 생기면 빠진다.
2. **observer 는 keepers 디렉터리와 Keeper 이름을 받는다.** 쓰기 자리 일부는 `base_path` 를 모른다. 서버는 시작할 때 자기 workspace 의 `C` 와 `R` 을 `base_path` 에 묶어 두고, observer 가 받은 디렉터리로 workspace 를 찾는다. 묶이지 않은 디렉터리의 쓰기는 알리지 않는다(그 workspace 를 보는 TUI 가 이 서버에 없다).
3. **알림은 바뀔 때마다 낸다.** 간격 제한·합치기를 서버에 두지 않는다. 읽는 쪽 비용은 행 하나로 줄인다(결정 4). TUI 는 지금처럼 진행 중인 읽기 하나로 몰아 읽는다(`Masc_tui_owed_read`).
4. **TUI 는 그 Keeper 행 하나만 읽는다.** 응답은 fleet 응답의 `keepers` 원소와 같은 모양이다. TUI 는 들고 있는 fleet 답에서 그 행만 바꾸고, 합계와 경보 요약을 다시 계산한다. 그 Keeper 가 없으면(삭제) 행을 지운다.
5. **합계와 경보 요약 계산은 모듈 하나로 둔다.** 지금은 서버만 계산한다. 서버 fleet 응답과 TUI 가 같은 모듈을 쓴다. 두 쪽이 따로 계산하면 숫자가 어긋난다.
6. **Memory 입력 창은 선택한 Keeper 의 알림에 다시 읽는다.** 지금은 2초 health 읽기에 묻어 갱신된다.
7. **보관 기간 정리는 지운 turn record 의 Keeper 마다 알린다.** 시간이 일으키는 변화도 쓰기 자리에서 알린다.

## 3. 층

한 층이 끝나야 다음 층을 연다. 층마다 그 자체로 맞게 동작한다.

| 층 | 내용 | 기대는 것 |
|---|---|---|
| L1 | 서버: `GET /api/v1/dashboard/keeper-memory-health?keeper=<k>`. 합계·경보 요약 계산을 공용 모듈로 옮기고, fleet 응답도 그 모듈을 쓴다 | main |
| L2 | wire 와 TUI: dataset `Memory_health { keeper }`. 알림이 오면 그 Keeper 행만 읽고 합친다. Memory 입력 창도 선택한 Keeper 알림에 읽는다. Browser lane 에서 돌아오면 그 화면에 도착한 것으로 읽는다. 2초 갈래는 아직 둔다 | L1, RFC-0480 2층(#48489, subject 디코더) |
| L3 | 서버: 입력 1~6·10·11·13 의 저장소 observer, `C`·`R` → `base_path` 묶음, 알림. 보관 기간 정리 알림 | L2 |
| L4 | 서버: 메모리 안 입력 7·8·12 의 observer. TUI: Memory 2초 갈래를 지운다 | L3 |

L4 가 2초 갈래를 지운다. 그 전까지는 2초 갈래가 남아 있어 중간 층이 main 에 들어가도 화면이 멈추지 않는다.

## 4. 검증

- L1: 한 Keeper 응답이 fleet 응답의 그 행과 같다. 없는 Keeper 는 404. fleet 합계가 공용 모듈 결과와 같다.
- L2: PTY 시험. Memory 화면에서 한 Keeper 알림이 그 Keeper 행 읽기 하나만 일으킨다. 다른 dataset 알림은 아무것도 읽지 않는다. 합친 합계가 fleet 응답 합계와 같다. Browser lane 을 닫으면 그사이 온 알림을 읽는다.
- L3·L4: 저장소마다 쓰기 한 번이 그 Keeper 알림 하나를 낸다. 묶이지 않은 디렉터리의 쓰기는 알리지 않는다. L4 PTY 시험은 `--refresh 1` 로 Memory 화면에 3초 머물며 알림 없이는 읽지 않는 것을 본다.
- 층마다 `scripts/harness/perf/tui_request_probe.py` 로 Memory 화면의 요청 수를 앞뒤로 잰다(준비되는 대로).

## 5. 손대지 않을 것

- Usage(Metrics) 화면의 다른 읽기, `r` 키 새로고침.
- `keeper_memory_journal_appended` 등 이미 있는 알림의 뜻. Memory health 알림은 따로 낸다.
- RFC-0486(미러링·관전).

## 6. 남는 것

- `keeper_memory_journal_appended` 는 workspace 를 싣지 않는 전역 방송이다. 서버 하나가 workspace 여럿을 볼 때 다른 workspace 의 TUI 도 받는다.
- 조사에서 health 가 읽는 Otel 라벨 `memory_os_current_read` 를 올리는 곳을 찾지 못했다. L4 에서 확인한다.
- keepers.toml 을 운영자가 손으로 고치면 쓰기 자리가 없어 알림이 없다. fleet 계산은 디렉터리를 매번 새로 읽으므로, TUI 가 fleet 전체를 다시 읽을 때(도착, 재확인) 보인다.
- health 를 읽는 쪽(`read_for_keepers_dir`)이 대기 중인 publication 을 마저 쓴다. 이 쓰기도 입력 1 의 쓰기라 알림을 낸다. 한 번 마치면 더 쓸 것이 없어 반복하지 않는다.
