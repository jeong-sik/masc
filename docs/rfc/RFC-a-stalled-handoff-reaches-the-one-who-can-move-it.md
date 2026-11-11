---
rfc: "a-stalled-handoff-reaches-the-one-who-can-move-it"
title: "멈춘 전달은 그것을 움직일 수 있는 쪽에 닿는다"
status: Draft
created: 2026-11-12
updated: 2026-11-12
author: claude
supersedes: []
superseded_by: null
related: ["keeper-world-state-shows-open-work", "at-name-resolves-to-declared-recipient", "task-lifecycle-a-verdict-assigns-no-work", "board-attention-asks-jev-once-per-event", "provider-path-rest", "keeper-github-apps", "0361", "0390", "0406"]
implementation_prs: []
---

# RFC: 멈춘 전달은 그것을 움직일 수 있는 쪽에 닿는다

줄 번호와 심볼은 `origin/main` `10daa5ef46cd` 기준이에요. 코드는 쓰지 않았어요.
표시: **[사실]** 은 내가 코드나 운영 기록에서 직접 확인한 것이에요. **[조사]** 는 읽기 전용 조사 에이전트가 읽거나 센 것이고 내가 다시 확인하지 않았어요. **[추정]**, **[제안]**, **[확인 필요]** 는 글자 그대로예요.

열린 이슈 지도(PR #51363)가 "Keeper 사이 전달·리뷰" 묶음으로 나눈 이슈 아홉 개를 다시 따라갔어요. 이 글은 그 조사와, 거기서 나온 수리 순서예요.

## 0. 요약

- **[사실]** 지금 운영 설치에서 전달 두 곳이 멈춰 있어요.
  - 한 Keeper 의 Board 판정 362건이 `Completed` 에서 정산되지 않아요. 그중 361건이 `relevant` 예요. 2026-11-09 05:02Z 부터예요. 그 뒤로 그 Keeper 의 partition 은 하나도 정산되지 않았어요. 자기를 지목하지 않은 Board 글은 판정을 거쳐야 Keeper 큐에 들어가는데, 그 길이 막혀 있어요.
  - 검증을 기다리는 Task 가 19개예요. 18개는 마지막 결과가 `execution_repair_required`, 1개는 `raised` 예요. 제출 뒤 6~208시간이 지났고 15개가 24시간을 넘겼어요.
- **[사실]** 두 곳 모두 로그와 기록 파일에는 적혀 있어요. 그것을 움직일 수 있는 쪽(그 Keeper, 제출한 Keeper, 운영자)의 턴이나 화면은 그 기록을 읽지 않아요.
- **[조사]** 아홉 이슈 가운데 여덟이 같은 자리에서 끊겨요. 넘긴 쪽의 기록까지는 남고, 받는 쪽에 닿았는지는 아무도 읽지 않아요(2절).
- **[제안]** 규칙은 하나예요. 넘긴 것이 멈추면 그 사실은 그것을 움직일 수 있는 쪽의 다음 문맥에 실려요. 멈춘 한 건이 다른 건의 전달을 막지 않고, 멈춘 채 "끝났다"고 적히지도 않아요.
- **[제안]** 층은 넷이에요. 새로 설계하는 것은 L1 과 L2 뿐이에요.
  - L1: Board 판정 정산이 후보 하나의 결과를 닫힌 합으로 받아요. 한 후보가 실패해도 다음 후보를 전달해요(5.1).
  - L2: 검증이 재시도 없이 멈추면 제출한 Keeper 와 운영자가 그 사실을 봐요(5.2).
  - L3: `RFC-keeper-world-state-shows-open-work` 의 S4·S6 을 구현해요. 운영자가 2026-09-28 에 이미 정했어요(5.3).
  - L4: `RFC-at-name-resolves-to-declared-recipient` 의 L3 를 구현해요. Active 인 RFC 의 남은 단계예요(5.4).
- 새 상태, 새 저장소, 새 Gate 는 없어요. L1 이 결과 타입에 갈래 둘을 더해요.
- 사용자가 정할 것은 10절에 셋 있어요.

## 1. 배경 (측정)

### 1.1 이슈 아홉 개의 지금 상태

이슈마다 producer → store → consumer → caller 를 main 코드로 따라가고, 운영 설치의 7일 기록(2026-11-05~11-11)에서 같은 증상을 셌어요.

| 이슈 | 증상 | 지금 | 7일 기록 |
|---|---|---|---|
| #38068 | Board 후보 원장에서 못 읽은 행 때문에 `relevant` 판정이 전달 없이 정산된다 | 코드 그대로 | 못 읽은 행 0건. 같은 꼴의 다른 원인으로 362건이 멈춰 있다(1.2) **[사실]** |
| #39677 | 검증이 재시도 없이 멈추고 제출자가 모른다 | 일부 | 이슈가 적은 문구는 0줄. 멈춘 검증 19건(1.2) **[사실]** |
| #41343 | 외부 세션이 만든 Task 를 아무 Keeper 도 집지 않는다 | 그대로 | todo 456개. 외부 세션이 7일 동안 만든 227개 중 102개가 todo, Keeper 가 만든 145개 중 23개 **[사실]** |
| #42017 | 리뷰어 Keeper 가 판정을 내고도 GitHub 쓰기를 시도하지 않고 "정책상 게시 불가"로 끝낸다 | 그대로 | 같은 꼴 1건, 비슷한 꼴 6건 **[조사]** |
| #46747 | 글 속 `@check` 같은 말이 받는 사람으로 읽힌다 | 일부 | Board 글·댓글은 0건(#46878 뒤). 브로드캐스트의 `Mention_rejected` 는 17건 **[사실]** |
| #46691 | 리뷰어 여럿이 GitHub 계정을 나눠 써서 리뷰 요청이 사라진다 | 일부 | Ready PR 114개 모두 현재 head 에 정식 리뷰가 있다 **[조사]**. 이슈가 잰 "56개 중 54개에 판정 없음"은 다시 나오지 않는다 |
| #26914 | 승인한 산출물이 커밋되지 않은 채 사라져도 모른다 | 일부 | 승인 153건 중 99건이 작업 트리 파일을 가리킨다. 그 뒤 사라진 수는 세지 못했다 **[조사]** |
| #45003 | 운영자 요청 뒤 coordinator 가 일을 하나도 만들지 않고 "쓰기가 실패했다"고 했다 | 모름 | 그 실험 서버의 기록이 남아 있지 않다. 운영 설치의 채팅 작업 1,674건 중 `Turn_exception` 117건 **[조사]** |
| #41311 | 공식 클라이언트 칸의 검증이 900초에 잘린다 | 아님 | 그 칸이 7일 동안 판정을 하지 않았다. 주장한 경로가 main 에서 보이지 않는다 **[조사]** |

### 1.2 지금 멈춘 곳 둘

**Board 판정 정산.** **[사실]** 2026-11-12 01:3x KST 에 운영 설치를 읽기만 해서 셌어요.

- `board_attention_partitions/*.jsonl` 19개 파일의 partition 463개: `settled` 97, `completed` 362, `abandoned` 2, `blocked` 1, `running` 1.
- `completed` 362개는 모두 한 Keeper 것이에요. 판정은 `relevant` 361, `not_relevant` 1. 가장 오래된 `completed_at` 이 11-09 05:02Z, 가장 새것이 11-11 16:08Z 예요. 다른 Keeper 18명은 `completed` 가 0개예요.
- 시스템 로그에서 `judgment conflicts with worker result` 가 든 줄이 11-09 208, 11-10 320, 11-11 165 로 693줄이에요. 모두 같은 후보 하나예요. 그중 692줄이 `Board attention completion remains pending; it did not block this Keeper turn` 줄이고, 첫 줄이 11-09T05:02:59Z, 마지막이 11-11T16:29:59Z 예요.
- 그 후보는 partition 과 원장 양쪽에서 `not_relevant` 예요. 두 판정은 결론이 같고 요청 해시와 판정 시각(1.2초 차이)이 달라요 **[조사]**.

**검증 대기.** **[사실]** 같은 시각에 셌어요.

- `tasks/backlog.json` 의 Task 1,458개 중 `awaiting_verification` 19개.
- 19개 모두 `verification-runs.jsonl` 의 마지막 결과가 판정이 아니에요. `execution_repair_required` 18(세부: "original execution lost its writer without a terminal settlement" 8, "original executions have no retained verdict" 8, 그 밖 2), `raised` 1.
- 제출 뒤 지난 시간은 최소 6, 중앙값 124, 최대 208시간이에요.
- 같은 파일에 남은 창(11-10 05:13Z 부터)에서 검증 64건의 마지막 결과는 `approved` 26, `rejected` 18, `execution_repair_required` 19, `raised` 1 이에요.

### 1.3 Task 가 집히는 길

**[사실]** `events/2026-11/05~11.jsonl` 에서 `task_claim`(id 를 골라 집음) 153건, `task_claim_next`(다음 것을 달라고 함) 4건이에요. **[조사]** 그 4건은 모두 같은 Task 하나로 갔고 매번 1~76분 안에 반납됐어요. 그 Task 는 27번 반납됐어요. Keeper 프롬프트가 보여 주는 할 일 목록의 앞 7행은 2026-09-07~09-29 에 만든 P1 이고, 행에는 `task_id` 만 있어요.

## 2. 문제

아홉 이슈는 넘기는 것이 서로 달라요. 판정, 검증 요청, Board 판정, Task, 운영자 요청이에요. 끊기는 자리는 같아요.

| 넘기는 것 | 넘긴 쪽이 남기는 것 | 받는 쪽에 닿았는지 읽는 곳 | 끊긴 자리 |
|---|---|---|---|
| 리뷰 판정 → GitHub (#42017) | 턴의 마지막 글 | 없음. 게시된 리뷰만 서버가 읽는다 | 판정을 냈는데 게시 시도가 0번이라는 사실이 글로만 남는다 |
| 리뷰할 PR → 리뷰어 (#46691) | GitHub 의 요청 목록 | 서버가 `unreviewed_on_head` 를 계산하지만 턴에 싣지 않는다 | consumer → caller |
| 검증 요청 → 판정 (#39677) | `verification-runs.jsonl` 의 멈춤 행, WARN 한 줄 | 대시보드 검증 화면뿐. 제출자 큐와 운영자 attention 은 읽지 않는다 | consumer → caller |
| 승인 → 산출물 (#26914) | `Done` | 없음 | 승인한 대상이 남았는지 기록하지 않는다 |
| Board 판정 → Keeper 큐 (#38068) | partition `Completed` | owner 의 정산 걸음 | 한 건이 실패하면 뒤가 모두 멈추거나, 못 찾으면 전달 없이 `Settled` 가 된다 |
| 글 → 받는 사람 (#46747) | 저장된 메시지 | 브로드캐스트 응답 | 저장되고 전달된 뒤에 `ok:false` 로 답한다 |
| Task → 할 Keeper (#41343) | `Todo` | 모든 Keeper 가 같은 `task_id` 목록을 본다 | 어느 문맥에도 "이 일은 네 것"이 없다 |
| 운영자 요청 → 일 (#45003) | 작업 `Failed` | 고정 문장 한 줄 | 요청이 일을 하나도 만들지 못했다는 사실이 없다 |

두 꼴로 나뉘어요.

- **조용히 넘어간다.** 받는 쪽 기록 없이 상태가 앞으로 가요. `Candidate_absent` 정산(#38068), 커밋 안 된 산출물의 `Done`(#26914), 고정 문장으로 끝난 `Failed`(#45003).
- **조용히 멈춘다.** 멈춘 사실이 로그와 기록 파일에만 있고, 움직일 수 있는 쪽이 읽지 않아요. Board 362건, 검증 19건, todo 456개, 게시되지 않은 판정.

**[사실]** 헌법(`docs/constitution.xml`)은 첫째 꼴을 이미 금지해요. `failure_keeps_evidence` 는 "전달 실패는 증거를 남기고 대상을 소비하지 않는다. 실패가 상태를 조용히 진행시키지 않는다"예요. 둘째 꼴은 조항이 없어요. 증거는 남았고 상태도 그대로라서 어느 불변식도 깨지지 않아요. 그런데 실패 조건 "여러 Keeper 가 자기들끼리 커뮤니케이션하지 않는다"가 실제로 일어나는 곳은 둘째 꼴이에요.

## 3. 지금 코드가 하는 일

L1 과 L2 가 고치는 자리만 적어요.

### 3.1 Board 판정 정산

- **[사실]** owner 의 heartbeat 가 `Keeper_board_attention_worker.settle_completed_snapshot` 을 불러요(`keeper_heartbeat_loop.ml:1017`). 실패하면 `remains pending; it did not block this Keeper turn` 을 로그에 쓰고 턴은 계속해요(`:1025`).
- **[사실]** `settle_completed_snapshot` 은 `completed_in_order` 가 준 목록을 `let* settled = settle_head partition` 으로 걸어요(`keeper_board_attention_worker.ml:1951` 부터). 첫 `Error` 에서 걸음 전체가 끝나요. 다음 heartbeat 는 같은 순서의 같은 맨 앞에서 다시 멈춰요.
- **[사실]** `settle_head` 가 부르는 `deliver_and_settle_completed`(`:818`)는 `Candidate.apply_judgment_and_deliver` 의 결과를 받아요. 결과 타입은 `Delivered of candidate | Candidate_absent` 둘이에요(`keeper_board_attention_candidate.ml:1175`). `Candidate_absent` 면 error 로그를 쓰고 `Partition.settle` 을 불러요.
- **[사실]** `apply_judgment_and_deliver` 는 후보가 이미 `Judged` 나 `Consumed` 인데 판정이 다르면 `Error "… judgment conflicts with worker result: <id>"` 를 문자열로 돌려줘요(`:1210-1213`). `same_judgment` 은 verdict, slot_id, source, judged_at 이 모두 같아야 참이에요(`:648`). 주석은 이 실패를 "조용히 풀지 말고 계속 크게 알릴 버그"라고 적어요.
- **[조사]** `load_candidates` 는 디코더가 거절한 행을 개수만 세고 목록에서 빼요. 그래서 못 읽은 행이 가린 후보는 `find_candidate` 에서 `None` 이 되고 `Candidate_absent` 로 정산돼요(#38068). `Partition.settled_receipt_gate` 는 같은 거절 행을 `load_candidates_with_rejections` 로 읽고 "숨은 후보가 살아 있을 수 있다"며 영수증을 남겨요. 같은 사실을 두 곳이 다르게 읽어요.
- **[추정]** 1.2 의 충돌은 worker 의 exact flow 와 fanout 이 같은 후보를 따로 판정해서 생겼어요. 11-09 05:02:52Z 에 worker 의 판정 완료, 05:02:55Z 에 fanout 의 `partition is not Running` 경고가 찍혔어요 **[조사]**. 두 판정이 어떻게 둘 다 기록됐는지는 확인하지 못했어요.
- **[조사]** 11-05 에 같은 충돌 두 건은 Consumed 행이 prune 으로 지워지면서 `Candidate_absent` 정산으로 풀렸어요. #48804(11-06)가 열린 partition 의 Consumed 행을 지우지 않게 한 뒤로는 그 길이 없어요. #48804 는 맞는 수리예요. 충돌이 우연히 풀리던 길이 같이 닫혔을 뿐이에요.

### 3.2 검증 멈춤

- **[사실]** `Completion_authority_agent.retry_request_of_stop_cause` 는 `Execution_repair_required`, `Infrastructure_unavailable`, `Commit_failed`, `Raised`, 그리고 다시 볼 runtime 이 없는 `Not_reviewed` 에 `No_retry_requested` 를 줘요(`completion_authority_agent.ml:653-658`). 주석은 "다음 수는 producer, 운영자, backlog 전체 sweep 에 남긴다"예요.
- **[사실]** `Operator_task_attention.project` 는 `AwaitingVerification` 을 빼요. 주석은 "완료는 system authority 를 기다리고, 그것은 돌고 있다"예요(`operator_task_attention.ml:72-74`). 멈춘 검증에는 이 전제가 맞지 않아요.
- **[조사]** 멈춘 사실은 `Verification_run_registry.mark_completed`(`verification-runs.jsonl`)와 `announce_stall` 의 WARN 로그에 적혀요. #47927 이 검증 정체를 알리던 Board 글을 지웠어요. 제출한 Keeper 의 큐에는 정체 이벤트가 없어요.
- **[사실]** 대시보드의 검증 화면은 `execution_repair_required` 를 그려요(`lib/dashboard/dashboard_verification.ml:404`). 그 화면을 열어야 보여요.
- **[조사]** #39677 이 처음 적은 원인은 따로 남아 있어요. `keeper_turn_driver` 의 `complete_media` 는 글 전용 검증 칸에 이미지가 오면 `InvalidConfig` 로 거절해요. `anti_rationalization` 의 주석은 그 칸이 미디어를 벗기고 판정한다고 적어요. 두 약속이 어긋나요. 7일 로그에 이 거절은 0줄이에요.

## 4. 후보 설계

### 4.1 규칙

**[제안]** 넘긴 것이 멈추면, 그 사실은 그것을 움직일 수 있는 쪽의 다음 문맥에 실려요.

- 사실은 이미 저장된 기록에서 읽어요. 새 저장소를 두지 않아요.
- 다음에 무엇을 할지는 받은 쪽이 골라요. 대기, 재시도, 응답 의무를 만들지 않아요.
- 멈춘 한 건이 다른 건의 전달을 막지 않아요.
- 멈춘 채 "끝났다"고 적지 않아요(이미 헌법 조항이에요).

### 4.2 좌: 잘못된 상태를 만들 수 없게 한다

| 이슈 | 내용 | 원칙과 맞는가 |
|---|---|---|
| #38068, 362건 | 판정 전달 결과를 닫힌 합으로 낸다. 정산 걸음이 후보 단위로 결과를 받는다 | 맞다. 지금은 "전달됐다"와 "못 읽었다"가 같은 `Settled` 로 섞인다 |
| #39677 | 글 전용 칸으로 갈 때 이미지 블록을 벗기고 참조 줄만 남긴다. `InvalidConfig` 라는 틀린 상태가 생기지 않는다 | 맞다. 어긋난 두 약속 중 하나를 지운다 |
| #46747 | 브로드캐스트가 Board 와 같은 선언 조회를 쓴다(`routing_target` 삭제) | 맞다. Active RFC 의 L3 그대로다 |
| #46691 | Keeper 마다 GitHub 신원을 따로 둔다 | 맞다. 다만 계정·App 7~8개의 관리가 든다 |
| #41343 | Task 를 만들 때 받는 쪽을 닫힌 합으로 받는다(`Keeper` / `Goal` / `Pool`) | 일부. `Pool` 을 고르면 지금과 같다. 담당 필드를 두면 "담당은 claim 으로 정한다"와 부딪힌다 |
| #45003 | provider 가 쉬는 중이라 효과 없이 끝난 채팅 작업을 terminal 로 두지 않는다 | 맞다. `RFC-provider-path-rest` 의 범위다 |
| #42017 | 리뷰어를 내장 도구 없는 자세로 돌린다 | 일부. Codex·Muse 레인은 그 자세를 지원하지 않는다 **[조사]** |

### 4.3 우: 있는 사실을 읽게 한다

| 이슈 | 내용 | 원칙과 맞는가 |
|---|---|---|
| #46691, #42017 | 서버가 이미 계산하는 `unreviewed_on_head` 를 리뷰어의 World State 에 싣는다 | 맞다. projection 이고 운영자가 정한 S4 다 |
| #41343 | Task 행에 제목, 만든 이, 나이, 이어진 Goal, 반납 횟수, 마지막 반납 이유를 싣는다 | 맞다. 운영자가 정한 S6 이다 |
| #39677, 19건 | 멈춘 검증을 제출한 Keeper 의 문맥과 운영자 attention 에 싣는다 | 맞다. 다만 이것만 하면 미디어 거절은 남는다 |
| #38068 | 정산 근거와 못 읽은 행 수를 화면에 싣는다 | 단독으로는 맞지 않다. 전달 손실이 그대로라 "보이게만 하기"다 |
| #45003 | 실패 행에 닫힌 사유 variant 를 싣는다 | 맞다 |

### 4.4 고른 조합

| 층 | 방향 | 고른 이유 |
|---|---|---|
| L1 Board 정산 | 좌 | 지금 손실이 나는 곳이다. 보이게만 해서는 361건이 전달되지 않는다 |
| L2 검증 멈춤 | 우 + 좌 | 움직일 쪽은 있는데 모른다(우). 미디어 거절은 틀린 상태라 따로 지운다(좌) |
| L3 World State S4·S6 | 우 | 설계와 운영자 결정이 끝났다. 리뷰와 Task 두 이슈의 끊긴 자리가 consumer → caller 다 |
| L4 at-name L3 | 좌 | Active RFC 의 남은 단계다 |

**[제안]** #46691 의 좌(Keeper 별 GitHub 신원)는 지금 하지 않아요. Ready PR 114개가 모두 현재 head 에 리뷰를 받았어요. L3 뒤에 다시 재요(10절).

## 5. 층별 내용

### 5.1 L1 — Board 판정 정산은 후보 단위로 결과를 받는다

**[제안]** `judgment_delivery_outcome` 에 갈래 둘을 더해요.

```ocaml
type judgment_delivery_outcome =
  | Delivered of candidate
  | Candidate_absent            (* 거절 행이 0인 원장에서만 *)
  | Candidate_unreadable of { rejected_rows : int }
  | Judgment_conflict of { recorded : judgment; offered : judgment }
```

- `Candidate_absent` 는 `load_candidates_with_rejections` 가 거절 0을 돌려준 원장에서만 만들어요. 거절 행이 있으면 `Candidate_unreadable` 이에요.
- `Judgment_conflict` 는 지금 문자열 `Error` 인 갈래예요. 값이 되면 부르는 쪽이 `match` 에서 반드시 다뤄요.
- `Error` 는 원장을 읽지 못한 것처럼 걸음 전체가 멈춰야 하는 실패에만 남아요.

**[제안]** `settle_completed_snapshot` 의 걸음은 partition 마다 결과를 받아요.

| 결과 | partition | 다음 partition |
|---|---|---|
| `Delivered` | `Settled` | 계속 |
| `Candidate_absent` | `Settled`(지금과 같음) | 계속 |
| `Candidate_unreadable` | `Completed` 로 남는다 | 계속 |
| `Judgment_conflict` | `Completed` 로 남는다 | 계속 |
| `Error` | 그대로 | 멈춘다 |

- 남은 partition 은 지금처럼 heartbeat 마다 error 로그를 내요. 크게 알리는 것은 그대로예요.
- 전달 순서가 바뀌어요. 지금은 `completed_at` 순서에서 한 건도 건너뛰지 않아요. **[확인 필요]** Keeper 큐에 들어가는 Board 사건이 후보 사이의 순서에 기대는지 구현 전에 확인해요.
- `settle_if_not_relevant`(`:858`)도 같은 결과 타입을 받아요. 네 갈래를 모두 적어요.

**[제안]** 충돌이 생기는 원인은 따로 닫아요. worker 와 fanout 이 같은 후보에 판정을 둘 다 기록할 수 있는 길을 찾아 하나로 줄여요. 이 조사가 끝나기 전에는 L1 을 "충돌을 없앴다"고 적지 않아요.

**하지 않는 것.** verdict 가 같으면 같은 판정으로 치는 비교는 넣지 않아요. 두 판정이 왜 생겼는지 모르는 채 `same_judgment` 을 느슨하게 하면 `relevant` 와 `not_relevant` 가 갈리는 충돌도 같은 길로 지나가요.

**시험.**
- 맨 앞 partition 이 `Judgment_conflict` 이고 뒤에 `relevant` 둘이 있는 fixture: 뒤 둘이 Keeper 큐에 들어가고 `Settled` 가 된다. 맨 앞은 `Completed` 로 남는다.
- 거절 행 하나가 든 원장에서 그 id 를 찾으면 `Candidate_unreadable` 이고 `Settled` 가 되지 않는다.
- 원장 읽기를 `Error` 로 만들면 뒤 partition 을 건드리지 않는다.

### 5.2 L2 — 멈춘 검증은 제출자와 운영자에게 보인다

**[제안]** 읽는 사실은 `verification-runs.jsonl` 의 마지막 행 하나예요. `retry_request_of_stop_cause` 가 `No_retry_requested` 를 준 멈춤만 대상이에요.

- `Operator_task_attention.project` 가 `AwaitingVerification` 을 무조건 빼지 않아요. 그 `verification_id` 의 마지막 행이 재시도 없는 멈춤이면 목록에 실어요. 판정이 돌고 있거나 재시도가 서 있으면 지금처럼 빼요.
- 제출한 Keeper 의 World State 에 한 줄을 실어요. 예: `task-… 제출 vrf-… 은 판정되지 않았고 다시 돌 예약이 없다 (execution_repair_required)`. 사유는 `Verification_run_registry.outcome` 의 닫힌 값이에요. 세부 문장은 싣지 않아요.
- Keeper 가 그 줄을 보고 무엇을 할지는 정하지 않아요.

**[제안]** 미디어 거절(#39677 의 처음 원인)은 좌로 지워요. 글 전용 칸으로 가는 goal_blocks 에서 이미지 블록을 벗기고 참조 줄을 남겨요. `complete_media` 의 `InvalidConfig` 갈래는 닿지 않게 되면 지워요.

**[확인 필요]** `execution_repair_required` 를 운영자가 실제로 푸는 방법이 무엇인지 확인하지 못했어요. 18건 중 8건은 "실행 기록의 writer 를 잃었다"예요. 재시작이 도는 검증을 모두 운영자 수리로 보내는지, 그게 의도인지는 `RFC-0361` 과 #46132 를 읽고 정해야 해요. 보여 주기만 하고 풀 방법이 없으면 L2 는 반쪽이에요.

### 5.3 L3 — World State 의 S4·S6

**[사실]** `RFC-keeper-world-state-shows-open-work` 는 S1, S2, S5 가 병합됐어요(#50213, #50214, #50259). S4 는 main 에 없어요. `world.pull_requests` 가 `lib`, `config` 에 0건이에요. 운영자가 2026-09-28 에 D1~D7 을 정했어요. **[조사]** S6(Task 행)도 main 에 없어요.

이 글은 그 설계를 바꾸지 않아요. 순서의 근거만 더해요.

- S6(Task 행)이 S4 보다 먼저예요. todo 456개, 외부 세션이 만든 Task 의 45%가 7일 뒤에도 todo, `task_claim_next` 4건이 모두 27번 반납된 Task 하나로 갔어요. S6 은 Task 쪽만이라 S3a·S3b 를 기다리지 않아요.
- S4(PR 행)는 S3a·S3b 뒤예요. 지금 Ready PR 은 모두 리뷰를 받고 있어서 급하지 않아요.
- **[제안]** S6 의 Task 행에 반납 횟수(`cycle_count`)를 더해요. 그 RFC 의 6.1 은 제목, 만든 이, 나이, Goal, 마지막 반납 이유를 적었고 횟수는 없어요. 필드는 이미 backlog 에 있어요.

### 5.4 L4 — 브로드캐스트의 받는 사람

**[사실]** `Workspace_broadcast` 는 `Board_addressing.routing_target` 으로 멘션 대상을 뽑아요(`workspace_broadcast.ml:970`). 선언을 묻지 않아요. `mcp_tool_runtime_board.ml:263`, `:310` 의 알림도 같은 함수를 써요. 7일 동안 `Mention_rejected` 가 17건이에요.

`RFC-at-name-resolves-to-declared-recipient` 의 L3 가 이것을 고쳐요. 이 글은 더하지 않아요.

## 6. 비용

| 층 | 바뀌는 곳 | 대가 |
|---|---|---|
| L1 | `keeper_board_attention_candidate.ml`, `keeper_board_attention_worker.ml`, 그 시험 | `judgment_delivery_outcome` 을 `match` 하는 곳을 모두 고친다. 전달 순서 보장이 약해진다 |
| L2 | `operator_task_attention.ml`, World State 층 하나, `keeper_turn_driver.ml` 의 미디어 갈래 | 운영자 attention 목록이 길어진다. 지금 19행이 더해진다 |
| L3 | 그 RFC 의 8절 | 그 RFC 에 적혀 있다 |
| L4 | 그 RFC 의 L3 | 그 RFC 에 적혀 있다 |

## 7. 다른 RFC 와의 관계

| RFC | 관계 |
|---|---|
| `keeper-world-state-shows-open-work` (Draft) | L3 가 이 RFC 의 S4·S6 이다. 이 글은 순서의 근거와 `cycle_count` 한 칸을 더한다 |
| `at-name-resolves-to-declared-recipient` (Active) | L4 가 이 RFC 의 L3 다 |
| `task-lifecycle-a-verdict-assigns-no-work` (Draft) | 1.5절이 같은 검증 정체와 운영자 attention 제외를 적었다. L2 와 같은 자리다. 그 RFC 가 먼저 구현되면 L2 의 attention 부분은 거기에 합친다 |
| `0361`, `0406` (Draft) | 검증 원본 보관과 원격 게스트 읽기. L2 의 "확인 필요"가 여기에 달렸다 |
| `board-attention-asks-jev-once-per-event` (Draft) | fanout 이 직접 판정하는 길. L1 의 충돌 원인 조사와 닿는다 |
| `provider-path-rest` (Draft) | #45003 의 좌가 이 RFC 범위다. 이 글은 다루지 않는다 |
| `keeper-github-apps` (Draft) | #46691 의 좌. 지금 하지 않는다(10절) |
| `0390` (Draft) | 공식 클라이언트의 내장 도구 자세. #42017 의 좌가 여기에 달렸다 |
| Draft PR #51381 (영수증을 기다리며 턴이 끝나는 상태 기계) | 한 Keeper 가 자기 도구 결과를 기다리는 설계다. 이 글은 서로 다른 쪽 사이의 전달을 다룬다. 고치는 파일이 겹치지 않는다 |

## 8. 하네스

배포 뒤 같은 방법으로 다시 세요. 기준은 이 글에 고정해요.

| 층 | 재는 것 | 지금 | 기대 |
|---|---|---|---|
| L1 | Keeper 별 `Completed` partition 수 | 한 Keeper 362, 나머지 0 | 충돌·못 읽은 것만 남는다. 지금 자료로는 1 |
| L1 | `completion remains pending` 로그가 가리키는 후보 수 | 1(693줄) | 줄 수는 그대로일 수 있다. 뒤에 밀린 partition 이 0이어야 한다 |
| L2 | `awaiting_verification` 중 마지막 행이 재시도 없는 멈춤인 것 | 19 | 수는 그대로일 수 있다. 19건이 운영자 attention 과 제출자 문맥에 보여야 한다 |
| L3 | 7일 동안 외부 세션이 만든 Task 중 todo 비율 | 45% (102/227) | 낮아지는지 본다. 목표값은 두지 않는다 |
| L3 | `task_claim_next` 가 간 Task 의 반납 횟수 | 27 | 같은 Task 로 다시 가지 않는지 본다 |
| L4 | 7일 `Mention_rejected` | 17 | 선언된 이름의 진짜 실패만 남는다 |

**[사실]** `specs/` 에는 이름에 attention, partition, candidate 가 든 파일이 없고 `specs/INDEX.md` 에도 Board attention 항목이 없어요. **[제안]** L1 의 충돌 원인을 고칠 때 정산 걸음의 모델을 새로 써요. 정상 `Next` 는 "`Completed` 인 `relevant` 판정은 결국 전달된다"를 지키고, 맨 앞 한 건이 걸음을 멈추는 `BugAction` 은 그것을 깨야 해요.

## 9. 하지 않는 것

- 멈춘 건수에 상한이나 cooldown 을 두지 않아요.
- 멈춤을 알리는 Gate, 응답 의무, 재시도 의무를 만들지 않아요.
- 턴의 마지막 글을 분류하지 않아요(#42017). "게시 못 함"이라는 문장을 문자열로 가려내면 `closed_sum_over_string` 에 어긋나요.
- 리뷰 재요청을 자동으로 걸지 않아요(#46691). 요청을 일 배정으로 쓰는 것이에요.
- Task 레코드에 담당 필드를 두지 않아요(#41343).
- 멈춰 있는 362건과 19건의 운영 자료를 이 글의 구현이 직접 고치지 않아요. L1 이 배포되면 361건은 다음 heartbeat 에 전달돼요. 19건은 10절의 결정에 달렸어요.

## 10. 사용자가 정할 것

| # | 정할 것 | 정석 | 대가 |
|---|---|---|---|
| 1 | L1 뒤에도 남는 충돌 partition 하나를 어떻게 하나 | 그대로 둔다. 원인 조사가 끝나면 그 결과로 정한다 | heartbeat 마다 error 로그 한 줄이 계속 난다(지금 하루 165~320줄) |
| 2 | 멈춘 검증 19건 | L2 로 보이게 한 뒤 운영자가 건별로 푼다. 푸는 방법은 `RFC-0361` 쪽에서 확인한다 | 그때까지 19개 Task 가 `awaiting_verification` 으로 남는다 |
| 3 | Keeper 별 GitHub 신원(#46691 의 좌) | 지금 하지 않는다. L3 의 S4 가 배포된 뒤 "현재 head 에 리뷰 없는 Ready PR" 을 다시 잰다 | 어느 Keeper 가 리뷰했는지는 계속 계정 단위로만 남는다 |

## 11. 확인하지 못한 것

- 충돌한 두 판정이 어떻게 둘 다 기록됐는지. worker 와 fanout 의 경합이라는 것은 로그 순서에서 나온 추정이에요.
- Keeper 큐가 Board 사건의 순서에 기대는지.
- `execution_repair_required` 를 푸는 운영자 절차.
- #42017 의 7일 사례 1건과 비슷한 6건. 조사 에이전트가 raw trace 에서 읽었고 내가 다시 읽지 않았어요. raw trace 는 Keeper 마다 최근 약 200턴만 남아서 7일 전체를 세지 못했어요.
- #46691 의 "Ready 114개 모두 리뷰됨"이 왜 그런지. 스킬 문서의 순서, 운영자가 준 목록, 리뷰어 수 가운데 무엇 때문인지 가르지 못했어요.
- #26914 의 승인 뒤 사라진 산출물 수.
- #41311 이 주장한 경로가 main 에 없다는 것. 조사는 그렇게 읽었고(신뢰도 0.65) 내가 `run_named` 의 Claude Code 갈래를 끝까지 읽지 않았어요. 닫기 전에 한 번 더 대조해요.
- #45003. 실험 서버의 기록이 남아 있지 않아요.
