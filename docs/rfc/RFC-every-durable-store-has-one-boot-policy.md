---
title: "모든 영속 store 가 부팅 정책을 한 목록에서 받는다"
status: Draft
created: 2026-09-24
updated: 2026-09-26
author: claude-main
---

# RFC: 모든 영속 store 가 부팅 정책을 한 목록에서 받는다

- 관련: #32504 (부팅 때 한 자리에서 reconcile), #37900, #32463, #32461, RFC-0420, RFC-0444, #38595 · #38612, #38986, #39224
- 범위: 부팅 reconcile(`Keeper_store_boot_reconcile`)과 배포 preflight(`bin/deployment_preflight_helper.ml`)가 검사하는 store 목록과 각 store 의 부팅 정책. 각 store 의 스키마는 바꾸지 않는다.

## 무슨 일이 있었나 (사람이 읽는 서두)

같은 파일을 두 곳이 서로 다른 목록으로 검사한다.

- **배포 preflight** 는 store 16개를 검사하고, 하나라도 못 읽으면 배포를 멈춘다.
- **부팅 reconcile** 은 2개(keeper meta, memory current)만 거부 대상으로 보고, goal store 는 INFO 한 줄로 알린다.

그래서 셸에서 `masc start` 로 띄우면, preflight 라면 멈췄을 파일 14개를 아무도 보지 않고 부팅이 끝난다. 그 파일들은 몇 시간 뒤 어느 Keeper 의 어느 읽기에서 따로따로 터진다.

2026-09-26 에 실제로 그렇게 터졌다. 시각은 모두 KST 다.

- #38986 이 official-client session(`keepers/<name>/official-client-runtime/session.json`)의 스키마를 v1 에서 v2 로 올렸다. PR 본문에 "Fresh state required" 라고 적혀 있었다.
- 새 바이너리는 10:53 에 설치만 되고, 서버는 옛 바이너리로 14:09 까지 v1 파일을 계속 썼다.
- 14:09:38 에 `deploy.sh` 를 거치지 않은 `masc start` 로 새 바이너리가 떴다. 부팅은 이 store 를 보지 않았다.
- `session.json` 24개가 전부 v1 이었다. 그중 14:11~14:51 에 턴을 시도한 Claude Code·Codex·Antigravity Keeper 16개가 턴마다 실패했다(실패 로그 185줄).
- 운영자 복구 API(`Restart_fresh`)도 먼저 이 파일을 읽어야 해서 쓸 수 없었다.
- 파일 24개를 손으로 옮기고 나서야 돌았다 (#32504 댓글).

이 store 는 읽기 실패를 typed 로 보여 주고, 못 읽는 파일 위에 아무것도 쓰지 않는다. RFC-0444 의 두 질문만 물으면 부팅이 막을 이유가 없다. 하지만 못 읽는 동안 Keeper 가 턴을 아예 돌지 못한다. 그래서 세 번째 질문을 더한다.

이 RFC 는 14개를 모두 부팅에서 읽게 하지 않는다. 못 읽어도 Keeper 가 턴을 도는 store 는 실행 중에 처음 읽는 쪽이 알게 둔다. 부팅이 막는 것은 Keeper 를 멈추거나 잃은 것을 덮어쓰는 store 다.

## 1. 분류

store 마다 세 가지를 묻는다.

- **(a)** 읽기 실패를 모든 소비자가 typed 로 보여 주는가 (RFC-0444 §2.4)
- **(b)** 모든 쓰기가 못 읽는 파일을 거부하는가 (RFC-0444 §2.4). 못 읽는 파일을 옆으로 옮기고 새로 쓰거나, 없는 것으로 보고 다시 만드는 쓰기는 거부가 아니다.
- **(c)** 못 읽는 동안에도 Keeper 가 턴을 도는가. 워크스페이스 전체가 쓰는 store(gate pending, board, goal, World constitution)는 그 store 를 읽는 모든 Keeper 를 본다.

정책은 이렇게 정한다.

- (b) 나 (c) 가 **아니오** 면 `Refuse_boot` 다. 부팅이 모든 파일을 읽고, 하나라도 못 읽으면 뜨지 않는다.
- goal store 는 `Degrade_typed` 다. (a)(b)(c) 가 모두 예라서 규칙으로는 `Preflight_only` 와 같다. RFC-0444 가 부팅마다 INFO 한 줄로 보이게 하기로 해서(0444 판정 3), 부팅이 한 번 읽고 알린다. 파일 하나라 부팅 비용이 없다. 배포 preflight 는 이 store 를 읽지 않는다. RFC-0444 §5 가 적었듯, 이 store 에서 멈추면 운영자가 리셋을 서두르게 된다.
- 나머지는 `Preflight_only` 다. 부팅은 읽지 않는다. 배포 preflight 만 미리 읽는다.
- (a) 가 **아니오** 인 store 는 정책과 따로, 소비자를 고칠 결함이다. 소비자가 실패를 빈 값으로 바꾸면 Keeper 는 틀린 전제로 돈다. store 마다 PR 하나로 고친다.

| store | (a) | (b) | (c) 턴 | 부팅 정책 | (a) 를 깨는 곳 |
|---|---|---|---|---|---|
| keeper meta | — | 아니오 | 멈춤 | Refuse_boot (0420) | — |
| memory current | — | 아니오 | 돈다 (recall 빠짐) | Refuse_boot (0420) | — |
| official-client session | 예 | 예 | **멈춤** | **Refuse_boot** | — |
| Keeper event queue | — | — | **멈춤** | Refuse_boot (PR-3) | — |
| Keeper checkpoint | — | — | **멈춤** (버전을 올리지 않은 변경만) | 정하지 않음 (4장) | — |
| World constitution | 아니오 | 예 (append) | 돈다 (못 푼 줄은 빠짐) | 목록 밖 | 프롬프트가 `rejected` 줄을 보여 주지 않음 |
| goal store | 예 | 예 | 돈다 | Degrade_typed (0444) | — |
| memory-source current | 아니오 | 예 | 돈다 | Preflight_only | `keeper_tool_memory_runtime.ml:830-835`, `keeper_memory_os_recall.ml:72-80` |
| board posts | 아니오 | 예 (#38612) | 돈다 | Preflight_only | 대부분의 board 읽기가 부분 상태를 완전한 것처럼 씀 |
| turn records | 아니오 | 예 (append) | 돈다 | Preflight_only | `keeper_autonomous_turn_source.ml:460-481`, `keeper_next_request_forecast.ml:351-361` |
| turn boundaries | 아니오 | 예 (append) | 돈다 (맥락이 줄어듦) | Preflight_only | `keeper_checkpoint_purge.ml:269-274` |
| Librarian progress | 아니오 | 예 | 돈다 (Librarian 멈춤) | Preflight_only | `keeper_librarian_continuity.ml:99-104`, `server_dashboard_http_keeper_memory_health.ml:201`, `keeper_turn_driver_try_provider.ml:268-276` |
| turn fragments | 아니오 | 예 (append) | 돈다 (Librarian 멈춤) | Preflight_only | `keeper_status_detail.ml:522`, `dashboard_http_keeper_metrics.ml:112` |
| Librarian range receipts | 예 | 예 | 돈다 (Memory 쓰기 도구 실패) | Preflight_only | — |
| disposition receipts | 예 | 예 | 돈다 (턴 경로에 없음) | Preflight_only | — |
| provider-input | 거의 | 예 (append) | 돈다 | Preflight_only | — |
| official Librarian progress | 예 | 예 | 돈다 (턴 경로에 없음) | Preflight_only | — |
| absorbed facts | 예 | 예 (append) | 돈다 | Preflight_only | — |
| memory OS events | 예 | 예 (append) | 돈다 | Preflight_only | — |
| gate pending | 예 | 예 | 돈다 (Gate 가 필요한 도구만 실패) | Preflight_only | — |

- "—" 는 조사하지 않았다는 뜻이다. (c) 가 아니오면 정책이 이미 정해져서 (a)(b) 를 보지 않았다.
- (a) 칸의 file:line 은 09-24 조사 커밋 `eba5fb56ad` 기준이다. 지금은 줄이 옮겨진 곳이 있다. 소비자를 고치는 PR 이 그때의 위치를 다시 찾는다.
- (b) 아니오의 근거
  - keeper meta: 부팅이 스키마가 안 맞는 meta 를 없는 것으로 보고 선언에서 Keeper 를 다시 만든다 (`keeper_owner_registry.ml:96-101`).
  - memory current: Memory 쓰기가 못 읽는 스냅숏을 옆으로 옮기고 빈 상태에서 새로 쓴다 (`keeper_memory_os_current.ml:1895-1945`).

(c) 근거는 2026-09-26 조사다(6장). 턴이 멈추는 곳:

- keeper meta: `keeper_heartbeat_loop.ml:858-868` 이 dispatch 전에 meta 를 다시 읽는다. `keeper_unified_turn_execution.ml:50-56` 이 provider 호출 전에 턴을 거절한다.
- official-client session: `keeper_claude_code_runtime.ml:669-674`, `keeper_codex_runtime.ml:770-774`, `keeper_antigravity_runtime.ml:468-472` 가 runtime 을 만들지 못한다. `Internal` 오류는 다음 lane 후보로 넘어가지 않아서(`keeper_turn_driver_try_runtime.ml:84-98`) 턴이 끝난다.
- Keeper event queue: `keeper_event_queue_persistence.ml:349-377` 이 못 읽는 스냅숏을 그대로 두고 오류를 돌려준다. `keeper_heartbeat_stimulus_intake.ml:1060-1069` 가 `Pending_selection_failed` 로 바꾸고, `keeper_heartbeat_loop.ml:80-88` 이 매 cycle 턴을 돌리지 않는다. 2026-09-22 event-queue v18→v19 사고가 이것이다 (#37900). 파일 이름(`event-queue-v19.json`)은 두고 payload 표식만 올리면 이 상태가 된다 (`keeper_event_queue_schema.ml`).
- Keeper checkpoint: `keeper_run_context.ml:100-106` 이 `Superseded_version` 말고는 모든 읽기 실패를 `Checkpoint_unread` 로 올리고, `keeper_agent_run.ml:952-973` 이 그걸 `not_dispatched` 로 끝낸다. 다만 `checkpoint_version` 을 올린 hard cut 은 `Superseded_version` 이 되어 새 맥락으로 돈다. 턴이 멈추는 건 버전을 올리지 않은 codec 변경(`Parse_error`), 더 새 버전(`Newer_version`), 읽기 실패다.
- World constitution: 턴을 막는 건 파일 자체를 읽지 못할 때(`Unreadable`, I/O 오류)뿐이다 (`keeper_unified_prompt.ml:1359-1366`). 스키마가 바뀌어 못 푸는 줄은 `ledger.rejected` 로 빠지고, 턴은 그 조항 없이 돈다 (`world_constitution_store.ml:125-141`). 그래서 hard cut 으로 턴이 멈추는 store 가 아니다. 파일을 읽지 못하는 경우는 #39230 과 같은 부류다.

아직 목록에 없는 store 는 4장 PR-3 에서 다룬다.

- event queue: (c) 가 아니오라서 `Refuse_boot` 다. 지금은 preflight 셸이 `validate-current-queue`·`validate-current-wal` 로 따로 읽는다. 목록에 넣으면서 그 두 subcommand 와 셸 반복문을 지운다. 파일은 Keeper 당 두 개, 합쳐 10MB 라서 부팅 비용이 작다.
- 체크포인트: 현재 trace 의 checkpoint 는 24개 합쳐 642MB(가장 큰 것 89MB)다. 부팅마다 전부 풀면 2.2 의 전제가 깨진다. 버전을 올린 hard cut 은 이미 새 맥락으로 넘어가므로, 남은 위험은 버전을 올리지 않은 codec 변경이다. 부팅에서 읽을지, codec 을 바꾸면 버전을 올리도록 막을지는 운영자가 정한다.
- World constitution: hard cut 으로 턴이 멈추지 않아서 이 RFC 의 부팅 정책 대상이 아니다. 프롬프트가 `rejected` 줄을 보여 주지 않는 것은 (a) 결함이다.
- board comments, memory-journal: preflight 도 읽지 않는다. 읽는 함수부터 만들어야 한다 (#38595, #38596). (c) 는 조사하지 않았다.

## 2. 설계

### 2.1 store 목록은 lib 한 곳에 있다

`lib/keeper/keeper_durable_store.ml` 에 모든 store 를 둔다. 부팅 reconcile 과 배포 preflight 는 이 목록을 읽기만 하고, 자기 목록을 따로 갖지 않는다.

열거하는 타입은 `Id.t` 하나다. `[@@deriving enumerate]` 가 `Id.all` 을 만든다. 표도 하나다. `reader` 가 store 마다 정책과 읽는 법을 돌려준다.

```ocaml
module Id : sig
  type t = Keeper_meta | Memory_current | Goal_store | Official_client_session (* ... 17개 *)
  val all : t list   (* [@@deriving enumerate] *)
end

module Refusing : sig type t = Keeper_meta | Memory_current (* PR-2: | Official_client_session *) end
module Reported : sig type t = Goal_store end

type scan   (* store 하나를 읽는 법 *)
type reader =
  | Refuse_boot of Refusing.t * scan
  | Degrade_typed of Reported.t
  | Preflight_only of scan

val reader : Id.t -> reader            (* exhaustive, 표는 여기 하나 *)
val preflight_scan : Id.t -> scan option  (* Degrade_typed 는 None *)
val name : Id.t -> string
val run : scan -> base_path:string -> (report, string) result
```

손으로 쓴 목록이 없으므로 "preflight 에는 넣고 부팅에는 빠뜨리는" 일이 생기지 않는다.

- `Id.t` 에 생성자를 더하면 `reader` 가 채워질 때까지 컴파일되지 않는다.
- `Degrade_typed` 에는 `scan` 이 없다. 그래서 preflight 가 goal store 를 읽는 코드는 쓸 수 없다.
- store 를 `Refuse_boot` 로 보내려면 `Refusing.t` 에 생성자를 더해야 한다. 부팅의 이름·검사·옮기는 법이 `Refusing.t` 를 exhaustive 로 match 하므로, 셋을 다 채워야 컴파일된다.
- `Refusing.t` 값 하나가 두 `Id` 에서 오거나 어느 `Id` 에서도 오지 않는 실수는 컴파일러가 못 잡는다. 테스트가 `Id.all` 을 돌며 `Refusing.all`·`Reported.all` 과 하나씩 맞는지 본다.

### 2.2 부팅은 `Refuse_boot` 만 읽는다

부팅 reconcile 은 `all` 을 돌며 정책으로 나눈다.

- `Refuse_boot`: 모든 파일을 읽는다. 못 읽는 파일이 있으면 부팅을 거절하고 store·Keeper·경로·이유를 줄마다 찍는다. `--accept-store-quarantine` 을 주면 그 파일을 옆으로 옮기고 뜬다 (RFC-0420).
- `Degrade_typed`: 한 번 읽고, 못 읽으면 INFO 한 줄을 남긴다 (RFC-0444).
- `Preflight_only`: 읽지 않는다.

`Refuse_boot` store 는 옮기는 방법을 코드로 가져야 컴파일된다. 옮기는 것은 이름 바꾸기라서 바이트는 `.rejected-<ts>` 에 남는다. 파일이 여럿인 store 는 함께 옮긴다(event queue 는 스냅숏과 WAL).

- keeper meta: `<path>.rejected-<ts>` 로 이름을 바꾼다.
- memory current: `Keeper_memory_os_current.move_aside_for_keepers_dir`.
- official-client session (PR-2): 저장소 잠금(`official-client-runtime.lock`)을 잡고 `session.json` 을 `<path>.rejected-<ts>` 로 옮긴다. 이 store 의 fresh state 는 파일이 없는 상태다. 다음 claim 이 새 vendor 세션을 연다 (#38986 "Fresh state required"). 파일은 cluster 와 상관없이 `Common.keepers_runtime_dir_of_base` 아래에 있고, preflight 와 부팅은 store 의 `stored_bindings` 하나로 찾는다.

**부팅 비용.**
- 잰 것: 라이브 저장소에서 preflight 전체 스캔이 60초였다. 크기는 provider-input 3.4GB, turn records 57MB 이고, `Refuse_boot` 세 store 는 keeper meta 156KB, memory current 3.5MB, session 24KB 다.
- 재지 않은 것: store 별 스캔 시간. 크기로 보면 60초의 대부분은 provider-input 일 것이다.
- 그래서 부팅은 `Refuse_boot` 만 동기로 읽는다. `Preflight_only` 는 부팅에서 읽어 WARN 을 찍어도 그 store 의 Keeper 는 어차피 돌고, 고쳐지는 것은 없다.

### 2.3 배포 preflight 와 부팅이 같은 판정을 쓴다

preflight 의 `scan` 과 `on_refusal` 문구는 `Keeper_durable_store` 로 옮긴다. preflight 는 `Refuse_boot` 와 `Preflight_only` store 를 모두 읽고, 하나라도 못 읽으면 배포를 멈춘다. `Degrade_typed` store 는 읽지 않는다(2.1, 1장).

- keeper meta 와 memory current 는 부팅과 preflight 가 파일을 찾는 길이 다르다(부팅은 `Workspace.config`, preflight 는 `base_path`). 같은 fixture 에서 둘이 같은 파일을 거절한다는 테스트로 묶는다.
- `Preflight_only` store 는 preflight 만 미리 읽는다. preflight helper 가 서버와 같은 build 여야 판정이 맞다. 설치 스크립트가 helper 를 같이 설치하지 않는 문제는 #39224 다.

## 3. 판정 기준

1. `rg -n 'durable_stores =' bin/deployment_preflight_helper.ml` 0줄. preflight 는 `Keeper_durable_store.Id.all` 과 `reader` 를 쓴다.
2. `Id.all` 을 돌며 모은 `Refuse_boot`·`Degrade_typed` 값이 `Refusing.all`·`Reported.all` 과 하나씩 맞고, 이름이 서로 다르다는 테스트.
3. 같은 fixture 에서 부팅이 지목한 `Refuse_boot` 파일을 preflight 도 거절하고, 부팅이 INFO 만 남기는 goal store 는 preflight 가 읽지 않는다는 테스트.
4. PR-2: v1 `session.json` 을 둔 base path 로 `Keeper_store_boot_reconcile.examine`·`admit` 을 돌리면 플래그 없이는 거절하고, 거절 문구에 Keeper 와 경로가 있다. 파일 digest 는 그대로다. `quarantine` 뒤에는 파일이 없고, 옮긴 사본이 같은 바이트를 가지며, `load` 는 `None` 이다.
5. PR-3: event queue 를 못 읽는 fixture 로 부팅이 거절하고, 격리하면 스냅숏과 WAL 이 함께 옮겨진다. preflight 의 `validate-current-queue`·`validate-current-wal` 과 셸 반복문이 사라진다.
6. 소비자 수정 PR 은 1장 마지막 열의 해당 소비자를 고치고, 읽기 실패가 typed 로 보이는 것을 테스트로 보인다.

## 4. 단계

- **PR-1 목록**: `Keeper_durable_store`(`Id`, `Refusing`, `Reported`, `reader`, `preflight_scan`, `name`, `run`, `on_refusal`). store 별 읽는 법은 preflight 에서 이 모듈로 옮기고 내보내지 않는다. `reader` 가 더는 가리키지 않는 읽는 법은 unused 경고로 빌드가 멈춘다. preflight 와 부팅 reconcile 이 이 목록을 쓴다. 부팅과 preflight 의 동작은 바뀌지 않는다. 판정 1·2·3.
- **PR-2 세션**: official-client session 을 `Refuse_boot` 로 올리고, 잠금을 잡고 옮기는 방법을 더한다. 판정 4.
- **PR-3 event queue**: 목록에 넣고 `Refuse_boot` 로 둔다. 격리는 queue 소유자 잠금 아래에서 스냅숏과 WAL 을 함께 옮긴다. 판정 5.
- **체크포인트**: 운영자 결정을 기다린다 (1장 아래 설명).
- **PR-4 읽는 함수가 없는 store**: board comments, memory-journal(#38596). (c) 부터 조사한다.
- **PR-5~ 소비자**: 1장 마지막 열의 소비자를 store 별로 고친다. 판정 6.
- 별도 결함: #38597(memory events), #38598(preflight 문구), #39224(설치된 preflight helper 가 서버보다 오래됨).

## 5. 반론과 답

- **"RFC-0444 규칙대로 (a) 를 못 채운 6개를 `Refuse_boot` 로 올리면 된다."** 6개 모두 못 읽는 동안에도 Keeper 는 턴을 돈다. 한 Keeper 의 turn record 한 줄 때문에 fleet 전체가 서면, 운영자는 부팅을 위해 파일을 서둘러 옮기고, 월별 jsonl 이나 진행 커서를 옮기면 멀쩡한 행까지 안 읽히게 된다. 이 6개의 결함은 소비자에 있으니 소비자를 고친다.
- **"그럼 6개를 `Degrade_typed` 로 선언하면 된다."** 규칙 (a) 를 못 채운다. 선언만 바꾸는 건 규칙을 무시하는 일이다. 부팅이 읽지 않는다는 점은 `Preflight_only` 가 그대로 말한다.
- **"(c) 로 부팅을 막으면 파일 하나 때문에 fleet 전체가 선다."** 맞다. 그래서 (c) 는 Keeper 를 이미 멈추는 store 에만 쓴다. 이런 store 를 못 읽으면 부팅을 막지 않아도 그 Keeper 는 돌지 못한다. 막으면 달라지는 건 두 가지다. 운영자가 Keeper 가 돌기 전에 파일 목록을 한 번에 보고, 조용히 쌓이는 실패 로그가 없다. 오늘 같은 스키마 hard cut 은 모든 Keeper 의 파일을 한꺼번에 못 읽게 만드니, 이때는 막는 쪽이 복구가 빠를 것이다(재지 않은 추론이다).
- **"`--accept-store-quarantine` 하나가 값싼 격리와 비싼 격리를 같이 허락한다."** 맞다. 세션을 옮기면 vendor 대화 하나를 잃고, memory current 를 옮기면 그 Keeper 가 빈 기억으로 뜬다. 플래그는 RFC-0420 §4.3 대로 하나다. 대신 거절 문구가 store 와 경로를 줄마다 보여 주고, 운영자는 그걸 본 뒤에 플래그를 준다. store 별 플래그는 이 RFC 범위 밖이다.
- **"게이트 없이 운영자 복구가 못 읽는 세션을 치우게 하면 된다."** `masc_keeper_clear` 는 이미 못 읽는 `session.json` 을 잠금 아래에서 지운다(`keeper_official_client_session_store.ml:886-912`). 하지만 Keeper 의 대화 기록까지 지우고, 운영자가 Keeper 마다 실패를 본 뒤에야 부를 수 있다. 오늘은 40분 동안 16개 Keeper 가 실패한 뒤였다. `Restart_fresh` 가 못 읽는 파일을 받게 하는 것도 같은 문제가 있다. 부팅 거절은 첫 턴 전에 한 번에 보여 준다.
- **"부팅이 hard cut 을 알아서 실행하면 검사도 필요 없다."** 2026-09-05 에 부팅이 memory snapshot 15개를 알아서 옮겼고, Keeper 들은 빈 기억으로 떴다 (RFC-0420). 옮기는 결정은 운영자가 한다.
- **헌법.**
  - `gates`: `<default>` 는 하드 게이팅을 기본으로 두지 않는다. 이 RFC 는 새 게이트를 만들지 않고, RFC-0420 의 부팅 거절이 보는 store 를 넓힌다. `<allow>` 는 실익이 크고 연속성이 좋아질 때 허락한다. 넓히는 기준 (c) 가 `failure_conditions` 첫 줄 "Keeper 가 턴을 못 돈다" 그 자체다. `<order>` 는 success_bar 뒤에 하나씩 더하라고 한다. 그래서 PR-2 는 store 하나만 올린다. (c) 로 부팅 거절을 넓히는 결정은 2026-09-26 운영자가 내렸다.
  - `projects.md` 는 "없을 때 durable truth 가 손상되는 경우에만 Gate 를 더한다" 고 한다. official-client session 은 (b) 가 예라서 durable truth 는 손상되지 않는다. 이 RFC 의 근거는 가용성(c)이고, 그래서 운영자 결정으로 적는다.
  - `hardcoded_path`: 경로는 기존 path 함수. `string_matching`: 분기는 전부 variant. `budget_gate`: 횟수·시간 조건 없음. `legacy_residue`: 목록 두 개를 지우고 하나를 둔다. RFC-0444 §2.4 의 규칙 문장도 이 RFC 를 가리키게 고친다.

## 6. 근거

- 첫 분류: 2026-09-24, origin/main `eba5fb56ad`, preflight store 16개 + memory-journal. 에이전트 세 명이 store 를 나눠 소비자와 writer 를 전수로 읽었다.
- (c) 조사: 2026-09-26, origin/main `dae899d581`. 17개 store 의 턴 경로 reader 를 읽었다(빌드·실행 없이). 멈춤은 keeper meta 와 official-client session 이다. 같은 날 적대적 리뷰가 목록 밖의 체크포인트·event queue 를 더 찾았고, World constitution 은 조사 중에 나왔다. 셋 다 코드로 다시 확인했고, World constitution 은 파일을 읽지 못할 때만 턴이 멈춘다는 것을 PR-3 준비 중에 확인했다. 턴 경로 전체를 다 봤다고 보장하지는 않는다.
- 2026-09-26 사고: #32504 댓글. 첫 실패 14:11:34 KST(05:11:34Z), 복구 14:51:46 KST(05:51:46Z). 파일 24개를 `backups-hardcut-20260926T055146Z-official-client-session-v1/` 로 옮긴 뒤 binding 실패 0건.
- 부팅 비용: 2026-09-26 14:54 KST, 설치된 `masc-deployment-preflight-helper validate-stores --base-path=/Users/dancer/me`. real 60.06s, user 55.81s. 크기는 `du` 로 쟀다: `keepers/*/provider-inputs` 3,488,888KB(249 파일), `turn-records` 57,260KB, `keepers/*.json` 156KB(24 파일), `memory-current.json` 합계 3.5MB, `official-client-runtime` 24KB(24 파일). 설치된 helper 는 09-07 빌드라 거절 수(23,767)는 의미가 없고(#39224), 시간만 하한으로 본다.
- preflight 목록: `bin/deployment_preflight_helper.ml` `durable_stores` (16개). 부팅 목록: `lib/keeper/keeper_store_boot_reconcile.ml` GADT (3개).
