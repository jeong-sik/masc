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
implementation_prs: ["#51440", "#51470", "#51525", "#51540", "#51589", "#51613", "#51618"]
---

# RFC: 멈춘 전달은 그것을 움직일 수 있는 쪽에 닿는다

줄 번호와 심볼은 `origin/main` `10daa5ef46cd` 기준이에요. 3.1 과 5.1 이 가리키는 Board attention 파일은 `9cfff6704657` 까지 바뀌지 않았어요. 이 글을 처음 쓸 때 코드는 쓰지 않았어요.
2026-11-12 오후에 검증 멈춤(1.2 의 둘째 묶음, 3.2, 5.2 와 거기에 딸린 표)을 `b2f9ee56605d` 기준으로 다시 썼어요. 처음 글은 멈춘 원인을 세지 않았고, 읽을 자료도 잘못 골랐어요. 그 뒤 적대적 검토를 두 번 받아 L2a 를 고쳤어요. 다시 돌지는 헌법대로 실패의 typed 판정이 정해요. 리뷰의 걸음(walk)이 결론을 남기지 못한 시도만 다시 걸어요. L1 은 PR #51440(L1a)과 #51470(L1b)으로 구현했어요.
2026-11-12 저녁에 L2 를 구현하면서 5.2 를 코드대로 고쳤어요. L2b 는 PR #51525 와 #51589, L2a 는 PR #51540, #51613, #51618 이에요. 고친 자리에는 "구현하며 고쳤어요"라고 적었어요.
2026-11-12 밤에 L2a 배포 뒤 측정(8절)을 적고, 거기서 찾은 경합을 고치는 L2c(5.2)를 더했어요. L2c 의 줄 번호는 `origin/main` `79c51d7c6725` 기준이에요.

- 요청된 판정 보고는 정산된 보고가 있을 때만 세요. 호출 노드가 아니라 기록된 provider 응답에서 읽어요.
- "보고 없이 성공으로 끝난 실행은 수리"라는 규칙은 뺐어요. 지금 코드와 맞지 않았어요.

표시: **[사실]** 은 내가 코드나 운영 기록에서 직접 확인한 것이에요. **[조사]** 는 읽기 전용 조사 에이전트가 읽거나 센 것이고 내가 다시 확인하지 않았어요. **[추정]**, **[제안]**, **[확인 필요]** 는 글자 그대로예요.

열린 이슈 지도(PR #51363)가 "Keeper 사이 전달·리뷰" 묶음으로 나눈 이슈 아홉 개를 다시 따라갔어요. 이 글은 그 조사와, 거기서 나온 수리 순서예요.

## 0. 요약

- **[사실]** 지금 운영 설치에서 전달 두 곳이 멈춰 있어요.
  - 한 Keeper 의 Board 판정 362건이 `Completed` 에서 정산되지 않아요. 그중 361건이 `relevant` 예요. 2026-11-09 05:02Z 부터예요. 그 뒤로 그 Keeper 의 partition 은 하나도 정산되지 않았어요. 자기를 지목하지 않은 Board 글은 판정을 거쳐야 Keeper 큐에 들어가는데, 그 길이 막혀 있어요.
  - 원인을 찾았어요. worker 가 판정하고 정산해 영수증이 지워진 직후에, 같은 Board 사건의 fanout 이 낡은 후보 값으로 root 를 다시 만들어 두 번째 판정을 내요(3.1). 8일 로그에서 3번 났어요.
  - 검증을 기다리는 Task 가 19개예요. 18개는 마지막 결과가 `execution_repair_required`, 1개는 `raised` 예요. 제출 뒤 6~208시간이 지났고 15개가 24시간을 넘겼어요.
  - 19개 가운데 17개는 잠깐의 장애가 영구 정지로 굳은 것이에요. 리뷰가 도는 중에 서버 프로세스가 끝났거나(8), 리뷰어의 provider 호출이 실패했거나(8), 판정을 보고한 뒤 다음 provider 호출이 실패했어요(1). 다시 시도하는 길도, 운영자에게 닿는 길도 없어요(1.2, 3.2).
- **[사실]** 두 곳 모두 로그와 기록 파일에는 적혀 있어요. 그것을 움직일 수 있는 쪽(그 Keeper, 제출한 Keeper, 운영자)의 턴이나 화면은 그 기록을 읽지 않아요.
- **[조사]** 아홉 이슈 가운데 여덟이 같은 자리에서 끊겨요. 넘긴 쪽의 기록까지는 남고, 받는 쪽에 닿았는지는 아무도 읽지 않아요(2절).
- **[제안]** 규칙은 하나예요. 넘긴 것이 멈추면 그 사실은 그것을 움직일 수 있는 쪽의 다음 문맥에 실려요. 멈춘 한 건이 다른 건의 전달을 막지 않고, 멈춘 채 "끝났다"고 적히지도 않아요.
- **[제안]** 층은 넷이에요. 새로 설계하는 것은 L1 과 L2 뿐이에요.
  - L1: Board 판정 정산이에요. 낡은 후보 값으로 root 를 다시 만드는 길을 닫아요(L1a). 정산이 후보 하나의 결과를 닫힌 합으로 받아서, 한 후보가 실패해도 다음 후보를 전달해요(L1b)(5.1).
  - L2: 리뷰 시도가 끊겼을 때 실행 기록이 "판정 보고가 없었다"를 확정하면 그 시도는 확정된 거절이 돼요. 리뷰의 걸음이 결론을 남겼으면 거기 실린 실패의 typed 판정이 다시 돌지 정해요. 취소나 프로세스 종료로 결론을 남기지 못했으면 다음 시도로 가요. 정산된 판정 보고가 하나 있으면 그 판정을 읽어요(L2a). 사람이 풀어야 하는 것은 운영자 목록에 실어요(L2b)(5.2).
  - L3: `RFC-keeper-world-state-shows-open-work` 의 S4·S6 을 구현해요. 운영자가 2026-09-28 에 이미 정했어요(5.3).
  - L4: `RFC-at-name-resolves-to-declared-recipient` 의 L3 를 구현해요. Active 인 RFC 의 남은 단계예요(5.4).
- **[사실]** L2a 배포 뒤 판정 없이 선 제출은 2026-11-12 12:59Z 에 17개, 13:59Z 에 18개예요(기대 10). 가장 큰 몫(8)은 공용 목록 읽기 실패예요(8절). **[추정]** 그 가운데 `changed` 5개는 같은 스코프의 다른 레코드가 진행을 쓴 사이에 깨진 것이에요(5.2 L2c).
  - **[제안]** L2c: 목록 읽기는 레코드의 신원만 대조하고, 진행 값은 지금 읽은 레코드를 따라요(5.2).
- 새 상태, 새 저장소, 새 Gate 는 없어요. L1 이 문자열 `Error` 로 나가던 결과 셋을 닫힌 합의 갈래로 옮겨요.
- 사용자가 정할 것은 10절에 있어요. 1·2·4·5번은 2026-11-12 에 정했고 3번이 남았어요.

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
| #41311 | 공식 클라이언트 칸의 검증이 900초에 잘린다 | 아님, 닫음 | 공식 클라이언트 시도는 진행 감시자를 거치지 않고, 네 runtime 은 조용한 시간만 잰다. 8일 로그(11-04~11-11)에 그 칸이 900초에 잘린 줄은 없다 **[사실]** |

### 1.2 지금 멈춘 곳 둘

**Board 판정 정산.** **[사실]** 2026-11-12 01:3x KST 에 운영 설치를 읽기만 해서 셌어요.

- `board_attention_partitions/*.jsonl` 19개 파일의 partition 463개: `settled` 97, `completed` 362, `abandoned` 2, `blocked` 1, `running` 1.
- `completed` 362개는 모두 한 Keeper 것이에요. 판정은 `relevant` 361, `not_relevant` 1. 가장 오래된 `completed_at` 이 11-09 05:02Z, 가장 새것이 11-11 16:08Z 예요. 다른 Keeper 18명은 `completed` 가 0개예요.
- 시스템 로그에서 `judgment conflicts with worker result` 가 든 줄이 11-09 208, 11-10 320, 11-11 165 로 693줄이에요. 모두 같은 후보 하나예요. 그중 692줄이 `Board attention completion remains pending; it did not block this Keeper turn` 줄이고, 첫 줄이 11-09T05:02:59Z, 마지막이 11-11T16:29:59Z 예요.
- 그 후보는 원장에서 `consumed`, partition 에서 `completed` 예요. 두 판정 모두 `not_relevant` 이고 source 가 `vendor_system_one` 이에요. 요청 해시와 판정 시각(1.23초 차이)이 달라요.
- 02:3x KST 에 다시 세니 `completed` 가 363개(`relevant` 362)였어요. 설치 전체에서, 후보가 이미 다른 판정으로 소비된 `completed` partition 은 이 하나예요.
- 13:0x KST 에 다시 세니 `completed` 가 394개였어요. 그 Keeper 것이 382개예요. 나머지 12개는 다른 Keeper 둘의 것(7개, 5개)이고 모두 `relevant` 예요.
  - 두 Keeper 는 provider 사용 한도로 쉬는 중이에요. 12개 모두 그 Keeper 의 마지막 턴이 끝난 뒤에 판정이 났어요. 두 Keeper 의 로그에는 마지막 턴 뒤로 정산 줄이 없어요.
  - **[추정]** 정산 호출은 턴을 내보내는 구간 안에 있어서(`keeper_heartbeat_loop.ml:987-1017`) Keeper 가 쉬는 동안에는 돌지 않는 것으로 보여요. 이 12개는 멈춘 것이 아니라 다음 턴을 기다리는 것이에요.
  - 그날 `judgment conflicts with worker result` 는 22줄이고, 모두 같은 Keeper 의 같은 후보예요.

**검증 대기.** **[사실]** 같은 시각에 셌어요.

- `tasks/backlog.json` 의 Task 1,458개 중 `awaiting_verification` 19개.
- 19개 모두 `verification-runs.jsonl` 의 마지막 결과가 판정이 아니에요. `execution_repair_required` 18(세부: "original execution lost its writer without a terminal settlement" 8, "original executions have no retained verdict" 8, 그 밖 2), `raised` 1.
- 제출 뒤 지난 시간은 최소 6, 중앙값 124, 최대 208시간이에요.
- 같은 파일에 남은 창(11-10 05:13Z 부터)에서 검증 64건의 마지막 결과는 `approved` 26, `rejected` 18, `execution_repair_required` 19, `raised` 1 이에요.

**검증 대기의 원인.** **[사실]** 2026-11-12 11:3x KST 에 다시 세고, 멈춘 제출마다 처음 멈춘 순간을 서버 로그(78개, 11-04 19:13 ~ 11-12 KST)와 리뷰 실행 기록에서 찾았어요. 읽기만 했어요.

- `awaiting_verification` 은 20개였어요. 1개는 판정이 돌고 있었고 19개가 멈춰 있었어요.
- 멈춘 19개의 마지막 문구와, 처음 멈춘 순간에 일어난 일이에요.

| 마지막 문구 | 수 | 처음 멈춘 순간 |
|---|---|---|
| `original execution lost its writer without a terminal settlement` | 8 | 3건: 리뷰를 예약하고 3분 뒤 서버가 SIGTERM 을 받았다(종료 한도 10초). 로그는 9초 뒤 종료 2단계에서 끝나고 3~5단계 줄이 없다. 그 실행 기록에는 끝이 없다. 5건: 로그 창보다 먼저 예약됐고, 창의 첫 시작 sweep 에서 이 문구로 처음 보인다. 8건의 마지막 시도에서 6건은 첫 칸이 사용 한도로 실패한 뒤 둘째 칸의 실행 기록에 끝이 없고, 2건은 첫 칸의 실행 기록에 끝이 없다 |
| `original executions have no retained verdict` | 8 | 8건 모두 마지막 시도의 실행 기록이 둘이다. 첫 검증 칸은 사용 한도 초과(다시 열리기까지 1.6~5일)로 실패했고, 둘째 칸은 연결 끊김(`end_of_file`) 5, 호출 시한 900초 2, DNS 실패 1 로 실패했다. 7건은 로그로도 확인했다. 1건은 로그 창보다 먼저 예약됐다 |
| `original report history cannot establish one accepted verdict` | 1 | 리뷰어가 `report_review_verdict` 를 불러 정산까지 됐고, 그다음 provider 호출이 연결 끊김으로 실패했다 |
| `original execution has an unsettled effect` | 1 | 원인을 가르지 못했다 |
| `raised`: `retained subject or lookup authority differs` | 1 | 원인을 가르지 못했다 |

- 같은 로그 창에 서버 시작 로그가 78개 있어요. 하루 10번꼴이에요. 멈춘 제출은 서버가 시작할 때마다 다시 관측되고 같은 결과로 다시 적혀요. 로그에 `requires original reconciliation` 줄이 1,124줄 있어요.
- 리뷰 실행 기록(`verifier-executions` 아래 `events.v1.wal`) 959개를 읽었어요. 이벤트 종류, 노드가 어떻게 닫혔는지, 실패로 닫힌 노드의 오류 글만 봤어요. 리뷰 내용(프롬프트, 응답, 도구 결과)은 읽지 않았어요.

| 실행의 끝 | `report_review_verdict` 호출 | 실행 기록 수 |
|---|---|---|
| 성공 | 1개, 정산됨 | 647 |
| 실패 | 없음 | 219 |
| 끝이 없음(writer 가 사라짐) | 없음 | 52 |
| 취소 | 없음 | 31 |
| 실패 | 1개, 정산됨 | 3 |
| 취소 | 1개, 정산됨 | 3 |
| 끝이 없음(writer 가 사라짐) | 1개, 정산됨 | 3 |
| 성공 | 없음 | 1 |

- 판정 보고 호출 노드는 정산 여부와 상관없이 셌어요. 보고 호출이 둘 이상인 실행 기록은 0개예요. 정산되지 않은 보고 호출이 있는 실행 기록도 0개예요.
  - 응답이 요청했는데 호출 노드가 열리지 않은 보고는 이 셈에 들어 있지 않아요. 구현은 그것도 세요(5.2 의 규칙 3).
- 실패로 끝나고 판정 보고가 없는 219개를 오류 글로 가르면 사용 한도 205, 연결 끊김 10, DNS 실패 2, timeout 2 예요.
  - 사용 한도는 코드가 확정된 거절로 분류하는 실패예요. provider 가 풀리는 시각을 밝혔으면 지금도 그 시각 뒤에 다시 돌아요(3.2).
  - 결과를 모르는 실패로 끝난 실행 기록은 14개예요. 14개 모두 코드가 다시 해 볼 실패(`Reviews_again`)로 분류하는 종류예요. 한 시도에 결과 모름이 하나라도 있으면 그 시도의 실행 기록을 모두 다시 읽어요(3.2).
  - timeout 2개는 호출 시한(`call_timeout_s`, 900초)을 넘겨 실패로 닫혔어요. 하나는 provider 입장 허가를 기다리다가, 하나는 응답을 받다가 넘겼어요.
  - 멈춘 19건의 마지막 시도가 남긴 실행 기록은 따로 읽었어요(위 표). 판정 보고가 없는 실패 기록 가운데 취소로 닫힌 것은 없어요.
- 보고 없이 취소된 31개의 취소 사유는 서버의 graceful shutdown 이 24개, `Fiber.Not_first` 가 7개예요.
- 같은 로그 창에 리뷰가 예약된 제출(`verification_id`)은 288개(Task 193개)예요. `requires original reconciliation` 으로 한 번이라도 멈춘 제출은 35개예요. 그중 18개가 지금도 그 Task 의 현재 제출이에요.

### 1.3 Task 가 집히는 길

**[사실]** `events/2026-11/05~11.jsonl` 에서 `task_claim`(id 를 골라 집음) 153건, `task_claim_next`(다음 것을 달라고 함) 4건이에요. **[조사]** 그 4건은 모두 같은 Task 하나로 갔고 매번 1~76분 안에 반납됐어요. 그 Task 는 27번 반납됐어요. Keeper 프롬프트가 보여 주는 할 일 목록의 앞 7행은 2026-09-07~09-29 에 만든 P1 이고, 행에는 `task_id` 만 있어요.

## 2. 문제

아홉 이슈는 넘기는 것이 서로 달라요. 판정, 검증 요청, Board 판정, Task, 운영자 요청이에요. 끊기는 자리는 같아요.

| 넘기는 것 | 넘긴 쪽이 남기는 것 | 받는 쪽에 닿았는지 읽는 곳 | 끊긴 자리 |
|---|---|---|---|
| 리뷰 판정 → GitHub (#42017) | 턴의 마지막 글 | 없음. 게시된 리뷰만 서버가 읽는다 | 판정을 냈는데 게시 시도가 0번이라는 사실이 글로만 남는다 |
| 리뷰할 PR → 리뷰어 (#46691) | GitHub 의 요청 목록 | 서버가 `unreviewed_on_head` 를 계산하지만 턴에 싣지 않는다 | consumer → caller |
| 검증 요청 → 판정 (#39677) | `verification-runs.jsonl` 의 멈춤 행, WARN 한 줄 | 대시보드 검증 화면뿐. 제출자 큐와 운영자 attention 은 읽지 않는다 | 실행 기록이 확정한 것까지 수리로 분류한다. 남는 것은 consumer → caller |
| 승인 → 산출물 (#26914) | `Done` | 없음 | 승인한 대상이 남았는지 기록하지 않는다 |
| Board 판정 → Keeper 큐 (#38068) | partition `Completed` | owner 의 정산 걸음 | 한 건이 실패하면 뒤가 모두 멈추거나, 못 찾으면 전달 없이 `Settled` 가 된다 |
| 글 → 받는 사람 (#46747) | 저장된 메시지 | 브로드캐스트 응답 | 저장되고 전달된 뒤에 `ok:false` 로 답한다 |
| Task → 할 Keeper (#41343) | `Todo` | 모든 Keeper 가 같은 `task_id` 목록을 본다 | 어느 문맥에도 "이 일은 네 것"이 없다 |
| 운영자 요청 → 일 (#45003) | 작업 `Failed` | 고정 문장 한 줄 | 요청이 일을 하나도 만들지 못했다는 사실이 없다 |

두 꼴로 나뉘어요.

- **조용히 넘어간다.** 받는 쪽 기록 없이 상태가 앞으로 가요. `Candidate_absent` 정산(#38068), 커밋 안 된 산출물의 `Done`(#26914), 고정 문장으로 끝난 `Failed`(#45003).
- **조용히 멈춘다.** 멈춘 사실이 로그와 기록 파일에만 있고, 움직일 수 있는 쪽이 읽지 않아요. Board 362건, 검증 19건, todo 456개, 게시되지 않은 판정.

**[사실]** 헌법(`docs/constitution.xml`)은 첫째 꼴을 이미 금지해요. `failure_keeps_evidence` 는 "전달 실패는 증거를 남기고 대상을 소비하지 않는다. 실패가 상태를 조용히 진행시키지 않는다"예요. 둘째 꼴을 가리키는 조항은 찾지 못했어요(`stall`, `정체`, `멈춤`, `가시`, `projection` 으로 찾았어요). 증거는 남았고 상태도 그대로라서 적힌 불변식은 깨지지 않아요. 그런데 실패 조건 "여러 Keeper 가 자기들끼리 커뮤니케이션하지 않는다"가 실제로 일어나는 곳은 둘째 꼴이에요.

## 3. 지금 코드가 하는 일

L1 과 L2 가 고치는 자리만 적어요.

### 3.1 Board 판정 정산

- **[사실]** owner 의 heartbeat 가 `Keeper_board_attention_worker.settle_completed_snapshot` 을 불러요(`keeper_heartbeat_loop.ml:1017`). 실패하면 `remains pending; it did not block this Keeper turn` 을 로그에 쓰고 턴은 계속해요(`:1025`).
- **[사실]** `settle_completed_snapshot` 은 `completed_in_order` 가 준 목록을 `let* settled = settle_head partition` 으로 걸어요(`keeper_board_attention_worker.ml:1951` 부터). 첫 `Error` 에서 걸음 전체가 끝나요. 다음 heartbeat 는 같은 순서의 같은 맨 앞에서 다시 멈춰요.
- **[사실]** `settle_head` 가 부르는 `deliver_and_settle_completed`(`:818`)는 `Candidate.apply_judgment_and_deliver` 의 결과를 받아요. 결과 타입은 `Delivered of candidate | Candidate_absent` 둘이에요(`keeper_board_attention_candidate.ml:1175`). `Candidate_absent` 면 error 로그를 쓰고 `Partition.settle` 을 불러요.
- **[사실]** `apply_judgment_and_deliver` 는 후보가 이미 `Judged` 나 `Consumed` 인데 판정이 다르면 `Error "… judgment conflicts with worker result: <id>"` 를 문자열로 돌려줘요(`:1210-1213`). `same_judgment` 은 verdict, slot_id, source, judged_at 이 모두 같아야 참이에요(`:648`). 주석은 이 실패를 "조용히 풀지 말고 계속 크게 알릴 버그"라고 적어요.
- **[조사]** `load_candidates` 는 디코더가 거절한 행을 개수만 세고 목록에서 빼요. 그래서 못 읽은 행이 가린 후보는 `find_candidate` 에서 `None` 이 되고 `Candidate_absent` 로 정산돼요(#38068). `Partition.settled_receipt_gate` 는 같은 거절 행을 `load_candidates_with_rejections` 로 읽고 "숨은 후보가 살아 있을 수 있다"며 영수증을 남겨요. 같은 사실을 두 곳이 다르게 읽어요.
- **[사실]** 1.2 의 충돌은 worker 의 exact flow 와 event fanout(`keeper_board_attention_fanout.ml`, #40521)이 같은 후보를 따로 판정해서 생겼어요. 그 Keeper 의 로그 순서예요(2026-11-09 05:02:52~55Z).
  1. worker: `exact_flow.execute terminal … outcome=judgment_completed jev=not_relevant`
  2. worker: `board_attention_settled_receipts_pruned … removed=1`
  3. fanout: `board_attention_event_fanout candidates=10 … outcome=answered`
  4. fanout: `… judgment conflicts with worker result`
  5. fanout: `partition is not Running`(`release` 가 부른 `Partition.defer`)
- **[사실]** 코드로 따라가면 이래요.
  - worker 가 판정 A 로 partition 을 `Completed` 로 만들어요. `not_relevant` 라서 `settle_if_not_relevant` 가 후보를 `Consumed` 로 적고 partition 을 `Settled` 로 만들어요.
  - worker 의 다음 걸음이 `Partition.prune_settled_receipts` 를 불러요(`keeper_board_attention_worker.ml:1691`). 후보가 `Consumed` 인 `Settled` 영수증은 지워져요(`settled_receipt_gate`, `keeper_board_attention_partition.ml:923`).
  - 그 뒤에 fanout 의 `claim` 이 `Partition.ensure_roots ~base_path ~keeper_name [candidate]` 를 불러요(`keeper_board_attention_fanout.ml:19`). 이 `candidate` 는 Board 사건을 보낼 때 받은 값이라 아직 `Pending` 이에요. `ensure_roots` 는 받은 목록을 다시 읽지 않아요(`keeper_board_attention_partition.ml:888`).
  - 영수증도 live owner 도 없으니 `Ready` root 가 새로 생겨요. fanout 이 그것을 집어 판정 B 를 받고 `Completed` 로 만든 뒤 `apply_judgment_and_deliver` 를 불러요(`keeper_board_attention_fanout.ml:63`). 원장의 후보는 이미 A 로 `Consumed` 라서 충돌이에요. partition 은 B 를 든 `Completed` 로 남아요.
- **[사실]** 운영 설치의 그 후보가 이 모양이에요. 원장은 `consumed`(판정 05:02:52.04Z, 소비 05:02:52.33Z)이고 partition 은 generation 2 의 `completed`(판정 05:02:53.27Z)예요. generation 2 는 새로 만든 root 가 `Running`, `Completed` 로 두 번 넘어간 값이에요.
- **[사실]** worker 는 이 위험을 알고 피해요. `prunes_and_read` 의 주석(`keeper_board_attention_worker.ml:1703-1710`)이 "prune 전에 읽은 목록으로 `ensure_roots` 를 부르면 영수증이 지워진 후보에 새 `Ready` root 가 생긴다"고 적고, 그래서 후보 목록을 두 prune 뒤에 읽어요. 이 순서를 지키는 것은 worker 의 읽는 자리뿐이에요. fanout 은 다른 fiber 에서 prune 전의 값을 들고 와요.
- **[사실]** `ensure_roots` 를 부르는 곳은 셋이에요(fanout `:19`, worker `:1505`, `:1728`). 잠금 안에서 후보를 다시 읽는 `ensure_current_roots`(`keeper_board_attention_partition.ml:892`)를 부르는 곳은 quarantine 명령 하나예요.
- **[사실]** 8일 로그(2026-11-04~11-11)에서 fanout 의 이 충돌 경고는 3번 났어요. 11-05 06:05:24Z 에 후보 둘, 11-09 05:02:53Z 에 후보 하나예요. 세 후보 모두 owner 의 정산이 같은 후보에서 실패했어요. 11-05 의 둘은 owner 쪽 실패 로그가 한 줄씩이고 그 뒤로 없어요.
- **[조사]** 11-05 에 같은 충돌 두 건은 Consumed 행이 prune 으로 지워지면서 `Candidate_absent` 정산으로 풀렸어요. #48804(11-06)가 열린 partition 의 Consumed 행을 지우지 않게 한 뒤로는 그 길이 없어요. #48804 는 맞는 수리예요. 충돌이 우연히 풀리던 길이 같이 닫혔을 뿐이에요.

### 3.2 검증 멈춤

- **[사실]** `Completion_authority_agent.retry_request_of_stop_cause` 는 `Execution_repair_required`, `Infrastructure_unavailable`, `Commit_failed`, `Raised`, 그리고 다시 볼 runtime 이 없는 `Not_reviewed` 에 `No_retry_requested` 를 줘요(`completion_authority_agent.ml:653-658`). 주석은 "다음 수는 producer, 운영자, backlog 전체 sweep 에 남긴다"예요.
- **[사실]** `Operator_task_attention.project` 는 `AwaitingVerification` 을 빼요. 주석은 "완료는 system authority 를 기다리고, 그것은 돌고 있다"예요(`operator_task_attention.ml:72-74`). 멈춘 검증에는 이 전제가 맞지 않아요.
- **[사실]** 멈춘 사실은 두 곳에만 적혀요. `announce_stall` 의 WARN 로그 한 줄(`completion_authority_agent.ml:777-779`)과 `Verification_run_registry` 의 완료 행(`verification-runs.jsonl`)이에요. **[조사]** #47927 이 검증 정체를 알리던 Board 글을 지웠어요.
- **[사실]** 그 원장은 끝난 행을 최근 64개만 남겨요(`verification_run_registry.ml:159` 의 `completed_retention`, `run_registry_core.ml` 의 `prune`). 멈춘 제출의 행은 새 리뷰 64건이 끝나면 밀려나요. 지금 남아 있는 것은 서버가 시작할 때마다 sweep 이 다시 적기 때문이에요. 그래서 이 원장은 "멈춘 제출 목록"의 출처가 될 수 없어요. `RFC-task-lifecycle-a-verdict-assigns-no-work` 3.7 이 같은 것을 먼저 적었어요.
- **[사실]** 제출한 Keeper 의 프롬프트는 그 Task 를 `awaiting verification (submitted …)` 한 줄로 보여 줘요(`keeper_unified_prompt.ml:442-445`, `config/prompts/keeper.md` 의 `world.current_task.status.awaiting_verification`). 리뷰가 멈췄는지는 싣지 않아요.
- **[사실]** 멈춘 제출을 움직이는 길은 셋이에요.
  - 제출한 쪽이 다시 제출해요. 새 `verification_id` 가 붙고 리뷰가 첫 시도부터 다시 돌아요(`workspace_task_lifecycle.ml:190-212`).
  - 제출한 쪽이 취소해요(같은 파일의 `Cancel` 갈래).
  - 운영자가 판정을 직접 내리거나 취소해요. 판정은 `POST /api/v1/verification/verdict`(`server_routes_http_routes_verification.ml:445`), 취소는 `POST /api/v1/dashboard/tasks/cancel`(`:425`)이에요.
  - 멈춘 리뷰를 다시 돌리게 하는 운영자 도구는 찾지 못했어요. **[조사]** `masc_operator_task_recovery_resolve` 는 `AwaitingVerification` 을 거절해요.
- **[사실]** 수리 필요는 `Verifier_review_execution.observe_call` 과 `observe` 가 정해요(`verifier_review_execution.ml:99-176`). 실행 기록에서 실행의 끝과 `report_review_verdict` 호출을 읽어요.

| 실행의 끝 | 판정 보고 호출 | 지금 결과 |
|---|---|---|
| 성공, 취소 | 1개, 성공으로 정산 | 그 판정 |
| 취소 | 없음 | 다음 시도(#49097) |
| 실패, 성공 | 없음 | 판정을 낸 호출도 취소된 호출도 없으면 수리 필요: `original executions have no retained verdict` |
| 실패 | 1개, 성공으로 정산 | 수리 필요: `original report history cannot establish one accepted verdict` |
| 끝이 없고 writer 가 없음 | 읽지 않는다 | 수리 필요: `original execution lost its writer …` |
| 어느 끝이든, 시도가 시작됐는데 결과가 없는 도구 호출이 있음 | 읽지 않는다 | 수리 필요: `original execution has an unsettled effect` |
| 공식 클라이언트 세션 | 읽지 않는다 | 수리 필요: `original official-client session requires operator reconciliation` |

- **[사실]** 서버가 살아 있을 때도 같은 표를 타요. provider 호출이 "결과를 모름"으로 실패하면(`Attempt_failed` 의 `Outcome_unknown`) `Verifier_review_worker.run_attempt_with` 는 리뷰가 끝난 뒤 `observe_pending` 으로 실행 기록을 다시 읽어요. 1.2 의 연결 끊김, 호출 시한 900초, DNS 실패가 이 길로 갔어요. 로그는 그 호출을 `retryable=false; no verdict committed` 로 적어요.
- **[사실]** 실패는 두 값으로 분류돼요(`lib/task/anti_rationalization.ml`).
  - 하나는 결과의 확실성이에요(`failure_certainty`). 보내기 전, 확정된 거절, 결과 모름 셋이에요. 연결 오류와 timeout 은 결과 모름이고, 사용 한도와 5xx 는 확정된 거절이에요.
  - 다른 하나는 다시 볼지예요(`candidate_failure`). `Reviews_again`, `Model_absent`, `Producer_must_act` 셋이에요. 연결 끊김, DNS 실패, timeout 은 `Reviews_again` 이에요. 설정 오류, 응답 해석 실패, 내부 오류는 `Producer_must_act` 예요.
  - 헌법은 둘째 값이 자동 재시도를 이어 갈지 정한다고 적어요(`docs/constitution.xml` 의 `AwaitingVerification` invariant). 횟수 상한은 없고 간격은 maintenance pulse 로 고정이에요.
- **[사실]** 결과 모름이면 walk 는 남은 칸으로 넘어가지 않고, 그 실패의 둘째 값도 버려요(`anti_rationalization.ml` 의 `must_preserve_original`). 저장되는 근거(`verifier_review_unknown/v1`)에는 다시 볼 runtime 이 비어 있어요. 그래서 `Reviews_again` 인 연결 끊김도 멈춰요.
- **[사실]** 판정 보고를 셀 때는 정산된 호출만 세요(`agent_execution_projection.ml:791`). 시도가 시작되지 않은 호출은 수리로도 가지 않아요(`execution_agent_scope.ml:857-868`). 두 번째 보고 호출이 시도되기 전에 실행이 끊기면 그 호출은 보이지 않아요. 살아 있는 서버라면 보고 둘은 규칙 위반이에요(`anti_rationalization.ml` 의 `step_verdict_call`).
- **[사실]** 살아 있는 서버의 walk 는 보고가 정산된 뒤 그 실행이 실패하면 그 판정을 버려요(`workspace_metric_hooks.ml` 의 `Error err` 갈래). 판정 보고 핸들러는 메모리에만 적고 Task 는 바꾸지 않아요.
- **[사실]** 검증 정책 문서는 지금 규칙을 이렇게 적어요(`docs/verification-pipeline-policy.md` 4절). 불확실하면 다음 시도를 만들지 않아요. 성공으로 끝난 실행의 정산된 판정 보고 하나만 되살려요. 둘째 문장은 #49097 뒤의 코드보다 좁아요.
- **[사실]** 같은 뿌리를 고친 PR 이 둘 있어요.
  - #47278(11-01)은 writer 가 사라진 실행을 "기다림"에서 "운영자 수리"로 옮겼어요. 본문은 "replay 나 자동 재시도 없이 실행 기록과 모르는 효과를 남긴다"예요.
  - #49097(11-06)은 취소로 끝나고 판정 보고가 없는 실행만 다음 시도로 넘겼어요. 본문은 실패로 끝난 실행을 그대로 둔 이유를 "같은 요청을 다시 해도 결과가 같을 것"이라고 적었어요. 1.2 에서 이 길로 온 실패 14개는 그 전제와 달라요. 모두 코드가 다시 해 볼 실패로 분류하는 종류예요.
- **[사실]** 리뷰 실행 959개가 부른 도구는 일곱 가지예요. `masc_web_fetch`, `tool_read_file`, `tool_search_files`, `masc_board_post_get`, `keeper_tasks_list`, `masc_fusion_status`, `report_review_verdict` 예요. 앞의 여섯은 리뷰어에게 주는 조회 도구의 닫힌 목록이고(`verification_authority_tools.ml:7-22`) 읽기만 해요.
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
| #38068, 362건 | root 를 만들 때 후보를 잠금 안에서 다시 읽는다. 판정 전달 결과를 닫힌 합으로 낸다. 정산 걸음이 후보 단위로 결과를 받는다 | 맞다. 지금은 낡은 값으로 root 가 다시 생기고, "전달됐다"와 "못 읽었다"가 같은 `Settled` 로 섞인다 |
| #39677 | 글 전용 칸으로 갈 때 이미지 블록을 벗기고 참조 줄만 남긴다. `InvalidConfig` 라는 틀린 상태가 생기지 않는다 | 맞다. 어긋난 두 약속 중 하나를 지운다 |
| #39677, 19건 | 리뷰 실행이 남긴 기록에서 판정을 한 규칙으로 읽는다. 판정 보고 호출이 하나이고 성공으로 정산됐으면 그 판정이다. 보고 호출이 없으면 그 시도는 확정된 거절이 된다. 걸음이 결론을 남겼으면 실패의 typed 판정이 다시 돌지 정하고, 남기지 못했으면 다음 시도로 간다 | 맞다. 지금은 실행의 끝마다 따로 고쳤고(#49097 은 취소만), 결과를 모르는 실패는 typed 판정을 버린 채 멈춘다 |
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
| #39677, 19건 | 판정을 기다리는 제출을 운영자 attention 에 싣는다 | 단독으로는 맞지 않다. 19건 중 17건은 잠깐의 장애가 굳은 것이라, 이것만 하면 "보이게만 하기"다. 좌를 한 뒤에 남는 것에는 맞다 |
| #38068 | 정산 근거와 못 읽은 행 수를 화면에 싣는다 | 단독으로는 맞지 않다. 전달 손실이 그대로라 "보이게만 하기"다 |
| #45003 | 실패 행에 닫힌 사유 variant 를 싣는다 | 맞다 |

### 4.4 고른 조합

| 층 | 방향 | 고른 이유 |
|---|---|---|
| L1 Board 정산 | 좌 | 지금 손실이 나는 곳이다. 보이게만 해서는 361건이 전달되지 않는다 |
| L2 검증 멈춤 | 좌 + 우 | 멈춘 19건 중 17건은 실행 기록이 판정을 갖고 있거나 판정이 없다는 것을 확정한다. 그것은 시스템이 잇는다(좌). 사람이 풀어야 하는 나머지는 운영자 목록에 싣는다(우) |
| L3 World State S4·S6 | 우 | 설계와 운영자 결정이 끝났다. 리뷰와 Task 두 이슈의 끊긴 자리가 consumer → caller 다 |
| L4 at-name L3 | 좌 | Active RFC 의 남은 단계다 |

**[제안]** #46691 의 좌(Keeper 별 GitHub 신원)는 지금 하지 않아요. Ready PR 114개가 모두 현재 head 에 리뷰를 받았어요. L3 뒤에 다시 재요(10절).

## 5. 층별 내용

### 5.1 L1 — Board 판정 정산

두 걸음이에요. L1a 가 충돌이 생기는 길을 닫고, L1b 가 남은 한 건이 다른 건을 막지 않게 해요.

#### L1a — 낡은 후보 값으로 root 를 만들지 않는다

**[제안]** fanout 의 `claim` 은 partition 잠금 안에서 후보를 다시 읽고 root 를 만들어요. `ensure_current_roots` 가 이미 그렇게 해요.

- 후보가 `Consumed` 가 된 뒤면 받은 값과 원장의 값이 달라서 root 를 만들지 않아요.
- 영수증 prune 과 이 읽기는 같은 잠금 안에서 일어나요. 후보는 `Consumed` 에서 `Pending` 으로 돌아가지 않아요. 그래서 "영수증은 지워졌는데 후보는 `Pending` 으로 읽히는" 틈이 없어요.
- 지금 `ensure_current_roots` 는 후보가 바뀐 것을 문자열 `Error` 로 돌려줘요. fanout 에서는 worker 가 먼저 끝낸 흔한 경우예요. 그래서 닫힌 결과로 받아요.

```ocaml
type root_restoration =
  | Roots_ensured of int
  | Candidates_changed   (* 받은 후보가 지금 원장의 후보와 다르다 *)
```

- fanout 은 `Candidates_changed` 면 그 후보를 건너뛰어요. 경고를 내지 않아요. quarantine 명령은 지금처럼 실패로 다뤄요.
- **[제안]** 스냅숏을 그대로 믿는 `ensure_roots` 는 prune 뒤에 읽은 값만 받게 해요. worker 의 `prunes_and_read` 가 돌려주는 목록을 `Partition` 이 만드는 추상 타입으로 감싸고, `ensure_roots` 가 그 타입만 받아요. prune 전에 읽은 목록으로 root 를 만드는 코드는 컴파일되지 않아요. 호출처를 하나씩 고치는 것이 아니라 틀린 호출을 쓸 수 없게 하는 쪽이에요.
- **[확인 필요]** `reconcile_quarantines` 는 prune 없이 후보를 읽고 바로 `ensure_roots` 를 불러요(`keeper_board_attention_worker.ml:1503-1505`). 같은 worker fiber 안이라 지금은 틈이 없다고 읽었어요. 타입을 바꾸면 이 자리도 같은 함수를 거치게 돼요.

**시험.** worker 의 기존 seam(`before_receipt_prune`)으로 순서를 만들어요. worker 가 정산하고 영수증을 지운 뒤 fanout 이 `Pending` 인 옛 값으로 `claim` 을 불러요. root 가 생기지 않고 Jev 호출이 0번이어야 해요. 지금 main 에서는 root 가 생기고 충돌 경고가 나요.

#### L1b — 정산은 후보 단위로 결과를 받는다

**[제안]** `judgment_delivery_outcome` 에 갈래 둘을 더해요.

```ocaml
type judgment_delivery_outcome =
  | Delivered of candidate
  | Candidate_absent            (* 거절 행이 0인 원장에서만 *)
  | Candidate_unreadable of { rejected_rows : int }
  | Judgment_conflict of { recorded : judgment; offered : judgment }
```

- `Candidate_absent` 는 `load_candidates_with_rejections` 가 거절 0을 돌려준 원장에서만 만들어요.
- 거절 행에서 `candidate_id` 를 읽을 수 있으면 그 id 를 찾을 때만 `Candidate_unreadable` 이에요. id 도 읽지 못한 행이 있으면 찾지 못한 후보는 모두 `Candidate_unreadable` 이에요. 닫힌 PR #38041 은 깨진 줄 하나로 오래된 후보를 모두 붙잡았어요. id 를 읽을 수 있는 거절 행까지 원장 전체를 막으면 같은 일이 생겨요.
- `Judgment_conflict` 는 지금 문자열 `Error` 인 갈래예요. 값이 되면 부르는 쪽이 `match` 에서 반드시 다뤄요. L1a 뒤에는 3.1 의 경합으로는 생기지 않아요. 이미 기록된 한 건과, 아직 모르는 다른 길이 있으면 그것이 여기로 와요.
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
- 한 건을 건너뛰어도 새로 깨지는 순서 약속은 없어요. **[사실]** 정산 걸음은 partition 사이에 넘기는 상태가 없어요. `settle_snapshot` 이 들고 다니는 것은 돌려줄 값(마지막으로 정산한 partition)뿐이에요. 한 건의 전달은 `candidate_id` 를 event id 로 하는 `enqueue_if_missing_durable_result` 한 번이에요(`keeper_board_attention_candidate.ml:1116`). Keeper 큐는 넣은 순서대로 꺼내는 FIFO 예요(`lib/keeper_runtime/keeper_event_queue.mli:418`).
- **[사실]** 지금도 Board 사건 순서대로 들어가지 않아요. `not_relevant` 는 worker 가 owner 를 기다리지 않고 따로 정산해요(`settle_if_not_relevant`). partition 은 판정이 끝난 순서대로 `Completed` 가 되고, owner 는 heartbeat 때 `Completed` 인 것만 `created_at` 순으로 걸어요. 순서를 약속한 문서나 주석은 찾지 못했어요.
- `settle_if_not_relevant`(`:858`)도 같은 결과 타입을 받아요. 네 갈래를 모두 적어요.

**하지 않는 것.** verdict 가 같으면 같은 판정으로 치는 비교는 넣지 않아요. `same_judgment` 을 느슨하게 하면 `relevant` 와 `not_relevant` 가 갈리는 충돌도 같은 길로 지나가요. 충돌은 L1a 가 생기지 않게 하고, 생긴 것은 값으로 남겨요.

**시험.**
- 맨 앞 partition 이 `Judgment_conflict` 이고 뒤에 `relevant` 둘이 있는 fixture: 뒤 둘이 Keeper 큐에 들어가고 `Settled` 가 된다. 맨 앞은 `Completed` 로 남는다.
- 거절 행 하나가 든 원장에서 그 id 를 찾으면 `Candidate_unreadable` 이고 `Settled` 가 되지 않는다.
- 원장 읽기를 `Error` 로 만들면 뒤 partition 을 건드리지 않는다.

### 5.2 L2 — 멈춘 검증

#### L2a — 실행 기록이 확정한 것은 시스템이 잇는다

**[제안]** 끊긴 리뷰 시도를 다시 읽는 규칙을 고쳐요. 재시도 규칙을 새로 만들지 않아요. 한 문장으로는 이래요. walk 가 결론을 남겼으면 그 결론을 따르고, 남기지 못했으면 다시 걸어요.

walk 는 리뷰 한 번이 검증 칸을 차례로 도는 걸음이에요(`Anti_rationalization.review_rendered`). 한 시도는 칸마다 실행 기록을 하나씩 남겨요.

한 시도를 다시 읽는 순서예요.

1. 그 시도의 실행 기록을 모두 읽어요. 실행 기록이 하나도 없으면 수리 필요예요. 둘 다 지금과 같아요.
   - 보내려 했다는 기록 뒤, 첫 실행 기록이 저장되기 전에 프로세스가 끝난 시도도 여기 들어요. provider 를 부르기 전이라 다시 돌려도 되는 경우예요. 멈춘 19건에 없어서 이 글은 지금 동작을 그대로 둬요.
2. 시도가 시작됐는데 결과가 없는 도구 호출이 하나라도 있으면 수리 필요예요. 지금과 같아요.
3. 판정 보고(`report_review_verdict`) 호출을 시도 전체에서 세요. 정산된 보고와, 기록된 provider 응답이 요청한 보고 호출을 같이 봐요. 요청됐는데 정산되지 않은 보고는 핸들러가 시작되지 않은 것이에요.
   - 요청 수는 호출 노드가 아니라 기록된 응답에서 세요. 호출 노드는 그 도구를 돌리기 직전에 하나씩 열려요. 한 응답이 보고를 두 번 요청하고 첫 보고 직후에 끊기면 둘째 요청은 노드로 남지 않아요. 구현의 독립 리뷰가 찾았어요.
   - 정산된 보고가 정확히 하나이고, 성공으로 정산됐고, 요청된 보고도 그 하나뿐이면 그 판정이에요. 그 실행이 뒤에 어떻게 끝났는지는 판정을 바꾸지 않아요.
   - 정산된 보고가 있는데 위 경우가 아니면 수리 필요예요. 둘 이상이거나, 성공으로 정산되지 않았거나, 요청만 된 보고가 옆에 있는 경우예요.
   - 정산된 보고가 하나도 없으면 판정은 적히지 않았어요. 요청만 된 보고가 있는 경우도 여기 들어요. 핸들러가 돌지 않아서 적힌 것이 없어요.
     - **구현하며 고쳤어요.** 처음 글은 이 경우도 수리로 적었어요. 지금 코드는 취소된 시도에서 이 경우를 다음 시도로 보내요. 수리로 바꾸면 그 길이 막혀요.
4. 정산된 보고가 없으면 "이 시도는 판정을 내지 않았다"가 확정돼요. 실행이 성공으로 끝났든(리뷰어가 보고 없이 턴을 끝낸 것) 실패, 취소, writer 유실로 끝났든 같아요. 결과를 모르던 시도는 확정된 거절이 돼요. 다시 돌지는 walk 가 남긴 것이 정해요.
   - **구현하며 고쳤어요.** 처음 글에는 "보고 없이 성공으로 끝난 실행이 있으면 수리 필요, 지금과 같다"는 규칙이 따로 있었어요. 틀렸어요. 지금 코드는 보고 없이 성공으로 끝난 실행 뒤에 취소된 실행이 있으면 다음 시도로 보내요. 살아 있는 walk 도 보고 없이 끝난 칸을 지나 다음 칸으로 가요. 그래서 그 규칙을 뺐어요.
   - walk 가 끝까지 가서 결과를 남겼으면, 그 결과에 실린 실패의 typed 판정(`candidate_failure`)이 정해요. `Reviews_again` 인 칸이 있으면 다음 시도로 가요. 없으면 지금처럼 멈춰요. 헌법의 `AwaitingVerification` invariant 그대로예요.
   - walk 가 결과를 남기지 못했으면 다음 시도로 가요. 취소됐거나 프로세스가 끝나서 걸음이 끊긴 경우예요. 취소는 지금도 이렇게 해요(#49097).
     - walk 가 끝났는데 결과를 저장하지 못한 경우도 여기 들어요. 저장이 실패했거나(`verifier_review_worker.ml:157-158`) 저장 도중에 취소된 경우예요(`:171-176`). 진행 이벤트로는 프로세스 종료와 가를 수 없어요. 그때 walk 가 계산한 typed 판정은 남지 않아서 그 시도는 한 번 다시 돌아요. 이것은 받아들여요.
     - **[추정]** 저장 장애가 이어지는 동안에는 되풀이되지 않아요. 다시 읽기도 같은 저장소에 거절과 다음 시도를 적어야 해서 오류로 멈춰요.
   - walk 결과에 typed 판정이 없으면 멈춰요. 지금 저장된 옛 근거가 이 경우예요.

| 시도가 남긴 것 | 실행 기록 | 지금 | 바꾼 뒤 | 지금 멈춘 19건 |
|---|---|---|---|---|
| walk 결과 없음(프로세스가 끝남) | 보고 없음, writer 유실 | 수리 필요 | 다음 시도 | 8 |
| walk 결과 없음(취소) | 보고 없음, 취소 | 다음 시도 | 그대로 | 0 |
| walk 결과: 결과 모름, typed 판정이 `Reviews_again` | 보고 없음 | 수리 필요 | 다음 시도 | 0. 배포 뒤에 생기는 것 |
| walk 결과: 결과 모름, typed 판정이 `Producer_must_act` 나 `Model_absent` | 보고 없음 | 수리 필요 | 멈춘다. 운영자 목록에 실린다(L2b) | 0. 배포 뒤에 생기는 것 |
| walk 결과: 결과 모름, typed 판정 없음(옛 근거) | 보고 없음 | 수리 필요 | 그대로 | 8 |
| 어느 것이든 | 성공으로 정산된 보고 1개 | 성공이나 취소로 끝난 실행만 그 판정. 나머지는 수리 필요 | 그 판정 | 1 |
| 어느 것이든 | 시도된 채 결과가 없는 도구 호출 | 수리 필요 | 그대로 | 1 |
| 어느 것이든 | 정산된 보고가 둘 이상이거나, 하나인데 성공으로 정산되지 않음 | 수리 필요 | 그대로 | 0 |
| 어느 것이든 | 정산된 보고 하나 옆에 요청만 된 보고 | 성공이나 취소로 끝난 실행이면 그 판정. 나머지는 수리 필요 | 수리 필요 | 0 |
| 위 줄들의 "보고 없음"과 같다 | 정산된 보고 없음, 요청만 된 보고가 있음 | 취소로 끝났으면 다음 시도. 나머지는 수리 필요 | 판정 없음으로 읽고 walk 가 남긴 것을 따른다 | 0 |
| walk 결과 없음 | 보고 없음, 성공으로 끝남 | 뒤에 취소된 실행이 있으면 다음 시도. 없으면 수리 필요 | 다음 시도 | 0 |

19건의 나머지 1건은 실행까지 가지 못했어요(`raised`, 권한 불일치). 이 규칙이 다루지 않아요.

**[사실]** 멈춘 19건의 마지막 시도가 남긴 진행 기록을 읽었어요(2026-11-12 13시, 읽기 전용).

- writer 유실 8건에는 walk 결과가 없어요. 진행 이벤트가 `dispatch_intended` 와 `waiting` 뿐이에요. 실행 기록은 2건이 하나, 6건이 둘이에요. 둘인 6건의 첫 실행 기록은 모두 사용 한도 실패로 닫혔어요. 성공으로 끝나고 보고가 없는 기록은 없어요. 8건 모두 규칙 4 로 가요.
- `no retained verdict` 8건과 보고 뒤에 실패한 1건에는 walk 결과(`verifier_review_unknown/v1`)가 있어요. 이 근거에는 `result` 만 있고 칸별 관측이 없어요(`verifier_review_worker.ml:138-139`).
- 정산 안 된 효과 1건에는 취소 처리(`verifier_review_worker.ml:176`)가 남긴 관측이 있어요.

**[사실]** 살아 있는 서버에서도 writer 유실이 생겨요. 그래서 규칙을 "writer 유실이면 다음 시도"로 적지 않았어요.

- 실행 정리(abort)가 실패하면 runner 는 끝을 적지 못한 채 `Error.Internal` 을 돌려줘요(`agent_execution_runner.ml:61` 의 `execution_failure`, `:205` 의 `abort_error`, `:224` 의 `settle_success`).
- walk 는 이 실패를 결과 모름으로 받아요. 그 칸이 쉬는 중이 아니면 typed 판정은 `Producer_must_act` 예요(`anti_rationalization.ml` 의 `failure_certainty` 와 `candidate_failure`).
- 이때는 walk 가 결과를 남겨요. 그 판정이 정하고, 다음 시도는 생기지 않아요.

그대로 두는 것이에요.

- walk 는 고치지 않아요. 다음 칸으로 갈지, walk 결과(`retryable_runtimes`)에 무엇을 적을지는 그대로예요. 같은 walk 를 쓰는 Goal 검증(`goal_criterion_agent.ml:117`, `:197`)은 바뀌지 않아요.
- 살아 있는 서버의 walk 는 보고가 정산된 뒤 그 실행이 확정된 거절로 실패하면 그 판정을 버리고 다음 칸에서 다시 리뷰해요(3.2). 그것도 그대로예요. 규칙 3 은 실행 기록을 다시 읽는 길에만 적용돼요. 다음 칸도 판정을 보고한 뒤에 걸음이 결론을 남기지 못하면, 다시 읽을 때 보고가 둘이라 수리 필요예요. 판정은 적히지 않고 운영자에게 가요.
  - 그래서 같은 기록이 서버가 끝난 때에 따라 갈려요. 첫 칸의 실행이 실패한 직후, 걸음이 결과를 저장하기 전에 서버가 끝나면 다시 읽는 쪽은 첫 칸의 판정을 읽어요. 서버가 살아 있었다면 다음 칸이 다시 리뷰했을 거예요. 어느 쪽이든 리뷰어가 실제로 보고한 판정이에요. 구현의 독립 리뷰가 다시 짚었고, 그대로 뒀어요.
- 시도가 시작되지 않은 도구 호출은 효과가 없어서 지금도 수리로 보내지 않아요(`execution_agent_scope.ml:857-868`). 판정 보고도 같아요. 정산된 보고 옆에 있을 때만 규칙 3 이 수리로 보내요.
- 공식 클라이언트 세션은 이 글이 다루지 않아요.

**[사실]** 판정이 둘 적히지 않는 근거예요.

- 한 시도는 판정과 거절을 둘 다 가질 수 없어요. `Judgment_retained` 와 `Refused` 는 둘 다 판정 대기 단계에서만 붙어요(`lane_addon_request_progress.ml:161-164`, `:189-193`).
- 다음 시도는 거절된 시도에서만 생겨요(`verifier_review_owner.ml:429-439`).
- 판정은 backlog 잠금 안에서, Task 가 그 `verification_id` 의 판정을 기다릴 때만 적혀요(`workspace_task_transitions.ml:902` 의 `commit_verdict_r`). 이미 판정이 적힌 Task 는 `InvalidState` 로, 다른 제출로 넘어간 Task 는 `VerificationSuperseded` 로 거절돼요(`:962-977`). 적은 뒤에 무엇이 적혔는지는 `completion_authority_agent.ml:790-822` 의 `observe_original_change` 가 읽어요. 그 함수는 쓰기를 막지 않아요.
- 여러 실행이 판정을 내면 수리 필요예요(`verifier_review_execution.ml` 의 `original report history cannot establish one accepted verdict`).
- 같은 제출은 한 프로세스에서 하나만 돌아요(`completion_authority_agent.ml:80` 의 `claim_review`). 다시 읽기는 walk 가 끝난 뒤 같은 fiber 가 해요(`verifier_review_worker.ml:165`). 판정이 저장된 시도는 다시 읽지 않아요(`:70-73`).

**[사실]** 다시 돌려도 되는 근거예요.

- 리뷰어가 Task 를 바꾸는 길은 판정 보고 하나예요. 판정 보고 핸들러는 메모리에만 적고, Task 는 walk 가 끝난 뒤 worker 가 적어요. 나머지 도구 여섯은 닫힌 목록이고 읽기만 해요(3.2). 그중 `masc_web_fetch` 는 바깥 주소에 GET 을 보내요. GET 이 바깥 상태를 바꾸지 않는다는 것은 이 글의 전제예요.
- provider 가 요청을 받았는지 모르는 것은 남은 효과와 상관이 없어요. 응답이 오지 않았으면 판정 보고 핸들러가 돌지 않았어요. 돌았으면 실행 기록에 호출 노드가 남아요.
- writer 가 사라진 실행 55개는 모두 도구 호출이 정산돼 있었어요. 모두 provider 응답을 기다리던 중이었어요.
- 보고 없이 취소된 실행 31개의 취소 사유는 서버의 graceful shutdown 이 24개, `Fiber.Not_first` 가 7개예요. writer 유실은 같은 종료에서 취소가 끝나기 전에 프로세스가 끝난 경우예요. 3건은 종료 한도(10초)로 확인했어요(1.2).
- 판정 보고 호출이 둘 이상이거나 정산되지 않은 실행 기록은 959개 중 0개예요(1.2).
- writer 가 없다는 것은 writer lock 으로 확인해요(`agent_execution_projection.ml` 의 `observe_ownership`, #47278).
- 다음 시도는 #49097 이 취소에 이미 쓰는 길이에요. 리뷰 입력은 처음 얼린 값 그대로이고 attempt 번호와 요청 id 만 새로 붙어요(`verifier_review_owner.ml:397-402`).

**[제안]** 바뀌는 곳이에요.

- `anti_rationalization.ml(i)`: walk 가 이미 계산하는 typed 판정을 실패 관측(`Attempt_failed`)에 실어요. 계산과 걸음은 그대로예요.
- `goal_criterion_agent.ml`: 그 관측을 받는 패턴(`:99`)에 새 필드를 더해요. 동작은 그대로예요.
- `verifier_review_worker.ml`
  - 결과 모름으로 끝난 walk 결과에 칸별 관측과 그 판정을 실어 저장해요(`verifier_review_unknown/v2`). 지금은 `result` 만 저장해요.
  - 다시 읽어서 "판정 없음"이 확정되면 거절을 적어요. 지금은 취소만 그렇게 적어요(`observe_pending` 의 `"cancelled"`).
  - typed 판정은 그 시도의 진행 이벤트에서 찾아요. 진행 단계는 가장 최근 관측만 들고 있어요(`lane_addon_request_progress.ml:157`). 뒤에 붙은 취소 관측이 앞의 walk 결과를 가리면 안 돼요.
  - walk 결과는 `schema` 가 `verifier_review_unknown/v2` 이고 필드가 맞는 `execution_unknown` 이벤트예요. 취소 처리가 남기는 `{"cause":"review_cancelled"}` 도 같은 종류의 이벤트지만 walk 결과가 아니에요. 그것만 있는 시도는 "walk 결과 없음"이에요.
  - 둘 중 어느 것도 아닌 결과 모름 관측이 있으면 수리 필요로 남아요. 옛 `v1` 근거가 여기 들어요. 옛 근거를 따로 읽는 코드는 두지 않았어요.
  - walk 결과를 쓰고 읽는 곳은 `verifier_review_walk_result.ml(i)` 하나예요(새 파일).
- `verifier_review_ending.ml(i)`(새 파일): 실행이 어떻게 끝났는지(성공, 실패, 취소, writer 유실)의 타입이에요. 거절 근거에 적는 관측을 여기서 쓰고 읽어요.
- `verifier_review_execution.ml` 의 `read_call` 과 `observe`: 실행의 끝과 판정 보고를 따로 읽고, 시도 단위로 위 순서대로 합쳐요. 지금은 끝의 종류마다 갈래가 있어요.
- `agent_execution_projection.ml` 과 `agent_execution_projection_intf.mli`: 정산된 도구 호출과, 기록된 provider 응답이 요청한 도구 이름을 한 스냅샷에서 내요(`tool_invocations`). `Owner_lost` 는 실행 트리에서 읽은 복구 근거를 같이 돌려줘요. writer 가 없다고 확인한 뒤라 트리는 더 바뀌지 않아요.
- `verifier_review_owner.ml`
  - `known_observations` 가 새 관측 값을 읽어요. 다시 읽어 만든 거절에는 `outcome_unknown` 을 싣지 않아요. 지금 `known_observations` 는 그 값을 거부해요(`:296`).
  - `next_attempt` 는 지금 "근거를 읽지 못했다"와 "다시 돌 칸이 없다"를 같은 "다음 시도 없음"으로 받아요(`:431`). 둘을 나눠 돌려줘요. 근거를 읽지 못한 것은 오류예요.
- `completion_authority_agent.ml`: 재시도 권한을 적은 주석 둘(`:615-617`, `:649-650`)을 고쳐요. 코드는 그대로예요. 다음 시도는 지금도 `Not_reviewed` 의 `retryable_runtimes` 로 전해져요.
- `docs/verification-pipeline-policy.md` 4절: "불확실하면 다음 시도를 만들지 않는다"와 "성공으로 끝난 실행의 판정 보고만 되살린다"는 두 문장을 이 규칙으로 고쳐요.
- `docs/constitution.xml` 의 `AwaitingVerification` invariant: walk 가 결과를 남기지 못한 시도가 다음 시도로 간다는 문장을 더해요. 지금 조항은 실패의 typed 판정만 적어요.
- 시험: 다시 읽어 만든 거절에서 다음 시도가 생기는지 봐요. typed 판정이 `Producer_must_act` 일 때는 생기지 않는지도 봐요. 리뷰어 프로세스를 따로 띄워 보고 전, 보고 도중, 두 보고 사이, 보고 뒤에 끝낸 네 경우를 읽어요.
- 새 상태와 새 Gate 는 없어요. 저장하는 근거 둘의 모양이 바뀌어요.
- 실패 사유를 문장으로 가르지 않아요. 실행 기록의 실패한 끝에는 사유가 문장으로만 남아요(`failure.kind` 는 모두 `internal`). 그래서 typed 판정은 살아 있는 서버가 그 실패를 볼 때 저장해요.

**[사실]** 이미 저장된 근거에는 typed 판정이 없어요. 그래서 지금 멈춘 `no retained verdict` 8건은 L2a 가 배포돼도 움직이지 않아요. 운영자가 판정하거나 제출한 쪽이 다시 제출해요.

**[사실]** 다음 시도의 간격과 횟수는 헌법이 이미 정했어요. 횟수 상한은 없고 간격은 maintenance pulse(기본 60초)로 고정이에요. 쉬는 칸은 풀리는 시각까지 기다려요(`Verification_retry.delay`). 연결 실패는 칸을 쉬게 하지 않아요. 쉼은 rate limit 과 quota 두 저장소에서만 읽어요(`keeper_turn_driver.ml:449-481` 의 `path_rest_parts`).

- 그래서 연결 실패가 이어지는 동안에는 그 리뷰에 pulse 마다 시도가 하나씩 생겨요. 확정된 거절로 분류되는 일시 실패는 지금도 그래요.
- 시도 하나가 남기는 것을 운영 설치에서 쟀어요. 곧바로 실패한 실행 기록 폴더는 중앙값 9.2 KB 예요(210개). 요청 기록 파일은 최근 6개가 91~264 KB 예요.
- 지금 있는 재시도 길은 8일 로그에 24번 쓰였어요(`will retry` 줄 24개, 제출 24개). 한 제출에 두 번 쓰인 적은 없어요. 그 창에 긴 장애는 없었어요.

**[추정]** 지금 멈춘 19건 가운데 L2a 가 배포된 뒤 첫 시작 sweep 에서 움직이는 것은 9건이에요. writer 를 잃은 8건은 walk 결과가 없어서 다음 시도로 가요. 판정 보고 뒤에 실패한 1건은 그 판정으로 가요. 남는 것은 10건이에요(typed 판정이 저장되지 않은 8, 정산 안 된 효과 1, `raised` 1). 배포 뒤에 생기는 연결 끊김과 timeout 은 멈추지 않고 다음 시도로 가요.

**[추정]** 위험 둘이에요.

- 리뷰 실행 자체가 서버 프로세스를 끝내는 경우에는, 서버가 다시 시작할 때마다 그 리뷰가 다시 돌아요. 표본에는 없어요. writer 를 잃은 55개는 모두 provider 응답을 기다리던 중이었어요. 이름에 시각이 든 서버 시작 로그 74개 중 72개가 SIGTERM 으로 끝났어요.
  - 헌법의 `budget_gate` 는 누적 재시작 수로 행동을 막는 게이트를 금해요. 막아야 한다면 계획된 종료와 비정상 종료를 typed 로 나눠야 해요. 이 글은 그 장치를 넣지 않아요. 대신 운영자 목록에 attempt 번호가 보여요(L2b).
- 저장하는 근거의 모양을 바꾼 뒤 옛 서버로 되돌리는 경우예요.
  - **[사실]** 옛 `known_observations` 는 새 관측 값을 거부해요. 옛 `observe_pending` 은 결과 모름 근거의 내용을 읽지 않아요. 판정이 틀리게 적히지 않아요.
  - **[사실]** 새 서버가 다음 시도를 만들기 전이면 옛 `next_attempt` 는 그 거절을 "다음 시도 없음"으로 받아요(`verifier_review_owner.ml:429-431`). 새 서버가 다음 시도를 이미 만들었으면 옛 서버는 `Corrupt_original` 로 멈추고 그 다음 시도에 닿지 못해요(`:416-417`).
  - **[사실]** 새 서버가 다음 시도를 만들기 전에 되돌리면 그 제출은 pulse 마다 재시도 요청을 되풀이해요. 옛 `next_attempt` 가 같은 시도를 돌려주고, 옛 `run_attempt` 는 저장된 거절 결과(다시 돌 runtime 이 적힌)를 그대로 돌려줘요. provider 호출은 없고 실행 원장에 줄만 쌓여요. 코드를 읽어 확인했어요. 옛 binary 를 돌려 보지는 않았어요.
  - 취소로 끝난 실행만 있는 거절은 관측 모양이 지금과 같아서 옛 서버도 읽어요.

#### L2b — 사람이 풀어야 하는 제출은 운영자 목록에 있다

**[제안]** `RFC-task-lifecycle-a-verdict-assigns-no-work` 3.7 의 `Awaiting_verdict` 항목을 그대로 따라요. 새로 설계하지 않아요.

- 운영자 목록(`Operator_task_attention.item`)에 판정을 기다리는 제출을 모두 실어요. 오래 기다린 순이에요.
- 목록은 backlog 에서 만들어요. 실행 원장에서 만들지 않아요(3.2 의 64개 보존).
- **[제안]** 항목에 그 제출의 attempt 번호를 싣자고 그 RFC 에 제안해요. 재시작마다 다시 도는 리뷰는 번호가 커지는 것으로 보여요. 번호로 행동을 막지는 않아요(헌법의 `budget_gate`). backlog 의 `AwaitingVerification` 에는 attempt 가 없어요(`lib/types/types_core.ml:210-214`). 번호를 보이려면 항목마다 검증 요청 저장소를 읽어야 해요.
- "멈춘 것"을 가려내는 기준을 두지 않아요. L2a 뒤에는 오래 기다리는 제출이 곧 사람이 볼 제출이에요.
- **[사실]** PR #51525 가 이 항목을 넣었어요. attempt 번호와 마지막 결과는 싣지 않았어요. TUI 프로세스가 검증 요청 저장소와 실행 원장을 읽지 않아요.
- 그 RFC 는 이 항목을 3단계에 뒀어요. **[추정]** 항목 하나를 더하는 일은 1단계(저장 형식 변경)에 기대지 않아서 먼저 낼 수 있어요. 순서를 바꿀지는 그 RFC 의 소유자가 정해요(10절).

처음 글은 제출한 Keeper 의 World State 에 "판정되지 않았고 다시 돌 예약이 없다"는 줄을 싣자고 했어요. 이 수정에서 뺐어요.

- 읽을 자료로 고른 실행 원장은 행을 64개만 남겨요(3.2). 그 줄이 조용히 사라질 수 있어요.
- 제대로 하려면 completion authority 가 "이 제출을 지금 누가 움직이고 있는가"를 답하는 읽기 면이 필요해요. 새 면이에요.
- L2a 뒤에 남는 것은 지금 자료로 10건이에요. 그중 8건은 이미 저장된 근거에 typed 판정이 없어서 남는 것이라 다시 생기지 않아요. L2a 와 L2b 를 배포하고 남는 수를 다시 잰 뒤에 정해요.
- 제출한 쪽이 다시 제출하면 리뷰가 처음부터 돈다는 것은 지금도 그대로예요(3.2).

#### L2c — 목록 읽기는 레코드의 신원만 대조한다

L2a 배포 뒤 측정(8절)에서 찾았어요.

**[사실]** 무엇이 섰나.

- L2a 배포 뒤 서 있는 제출 18개 가운데 8개의 마지막 사건이 목록 읽기 실패예요(2026-11-12 13:59Z, 셈 기준은 8절). `Add-on request ownership unavailable: an inventoried original changed` 가 5개, `original host judgment inventory unavailable` 이 3개예요.
- 그 서버가 시작한 뒤(10:31:50Z~) 검증이 멈춘 12번은 Task 12개에 한 번씩이에요. 8번이 이 둘이었고, 모두 실행을 등록하기 전(`stage=review_preparation`)이에요. 나머지 4번은 `raised`(권한 불일치)예요.
- 같은 문구가 Librarian Addon wake 의 거절에도 3줄 나와요(`lib/server/server_librarian_addon_wake.ml:131`). wake 는 다음 이벤트에 다시 찾아서 그쪽은 깨우기가 한 번 늦어져요.

**[사실]** 지금 코드가 하는 일.

- `Lane_addon_tool_request_owner.load_listed`(`lib/lane_addon/lane_addon_tool_request_owner.ml:245-250`)는 목록에서 본 레코드를 다시 읽고 `same_listed`(`:118-122`)로 같은지 봐요. 같다는 조건에 `progress` 까지 들어가요.
- `load_scope`(`:270-277`)와 `fold_all_with`(`:278-292`)가 레코드마다 이 함수를 불러요. 하나라도 다르면 목록 전체가 `Store_unavailable` 이에요. 이 목록 읽기를 쓰는 곳은 lib 에 17곳이에요. `load_scope` 14곳, `fold_all` 1곳(Librarian wake), `load_listed` 를 바로 부르는 2곳(시작 때 정산 보관 sweep, Goal 검증 worker)이에요.
- 목록 읽기, 레코드 읽기, 진행 쓰기는 모두 스코프 직렬화(`with_tool_request_owner_serialization`, `lib/lane_addon/lane_addon_store.ml:348`)를 잡아요. 셋은 저마다 따로 그 잠금을 잡았다 놓아요. 그래서 목록은 한 시점이에요. `load_scope` 는 목록 한 번과 레코드 읽기 N 번을 따로 잡아서, 그 사이에 진행 쓰기가 끼어들 수 있어요.
- 진행 쓰기(`advance_events_with`, `:336`)는 그 레코드를 다시 읽어 `expected` 와 같을 때만 저장해요. 진행은 이벤트를 뒤에 붙이기만 해요(`Lane_addon_request_progress.append`).
- 운영 설치의 `verifier-reviews` 스코프는 레코드 416개(19.8MB)와 본문 570개(39.6MB)예요(2026-11-12). 리뷰마다 이것을 통째로 다시 읽고 본문 해시를 확인해요. 읽는 동안이 길어서 경합 창도 길어요.
- 검증 리뷰는 넷까지 동시에 돌아요(`lib/completion_authority_agent.ml:70`). 서버 시작 때 정리는 기다리는 검증마다 fiber 를 띄워요(`:1569-1580`).
- 리뷰는 자기 검증의 기록을 고를 때 `verifier-reviews` 스코프 전체를 `load_scope` 로 읽은 뒤에 걸러요(`lib/keeper/verifier_review_owner.ml:369-381`).
- 목록 읽기가 실패한 리뷰는 `Infrastructure_unavailable` 로 끝나고 다음 시도가 없어요(`retry_request_of_stop_cause`, `completion_authority_agent.ml:658-662`). 다음 서버 시작이나 새 제출까지 서요.
- `retained_commits` 가 실패하면 오류를 버리고 고정 문구를 적어요(`:1059-1063`). 그래서 3개가 무엇으로 실패했는지 기록에 없어요.

**[추정]** 한 리뷰가 자기 레코드의 진행을 쓰는 사이에 다른 리뷰의 목록 읽기가 깨져요. 서버 시작 때 정리는 같은 스코프의 검증을 한꺼번에 돌려서, 멈춘 검증을 다시 돌리는 바로 그때 이 경합을 스스로 만들어요.

**[제안]** 규칙은 하나예요. 목록은 무엇이 있는지 말하고, 진행 값은 지금 읽은 레코드가 말해요.

- `load_listed` 는 신원(scope, request_id, installation_id, package_id, tool, request_digest, summary)이 같은지만 봐요. 같으면 지금 읽은 레코드를 돌려줘요. 진행은 그 레코드의 것이에요.
- 신원이 다르거나 레코드가 사라졌으면 지금처럼 `Store_unavailable` 이에요.
- 같은 모듈의 `reload`(`:255-268`)가 이미 이 규칙을 써요. 진행만 다를 수 있다고 적혀 있어요. 신원 비교를 함수 하나로 떼고, `load_listed` 와 `reload` 가 그 함수를 같이 써요.
- `same_listed` 는 그대로예요. 신원 비교에 진행 비교를 더한 것이고, 진행을 조건으로 쓰는 비교 둘이 이것을 써요. `settle` 의 `check_record`(`:383`)와 `advance_events_with` 의 `same_record` 예요. 둘은 "내가 본 값일 때만 바꾼다"는 compare-and-set 이에요.

잃는 것이 하나 있어요. 지금은 다시 읽은 값이 목록과 같아야 해서 `load_scope` 의 결과 전체가 목록의 한 시점이에요. 바꾸면 각 레코드는 그 레코드를 읽은 때의 값이에요. 레코드끼리는 같은 시점이 아닐 수 있어요.

그래도 되는 까닭이에요.

- **[사실]** 이 저장소의 쓰기는 모두 compare-and-set 이에요. 진행 쓰기는 저장된 레코드가 `expected` 와 같을 때만 쓰고 아니면 `State_conflict` 예요(`:351-360`). `settle` 은 같은 레코드일 때만 옮기고 아니면 `Settle_changed` 예요(`:383-387`).
- 그래서 읽은 뒤에 바뀐 레코드에 쓰려는 결정은 쓰는 순간 거부돼요. 지금은 그 결정을 내리기도 전에 읽기 전체가 실패해요.
- 다른 레코드의 값을 보고 이 레코드에 쓰는 결정은 그렇게 잡히지 않아요. 그런 자리가 있는지가 아래 16곳의 확인이에요.
- **[사실]** `load_scope` 와 `fold_all` 을 부르는 쪽은 목록에서 본 진행을 받지 않아요. 다시 읽은 레코드만 받아요. 받는 값의 모양은 그대로예요.
- **[사실]** 검증은 자기 검증의 레코드로만 결정해요. 한 검증은 한 번에 한 리뷰만 맡아요(`claim_review`, `completion_authority_agent.ml:80-90`). 그래서 검증 쪽은 다른 검증 레코드의 시점과 상관이 없어요.
- 나머지 16곳(Librarian 13, Goal 검증 2, 정산 보관 sweep 1)이 스코프 한 시점을 전제로 하는지는 구현 PR 이 본문에 호출처마다 한 줄씩 표로 적어요. 그 표가 없으면 구현 PR 은 끝난 것이 아니에요.

고르지 않은 길도 적어요.

- 목록과 다시 읽기를 직렬화 한 번 안에서 하면 한 시점을 지키면서 경합도 없어요. 대신 그동안 그 스코프의 진행 쓰기가 모두 기다려요. 검증 스코프에서는 리뷰마다 레코드 416개와 그 본문을 읽고 해시를 확인하는 동안이에요. 또 wake 는 목록 콜백 안에서 같은 스코프를 다시 읽어서(`test/test_lane_addon_request_discovery.ml:572-580`), 잠금을 콜백 너머로 잡지 않는다는 전제가 있어요(`lane_addon_store.ml:350-353`).
- 검증의 기록 선택만 고치면 Librarian 의 같은 경합이 남아요(10절 5번).
- 목록 읽기가 실패하면 다시 읽게 하는 길도 있어요. 그러면 진행을 쓰는 쪽이 계속 있을 때 몇 번을 다시 읽을지 상한을 정해야 해요. 이 글은 상한을 두지 않아요(9절).

바뀌지 않는 것이에요.

- 검증 기록의 신원 확인(`routing_verification`, `verifier_review_owner.mli:46-51`). 누구 것인지 확인할 수 없는 레코드가 있으면 지금처럼 거부해요.
- 재시도 규칙(`retry_request_of_stop_cause`). `Infrastructure_unavailable` 은 지금처럼 다음 시도가 없어요. 이 층은 실패를 다시 돌리지 않고, 그 실패가 생기지 않게 해요.

**[제안]** 실패 상세: `retained_commits` 의 오류 글을 stop 의 detail 에 실어요. 지금의 고정 문구는 그 앞에 둬요.

**[제안]** 시험이에요.

- `Owner.For_testing.fold_all ~after_inventory` 안에서 같은 스코프의 다른 레코드에 진행 이벤트를 더해요. 고친 뒤에는 목록이 성공하고 그 레코드의 새 진행이 보여요. 지금 코드에서는 `an inventoried original changed` 로 실패해요.
- 목록 뒤에 레코드의 신원(summary)을 바꾸면 지금처럼 실패해요.
- `settle` 은 진행이 바뀐 레코드를 지금처럼 `Settle_changed` 로 거부해요.

**[사실]** L2c 로 움직이지 않는 것이에요.

- 옛 근거 5개. `lib/keeper/verifier_review_walk_result.ml:92-120` 은 `verifier_review_unknown/v2` 모양과 취소 기록만 읽어요. #51540 은 옛 근거를 읽는 코드를 두지 않았어요. 운영자가 판정하거나 제출한 쪽이 다시 제출해요.
- 권한 불일치 4개와 정산 안 된 효과 1개(11절).
- 목록 뒤에 레코드가 사라진 실패(`an inventoried original disappeared`). 저장소 전체를 도는 sweep 둘(Librarian wake, `server_unowned_exact_sweep`)은 정산 막이(`with_tool_request_settlement_barrier`)를 잡아서, 그동안 정산이 들지 못해요. 검증 리뷰의 `load_scope` 는 막이를 잡지 않아서, 정산이 목록과 레코드 읽기 사이에 들 수 있어요. 목록 읽기는 사라진 까닭이 정산인지 바깥에서 지운 것인지 가르지 못해서, 지금처럼 목록 전체를 거부해요. 막이 안에서 바깥이 지운 경우는 `test_barrier_does_not_hide_an_external_disappearance` 가 지켜요. 이번 서버 시작 뒤에는 0번이었어요.

**[추정]** L2c 를 배포하면 서버가 시작할 때 정리가 목록 읽기에서 진 8개를 다시 돌려요. `changed` 5개는 그때 목록 읽기에서 지지 않아요. `inventory unavailable` 3개는 상세가 버려져서 같은 경합인지 몰라요. L2c 뒤에는 상세가 남아요. 그 뒤의 결과는 리뷰가 정해요.

#### 미디어 거절

**[제안]** 미디어 거절(#39677 의 처음 원인)은 좌로 지워요. 글 전용 칸으로 가는 goal_blocks 에서 이미지 블록을 벗기고 참조 줄을 남겨요. `complete_media` 의 `InvalidConfig` 갈래는 닿지 않게 되면 지워요. 7일 로그에 이 거절이 0줄이라 L2a 와 L2b 뒤에 해요.

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
| L1 | `keeper_board_attention_fanout.ml`, `keeper_board_attention_partition.ml(i)`, `keeper_board_attention_candidate.ml`, `keeper_board_attention_worker.ml`, `keeper_board_attention_quarantine_command.ml`, 그 시험 | `ensure_current_roots` 와 `judgment_delivery_outcome` 을 `match` 하는 곳을 모두 고친다. fanout 의 `claim` 마다 후보 원장을 한 번 더 읽는다 |
| L2a | `anti_rationalization.ml(i)`(실패 관측에 판정을 싣는 것과 보고 도구 이름), `goal_criterion_agent.ml`·`goal_verifier_worker.ml`(패턴 한 줄씩), `verifier_review_worker.ml`, `verifier_review_walk_result.ml(i)`·`verifier_review_ending.ml(i)`(새 파일), `agent_execution_projection.ml`, `agent_execution_projection_intf.mli`, `agent.ml(i)`, `verifier_review_execution.ml(i)`, `verifier_review_owner.ml(i)`, `completion_authority_agent.ml`(주석), 그 시험, `docs/verification-pipeline-policy.md`, `docs/constitution.xml` | 끊긴 리뷰가 다시 돈다. 리뷰 한 번의 토큰이 다시 든다. 연결 실패가 이어지면 그 리뷰에 pulse 마다 시도 하나가 쌓인다(5.2). 헌법 invariant 와 검증 정책 문서의 문장이 바뀐다 |
| L2b | `operator_task_attention.ml` 과 그 목록을 그리는 곳 | 운영자 목록에 판정을 기다리는 제출이 모두 실린다. 지금 20행이고, L2a 뒤에는 돌고 있는 리뷰와 남은 10건이다 |
| L2c | `lane_addon_tool_request_owner.ml`(`load_listed` 와 신원 비교), `completion_authority_agent.ml`(실패 상세), 그 시험 | 목록 읽기를 쓰는 17곳(`load_scope` 14, `fold_all` 1, `load_listed` 직접 2)에서 목록 읽기 실패가 줄어든다. 공용 층이라, 그 자리들이 목록에서 본 진행에 기대지 않는지 리뷰가 봐야 한다 |
| 미디어 거절 | `keeper_turn_driver.ml` 의 미디어 갈래 | 7일 로그에 0줄이라 맨 뒤다 |
| L3 | 그 RFC 의 8절 | 그 RFC 에 적혀 있다 |
| L4 | 그 RFC 의 L3 | 그 RFC 에 적혀 있다 |

## 7. 다른 RFC 와의 관계

| RFC | 관계 |
|---|---|
| `keeper-world-state-shows-open-work` (Draft) | L3 가 이 RFC 의 S4·S6 이다. 이 글은 순서의 근거와 `cycle_count` 한 칸을 더한다 |
| `at-name-resolves-to-declared-recipient` (Active) | L4 가 이 RFC 의 L3 다 |
| `task-lifecycle-a-verdict-assigns-no-work` (Draft) | 1.5절이 같은 검증 정체와 운영자 attention 제외를 적었고, 3.7 이 운영자 목록의 `Awaiting_verdict` 를 설계했다. L2b 는 그 항목이다. 이 글은 그 설계를 다시 쓰지 않는다 |
| `0361`, `0406` (Draft) | 검증 원본 보관과 원격 게스트 읽기. L2a 는 보관한 원본과 실행 기록을 읽는 규칙만 바꾼다 |
| PR #47278, #49097 (병합됨) | writer 가 사라진 실행을 운영자 수리로 보낸 것과, 취소된 실행을 다음 시도로 넘긴 것. L2a 는 #49097 의 전제(시도된 채 결과가 없는 도구 호출이 없다)를 실패와 writer 유실에도 쓴다. #47278 의 "자동 재시도 없음"은 걸음이 결론을 남기지 못한 리뷰 시도에 한해 바뀐다 |
| RFC-0489 (Goal 검증) | Goal 검증도 같은 walk 를 쓴다(`goal_criterion_agent.ml:117`). L2a 는 walk 의 걸음과 결과를 바꾸지 않아서 Goal 검증은 그대로다. Goal 쪽에 같은 멈춤이 있는지는 보지 않았다 |
| `docs/constitution.xml` 의 `AwaitingVerification` invariant | 자동 재시도를 이어 갈지는 실패의 typed 판정이 정한다. L2a 는 결과 모름으로 끝난 걸음도 그 판정을 저장하게 한다. 걸음이 결론을 남기지 못한 시도(취소, 프로세스 종료)는 그 조항에 없어서 문장을 더한다 |
| `docs/verification-pipeline-policy.md` 4절 | "불확실하면 다음 시도를 만들지 않는다"와 "성공으로 끝난 실행의 판정 보고만 되살린다"를 L2a 가 고친다 |
| `board-attention-asks-jev-once-per-event` (Draft) | fanout 이 직접 판정하는 길(#40521)이다. worker 도 같은 후보를 Jev 에게 물어서 두 길이 claim 을 두고 겨룬다. L1a 는 그 겨룸에서 root 가 다시 생기는 틈만 닫는다. 한 사건을 한 번만 묻게 하는 일은 그 RFC 에 남긴다 |
| `provider-path-rest` (Draft) | #45003 의 좌가 이 RFC 범위다. 이 글은 다루지 않는다 |
| `keeper-github-apps` (Draft) | #46691 의 좌. 지금 하지 않는다(10절) |
| `0390` (Draft) | 공식 클라이언트의 내장 도구 자세. #42017 의 좌가 여기에 달렸다 |
| Draft PR #51381 (영수증을 기다리며 턴이 끝나는 상태 기계) | 한 Keeper 가 자기 도구 결과를 기다리는 설계다. 이 글은 서로 다른 쪽 사이의 전달을 다룬다. 고치는 파일이 겹치지 않는다 |

## 8. 하네스

배포 뒤 같은 방법으로 다시 세요. 기준은 이 글에 고정해요.

| 층 | 재는 것 | 지금 | 기대 |
|---|---|---|---|
| L1a | fanout 의 `judgment conflicts with worker result` 경고 | 8일에 3번(후보 3개) | 0 |
| L1b | Keeper 별로, 그 Keeper 의 마지막 턴이 끝나기 전에 판정이 난 `Completed` partition 수. 쉬는 Keeper 에게 온 판정은 다음 턴을 기다리는 것이라 세지 않는다(1.2) | 한 Keeper 362(2026-11-12 13시에는 382), 나머지 0 | 충돌·못 읽은 것만 남는다. 지금 자료로는 1 |
| L1b | `completion remains pending` 로그가 가리키는 후보 수 | 1(693줄) | 줄 수는 그대로일 수 있다. 뒤에 밀린 partition 이 0이어야 한다 |
| L2a | `awaiting_verification` 중 판정도, 도는 리뷰도, 재시도 예약도 없는 제출 | 19 | 10. 그 뒤에 새로 생기는 것은 정산 안 된 효과, 보고 없이 끝난 리뷰, 권한 불일치, typed 판정이 `Producer_must_act` 나 `Model_absent` 인 실패뿐이어야 한다 |
| L2a | `requires original reconciliation` 으로 한 번이라도 멈춘 제출 수 | 8일에 35(예약 288). 마지막 사유가 `lost its writer` 인 것 9, `no retained verdict` 인 것 12 | 배포 뒤에 예약된 제출에서 `lost its writer` 는 0. `no retained verdict` 는 typed 판정이 `Reviews_again` 이 아닌 것만 남는다 |
| L2a | 한 제출에 쌓인 attempt 수 | 재시도 길이 쓰인 24번 모두 1 | 분포를 적는다. 목표값은 두지 않는다 |
| L2a | 판정 보고 호출이 둘 이상이거나 정산되지 않은 실행 기록 | 959개 중 0 | 0 이 아니면 그 실행 기록을 읽는다 |
| L2b | 판정을 기다리는 제출 가운데 운영자 목록에 없는 것 | 20(전부) | 0 |
| L2c | 서버 시작 한 번 동안 로그의 `an inventoried original changed` 줄(검증 멈춤과 Librarian wake 거절) | 검증 5(Task 5개에 한 줄씩), Librarian 3(2026-11-12 10:31:50Z 시작) | 레코드 신원이 바뀐 경우만 남는다. 지금 자료로는 0. 같은 기간 `an inventoried original disappeared` 줄은 0 이고, L2c 는 그 실패를 다루지 않는다 |
| L2c | 마지막 사건이 목록 읽기 실패인 `awaiting_verification` 제출 | 8(`changed` 5, `inventory unavailable` 3, 13:59Z) | 배포 뒤 첫 시작 정리가 지나면 `changed` 는 0. `inventory unavailable` 은 상세가 남아서 다시 나눠 센다 |
| L3 | 7일 동안 외부 세션이 만든 Task 중 todo 비율 | 45% (102/227) | 낮아지는지 본다. 목표값은 두지 않는다 |
| L3 | `task_claim_next` 가 간 Task 의 반납 횟수 | 27 | 같은 Task 로 다시 가지 않는지 본다 |
| L4 | 7일 `Mention_rejected` | 17 | 선언된 이름의 진짜 실패만 남는다 |

**[사실]** L2a 배포 뒤 측정이에요. 2026-11-12 12:59Z 에 셌어요. 운영 build 는 `778e441d5df1`(L2a 포함)이고, 서버는 10:31Z 즈음 시작했어요.

- `awaiting_verification` 18개 가운데 판정도, 도는 리뷰도, 재시도 예약도 없는 제출은 17개예요(기대 10).
- 배포 전에 서 있던 16개 가운데 15개가 서버 시작 뒤 새 시도를 했어요. 서버 시작 뒤 등록된 시도 19번의 결과는 approved 4, execution_repair_required 7, infrastructure_unavailable 4, raised 3, not_reviewed 1 이에요.
- `not_reviewed` 만 재시도가 예약돼서 한 번 더 돌았어요. 나머지에는 다음 시도가 없어요.
- 13:59Z 에 Task 마다 서버 시작 뒤 마지막 사건으로 다시 셌어요. 사건은 두 가지예요. 서버 로그의 `completion authority` 줄(멈춤, 원본 정리 필요, 재시도 예약)과 실행 기록의 완료예요.
- 그 기준으로 18개는 목록 읽기 실패 8(`changed` 5, `inventory unavailable` 3, L2c), 옛 근거 5, 권한 불일치 4, 정산 안 된 효과 1 이에요. 18개 모두 마지막 사건이 멈춤이에요. 재시도 예약이나 완료 기록 없는 실행으로 끝난 것은 없어요.
- 12:59Z 에 처음 센 표(목록 읽기 실패 6, 옛 근거 4, 권한 불일치 3, 정산 안 된 효과 1, 완료 기록 없는 실행 3, 실행 기록 없음 1)는 실행 기록을 먼저 봤어요. 목록 읽기 실패는 모두 실행을 등록하기 전에 나서 실행 기록에 남지 않아요. 그래서 일부가 다른 칸에 들어갔어요. 그때 완료 기록이 없던 실행 3개는 13:59Z 에는 모두 완료 기록이 있어요.
- 기대와 다른 것은 목록 읽기 실패 8과 옛 근거 5예요. 12:59Z 에 센 옛 근거 4는 5.2 의 "이미 저장된 근거에는 typed 판정이 없어요"가 말한 8건 가운데 있어요. 새 시도를 했지만 같은 근거를 읽고 다시 수리로 끝났어요. 13:59Z 에 하나 더 센 것은 그 8건과 대조하지 않았어요.
- #39677 댓글에도 같은 내용을 남겼어요. 고친 셈도 그 댓글에 이어 적어요.

**[사실]** `specs/` 에는 이름에 attention, partition, candidate 가 든 파일이 없고 `specs/INDEX.md` 에도 Board attention 항목이 없어요. **[제안]** L1 을 구현할 때 root 와 정산의 모델을 새로 써요. 불변식은 둘이에요. "한 후보에 기록되는 판정은 하나다"와 "`Completed` 인 `relevant` 판정은 결국 전달된다"예요. `BugAction` 도 둘이에요. prune 뒤에 낡은 `Pending` 값으로 root 를 다시 만드는 것은 첫째를 깨야 하고, 맨 앞 한 건이 걸음을 멈추는 것은 둘째를 깨야 해요.

## 9. 하지 않는 것

- 멈춘 건수에 상한이나 cooldown 을 두지 않아요.
- 멈춤을 알리는 Gate, 응답 의무, 재시도 의무를 만들지 않아요. L2a 는 completion authority 가 이미 가진 재시도 길을 쓰고, Keeper 에게 의무를 지우지 않아요.
- 턴의 마지막 글을 분류하지 않아요(#42017). "게시 못 함"이라는 문장을 문자열로 가려내면 `closed_sum_over_string` 에 어긋나요.
- 리뷰 재요청을 자동으로 걸지 않아요(#46691). 요청을 일 배정으로 쓰는 것이에요.
- Task 레코드에 담당 필드를 두지 않아요(#41343).
- 멈춰 있는 362건과 19건의 운영 자료를 이 글의 구현이 직접 고치지 않아요. L1b 가 배포되면 밀려 있던 `relevant` 판정은 다음 heartbeat 에 전달돼요. 19건 가운데 9건은 L2a 가 배포되면 다음 시작 sweep 이 다시 읽어 움직여요. 나머지 10건은 운영자나 제출한 쪽이 풀어요(5.2). L2a 배포 뒤 남은 18건 가운데 목록 읽기에서 진 8건은 L2c 가 배포된 뒤 첫 시작 정리가 다시 돌려요.

## 10. 사용자가 정할 것

| # | 정할 것 | 정석 | 대가 |
|---|---|---|---|
| 1 | L1 뒤에도 남는 충돌 partition 하나를 어떻게 하나. 후보는 이미 `not_relevant` 로 소비됐고, 남은 것은 같은 결론의 두 번째 판정이다 | 2026-11-12 에 정했다: 그대로 둔다. 코드 주석이 이 충돌을 "조용히 풀지 말고 크게 알릴 버그"로 정해 뒀고, L1b 뒤에는 다른 건을 막지 않는다 | heartbeat 마다 error 로그 한 줄이 계속 난다(지금 하루 165~320줄). 다른 쪽은 "후보가 이미 `Consumed` 면 뒤에 온 판정은 전달 없이 닫는다"를 갈래로 두는 것이다. 로그는 멎지만, 다른 원인으로 생긴 이중 판정도 같이 닫힌다 |
| 2 | 멈춘 검증과 L2a | 2026-11-12 에 정했다: L2a 를 한다. 실행 기록이 "판정 보고가 없었다"를 확정한 시도는 확정된 거절이 되고, 걸음이 결론을 남겼으면 헌법대로 실패의 typed 판정이 다시 돌지 정한다. 취소나 프로세스 종료로 결론을 남기지 못한 시도는 다음 시도로 간다. 정산된 판정 보고가 하나 있으면 그 판정을 읽는다. 근거는 1.2 의 실행 기록 959개와 5.2 다 | #47278 이 정한 "writer 가 사라지면 자동 재시도 없음"이 걸음이 결론을 남기지 못한 리뷰 시도에 한해 바뀐다. 헌법 invariant 와 검증 정책 문서에 문장이 더해진다. 리뷰가 다시 도는 만큼 토큰이 든다. 리뷰 실행이 서버를 끝내는 경우에는 다시 시작할 때마다 그 리뷰가 다시 돈다(표본에 없음). 지금 멈춘 19건 중 10건은 그대로 남는다. 다른 쪽은 지금 규칙을 두고 L2b 만 하는 것이다. 그러면 같은 멈춤이 8일에 35번꼴로 계속 생기고 운영자가 하나씩 판정한다 |
| 3 | Keeper 별 GitHub 신원(#46691 의 좌) | 지금 하지 않는다. L3 의 S4 가 배포된 뒤 "현재 head 에 리뷰 없는 Ready PR" 을 다시 잰다 | 어느 Keeper 가 리뷰했는지는 계속 계정 단위로만 남는다 |
| 4 | L2b 를 `task-lifecycle` RFC 의 3단계에서 떼어 먼저 낼지 | 2026-11-12 에 정했다: 먼저 낸다(PR #51525). L2a 뒤에 남는 제출을 볼 곳이 운영자 목록뿐이다 | 그 RFC 의 단계 순서가 바뀐다. 그 RFC 3.7 은 목록이 짧다는 전제를 1단계 뒤로 잡았다. 먼저 내면 그때까지 목록에 돌고 있는 리뷰도 같이 보인다 |
| 5 | L2a 배포 뒤 남은 목록 읽기 경합 | 2026-11-12 에 정했다: RFC 절(L2c)부터 쓰고 구현한다. 규칙은 "목록 읽기는 레코드의 신원만 대조하고, 진행 값은 지금 읽은 레코드를 따른다"이다 | 공용 층(목록 읽기를 쓰는 17곳)의 실패 조건이 바뀐다. 다른 쪽은 검증 lane 의 선택만 바꾸는 것인데, 그러면 Librarian 의 같은 경합이 남는다 |

## 11. 확인하지 못한 것

- 11-05 의 충돌 둘이 owner 쪽에서 한 번씩만 실패하고 풀린 길. 조사 에이전트는 prune 뒤의 `Candidate_absent` 정산으로 읽었고 내가 다시 따라가지 않았어요.
- L1a 의 경합을 시험으로 재현하지 않았어요. 로그 순서, 운영 설치의 두 행, 코드 읽기가 서로 맞는 것까지 확인했어요.
- worker 와 fanout 이 같은 후보를 둘 다 Jev 에게 묻는 것이 의도인지.
- 멈춘 19건 가운데 `unsettled effect` 1건과 `raised` 1건의 원인.
- L2a 배포 뒤 권한 불일치 4건이 다섯 조건 가운데 무엇 때문인지. `verifier_review_worker.ml:137-144` 의 조건문 하나가 subject id, task, worker, lookup binding 다이제스트, schema 이름을 같은 문구로 거부해요. binding 다이제스트에 도구 설명, route, read authority 가 들어가서(`lib/verification_authority_tools.ml:799-811`) 배포가 그것을 바꾸면 걸린다고 추정만 했어요.
- 12:59Z 에 완료 기록이 없던 실행 3개가 언제 끝났는지. 13:59Z 에는 모두 완료 기록이 있는데, 완료 행에는 적힌 시각이 없어요.
- L2c 의 경합을 운영 설치에서 재현하지 않았어요. 로그 시각, 동시 실행 수, 코드 읽기가 서로 맞는 것까지 봤어요.
- 실패 219개를 사용 한도 205와 결과 모름 14로 나눈 것은 실행 기록의 오류 글로 가른 값이에요. 그때 코드가 매긴 `failure_certainty` 값은 저장돼 있지 않아요.
- 저장하는 근거의 모양을 바꾼 뒤 옛 서버로 되돌리는 경우를 옛 binary 로 돌려 보지 않았어요. 코드를 읽은 결과는 5.2 에 있어요.
- 로그의 "900초 동안 진행이 없었다" 줄이 어느 실행 기록을 가리키는지. 멈춘 19건의 실행 기록에서는 시한 실패 2건이 모두 실패로 닫혔어요.
- 같은 호스트에서 두 프로세스가 같은 설치를 여는 경우. 적대적 검토는 RFC-0489 6.2 와 #48709 를 들어 임시 폴더가 다르면 둘이 lease 를 같이 가질 수 있다고 적었어요. 직접 읽지 않았어요.
- 첫 실행이 기록되기 전에 끊긴 시도. 실행 기록이 없어서 "locator 없음" 수리로 남아요. provider 호출이 없었으니 다시 리뷰해도 되는 경우인데 L2a 는 다루지 않았어요. 멈춘 19건에는 없고, 운영 설치에 몇 건 있는지는 세지 않았어요. L2a 3층의 독립 리뷰가 찾았어요.
- 살아 있는 리뷰가 받아들이는 "거절된 보고 뒤에 사유를 붙여 다시 보낸 REJECT"는 다시 읽으면 정산된 보고가 둘이라 수리로 남아요. 고치기 전에도 그랬어요.
- Goal 검증에 같은 멈춤이 얼마나 있는지. 코드에는 같은 꼴이 있어요. 결과 모름으로 끝난 Goal 검증은 새 리뷰를 시작하지 않고 원래 실행을 보라고 답해요(`goal_verifier_worker.ml` 의 `select_frontier`). Goal 검증은 실행 기록의 위치를 남기지 않아서 L2a 의 방법을 그대로 쓸 수 없어요. 건수는 세지 않았어요.
- 여러 호스트나 네트워크 파일시스템에서 writer lock 이 맞게 도는지. 적대적 검토가 추정으로 남겼어요.
- 리뷰 실행이 서버 프로세스를 끝낸 적이 있는지. 표본의 writer 유실 55개는 모두 provider 응답을 기다리던 중이었다는 것까지만 봤어요.
- writer 를 잃은 8건 중 5건, 판정 없이 끝난 8건 중 1건이 처음 멈춘 순간. 로그 창(11-04 19:13 KST)보다 먼저예요.
- 서버 종료가 10초 한도 안에 도는 리뷰를 취소로 정산하지 못하는 까닭. 11-07 의 재시작 한 번에서 리뷰 셋이 끝 없이 남은 것까지만 봤어요.
- 실행 기록을 Task 에 맞춘 방법. 기록 속에 가장 많이 나온 Task id 와 시각으로 맞췄어요. 1.2 의 원인 표는 로그 줄(`verification_id` 가 적힘)로 셌고, 실행 기록 수는 Task 에 맞추지 않은 전체 수예요.
- 공식 클라이언트 세션으로 돈 리뷰가 멈춘 수. 지금 멈춘 19건에는 없어요.
- #42017 의 7일 사례 1건과 비슷한 6건. 조사 에이전트가 raw trace 에서 읽었고 내가 다시 읽지 않았어요. raw trace 는 Keeper 마다 최근 약 200턴만 남아서 7일 전체를 세지 못했어요.
- #46691 의 "Ready 114개 모두 리뷰됨"이 왜 그런지. 스킬 문서의 순서, 운영자가 준 목록, 리뷰어 수 가운데 무엇 때문인지 가르지 못했어요.
- #26914 의 승인 뒤 사라진 산출물 수.
- #45003. 실험 서버의 기록이 남아 있지 않아요.
