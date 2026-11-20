---
rfc: "board-has-one-writer-and-one-log"
title: "Board 는 쓰는 자리 하나가 사건 로그 하나에 쓴다"
status: Draft
created: 2026-11-20
updated: 2026-11-20
author: claude
supersedes: []
superseded_by: null
related: ["a-persons-keeper-runs-on-the-engine"]
implementation_prs: []
---

# RFC: Board 는 쓰는 자리 하나가 사건 로그 하나에 쓴다 (board-has-one-writer-and-one-log)

- 이슈: #53661
- 사실의 근거: main `1c604689ccb8d` 에서 직접 읽은 코드다. 서버를 띄워 재지 않았다.
- 정하는 것: 저장 모양(§2), 옛 파일을 끊는 방식(§3), 층(§4). 사용자가 정할 것은 §5 에 넷 있다.

## 0. 요약

Board 는 이미 한 프로세스, 한 store, 잠금 하나로 쓴다.
그런데 파일이 여섯이고 파일마다 쓰는 길이 여럿이다.
글 하나를 지우면 결정 표지 파일을 먼저 쓰고, 파일 넷을 차례로 다시 쓴다.
투표 하나를 쓰려면 글 파일 전체를 다시 읽어 바이트를 견준다.

이 RFC 는 여섯 파일을 사건(event) 로그 한 파일로 바꾼다.

- 한 줄은 사건 하나다. 글 만듦, 댓글 붙임, 투표, 반응, 하위 게시판, 지움, 만료.
- 쓰는 자리는 하나다. 그 안에서 「정하기 → 붙이기 → 메모리에 반영」을 끝낸다.
- 지울 때 딸린 댓글·투표·반응을 치우는 일은 접기(fold) 함수 한 곳이 한다.
- 댓글 수·투표 수 같은 파생 값은 저장하지 않는다. 불러올 때 접어서 만든다.
- 옛 파일 여섯은 읽지 않는다. 옮기는 코드도 없다(§3).

## 1. 지금

### 1.1 쓰는 프로세스와 store 는 이미 하나다

이슈 본문의 「여러 writer 가 같은 파일을 고친다」는 프로세스 수준에서 맞지 않다.

| 사실 | 자리 |
|---|---|
| HTTP 서버는 base path lease 를 잡고, 이미 주인이 있으면 멈춘다 | `bin/main_eio.ml:265`, `bin/main_eio.ml:296` |
| stdio 서버도 같은 lease 를 잡는다 | `bin/main_stdio_eio.ml:54`, `bin/main_stdio_eio.ml:58` |
| 프로세스에 store 는 하나다. 처음 부른 쪽이 BasePath 를 정한다 | `lib/board/board_store_lifecycle.ml:73`, `lib/board/board_store_lifecycle.ml:77` |
| Keeper 컨테이너는 Board 파일을 읽기 전용으로 받는다 | `lib/keeper/keeper_sandbox_runtime_setup.ml:435`, `lib/keeper/keeper_sandbox_runtime_setup.ml:478` (`:ro`) |
| 프로세스 안의 파일 쓰기는 모두 `persist_mutex` 하나로 줄 선다 | `lib/board/board_core_persist.ml:270`, `lib/board/board_core_persist.ml:279` |

여럿인 것은 writer 가 아니다. 파일 수와 파일마다의 쓰는 길이다.

### 1.2 파일 여섯, 파일마다 쓰는 길

파일 이름은 `lib/board/board_paths.ml:23` 에서 정한다.

| 파일 | 쓰는 길 | 자리 |
|---|---|---|
| `board_posts.jsonl` | 새 글 append | `lib/board/board_core_persist.ml:1033`, `:1035` |
| | thread·고정·닫기 append | `lib/board/board_votes.ml:106`, `:209`, `:251` |
| | 글 고치기: 파일 전체 rewrite | `lib/board/board_core_persist.ml:1422` |
| | flush·삭제: 파일 전체 rewrite | `lib/board/board_deletion.ml:111` (`:405`, `:527` 에서 부름) |
| `board_comments.jsonl` | 댓글 append | `lib/board/board_comments.ml:225` |
| | 거절된 댓글을 지우는 rewrite | `lib/board/board_comments.ml:291` |
| | flush·삭제 rewrite | `lib/board/board_deletion.ml:112` |
| `board_votes.jsonl` | 투표 append, rewrite | `lib/board/board_voting.ml:81`, `:74` |
| `board_reactions.jsonl` | 반응 하나마다 파일 전체 rewrite | `lib/board/board_reactions.ml:320` |
| `board_sub_boards.jsonl` | 만들기 append, 고치기 rewrite | `lib/board/board_sub_boards.ml:100`, `:162` |
| `board_deletion.jsonl` | 삭제 결정 표지 기록·지움 | `lib/board/board_deletion.ml:469`, `:488`, `:397` |

글과 댓글 파일은 같은 id 의 뒤 행이 앞 행을 덮는다(`lib/board/board_votes_json.ml:29`).
그러니 지금도 반쯤은 로그다. 다만 줄이 사건이 아니라 엔티티 전체다.
그래서 고칠 때마다 파일 전체를 다시 쓴다.

### 1.3 파일끼리 맞춰야 하는 자리

- 투표·반응을 쓰기 전에 글 파일 전체를 다시 읽고, 기억한 바이트와 `String.equal` 로 견준다.
  댓글이 대상이면 댓글 파일도 같이 읽는다.
  (`lib/board/board_target_admission.ml:98`, `lib/fs_compat/fs_compat_private_jsonl_guard.ml:39`, `:44`)
- 그러려고 store 는 파일마다 전체 바이트를 메모리에 들고 있다.
  (`lib/board_types/board_types.mli:541`, `:658`, `:752`, `:817`, `:911`, `:992`)
- 글을 지우면 표지 파일에 결정을 먼저 쓰고, 글·댓글·투표·반응 파일을 차례로 rewrite 한다.
  중간에 실패하면 남은 파일은 `Pending` 으로 남고 다음 flush 가 이어 쓴다.
  (`lib/board/board_deletion.ml:469`, `lib/board/board_snapshot_batch.ml:34`, `:63`)
- flush 도 네 파일을 차례로 쓴다(`lib/board/board_snapshot_batch.ml:38`).
  하나만 쓰고 멈추면 파일끼리 어긋난다.
- 불러올 때 댓글 수와 투표 수를 다시 센다. 파일끼리 어긋난 것을 읽는 쪽이 견딘다.
  (`lib/board/board_store_load.ml:11`, `:30`)
- 만료 청소(sweep)는 메모리에서만 투표·반응을 지운다. 투표·반응 파일은 다음 rewrite 까지 그 행을 들고 있다.
  (`lib/board/board_core_persist.ml:357`)

### 1.4 쓰는 순서가 연산마다 다르다

| 연산 | 순서 | 자리 |
|---|---|---|
| 댓글 | 파일에 붙임 → 메모리에서 검사 → 거절이면 파일을 다시 써서 그 행을 지움 | `lib/board/board_comments.ml:225`~`:291` |
| 고정(pin) | 메모리를 먼저 바꿈 → 붙임 → 안 써졌으면 메모리를 되돌림 | `lib/board/board_votes.ml:87`~`:110` |
| 글 고치기 | 잠금 밖에서 계획 → 파일 전체 rewrite → 메모리 반영, 그 사이 글이 바뀌었으면 다시 계획 | `lib/board/board_core_persist.ml:1352`~`:1445` |

댓글 쪽 주석은 「재시작이 정리보다 먼저 오면 거절된 행이 다시 읽힌다(#26378)」고 적었다(`lib/board/board_comments.ml:290`).
순서가 셋이면 결과를 모르는 쓰기를 정리하는 규칙도 셋이 된다.
지금은 파일마다 상태 타입이 따로 있다. 여섯 타입의 갈래를 모두 더하면 31개다.
`lib/board/board_store_lifecycle.ml:13`~`:34` 이 그 31개를 전부 나열한다.

### 1.5 2026-10-21 이후 `fix` 22건은 어디서 왔나

`git log origin/main --since=2026-10-21 -- lib/board/board_core_persist.ml` 에서 제목이 `fix` 로 시작하는 커밋 22건이다.
11-10~11-11 이틀에 든 것은 9건이다(commit date 기준).

| 갈래 | PR | 수 | 이 RFC 로 |
|---|---|---|---|
| 파일마다 「읽은 바이트에만 쓴다」 울타리 | #47224 #50794 #50840 #50918 #50998 | 5 | 사라진다 |
| 결과를 모르는 쓰기의 정산·영수증 | #47672 #47145 #51178 | 3 | 규칙 하나로 준다(§2.5) |
| 파일 사이 순서(정책↔글, 하위 게시판 삭제↔댓글, 삭제 결정↔연쇄) | #47178 #51156 #51146 #51116 #50864 | 5 | 사라진다 |
| 어느 workspace 디렉터리에 쓰나 | #47192 #47388 #47268 #48004 #51878 | 5 | 그대로 남는다. 맞출 파일만 하나로 준다 |
| 잠금 안에서 부른 관측자의 교착 | #51915 | 1 | 남는다 |
| Board 저장과 무관 | #44697(수신자 규칙) #47163(fusion producer) #53573(runtime) | 3 | 무관 |

13건이 「파일 여섯 × 쓰는 길 여럿 × 파일마다 상태 기계」에서 나왔다.
울타리 5건이 막는 상대는 「다른 store」다(`CHANGELOG.md:5899`, `:5919`).
그 상대는 §1.1 의 lease 와 store 하나가 이미 막는다.

### 1.6 프로세스 밖에서 읽는 쪽

| 읽는 쪽 | 읽는 파일 | 자리 |
|---|---|---|
| 배포 전 점검(preflight) | `board_posts.jsonl` | `lib/keeper/keeper_durable_store.ml:348`, `:1187` |
| SLO 추출 스크립트 | 글·댓글 | `scripts/board-slo-extractor.sh:54` |
| fleet 준비 점검 스크립트 | 글 | `scripts/audit-keeper-fleet-readiness.py:606` |
| Keeper 컨테이너 | 글·댓글·투표·반응(읽기 전용) | `lib/keeper/keeper_sandbox_runtime_setup.ml:435` |

컨테이너 안에서 이 파일을 실제로 여는 쪽은 아직 찾지 못했다(§5 결정 4).

## 2. 목표 모양

### 2.1 파일 하나

`<base-path>/.masc/board_events.jsonl` 한 파일이다. 한 줄이 사건 하나다.
줄의 순서가 일어난 순서다. 순번 칸은 두지 않는다.

```json
{"at":1763600000.0,"event":"post_created","post":{...}}
{"at":1763600010.0,"event":"comment_added","comment":{...}}
{"at":1763600020.0,"event":"post_deleted","post_id":"p-...","by":"operator"}
```

### 2.2 사건

닫힌 합타입 하나다. `event` 칸의 글자는 이 타입의 wire 이름이다.
모르는 이름은 읽을 때 거절한다. `_ ->` 갈래는 두지 않는다.

| 사건 | 지금의 연산 | 담는 것 |
|---|---|---|
| `Post_created` | `create_post*`, `create_post_once_by_fusion_run_id` | 글 기록 전체 |
| `Post_edited` | `update_post_with_outcome` | 작성자, 제목, 본문, meta, audience, 내용 시각 |
| `Post_marked` | `set_thread_id`, `set_pinned`, `set_closed` | 글 id 와 바뀐 표지 하나 |
| `Comment_added` | `add_comment*` | 댓글 기록 전체 |
| `Vote_cast` | `vote`, `vote_comment` | 투표 key(대상·투표자), 방향 |
| `Reaction_set` | `toggle_reaction` | 반응 key, 켬·끔 |
| `Sub_board_created` · `Sub_board_updated` · `Sub_board_deleted` | 하위 게시판 셋 | 하위 게시판 기록, 지운 권한 |
| `Post_deleted` | `delete_post` | 글 id, 지운 권한 |
| `Expired` | `sweep` | 만료된 글·댓글 id |

`Post_marked` 의 칸과 `set_closed` 가 담는 값(`closed_by`, `successor`, `summary`)은 L1 에서 `lib/board/board_votes.ml:158` 을 읽고 정한다.

### 2.3 쓰기: 정하기 → 붙이기 → 반영, 한 자리 안에서

쓰는 자리는 지금의 `persist_mutex` 하나다. 이름을 writer 잠금으로 바꾼다.
이 잠금 안에서 셋을 끝낸다.

1. 정하기: 메모리 모델만 읽고 사건 하나를 만들거나 거절한다(`model -> (event, board_error) result`).
2. 붙이기: 사건 한 줄을 붙인다. `Fs_compat.append_private_jsonl_durable_locked_at_cursor_result` 를 쓴다(`lib/fs_compat/fs_compat.mli:2048`).
   writer 가 기억한 cursor(파일 identity 와 끝 offset)만 넘긴다. 앞 바이트를 다시 읽지 않는다.
3. 반영: 2가 성공하면 그 사건을 접기 함수로 메모리에 반영한다. 불러올 때와 같은 함수다.

모델을 바꾸는 쪽이 writer 하나뿐이다. 그래서 정한 뒤 반영하기 전에 모델이 바뀌지 않는다.
다시 검사하기, 거절된 행 지우기, 메모리 되돌리기가 모두 없어진다.
fusion 중복 생성을 막던 `origin_create_mutex`(`lib/board/board_core_persist.ml:1194`)도 정하기 안의 `posts_by_run_id` 조회로 바뀐다.

수신자 lookup 처럼 Keeper 쪽에 묻는 일은 writer 밖에서 먼저 한다.
writer 안에서는 그 답을 만든 글이 그대로인지만 본다.
글 고치기의 「다시 계획」(`same_plan_inputs`, `lib/board/board_core_persist.ml:1338`)은 이 자리에 남는다.

읽기는 지금처럼 상태 잠금(`store.mutex`) 아래 메모리 모델을 읽는다.
읽는 쪽 모델과 색인(hot·recent·updated)은 이 RFC 에서 바꾸지 않는다.

### 2.4 불러오기: 접기

서버가 뜰 때 `Fs_compat.recover_private_jsonl_durable_locked_result` 로 읽는다(`lib/fs_compat/fs_compat.mli:1905`).
이 함수는 쓰다 멈춘 마지막 줄을 잘라 내고 fsync 한다.
그다음 줄마다 사건을 풀어 빈 모델에 차례로 접는다.

- `Post_deleted` 와 `Expired` 는 딸린 댓글·투표·반응을 같이 치운다. 치우는 코드는 접기 함수 한 곳에만 있다.
- `Sub_board_deleted` 는 그 하위 게시판에 있던 글의 hearth 를 푼다.
- `reply_count`, `votes_up`, `votes_down`, `updated_at` 은 저장하지 않는다. 접으면서 센다.
  지금 불러올 때 다시 세는 두 함수(`lib/board/board_store_load.ml:11`, `:30`)가 접기 안으로 들어간다.

### 2.5 결과를 모르는 쓰기

붙이기가 「썼는지 모름」으로 끝나면 writer 는 닫힌다. 쓰기는 모두 `Error` 를 돌려준다.
writer 를 다시 여는 길은 하나다. 기억한 cursor 뒤를 다시 읽는다.

- 그 사건 한 줄이 다 있으면 반영하고 연다.
- 아무것도 없으면 안 쓴 것으로 보고 연다.
- 반쪽 줄이면 잘라 내고 안 쓴 것으로 본다.
- cursor 가 맞지 않으면 writer 밖에서 파일이 바뀐 것이다. 닫힌 채로 둔다. 다음 기동이 처음부터 다시 접는다.

지금 파일마다 있는 정산 상태 다섯 벌(`posts_source_state` 등, `lib/board_types/board_types.mli:604`~`:1056`)이 이 규칙 하나로 바뀐다.

### 2.6 다시 쓰기(compaction)

writer 는 지금 모델을 가장 짧은 사건 목록으로 다시 쓸 수 있다.
산 글마다 `Post_created` 하나, 산 댓글마다 `Comment_added` 하나, 산 투표·반응·하위 게시판마다 하나다.
지운 것과 만료된 것은 남지 않는다.
`Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result` 로 통째로 바꾼다(`lib/fs_compat/fs_compat.mli:2082`).
언제 다시 쓰는지는 §5 결정 2 다.

### 2.7 없어지는 것과 남는 것

없어지는 것:

- 파일별 source 모듈 여섯(`lib/board/board_{posts,comments,votes,reactions,sub_boards,deletion}_source.ml` 과 `.mli`)
- `lib/board/board_snapshot_batch.ml`, `lib/board/board_target_admission.ml` 의 파일 울타리, `lib/board/board_deletion.ml` 의 표지·재개 부분, `lib/board/board_posts_inspection.ml`
- `board_types` 의 파일별 상태 타입, dirty 표지와 id 표, `post_rows`·`comment_rows`
- flusher actor 와 inbox, 버린 예약을 세는 counter(`lib/board/board_core_persist.ml:23`), flush 실패를 로그와 counter 로만 남기는 길(`lib/board/board_deletion.ml:553`)
- 종료할 때의 `Board_dispatch.flush ()`(`bin/main_eio.ml:760`, `bin/main_stdio_eio.ml:197`). 쓰지 않은 상태가 메모리에 남지 않는다.
- 위 모듈만 붙잡는 시험 14개, 7,369줄(`test/test_board_*source*.ml`, `test_board_delete_*.ml`, `test_board_deletion_recovery.ml`, `test_board_persistence_*.ml`, `test_board_snapshot_rows.ml`, `test_board_sub_board_deletion_recovery.ml`, `test_board_ttl.ml`, `test_board_vote_persistence.ml`)

source 여섯, 삭제, batch, 점검 모듈을 합치면 3,724줄이다(`.mli` 포함). 삭제 모듈의 권한 검사처럼 남는 부분은 L3 에서 다시 짠다.

남는 것:

- workspace 묶기(`lib/board_types/board_workspace_binding.ml`). §1.5 의 경로 갈래 5건이 지킨 것이다.
- 읽는 모델, 색인, 접근 규칙, audience, 수신자 lookup, Dashboard 의 반응 batch 처리
- 큐레이션 snapshot. 메모리에만 있고 저장하지 않는다(`lib/board/board_curation.ml:75`).
- 만료 시각 계산과 청소 주기. 청소는 메모리를 직접 바꾸지 않고 `Expired` 사건 하나를 writer 에 넘긴다.

## 3. 옛 파일 끊기 (hard cut)

- 새 build 는 `board_events.jsonl` 만 읽고 쓴다. 빈 Board 로 시작한다.
- 옛 파일 여섯과 `.lock` 형제 파일은 읽지 않는다. 옮기는 코드, 옛 이름을 아는 코드를 두지 않는다.
- `.masc` 데이터는 버려도 된다는 운영자 결정(2026-11-19)을 따른다.
- changelog 에 `### Fresh state required` 를 쓴다. 내용: Board 는 비어서 시작한다. 운영자는 `.masc/board_{posts,comments,votes,reactions,sub_boards,deletion}.jsonl` 과 그 `.lock` 을 지운다.

## 4. 층

한 층은 PR 하나다. 맨 아래 층만 main 을 base 로 둔다.

| 층 | 하는 일 | 확인 |
|---|---|---|
| L0 | 이 RFC | 리뷰 |
| L1 | `Board_event` 타입·JSON 풀기, 순수 접기 `Board_fold.apply`. 부르는 곳 없음 | 사건마다 왕복 시험. 글 지움이 댓글·투표·반응을 치운다. 접어서 센 수가 지금 `recalculate_*` 결과와 같다. `Expired` 가 `Post_deleted` 와 같은 것을 치운다 |
| L2 | `Board_log`: 열기(잘린 줄 처리 + 접기), 쓰기(§2.3), 모름 규칙(§2.5), 다시 쓰기 함수(§2.6). 부르는 곳 없음 | 임시 디렉터리에서 fiber 여럿이 동시에 쓰면 파일 순서와 모델이 같다. 줄 중간에서 자른 파일을 열면 그 줄만 빠진다. cursor 가 어긋나면 쓰기를 거절한다. 다시 쓴 파일을 접은 모델이 원래 모델과 같다 |
| L3 | 모든 쓰기 연산을 `Board_log` 로 돌리고, 기동을 접기로 바꾼다. Fresh state | 지금 있는 Board 동작 시험(글·댓글·투표·반응·하위 게시판·지움)이 새 저장으로 그대로 통과한다. 새 시험: 지운 글이 재시작 뒤에도 돌아오지 않는다. 거절된 댓글이 파일에 남지 않는다 |
| L4 | §2.7 의 없어지는 것을 지운다 | `rg -w` 로 지운 이름이 `docs`·`CHANGELOG.md` 밖에서 0건 |
| L5 | 밖에서 읽는 쪽: preflight scan, 컨테이너 mount, 스크립트 둘 | preflight 시험이 잘린 줄과 모르는 사건을 보고한다 |

L3 은 둘로 나누지 않는다.
글만 먼저 옮기면 지울 때 옛 투표 파일과 새 로그를 같이 맞춰야 한다.
이 RFC 가 없애려는 바로 그 일이다.
그래서 L3 은 부르는 자리만 바꾸고, 지우기는 L4 에 몰아 L3 의 크기를 줄인다.

## 5. 사용자가 정할 것

1. **중간 줄이 풀리지 않을 때.**
   추천: 그 줄 앞까지 접은 모델로 읽기를 열고, 쓰기는 거절한다. preflight 는 그 줄 번호를 보고한다.
   로그의 앞부분은 실제로 있었던 상태다. 줄 하나를 건너뛰면 뒤의 지움이 엉뚱한 글에 닿을 수 있다.
   다른 안: Board 전체를 닫는다.
2. **다시 쓰는 때.**
   추천: 기동할 때만 다시 쓴다. 로그가 커지는 속도를 L5 에서 잰 뒤 다시 본다.
   지금은 글을 고칠 때마다 글 파일 전체를 다시 쓴다. 로그는 한 줄만 붙는다. 다만 기동이 접는 줄 수가 는다.
   다른 안: 실행 중에도 다시 쓴다. 기준을 숫자로 둬야 해서 근거가 먼저 필요하다.
3. **Board 가 기동을 막는지.**
   지금 Board 는 preflight 에만 보고하고 기동을 막지 않는다(`Preflight_only`, `lib/keeper/keeper_durable_store.ml:1187`).
   추천: 그대로 둔다. 결정 1 의 「읽기만 연다」와 맞는다.
4. **컨테이너의 Board mount.**
   컨테이너 안에서 Board 파일을 여는 쪽을 찾지 못했다.
   추천: L5 에서 찾아보고, 없으면 Board mount 를 지운다. 있으면 `board_events.jsonl` 하나를 읽기 전용으로 준다.

## 6. 고르지 않은 안

- **파일 여섯은 두고 울타리만 걷는다.**
  §1.5 의 울타리·정산 8건은 줄지만, 파일 사이 순서 5건은 그대로다. 삭제 표지와 차례 rewrite 가 남는다.
- **SQLite 로 옮긴다.**
  표 사이 transaction 은 파일 사이 순서를 푼다. 하지만 새 C 의존성이 들고, 읽는 모델은 어차피 메모리에 있다.
  masc 에는 이미 durable JSONL append·rewrite 가 있다(`lib/fs_compat/fs_compat.mli:2024`~`:2091`).
  로그가 커져 기동이 느려지면 그때 다시 본다.
- **writer 를 전용 fiber(actor)로 둔다.**
  여러 쓰기를 한 fsync 로 묶을 수 있다. 하지만 큐가 생기고 큐가 차면 어떻게 할지 정해야 한다.
  지금 잠금 하나로 이미 줄 서므로 잠금을 쓴다. 쓰기 대기가 길다는 측정이 나오면 다시 본다.
