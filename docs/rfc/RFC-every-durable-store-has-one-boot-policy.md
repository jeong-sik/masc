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

그리고 분류하다가 실제 데이터 손실 하나를 찾았다. board 글 파일에 깨진 줄이 있으면 다음 flush 가 그 줄과 뒤의 모든 글을 지웠다(#38595, #38612 에서 수정).

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

`lib/keeper/keeper_durable_store.ml` 에 모든 store 를 닫힌 variant 로 둔다. 부팅 reconcile 과 배포 preflight 는 이 목록을 읽기만 하고, 자기 목록을 따로 갖지 않는다.

```ocaml
type id =
  | Keeper_meta | Memory_current | Goal_store | Memory_source_current
  | Board_posts | Board_comments | Turn_records | Turn_boundaries
  | Librarian_progress | Librarian_official_progress | Turn_fragments
  | Memory_journal | Librarian_range_receipts | Disposition_receipts
  | Provider_input | Official_client_session | Memory_absorbed
  | Memory_os_events | Gate_pending
[@@deriving enumerate]
```

`all` 은 `[@@deriving enumerate]` 가 만든다. 손으로 쓴 목록이 없으므로 "preflight 에는 넣고 부팅에는 빠뜨리는" 일이 생기지 않는다. 새 생성자를 넣으면 아래 세 함수의 exhaustive match 가 컴파일을 막는다.

### 2.2 store 마다 세 가지를 한 곳에서 정한다

```ocaml
val boot_policy : id -> [ `Refuse_boot | `Degrade_typed ]
val quarantine  : id -> quarantine
val examine     : id -> base_path:string -> finding list
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

- **1단계 (목록 통합):** `examine` 은 19개를 모두 본다. `boot_policy` 는 지금 부팅 동작을 그대로 옮긴다(keeper meta, memory current 만 `Refuse_boot`). 나머지 `Refuse_boot` 판정 store 8개는 부팅을 막지 않고 **store 마다 WARN 한 줄과 health 행**으로 보고한다. preflight 는 지금처럼 16개를 거부하고, 목록이 하나가 되면서 board comments 와 memory-journal 도 거부 대상에 들어간다.
- **2단계 (소비자 수정):** 1장 마지막 열의 소비자를 typed 로 고친다. 고친 store 는 규칙상 `Degrade_typed` 가 되고 WARN 도 사라진다. 끝까지 typed 로 못 만드는 store 만 `Refuse_boot` 로 올린다. 그때의 부팅 거부는 1단계의 WARN 으로 이미 한 번 이상 보인 파일에만 걸린다.

1단계의 "막지 않고 보고"는 게이트를 미루는 것이 아니다. 지금 부팅은 이 8개를 아예 보지 않는다. 1단계는 보지 않던 것을 보게 만들고, 2단계가 그 보고를 없앤다.

### 2.4 배포 preflight 와 부팅이 같은 판정을 쓴다

preflight 의 `scan` 과 `on_refusal` 문구는 `Keeper_durable_store` 로 옮긴다. preflight 는 모든 store 를 거부 대상으로 보는 지금 정책을 유지한다(배포는 운영자가 지켜보는 자리라 멈춰도 된다). 판정 함수는 하나라서, 두 곳의 판정이 어긋날 수 없다. 지금 어긋난 설명 문구 두 개(#38598)는 옮기면서 고친다.

## 3. 판정 기준

1. `rg -n 'durable_stores =' bin/deployment_preflight_helper.ml` 0줄. preflight 는 `Keeper_durable_store.all` 을 쓴다.
2. `Keeper_durable_store.all` 의 길이가 `id` 생성자 수와 같다는 테스트. 새 생성자를 넣으면 `boot_policy`·`quarantine`·`examine` 셋 다 컴파일이 실패한다.
3. store 마다 깨진 fixture 로 부팅하는 테스트. `Refuse_boot` 는 거부, 1단계의 보고 대상은 WARN 한 줄과 health 행, `Degrade_typed` 는 INFO 한 줄. 두 번 부팅해도 파일 digest 가 같다.
4. `Operator_repairs` store 는 `--accept-store-quarantine` 을 줘도 파일 digest 가 바뀌지 않는다는 테스트.
5. 같은 fixture 에서 preflight 와 부팅이 같은 store 를 "못 읽음"으로 판정한다는 테스트.
6. 2단계 PR 은 1장 마지막 열의 해당 소비자를 고치고, 그 store 의 판정이 바뀌는 것을 3번 테스트로 보인다.

## 4. 단계

- **PR-1 목록**: `Keeper_durable_store` 에 `id`, `all`, `examine`, `quarantine`. preflight 가 이 목록을 쓴다. 판정 1·2·5.
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
- board 손실: #38595, `lib/board/board_votes.ml` `flush_dirty` 가 `posts_load_result` 를 보지 않고 스냅샷을 썼다.
