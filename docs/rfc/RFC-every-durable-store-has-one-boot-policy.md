---
title: "모든 영속 store 가 부팅 정책을 한 목록에서 받는다"
status: Draft
created: 2026-09-24
updated: 2026-09-26
author: claude-main
---

# RFC: 모든 영속 store 가 부팅 정책을 한 목록에서 받는다

- 관련: #32504 (부팅 때 한 자리에서 reconcile), #32463, #32461, RFC-0420, RFC-0444, #38595 · #38612, #38986, #39224
- 범위: 부팅 reconcile(`Keeper_store_boot_reconcile`)과 배포 preflight(`bin/deployment_preflight_helper.ml`)가 검사하는 store 목록과 각 store 의 부팅 정책. 각 store 의 스키마는 바꾸지 않는다.

## 무슨 일이 있었나 (사람이 읽는 서두)

같은 파일을 두 곳이 서로 다른 목록으로 검사한다.

- **배포 preflight** 는 store 16개를 검사하고, 하나라도 못 읽으면 배포를 멈춘다.
- **부팅 reconcile** 은 2개(keeper meta, memory current)만 거부 대상으로 보고, goal store 는 INFO 한 줄로 알린다.

그래서 셸에서 `masc start` 로 띄우면, preflight 라면 멈췄을 파일 14개를 아무도 보지 않고 부팅이 끝난다. 그 파일들은 몇 시간 뒤 어느 Keeper 의 어느 읽기에서 따로따로 터진다.

2026-09-26 에 실제로 그렇게 터졌다.

- #38986 이 official-client session(`keepers/<name>/official-client-runtime/session.json`)의 스키마를 v1 에서 v2 로 올렸다. PR 본문에 "Fresh state required" 라고 적혀 있었다.
- 새 바이너리는 10:53 KST 에 설치만 되고, 서버는 옛 바이너리로 14:09 까지 v1 파일을 계속 썼다.
- 14:09:38 에 `deploy.sh` 를 거치지 않은 `masc start` 로 새 바이너리가 떴다. 부팅은 이 store 를 보지 않았다.
- Claude Code·Codex·Antigravity Keeper 16개가 40분 동안 턴마다 실패했다(185줄). 운영자 복구 API(`Restart_fresh`)도 먼저 이 파일을 읽어야 해서 쓸 수 없었다.
- 24개 파일을 손으로 옮기고 나서야 돌았다 (#32504 댓글).

이 RFC 의 첫 분류(09-24)는 이 store 를 부팅이 막지 않는 쪽(`Degrade_typed`)에 두었다. 규칙이 "실패를 typed 로 드러내는가"와 "못 읽는 파일 위에 쓰는가"만 물었기 때문이다. 이 store 는 둘 다 통과한다. 하지만 못 읽는 동안 Keeper 가 턴을 아예 돌지 못한다. 그래서 규칙에 (c)를 더했다.

## 1. 분류

store 마다 세 가지를 묻는다.

- **(a)** 읽기 실패를 모든 소비자가 typed 로 보여 주는가 (RFC-0444 §2.4)
- **(b)** 모든 쓰기가 못 읽는 파일 위에 쓰지 않는가 (RFC-0444 §2.4)
- **(c)** 못 읽는 동안 그 Keeper 가 턴을 도는가

정책은 이렇게 정한다.

- (b) 나 (c) 가 **아니오** 면 `Refuse_boot` 다. 부팅이 모든 파일을 읽고, 하나라도 못 읽으면 뜨지 않는다. 쓰는 쪽이 잃은 것을 덮어쓰거나 Keeper 가 멈추는 일은, Keeper 루프가 돌기 전에 한 번 막는 편이 낫다.
- goal store 는 `Degrade_typed` 다. RFC-0444 가 부팅마다 INFO 한 줄을 요구해서, 부팅이 한 번 읽고 알린다.
- 나머지는 `Preflight_only` 다. 부팅은 읽지 않는다. 배포 preflight 만 미리 읽는다.
- (a) 가 **아니오** 인 store 는 정책과 따로, 소비자를 고칠 결함이다. 소비자가 실패를 빈 값으로 바꾸면 Keeper 는 틀린 전제로 돈다. store 마다 PR 하나로 고친다.

| store | (a) | (b) | (c) 턴 | 부팅 정책 | (a) 를 깨는 곳 |
|---|---|---|---|---|---|
| keeper meta | — | 아니오 | 멈춤 | Refuse_boot (0420) | — |
| memory current | — | 아니오 | 돎 (recall 빠짐) | Refuse_boot (0420) | — |
| official-client session | 예 | 예 | **멈춤** | **Refuse_boot** | — |
| goal store | 예 | 예 | 돎 | Degrade_typed (0444) | — |
| memory-source current | 아니오 | 예 | 돎 | Preflight_only | `keeper_tool_memory_runtime.ml:830-835`, `keeper_memory_os_recall.ml:72-80` |
| board posts | 아니오 | 예 (#38612) | 돎 | Preflight_only | 대부분의 board 읽기가 부분 상태를 완전한 것처럼 씀 |
| turn records | 아니오 | 예 (append) | 돎 | Preflight_only | `keeper_autonomous_turn_source.ml:460-481`, `keeper_next_request_forecast.ml:351-361` |
| turn boundaries | 아니오 | 예 (append) | 돎 (맥락이 줄어듦) | Preflight_only | `keeper_checkpoint_purge.ml:269-274` |
| Librarian progress | 아니오 | 예 | 돎 (Librarian 멈춤) | Preflight_only | `keeper_librarian_continuity.ml:99-104`, `server_dashboard_http_keeper_memory_health.ml:201`, `keeper_turn_driver_try_provider.ml:268-276` |
| turn fragments | 아니오 | 예 (append) | 돎 (Librarian 멈춤) | Preflight_only | `keeper_status_detail.ml:522`, `dashboard_http_keeper_metrics.ml:112` |
| Librarian range receipts | 예 | 예 | 돎 (Memory 쓰기 도구 실패) | Preflight_only | — |
| disposition receipts | 예 | 예 | 돎 (턴 경로에 없음) | Preflight_only | — |
| provider-input | 거의 | 예 (append) | 돎 | Preflight_only | — |
| official Librarian progress | 예 | 예 | 돎 (턴 경로에 없음) | Preflight_only | — |
| absorbed facts | 예 | 예 (append) | 돎 | Preflight_only | — |
| memory OS events | 예 | 예 (append) | 돎 | Preflight_only | — |
| gate pending | 예 | 예 | 돎 (Gate 가 필요한 도구만 실패) | Preflight_only | — |

(c) 칸의 근거는 2026-09-26 조사다(6장). 턴이 멈추는 곳:

- keeper meta: `keeper_heartbeat_loop.ml:858-868` 이 dispatch 전에 meta 를 다시 읽고, `keeper_unified_turn_execution.ml:50-56` 이 provider 호출 전에 턴을 거절한다.
- official-client session: `keeper_claude_code_runtime.ml:669-674`, `keeper_codex_runtime.ml:770-774`, `keeper_antigravity_runtime.ml:468-472` 가 runtime 을 만들지 못하고 `Internal` 오류로 턴을 끝낸다.

아직 목록에 없는 store 도 있다. 4장 PR-3 에서 다룬다.

- **World constitution store**: `keeper_unified_prompt.ml:1359-1366` 에서 읽기 실패가 dispatch 전에 턴을 거절한다. (c) 가 아니오라서 `Refuse_boot` 후보다. 경로와 소비자를 다시 확인한 뒤 넣는다.
- **board comments**, **memory-journal**: preflight 도 읽지 않는다. 읽는 함수부터 만들어야 한다 (#38595, #38596).

## 2. 설계

### 2.1 store 목록은 lib 한 곳에 있다

`lib/keeper/keeper_durable_store.ml` 에 모든 store 를 둔다. 부팅 reconcile 과 배포 preflight 는 이 목록을 읽기만 하고, 자기 목록을 따로 갖지 않는다.

정책은 GADT 의 타입 인덱스로 들고 있다. store 를 다른 정책으로 옮기면 그 store 를 다루는 examiner 를 고칠 때까지 컴파일이 실패한다. `[@@deriving enumerate]` 는 GADT 에 붙지 않으므로 목록용 평평한 `Id.t` 를 따로 두고, 두 방향 exhaustive match 로 둘을 묶는다.

```ocaml
type refuse_boot = [ `Refuse_boot ]
type degrade_typed = [ `Degrade_typed ]
type preflight_only = [ `Preflight_only ]

type _ t =
  | Keeper_meta : refuse_boot t
  | Memory_current : refuse_boot t
  | Goal_store : degrade_typed t
  | Official_client_session : preflight_only t   (* PR-2 에서 refuse_boot *)
  (* ... 17개 전부 *)

module Id : sig
  type t = Keeper_meta | Memory_current | Goal_store | (* ... *)
  val all : t list   (* [@@deriving enumerate] *)
end

type any = Any : _ t -> any
val id : _ t -> Id.t          (* exhaustive *)
val of_id : Id.t -> any       (* exhaustive *)
val all : any list            (* List.map of_id Id.all *)
val policy : 'a t -> 'a boot_policy
val name : _ t -> string
val on_refusal : _ t -> string
val scan : _ t -> base_path:string -> (report, string) result
```

손으로 쓴 목록이 없으므로 "preflight 에는 넣고 부팅에는 빠뜨리는" 일이 생기지 않는다. `Id.t` 에 생성자를 더하면 `of_id` 가, `t` 에 더하면 `id`·`policy`·`name`·`scan` 이 컴파일을 막는다.

### 2.2 부팅은 `Refuse_boot` 만 읽는다

부팅 reconcile 은 `all` 을 돌며 정책으로 나눈다.

- `Refuse_boot`: 모든 파일을 읽는다. 못 읽는 파일이 있으면 부팅을 거절하고 경로와 이유를 찍는다. `--accept-store-quarantine` 을 주면 그 파일을 옆으로 옮기고 뜬다 (RFC-0420).
- `Degrade_typed`: 한 번 읽고, 못 읽으면 INFO 한 줄을 남긴다 (RFC-0444).
- `Preflight_only`: 읽지 않는다.

옮기는 방법은 `Refuse_boot` store 마다 exhaustive match 로 정한다. 옮길 방법이 없는 store 는 `Refuse_boot` 로 올릴 수 없다. 컴파일러가 옮기는 코드를 요구하기 때문이다.

- keeper meta: `<path>.rejected-<ts>` 로 이름을 바꾼다.
- memory current: `Keeper_memory_os_current.move_aside_for_keepers_dir`.
- official-client session (PR-2): 저장소 잠금(`official-client-runtime.lock`)을 잡고 `session.json` 을 `<path>.rejected-<ts>` 로 옮긴다. 파일이 없으면 다음 턴은 새 vendor 세션을 연다. 이 store 의 fresh state 가 그것이다 (#38986 "Fresh state required").

**부팅 비용.** 라이브 저장소에서 preflight 전체 스캔은 60초였고, 대부분 provider-input(3.4GB)이었다(6장). `Refuse_boot` 세 store 는 합쳐 몇 MB 다. 그래서 부팅은 `Refuse_boot` 만 동기로 읽고, `Preflight_only` 는 읽지 않는다. 부팅에서 `Preflight_only` 를 읽어 WARN 을 찍어도 그 store 의 Keeper 는 어차피 돌고, 고쳐지는 것은 없다. 재시작마다 60초를 쓸 이유가 없다.

### 2.3 배포 preflight 와 부팅이 같은 판정을 쓴다

preflight 의 `scan` 과 `on_refusal` 문구는 `Keeper_durable_store` 로 옮긴다. preflight 는 정책과 상관없이 모든 store 를 읽고, 하나라도 못 읽으면 배포를 멈춘다. 배포는 운영자가 지켜보는 자리라 멈춰도 된다.

- goal store 도 preflight 대상이 된다. 부팅에서는 INFO 뿐이지만, 배포는 이 build 가 못 읽는 `goals.json` 에서 멈춘다. `Goal_store.validate_state_json` 로 읽고, 경로는 부팅과 같은 cluster 규칙(`Workspace_utils.masc_root_dir_from`)으로 구한다.
- keeper meta 와 memory current 는 부팅과 preflight 가 파일을 찾는 길이 다르다(부팅은 `Workspace.config`, preflight 는 `base_path`). 같은 fixture 에서 둘이 같은 파일을 거절한다는 테스트로 묶는다.

## 3. 판정 기준

1. `rg -n 'durable_stores =' bin/deployment_preflight_helper.ml` 0줄. preflight 는 `Keeper_durable_store.all` 을 쓴다.
2. `Keeper_durable_store.all` 의 모든 store 가 `id` 로 `Id.all` 과 같은 순서의 같은 값을 돌려주고, 이름이 서로 다르다는 테스트.
3. 같은 fixture 에서 부팅이 지목한 `Refuse_boot` 파일을 preflight 도 거절한다는 테스트. goal store 는 부팅이 INFO 만 남기는 파일을 preflight 가 거절한다.
4. PR-2: v1 `session.json` 을 둔 base path 로 준비 단계를 돌리면 플래그 없이는 거절하고, 표준 오류에 그 경로와 거절 이유가 있다. 파일 digest 는 그대로다. `--accept-store-quarantine` 을 주면 파일이 옮겨지고, 그 Keeper 의 다음 claim 은 새 세션으로 시작한다.
5. 소비자 수정 PR 은 1장 마지막 열의 해당 소비자를 고치고, 읽기 실패가 typed 로 보이는 것을 테스트로 보인다.

## 4. 단계

- **PR-1 목록**: `Keeper_durable_store`(`id`, `all`, `t`, `policy`, `name`, `on_refusal`, `scan`)와 `Keeper_durable_store_scan`(store 별 읽는 법, preflight 에서 옮김). preflight 와 부팅 reconcile 이 이 목록을 쓴다. 부팅 동작은 바뀌지 않는다. preflight 는 goal store 를 새로 읽는다. 판정 1·2·3.
- **PR-2 세션**: official-client session 을 `Refuse_boot` 로 올리고, 잠금을 잡고 옮기는 방법을 더한다. 판정 4.
- **PR-3 목록에 없는 store**: World constitution store(`Refuse_boot` 후보), board comments, memory-journal(#38596). 읽는 함수가 먼저 있어야 한다.
- **PR-4~ 소비자**: 1장 마지막 열의 소비자를 store 별로 고친다. 판정 5.
- 별도 결함: #38597(memory events), #38598(preflight 문구), #39224(설치된 preflight helper 가 서버보다 오래됨).

## 5. 반론과 답

- **"RFC-0444 규칙대로 (a) 를 못 채운 8개를 `Refuse_boot` 로 올리면 된다."** 8개 모두 못 읽는 동안에도 Keeper 는 돈다. 한 Keeper 의 turn record 한 줄 때문에 fleet 전체가 서면, 운영자는 부팅을 위해 파일을 서둘러 옮기고, 월별 jsonl 이나 진행 커서를 옮기면 데이터를 잃는다. 이 8개의 결함은 소비자에 있으니 소비자를 고친다.
- **"그럼 8개를 `Degrade_typed` 로 선언하면 된다."** 규칙 (a) 를 못 채운다. 선언만 바꾸는 건 규칙을 무시하는 일이다. 부팅이 읽지 않는다는 점은 `Preflight_only` 가 그대로 말한다.
- **"(c) 는 Keeper 하나의 사정인데 fleet 전체를 세운다."** 오늘처럼 스키마 hard cut 은 모든 Keeper 의 파일을 한꺼번에 못 읽게 만든다. 그때 부팅이 서지 않으면 운영자는 Keeper 가 돌기 전에 한 번 결정한다. 서지 않는 게 싫으면 `--accept-store-quarantine` 한 번으로 fresh state 로 뜬다. 부팅이 서지 않는 쪽이, 16개 Keeper 가 40분 동안 조용히 실패하는 쪽보다 복구가 빠르다.
- **"부팅이 hard cut 을 알아서 실행하면 검사도 필요 없다."** 2026-09-05 에 부팅이 memory snapshot 15개를 알아서 옮겼고, Keeper 들은 빈 기억으로 떴다 (RFC-0420). 옮기는 결정은 운영자가 한다.
- **헌법.** `hardcoded_path`: 경로는 기존 path 함수. `string_matching`: 분기는 전부 variant. `budget_gate`: 횟수·시간 조건 없음. `legacy_residue`: 목록 두 개를 지우고 하나를 둔다. `gates`: 부팅 거부는 Keeper 가 턴을 못 돌거나 잃은 것을 덮어쓰는 store 에만 건다.

## 6. 근거

- 첫 분류: 2026-09-24, origin/main `eba5fb56ad`, preflight store 16개 + memory-journal. 에이전트 세 명이 store 를 나눠 소비자와 writer 를 전수로 읽었다.
- (c) 조사: 2026-09-26, origin/main `dae899d581`. 17개 store 의 턴 경로 reader 를 전수로 읽었다(빌드·실행 없이). 멈춤은 keeper meta 와 official-client session 둘이다.
- 2026-09-26 사고: #32504 댓글. 첫 실패 05:11:34Z, 복구 05:51:46Z. 파일 24개를 `backups-hardcut-20260926T055146Z-official-client-session-v1/` 로 옮긴 뒤 binding 실패 0건.
- 부팅 비용: 2026-09-26 05:54Z, 설치된 `masc-deployment-preflight-helper validate-stores --base-path=/Users/dancer/me`. real 60.06s, user 55.81s. `keepers/*/provider-inputs` 3,488,888KB(249 파일), `turn-records` 57,260KB, `official-client-runtime` 24KB(24 파일), `memory-current.json` 합계 3.5MB. 설치된 helper 는 09-07 빌드라 거절 수(23,767)는 의미가 없고(#39224), 시간만 하한으로 본다.
- preflight 목록: `bin/deployment_preflight_helper.ml` `durable_stores` (16개). 부팅 목록: `lib/keeper/keeper_store_boot_reconcile.ml` GADT (3개).
