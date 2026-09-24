---
title: "모든 영속 store 가 부팅 정책과 격리 방법을 한 표에서 받는다"
status: Draft
created: 2026-09-24
author: claude-main
---

# RFC: 모든 영속 store 가 부팅 정책과 격리 방법을 한 표에서 받는다

- 관련: #32504 (부팅 때 한 자리에서 reconcile), #32463, #32461, RFC-0420, RFC-0444, #38595 · #38612
- 범위: 부팅 reconcile(`Keeper_store_boot_reconcile`)과 배포 preflight(`bin/deployment_preflight_helper.ml`)가 검사하는 store 목록, 그 정책, 깨진 파일을 다루는 방법. 각 store 의 스키마는 바꾸지 않는다.

## 무슨 일이 있었나 (사람이 읽는 서두)

같은 파일을 두 곳이 서로 다른 목록으로 검사한다.

- **배포 preflight** 는 store 16개를 검사하고, 하나라도 못 읽으면 배포를 멈춘다.
- **부팅 reconcile** 은 2개(keeper meta, memory current)만 거부 대상으로 보고, goal store 는 INFO 한 줄로 알린다.
- **memory-journal** 은 어느 쪽도 검사하지 않는다.

그래서 셸에서 `masc start` 로 띄우면, preflight 라면 멈췄을 파일 14개를 아무도 보지 않고 부팅이 끝난다. 그 파일들은 몇 시간 뒤 어느 Keeper 의 어느 읽기에서 따로따로 터진다. #32504 가 말한 "하드컷이 store 마다 따로 터진다"가 지금도 절반쯤 그대로다.

목록을 하나로 합치려고 RFC-0444 §2.4 규칙으로 16개를 모두 분류했다(2026-09-24, origin/main `eba5fb56ad`). 두 가지가 드러났다.

1. **규칙대로면 8개가 `Refuse_boot` 다.** 그런데 이유가 거의 다 "소비자 한두 곳이 읽기 실패를 빈 값으로 바꾼다"이다. 이대로 부팅 거부를 넓히면 Keeper 한 명의 turn record 한 줄 때문에 서버 전체가 서지 않는다.
2. **"파일을 옆으로 옮긴다"는 격리가 절반 이상에서 데이터를 잃는다.** 월별 jsonl 을 통째로 옮기면 멀쩡한 행이 사라지고, 줄 번호를 세는 커서가 파일 끝을 넘고, 진행 파일을 옮기면 "아직 안 읽음"이 되어 같은 범위를 두 번 흡수한다.

그리고 분류하다가 실제 데이터 손실 하나를 찾았다. board 글 파일에 깨진 줄이 있으면 다음 flush 가 메모리에 없는 그 줄을 지웠다. 로더(`board_votes_json.ml:283-296` `load_source_rows`)는 못 읽은 줄만 건너뛰고 뒤의 좋은 줄은 메모리에 올리므로, 지워지는 건 못 읽은 줄뿐이다(#38595, #38612 에서 수정 중).

## 1. 분류 결과

RFC-0444 §2.4 규칙: **읽기 실패를 모든 소비자가 typed 로 보여 주고(a), 모든 쓰기가 못 읽는 파일 위에 쓰지 않는(b) store 만 `Degrade_typed` 다.**

| store | (a) | (b) | 영향 범위 | 파일째 옮기기 | 지금 규칙의 판정 | (a) 를 깨는 곳 |
|---|---|---|---|---|---|---|
| keeper meta | — | — | Keeper 하나 | 됨 | Refuse_boot (0420) | — |
| memory current | — | — | Keeper 하나 | 됨 | Refuse_boot (0420) | — |
| goal store | 예 | 예 | 기능 하나 | 네 파일 한꺼번에 | Degrade_typed (0444) | — |
| memory-source current | 아니오 | 예 | Keeper 하나 | 됨 | Refuse_boot | `keeper_tool_memory_runtime.ml:830-835`, `keeper_memory_os_recall.ml:72-80` |
| board posts | 아니오 | 아니오 → #38612 후 예 | 서버 전체 | 안 됨 | Refuse_boot | 대부분의 board 읽기가 부분 상태를 완전한 것처럼 씀 |
| board comments (preflight 도 안 봄) | 아니오 | 아니오 → #38612 후 예 | 서버 전체 | 안 됨 | Refuse_boot | board posts 와 같은 구조 |
| turn records | 아니오 | 예(append) | Keeper 하나 | 안 됨(월 파일) | Refuse_boot | `keeper_autonomous_turn_source.ml:460-481`, `keeper_next_request_forecast.ml:351-361` |
| turn boundaries | 아니오 | 예(append) | Keeper 하나 | 안 됨(줄 번호 커서) | Refuse_boot | `keeper_checkpoint_purge.ml:269-274` |
| Librarian progress | 아니오 | 예 | Keeper 하나 | 안 됨("안 읽음"이 됨) | Refuse_boot | `keeper_librarian_continuity.ml:99-104`, `server_dashboard_http_keeper_memory_health.ml:201`, `keeper_turn_driver_try_provider.ml:268-276` |
| turn fragments | 아니오 | 예(append) | Keeper 하나 | 안 됨(빈 흡수) | Refuse_boot | `keeper_status_detail.ml:522`, `dashboard_http_keeper_metrics.ml:112` |
| memory-journal | 아니오 | 예(append, 둘) | Keeper 하나 | 됨 | Refuse_boot | `server_dashboard_http_keeper_memory_health.ml:233`, `dated_jsonl.ml:681-686` 의 raise (#38596) |
| Librarian range receipts | 예 | 예 | Keeper 하나 | 위험(중복 흡수) | Degrade_typed | — |
| disposition receipts | 예 | 예 | Keeper 하나 | 위험(재실행 기록 손실) | Degrade_typed | — |
| provider-input | 거의(재사용 최적화만) | 예(append) | Keeper 하나 | 안 됨(월 파일) | Degrade_typed | — |
| official-client session | 예 | 예 | Keeper 하나 | 됨(lock 과 함께) | Degrade_typed | — |
| official Librarian progress | 예 | 예 | Keeper 하나 | 안 됨 | Degrade_typed | — |
| absorbed facts | 예 | 예(append) | Keeper 하나 | 됨 | Degrade_typed | — |
| memory OS events | 예 | 예(append) | Keeper 하나 | 됨 | Degrade_typed | — |
| gate pending | 예 | 예 | 워크스페이스 Gate | 세 파일 한꺼번에 | Degrade_typed | — |

각 칸의 근거(file:line)는 PR 본문의 조사 기록에 있다. 이 표는 그 요약이다.

## 2. 설계

### 2.1 store 목록은 lib 한 곳에 있다

`lib/keeper/keeper_durable_store.ml` 에 모든 store 를 둔다. 부팅 reconcile 과 배포 preflight 는 이 목록을 읽기만 하고, 자기 목록을 따로 갖지 않는다.

지금 `keeper_store_boot_reconcile.ml:7-22` 는 store 의 정책을 GADT 의 타입 인덱스로 들고 있다. 그래서 store 를 다른 정책으로 옮기면 examiner 를 고칠 때까지 컴파일이 실패한다. 2단계(2.3)가 바로 store 를 다른 정책으로 옮기는 일이라, 이 보장을 버리지 않는다. `[@@deriving enumerate]` 는 GADT 에 붙지 않으므로 목록용 평평한 `id` 를 따로 두고, 두 방향 exhaustive match 로 둘을 묶는다.

```ocaml
(* 목록용. all 은 deriving 이 만든다. *)
type id =
  | Keeper_meta | Memory_current | Goal_store | Memory_source_current
  | Board_posts | Board_comments | Turn_records | Turn_boundaries
  | Librarian_progress | Librarian_official_progress | Turn_fragments
  | Memory_journal | Librarian_range_receipts | Disposition_receipts
  | Provider_input | Official_client_session | Memory_absorbed
  | Memory_os_events | Gate_pending
[@@deriving enumerate]

(* 정책은 타입 인덱스에 있다. *)
type refuse_boot = [ `Refuse_boot ]
type untyped_consumers = [ `Untyped_consumers ]   (* 2.3 의 1단계 보고 대상 *)
type degrade_typed = [ `Degrade_typed ]

type _ store =
  | Keeper_meta : refuse_boot store
  | Memory_current : refuse_boot store
  | Goal_store : degrade_typed store
  | Turn_records : untyped_consumers store
  (* ... 19개 전부 *)

type any = Any : _ store -> any

val store_of_id : id -> any                        (* exhaustive *)
val id_of_store : 'a store -> id                   (* exhaustive *)
```

`all` 은 `[@@deriving enumerate]` 가 만든다. 손으로 쓴 목록이 없으므로 "preflight 에는 넣고 부팅에는 빠뜨리는" 일이 생기지 않는다. `id` 에 생성자를 더하면 `store_of_id` 가, `store` 에 더하면 `id_of_store` 가 컴파일을 막는다. store 의 인덱스를 바꾸면 아래 `policy` 와 `examine` 이 컴파일을 막는다.

### 2.2 store 마다 세 가지를 한 곳에서 정한다

```ocaml
val policy     : 'a store -> 'a boot_policy        (* 인덱스에서 나온다 *)
val quarantine : id -> quarantine
val examine    : 'a store -> base_path:string -> 'a finding list
```

`quarantine` 이 이 RFC 가 더하는 두 번째 축이다.

```ocaml
type quarantine =
  | Move_file                 (* 파일 하나를 <path>.rejected-<ts> 로 옮긴다 *)
  | Move_set of string list   (* 이름 붙은 파일 묶음을 함께 옮긴다 (goal store, gate pending) *)
  | Operator_repairs          (* 옮기면 데이터를 잃는다. 운영자가 파일을 고친다 *)
```

- `--accept-store-quarantine` 은 `Move_file` 과 `Move_set` 인 store 에만 닿는다. `Operator_repairs` store 는 플래그가 있어도 옮기지 않고, 부팅 거부 사유에 "이 파일은 고쳐야 한다"와 경로를 적는다.
- 1장 표의 "파일째 옮기기" 열이 이 값이다. 안 됨 → `Operator_repairs`, 됨 → `Move_file`, 묶음 → `Move_set`.

### 2.3 부팅 거부를 넓히는 순서

1장 표를 그대로 적용하면 부팅 거부 store 가 2개에서 10개로 는다. 셸에서 `masc start` 하던 운영자는 전에 뜨던 서버가 안 뜨는 것을 처음 보게 된다. 그래서 두 단계로 나눈다.

- **1단계 (목록 통합):** `examine` 은 19개를 모두 본다. `policy` 는 지금 부팅 동작을 그대로 옮긴다(keeper meta, memory current 만 `Refuse_boot`). 나머지 `Refuse_boot` 판정 store 8개는 `untyped_consumers` 인덱스를 받고, 부팅을 막지 않고 **store 마다 WARN 한 줄과 health 행**으로 보고한다. preflight 는 지금처럼 16개를 거부하고, 목록이 하나가 되면서 board comments 와 memory-journal 도 거부 대상에 들어간다.
- **2단계 (소비자 수정):** 1장 마지막 열의 소비자를 typed 로 고친다. 고친 store 는 인덱스를 `degrade_typed` 로 바꾸고 WARN 도 사라진다. 끝까지 typed 로 못 만드는 store 만 `refuse_boot` 로 올린다. 어느 쪽이든 인덱스를 바꾸는 순간 `examine` 이 컴파일에서 막히므로, examiner 를 같이 고치지 않고는 정책만 옮길 수 없다. 그때의 부팅 거부는 1단계의 WARN 으로 이미 한 번 이상 보인 파일에만 걸린다.

1단계의 "막지 않고 보고"는 게이트를 미루는 것이 아니다. 지금 부팅은 이 8개를 아예 보지 않는다. 1단계는 보지 않던 것을 보게 만들고, 2단계가 그 보고를 없앤다.

**부팅 비용.** preflight 는 배포 때 한 번이지만 부팅은 재시작마다다. 라이브 저장소에서 preflight store 스캔 한 번에 71초가 걸렸다(6장). 그래서 1단계가 19개 store 의 전체 이력을 부팅 경로 안에서 동기로 decode 하면 재시작이 1분 넘게 늦어진다. 이 비용을 어디서 치를지는 아직 정하지 않았다(7장 질문 1).

### 2.4 배포 preflight 와 부팅이 같은 판정을 쓴다

preflight 의 `scan` 과 `on_refusal` 문구는 `Keeper_durable_store` 로 옮긴다. preflight 는 모든 store 를 거부 대상으로 보는 지금 정책을 유지한다(배포는 운영자가 지켜보는 자리라 멈춰도 된다). 판정 함수는 하나라서, 두 곳의 판정이 어긋날 수 없다. 지금 어긋난 설명 문구 두 개(#38598)는 옮기면서 고친다.

## 3. 판정 기준

1. `rg -n 'durable_stores =' bin/deployment_preflight_helper.ml` 0줄. preflight 는 `Keeper_durable_store.all` 을 쓴다.
2. `Keeper_durable_store.all` 의 모든 `id` 가 `store_of_id` 를 거쳐 `id_of_store` 로 같은 `id` 로 돌아온다는 테스트. `id` 나 `store` 한쪽에만 생성자를 넣으면 두 방향 match 중 하나가, store 의 정책 인덱스를 바꾸면 `policy`·`examine` 이 컴파일에서 실패한다.
3. store 마다 깨진 fixture 로 부팅하는 테스트. `Refuse_boot` 는 거부, 1단계의 보고 대상은 WARN 한 줄과 health 행, `Degrade_typed` 는 INFO 한 줄. 두 번 부팅해도 파일 digest 가 같다.
4. `Operator_repairs` store 는 `--accept-store-quarantine` 을 줘도 파일 digest 가 바뀌지 않는다는 테스트.
5. 같은 fixture 에서 preflight 와 부팅이 같은 store 를 "못 읽음"으로 판정한다는 테스트.
6. 2단계 PR 은 1장 마지막 열의 해당 소비자를 고치고, 그 store 의 판정이 바뀌는 것을 3번 테스트로 보인다.

## 4. 단계

- **PR-1 목록**: `Keeper_durable_store` 에 `id`, `all`, `store`, `store_of_id`/`id_of_store`, `policy`, `examine`, `quarantine`. preflight 가 이 목록을 쓴다. 판정 1·2·5.
- **PR-2 부팅**: 부팅 reconcile 이 19개를 본다. 2.3 의 1단계 보고, `Operator_repairs` 는 플래그로도 옮기지 않음. 판정 3·4.
- **PR-3~ 소비자**: 1장 마지막 열의 소비자를 store 별로 고친다(store 하나에 PR 하나). 판정 6.
- 별도 결함: #38595(board 삭제, #38612), #38596(memory-journal), #38597(memory events), #38598(preflight 문구).

## 5. 반론과 답

- **"RFC-0444 규칙대로 8개를 바로 `Refuse_boot` 로 올리면 된다."** 8개 중 서버 전체에 영향을 주는 건 board 글·댓글 둘이다. 나머지는 Keeper 한 명의 기능 하나다. 한 Keeper 의 파일 한 줄 때문에 fleet 전체가 서면, 운영자는 부팅을 위해 파일을 서둘러 옮기고, 그 옮기기가 절반의 store 에서 데이터를 잃는다. 0444 가 goal store 를 `Refuse_boot` 로 두지 않은 이유와 같다.
- **"그럼 8개를 `Degrade_typed` 로 선언하면 된다."** 규칙 (a) 를 못 채운다. 소비자가 빈 값을 보고 판단하는 동안 Keeper 는 틀린 전제로 돈다. 선언만 바꾸는 건 규칙을 무시하는 일이다. 소비자를 고친 store 만 자격을 얻는다.
- **"1단계의 WARN 은 텔레메트리-as-fix 아닌가."** 1단계 자체는 고치는 단계가 아니다. 보지 않던 파일을 보게 하는 단계이고, 고치는 일은 2단계에 store 별 PR 로 이름이 붙어 있다. WARN 만 넣고 멈추면 워크어라운드 체크리스트 1번에 해당한다. 그래서 1단계 PR 은 2단계 이슈 번호를 store 마다 적는다.
- **"`Operator_repairs` 는 운영자에게 일을 떠넘긴다."** 옮기기가 데이터를 지우는 store 에서 자동 옮기기는 손실을 자동화하는 일이다. 바이트를 그 자리에 두고 경로를 알려 주는 편이 복구할 수 있는 상태를 남긴다(헌법 `failure_keeps_evidence`).
- **헌법.** `hardcoded_path`: 경로는 기존 path 함수. `string_matching`: 분기는 전부 variant. `budget_gate`: 횟수·시간 조건 없음. `legacy_residue`: 옛 목록 두 개를 지우고 하나를 둔다. `gates`: 부팅 거부를 넓히는 일은 2단계에서 store 별로, 증거와 함께 한다.

## 6. 근거

- 분류: 2026-09-24, origin/main `eba5fb56ad`, preflight store 16개 + memory-journal. board comments 는 #38595 조사에서 같은 구조로 확인했다. 에이전트 세 명이 store 를 나눠 소비자와 writer 를 전수로 읽었다.
- preflight 목록: `bin/deployment_preflight_helper.ml:1359-1377` (`durable_stores`, 16개).
- 부팅 목록: `lib/keeper/keeper_store_boot_reconcile.ml:7-22` (GADT 3개).
- board 손실: #38595, `lib/board/board_votes.ml` `flush_dirty` 가 `posts_load_result` 를 보지 않고 스냅샷을 썼다. 로더 `load_source_rows`(`lib/board/board_votes_json.ml:283-296`)는 못 읽은 줄만 건너뛴다.
- 부팅 비용: 2026-09-24 12:13Z, 설치된 `masc-deployment-preflight-helper validate-stores --base-path=~/me`(0.37.0, `.masc` 80G). real 71.14s, user 46.96s, sys 1.07s. 이 바이너리는 store 11개만 알고(main 은 16개), turn records 14,370행·provider-input 26,691행을 읽었다. 설치본의 decoder 가 라이브 데이터보다 오래돼 거부 수(14,720행)는 의미가 없고, 시간만 하한으로 본다. 이 RFC 의 19개를 다 읽으면 더 걸린다.

## 7. 소유자에게 묻는 질문

1. **부팅 비용을 어디서 치르나.** 71초(6장)는 부팅 경로에 그대로 넣을 수 없다. 후보는 셋이다.
   - (가) 부팅은 `refuse_boot` store 만 동기로 다 읽는다. 나머지는 서버가 뜬 뒤 백그라운드에서 `examine` 하고 WARN·health 행을 늦게 낸다. 지금 `refuse_boot` 인 keeper meta·memory current 는 19·22행이라 싸다. 다만 2단계에서 turn records 같은 큰 store 가 `refuse_boot` 로 올라가면 비용이 부팅으로 돌아온다.
   - (나) `examine` 이 파일마다 마지막으로 검사한 크기·mtime 을 기억하고 바뀐 파일만 다시 읽는다. 새 파생 상태가 하나 생기고, 그 기록이 틀리면 깨진 파일을 못 본다.
   - (다) 1단계 보고 대상과 `degrade_typed` store 는 부팅에서 보지 않고, 첫 읽기가 typed 로 드러내게 둔다. 1단계 보고 대상은 소비자가 아직 typed 가 아니라서, 2단계 전까지는 아무도 보지 않던 지금과 같다.
2. **1단계 보고 대상을 세 번째 인덱스(`untyped_consumers`)로 둘까.** 2.1 은 1단계 동작(부팅은 안 막고 WARN·health)을 타입으로 드러내려고 인덱스를 셋으로 했다. 인덱스를 둘로 두고 이 8개를 `refuse_boot` 인덱스 + 1단계 한정 예외로 둘 수도 있지만, 그러면 예외 목록이 손으로 쓴 두 번째 목록이 된다.
