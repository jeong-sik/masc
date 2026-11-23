---
rfc: "librarian-read-waits-and-shrinks-no-further-than-the-refusal-says"
title: "Librarian 읽기를 미루거나 줄일 때는 받는 쪽의 거절이 말한 만큼만 한다"
status: Superseded
created: 2026-11-17
updated: 2026-11-23
author: vincent + claude
supersedes: []
superseded_by: "librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line"
related: ["librarian-lifecycle", "host-cycle-runs-exact-requests-side-by-side", "librarian-ends-waiting-requests-of-a-replaced-declaration", "librarian-waiting-pass-reads-records-not-bodies"]
---

# Librarian 읽기를 미루거나 줄일 때는 받는 쪽의 거절이 말한 만큼만 한다

## 0. 요약

- 2026-11-17 00:09 KST 운영 서버에서 Librarian 이 아직 안 읽은 턴은 8,031개다. 그 전 24시간에 끝난 턴은 시간당 90.3개다.
- 밀리는 자리는 둘이다.
  - 접수. keeper-librarian worker 는 기다리는 요청 전체가 답 frame 하나에 들어갈 때만 새 요청을 받는다. frame 의 24~98% 인 요청 아홉 개가 3~392번 거절되고 한 번도 접수되지 않았다.
  - 폭. 끝난 원본이 거절이면 다음 회차는 가장 오래된 한 턴만 읽고, 밀린 범위가 빌 때까지 그대로다. 안 읽은 턴의 52.7% 를 가진 code-reviewer 가 이 상태다. 하루 351턴을 끝내는데 한 턴 읽기는 하루 120번쯤이다.
- 둘은 맞물린다. 밀릴수록 요청이 커지고, 클수록 덜 접수되고, frame 을 넘으면 한 턴으로 떨어진다.
- 이 RFC 는 규칙 하나를 세운다. **읽기를 미루거나 줄일 때는 받는 쪽의 거절이 말한 만큼만 한다.**
- 규칙에서 결정 둘이 나온다.
  - D1. worker 는 요청 하나가 frame 에 들어가면 받는다. 목록은 frame 만큼씩 여러 장으로 내놓고, host cycle 은 모든 장을 걷는다. `capacity_wait` 는 지운다.
  - D2. 거절된 회차는 다음에 한 턴이 아니라 절반을 읽는다. 거절된 범위를 다 읽으면 그 거절은 끝난 것으로 본다. 거절 없이 끝난 회차는 폭을 줄이지 않는다.
- 바꾸지 않는 것: `max_exact_in_flight` 값, exact lane 구성, frame 크기, 어떤 거절이 폭을 줄이는지, 연속성 회차의 좁히기, 기다리는 기록의 스키마.
- 이 RFC 만으로 밀린 턴이 0 이 된다고 약속하지 않는다. 처리량은 함께 실행하는 수와 모델 응답 시간이 정한다(§4.3). 층마다 재서 운영자가 정한다.

## 1. 지금

### 1.1 운영 서버에서 잰 값

안 읽은 턴(11-17 00:09 KST). Keeper 의 `turn-boundaries.jsonl` 과 읽은 위치 파일 둘을 비교해 셌다.

| Keeper | atom 턴 | official 턴 | 가장 오래된 안 읽은 턴 |
|---|---:|---:|---:|
| code-reviewer | 450 | 3,779 | 289.1시간 전 |
| pr-updater | 0 | 2,306 | 302.5시간 전 |
| code-reviewer-father | 189 | 137 | 78.8시간 전 |
| e-masc-the-leader | 227 | 0 | 76.1시간 전 |
| code-reviewer-sister | 180 | 37 | 78.2시간 전 |
| wkbl-web-leader | 30 | 164 | 47.7시간 전 |
| ocaml-agent-ic | 155 | 2 | 14.1시간 전 |
| 그 밖 22개 | | 합 375 | |
| 합 | 1,399 | 6,632 | 8,031 |

code-reviewer 와 pr-updater 가 6,535턴, 81.4% 다.

들어오는 양과 읽는 양.

| 무엇 | 값 | 창 |
|---|---|---|
| 끝난 턴 | 2,168개(atom 680, official 1,488). 시간당 90.3개 | 11-16 00:01~11-17 00:01 KST |
| 그중 120개 넘게 끝낸 Keeper | code-reviewer 351, pr-updater 267, github-pr-checker 201, wkbl-web-leader 167, ocaml-agent-ic 156 | 같은 창 |
| durable 요청이 답을 받은 횟수 | 65번. 시간당 4.9번 | 11-16 00:00~13:23Z |
| durable 요청 하나의 시도가 답으로 끝나기까지 | p50 717.5초, p90 951초, 최대 1,280초 | 같은 창 |
| 같은 창의 admission 요청 | 답 19번, p50 664초 | 같은 창 |
| 시도를 시작할 때 이미 돌던 수(`running_at_start`) | 0, 1, 2. 자기를 뺀 수라서 2 가 설정값 3 을 다 쓴 것이다 | 같은 창 |

본문이 남아 있는 `derive_memory` 원본 기록(11-17 00:15 KST). 27개이고, Exact 요청 크기 추정의 합은 37,737,913 B 다. frame(4,194,304 B) 9.0개 분량이다. 앞 원본과 그것을 잇는 원본이 같이 남은 Keeper 는 두 줄이다.

| Keeper | 요청 크기 추정 | frame 대비 | 접수 거절 | 접수 |
|---|---:|---:|---:|---|
| code-reviewer | 12,706,471 B | 303% | 아직 제출 전 | 안 됨 |
| pr-updater | 4,104,755 B | 98% | 186번 | 안 됨 |
| wkbl-web-leader | 2,990,454 B | 71% | 261번 | 안 됨 |
| wkbl-web-leader | 2,990,454 B | 71% | 41번 | 안 됨 |
| code-reviewer-sister | 2,535,848 B | 60% | 127번 | 안 됨 |
| code-reviewer-father | 1,897,272 B | 45% | 143번 | 안 됨 |
| github-pr-checker | 1,231,635 B | 29% | 3번 | 안 됨 |
| msx-retro-mania | 1,120,118 B | 27% | 75번 | 안 됨 |
| e-masc-the-leader | 1,076,828 B | 26% | 93번 | 안 됨 |
| ocaml-agent-ic | 987,955 B | 24% | 392번 | 안 됨 |
| 그 밖 17개 | 모두 654,581 B 이하 | 16% 이하 | 0~53번 | 됨 |

- 987,955 B(frame 의 24%) 이상인 기록은 하나도 접수되지 않았다. 접수된 17개는 모두 654,581 B(16%) 이하다.
- 00:38 KST 에 다시 재니 거절이 더 늘어 있었다(pr-updater 186→197, ocaml-agent-ic 392→417). 11-16 22:19, 23:25 KST 에 서버를 다시 띄운 뒤의 일이다.
- 거절될 때마다 pass 가 원본 본문을 다시 읽고 요청을 worker 에 다시 보낸다. 11-15 20:00~22:42 KST 에 거절이 627번 있었다. 본문 파일 크기에 거절 횟수를 곱해 더하면 약 7.3 GB 다(#51280 댓글). 보낸 양은 많아야 627 × frame = 2.6 GB 다.

한 턴으로 떨어진 예.

- code-reviewer 의 전부 읽기 원본은 11-16 10:37Z 에 `request_body_refused` 로 끝났다. 그 뒤 한 턴 원본이 119번 거절된 끝에 접수돼 한 턴(atom 4169→4188)을 커밋했다. 읽은 위치는 약 1.5시간에 두 턴 움직였다. 그 한 턴 요청은 약 296,740 B 였고, 그중 지금 Memory 가 217,200 B, 대화가 71,213 B 다.
- 서버를 다시 띄운 뒤 같은 일이 되풀이됐다. 00:15 KST 의 전부 읽기 원본(303%)은 00:38 KST 에 한 턴 원본(264,138 B, frame 의 6%)으로 바뀌어 접수돼 있었다.

같은 기간에 keeper-librarian 설치가 멈춘 구간이다. 그동안에는 읽지 못한다. 원인은 이 RFC 에서 따지지 않는다.

- 11-13 19:59~20:03 KST: 설치 실패
- 11-14 18:17~11-15 19:33 KST: Add-on 이 붙어 있지 않음
- 11-16 15:18~18:5x KST: `record_failed` 14,274번(durable 12,076, admission 2,198)
- 11-16 21:00:23 KST: worker 가 종료 코드 137 로 끝남

이 구간에 durable 회차는 "원본을 낼 수 없다"(`Original_publication_blocked`)를 이틀 동안 356번 보고했다. 이 오류로 끝난 회차는 표식을 남기지 않는다. 이 값을 만드는 자리가 consumer 밖에 있어서다(§1.2).

재는 법과 한계.

- 안 읽은 턴은 서버가 세는 값이 아니라 파일을 읽는 스크립트로 셌다. dashboard API 는 인증이 필요해 TUI 값과 맞춰 보지 못했다.
- 요청 크기는 추정이다. 원본 본문의 메시지를 Librarian 이 프롬프트로 옮기는 규칙(`keeper_librarian.ml` 의 `text_of_content`)대로 셌고, worker 가 재는 canonical 바이트와 같지 않다.
- 접수 거절은 `<base>/.masc/lane-addons/tool-request-owners` 기록의 `admission_declined` 사건 수다.
- 한 턴 원본이 얼마나 자주 생기는지는 세지 못했다. 끝난 원본의 본문은 남지 않는다. 본 것은 code-reviewer 한 Keeper 다.
- 큰 요청(1~4 MB)이 공급자에서 받는 답은 재지 못했다. 접수된 적이 없어서 공급자에 닿은 적이 없다.
- 본문과 대화 내용은 읽어서 세기만 했고 옮겨 적지 않았다.

### 1.2 코드 (`origin/main` `db84e1677d90`)

접수와 목록.

| 무엇 | 자리 |
|---|---|
| 접수 판정. 기다리는 요청과 새 요청을 합친 목록이 frame 에 안 들어가면 `capacity_wait` | `addons/exact_worker.py` 402~412행 |
| 목록. 기다리는 요청 전체를 답 하나로 돌려준다. 안 들어가면 오류다 | 같은 파일 460행 `host_requests` |
| 기다리는 기록의 순서는 파일 이름 순서다. 이름은 요청 id 의 sha256 이다 | 같은 파일 287행, 298행 `Store.pending` |
| 기다리는 기록은 필드 넷(`version`, `request`, `digest`, `result`)이 정확히 맞아야 읽힌다. 하나라도 못 읽으면 worker 가 멈춘다 | 같은 파일 235행, 289~292행 |
| `capacity_wait` 는 원본을 끝내지 않는다. 거절 기록만 남기고 기다린다 | `lib/lane_addon/lane_addon_submit_once.ml` 179~182행 |
| 결과 하나가 전달되면 그 설치의 capacity 대기자를 모두 깨운다 | `lib/keeper/keeper_librarian_queue_refresh.ml` 57행, `lib/server/server_librarian_addon_wake.ml` 172행 |
| host cycle. 목록의 요청을 cycle 에 한 번씩 시도하고, 전달이 있었으면 목록을 다시 받는다 | `lib/lane_addon/lane_addon_runtime.ml` 1436행, 1443~1453행 |
| 끝나지 않은 시도는 목록에 남아 다음에 다시 시도된다. 횟수 상한을 두는 문장은 없다 | `lib/lane_addon/lane_addon_exact.mli` 168~169행 |
| 목록의 계약 문장: "the worker lists every request it waits for" | `lib/lane_addon/lane_addon_types.mli` 115행 |

폭.

| 무엇 | 자리 |
|---|---|
| 읽는 폭. 표식이 있으면 한 턴, 없으면 전부 | `lib/keeper/keeper_librarian_durable_consumer.ml` 1693행 |
| 표식을 세우는 자리 ①. 다시 잡은 원본이 거절로 끝났을 때. 거절의 종류는 보지 않는다. counterpart 만 담은 원본은 뺀다 | `lib/keeper/keeper_librarian_durable_execution.ml` 368~376행 |
| 표식을 세우는 자리 ②. message floor 후보가 있을 때 | 같은 파일 686~691행 |
| 표식을 세우는 자리 ③. consumer 안의 읽기 오류, 같은 pass 에서 받은 거절, 예외와 취소 | `keeper_librarian_durable_consumer.ml` 1698행, 1709~1738행 |
| ③ 은 pass 를 시작할 때 표식을 세우고, 끝난 모양을 보고 지운다. `Pending`, 읽을 것이 없음, 전부 읽기의 성공에서 지운다. 한 턴 읽기의 성공, 같은 pass 의 거절, 오류 갈래 22개에서는 그대로 둔다. 거절된 원본 없이도 표식이 남는다 | `keeper_librarian_durable_consumer.ml` 1698행, 1709~1738행 |
| `Original_publication_blocked` 로 끝난 회차는 표식을 남기지 않는다. 이 값을 만드는 자리는 execution 의 도우미 하나뿐이다. consumer 를 부르기 전에 돌아가거나, consumer 가 부른 commit 안에서 `Memory_pending` 이 된다. 그때 consumer 는 `Pending` 을 돌려주며 이번 pass 의 표식을 지우고, 그 뒤에 execution 이 결과를 이 오류로 바꾼다. consumer 의 1726행 갈래는 타입을 다 덮으려고 있고, consumer 안에는 이 값을 만드는 곳이 없다 | `keeper_librarian_durable_execution.ml` 336행, 625~626행, 692~695행, `keeper_librarian_durable_consumer.ml` 1710~1713행 |
| durable 회차 루프는 커밋 뒤에 바로 다음 범위를 읽는다. 기다리는 unit 이 있으면 양보한다. 거절이나 오류 뒤에는 멈추고 다음 신호를 기다린다 | `keeper_librarian_queue_refresh.ml` 361~372행, 373~382행 |
| 표식은 읽을 것이 없을 때, baseline 을 옮겼을 때, 전부 읽기가 성공했을 때, official 줄에서 멈췄을 때 풀린다 | `keeper_librarian_durable_consumer.ml` 1718~1723행 |
| Keeper 의 durable 회차는 끝나지 않은 원본이 있으면 그것만 다시 잡는다 | `keeper_librarian_durable_execution.ml` 592~595행 |
| 폭의 타입은 `All_unread`, `To_first_cut_point` 둘이다 | `lib/keeper/keeper_librarian_range.mli` 28~29행 |
| 한 턴 읽기는 atom 과 official 중 앞선 하나만 남긴다 | `keeper_librarian_durable_consumer.ml` 1326~1330행 |
| 원본에 적는 폭 라벨은 `all_unread`, `first_cut`. 원본 검증은 그 라벨로 범위를 다시 고른다 | `lib/keeper/keeper_librarian_durable_capture.ml` 455행, 577행, 596행 |
| 연속성 회차는 이름 붙은 크기 거절로 접은 뒤 다음 회차를 스스로 건다. durable 회차는 걸지 않는다 | `lib/keeper/keeper_librarian_queue_refresh.ml` 784~786행 |

공용 worker(`addons/exact_worker.py`)는 keeper-librarian, workspace-curator, candle-appraiser, hitl-auto-judge 가 같이 쓴다. 목록에는 `exact_output` 요청만 실린다.

## 2. 문제

밀린 양이 그 Keeper 가 읽히는 양을 줄인다. 자리는 둘이다.

접수. worker 가 받을 수 있는 양의 상한이 답 frame 하나다. 목록을 답 하나로 돌려주기 때문에 생긴 상한이고, 기다릴 수 있는 양과는 상관없는 값이다. frame 은 혼자 오는 요청을 거절하지 않았는데 worker 는 미룬다. 자리가 났을 때 들어맞는 요청이 들어가니 작은 요청은 자주 들어가고 큰 요청은 거의 못 들어간다. 밀린 Keeper 의 요청이 가장 크다.

폭. 거절된 회차는 다음에 한 턴만 읽는다. 거절은 "그 범위는 많다"는 말인데 코드는 "한 턴보다 많으면 안 된다"로 읽는다. 표식은 밀린 범위를 다 읽어야 풀린다. `RFC-librarian-lifecycle` §4.3 은 근거를 "잘못 좁혀도 비용은 한 턴씩 읽는 회차들"이라고 적었다. 잰 값은 이 전제와 다르다.

- 한 턴 회차도 요청 하나다. 답까지 걸리는 시간의 중앙값이 717.5초다. Keeper 는 원본 하나가 끝나야 다음 범위를 고른다. 중앙값으로 어림하면 하루에 86,400 / 717.5 = 120번쯤이다.
- 하루에 그보다 많이 끝내는 Keeper 는 한 턴 읽기로 밀린 범위를 비우지 못한다. 표식이 풀리지 않는다. §1.1 의 다섯 Keeper 가 그만큼 끝낸다.
- 한 턴 요청의 대부분은 턴과 상관없는 고정 부분이다. code-reviewer 의 한 턴 요청 296,740 B 중 지금 Memory 가 217,200 B 다.

두 자리는 서로를 키운다. 접수되지 못한 요청은 밀린 양만큼 커진다. frame 을 넘으면 거절을 받아 한 턴으로 떨어진다. 한 턴 요청은 작아서 접수되지만 들어오는 양보다 느리다.

## 3. 결정

규칙은 하나다.

> 읽기를 미루거나 줄일 때는 받는 쪽의 거절이 말한 만큼만 한다.

받는 쪽은 worker 의 답 frame 과 exact lane 의 공급자다. 거절이 말하는 것은 "이 요청은 받지 못한다" 하나다. 다른 요청과 더 작은 범위에 대해서는 말하지 않는다.

### 3.1 D1. worker 는 요청 하나만 보고 받고, host cycle 은 기다리는 요청을 모두 걷는다

`capacity_wait` 는 frame 이 거절하지 않은 요청을 미룬다. 규칙에 어긋난다.

- 접수는 요청 하나가 frame 에 들어가는지만 본다. 들어가면 받는다. 안 들어가면 지금처럼 본문 없는 `request_body_refused` 로 끝낸다.
- 목록은 여러 장이다. 그렇게 답하는 package 는 manifest 에 `[world] host_request_pages = true` 를 적는다.
- 한 장은 기다리는 요청을 request id 가 커지는 순서로, frame 에 들어가는 만큼 싣는다. 순서는 바이트 순서다. 답은 지금과 같은 `{"requests": [...]}` 이고, 키를 더하지 않는다(§4.5).
- host 는 장의 마지막 request id 를 `after` 인자로 넘겨 다음 장을 받는다. 빈 장이 오면 목록이 끝난다.
- host 는 장마다 id 가 `after` 보다 크고 바로 앞 id 보다 큰지 본다. 어긋난 장이 오면 그 목록을 거절한다.
- 혼자서도 지금 frame 에 안 들어가는 기록을 만나면 지금처럼 오류로 답한다. 접수한 뒤에 frame 이 줄어든 경우다. 말없이 건너뛰지 않는다.
- host cycle 의 pass 는 모든 장을 걷는다. walk 는 다음 장을 필요할 때 받는다. 그래서 함께 실행하는 수가 장의 경계에서 줄지 않는다.
- worker 는 장 하나를 만들 때 frame 하나 분량의 본문만 든다. 지금은 기다리는 본문 전체를 한꺼번에 읽는다(`Store.pending`).
- 기다리는 기록의 필드는 바꾸지 않는다. 새 worker 가 앞 worker 의 기록을 그대로 읽는다. `RFC-librarian-ends-waiting-requests-of-a-replaced-declaration` 5절이 package 를 올리는 쪽에 건 조건이다.
- 받은 순서는 따로 적지 않는다. 한 cycle 이 기다리는 요청을 모두 한 번씩 시도하므로 순서가 요청을 굶기지 않는다.

지우는 것.

- worker 의 `capacity_wait` 답
- `lane_addon_submit_once.ml` 의 `Capacity_wait` 와 그 거절 기록. `Admission_declined` 는 보내지 못한 경우(`not_sent`)에만 남는다
- capacity 대기를 나르는 타입과 라벨: `keeper_librarian_pending.ml`, `keeper_librarian_durable_owner.ml`, `keeper_librarian_admission_dispatch.ml`, `keeper_librarian_floor_step_owner.ml`, `keeper_librarian_durable_execution.ml` 342행, `server_workspace_memory_addon.ml`, TUI 의 `capacity` 표시
- capacity 대기자를 깨우는 장치(`capacity_released`, `recheck_capacity_release`, `server_librarian_addon_wake.ml` 의 호출)
- `server_candle_appraiser.ml` 의 `Capacity_wait` 와 두 Add-on README 의 문장

목록의 계약 문장은 이렇게 바꾼다. worker 는 기다리는 요청을 모두 내놓는다. `host_request_pages` 를 선언한 worker 는 여러 장으로 내놓는다. 선언하지 않은 worker 는 지금처럼 답 하나로 내놓고, host 는 그 worker 에게 `after` 를 보내지 않는다. operator-quiz 계열 worker 는 고치지 않는다.

### 3.2 D2. 거절된 회차는 다음에 절반을 읽고, 거절된 범위를 다 읽으면 그 거절은 끝난다

지금은 범위가 얼마든 한 턴으로 떨어지고 밀린 범위가 빌 때까지 그대로다. 거절이 말한 것보다 더 줄이고, 거절이 말하지 않은 범위에까지 적용한다. 규칙에 어긋난다.

폭을 줄이는 계기는 거절로 끝난 원본이다. 거절의 종류는 지금처럼 보지 않는다(§9 Q3). 바뀌는 것은 얼마나 줄이고 언제 푸는가다.

- §1.2 의 ①, ②, 그리고 ③ 가운데 같은 pass 에서 받은 거절이 여기에 든다. 셋 다 거절된 원본이 있고 그 원본이 범위를 담고 있다.
- ③ 의 나머지는 거절된 원본이 없다. consumer 안의 읽기 오류, 예외, 취소다. 받는 쪽이 아무 말도 하지 않았으므로 폭을 줄이지 않는다. 다음 회차의 폭은 그 pass 가 없었을 때와 같다.
  - 지금은 이 경우에도 한 턴으로 떨어지고 밀린 범위가 빌 때까지 그대로다. 이 RFC 가 계기에서 바꾸는 것은 이 하나다.
  - 이 오류들 가운데 받는 쪽이 낸 것은 없다. consumer 가 Keeper 의 기록과 읽은 위치를 다루다 낸다. 받는 쪽의 답은 commit 의 결과(`Memory_refused`, `Memory_pending`, `Memory_committed`)로만 들어온다.
  - 이틀 로그의 "범위를 읽지 못함" 보고 356건에 이 종류는 없었다(§1.1). 예외와 취소는 그 보고에 잡히지 않는다(§9 Q6).
- 그래서 pass 를 시작할 때 세우는 표식(1698행)이 없어진다. 적어 두는 것은 아래 "풀기"의 수뿐이고, 그 수는 거절된 원본에서만 생긴다.

폭.

- 폭의 타입을 `All_unread | First_cut_points of n`(n 은 1 이상)으로 바꾼다. 지금의 `To_first_cut_point` 는 n = 1 이다.
- cut point 는 atom 턴의 끝 줄과 official 턴의 줄이다. 두 종류를 경계 기록의 줄 순서로 합쳐 가장 오래된 n개를 센다.
- 합쳐 고르는 함수를 `keeper_librarian_range.ml` 에 하나 둔다. 지금은 한 턴일 때만 consumer 가 둘 중 앞선 것을 고른다(1326~1330행). consumer, 원본 검증(`validate_selection`), `bin/masc_librarian_replay.ml` 이 같은 함수를 쓴다. 그래야 저장된 라벨만으로 같은 범위가 다시 골라진다.

줄이기.

- cut point w개를 읽은 원본이 거절로 끝났으면 다음 회차는 가장 오래된 ⌊w/2⌋개를 읽는다. w 가 2 이상일 때다. w 는 거절된 원본이 담은 범위에서 센다.
- w 가 1 이면 지금과 같다. 한 턴 안에서는 message floor 가 메시지 단위로 내려간다(`keeper_librarian_floor_descent.ml`).
- 절반은 고른 숫자가 아니다. 거절은 그 범위가 많다는 것만 말한다. 더 작은 범위 가운데 아무것도 가정하지 않고 고를 수 있는 걸음이다. Keeper 턴의 이력 줄이기(`keeper_turn_driver_try_provider.ml`), Memory admission 의 나누기(`keeper_memory_admission_queue.mli`), 연속성 폭 모델(`LibrarianContinuityWidth.tla`)이 같은 걸음을 쓴다.
- 접은 뒤에는 다음 회차를 바로 건다. 연속성 회차가 하는 것과 같다. 턴을 더 끝내지 않는 Keeper 도 내려간다.
  - 지금 루프는 거절 뒤에 멈추고 다음 신호를 기다린다(§1.2). 폭을 접은 거절에서만 그 Keeper 의 신호를 한 번 넣는다. w 가 1 인 거절과 거절 없는 오류는 지금처럼 멈춘다.
  - 커밋 뒤에는 지금도 루프가 바로 다음 범위를 읽는다. 이 부분은 바꾸지 않는다.

풀기.

- 거절은 그 범위에 대한 말이다. 그 범위를 다 읽으면 그 거절은 끝났다.
- 루프는 거절된 범위마다 "그 범위의 끝까지 남은 cut point 수"를 적어 둔다. 여러 번 접었으면 안쪽 범위부터 차례로 쌓인다.
- k개를 커밋하면 적어 둔 수에서 모두 k 를 뺀다. 0 이 된 것은 지운다.
  - 지금은 한 턴 읽기가 성공해도 표식을 그대로 둔다(`Ok (Progress_advanced | Official_advanced), To_first_cut_point` 갈래, 1724행). 이 갈래가 수를 빼는 자리로 바뀐다.
- message floor 후보(②)는 한 턴 원본이 거절됐다는 저장된 증거다. 남은 수 1 로 적는다.
- 다음 폭은 가장 안쪽에 남은 범위가 정한다. 그 범위에서 아직 아무것도 커밋하지 않았으면 절반이다. 커밋한 것이 있으면 남은 부분 전부다. 남은 부분은 거절된 범위보다 작으니 거절된 적이 없는 범위다.
- 남은 범위가 없으면 전부 읽는다.
- message floor 가 한 턴을 넘기면 그 한 턴을 커밋한 것으로 센다.
- 이력 세대가 바뀌면 적어 둔 것을 지운다. 지금처럼 루프의 메모리에만 두고, 서버가 재시작하면 전부 읽기부터 다시 한다. 재시작 뒤 message floor 후보가 있으면 지금처럼 한 턴부터다.

예. 가장 오래된 턴 하나가 혼자서도 거절되는 크기이고 뒤의 턴은 작다. 16개가 밀려 있다.

| 회차 | 읽은 것 | 결과 | 남은 수(안쪽부터) |
|---|---|---|---|
| 1 | 16개 | 거절 | 16 |
| 2 | 8개 | 거절 | 8, 16 |
| 3 | 4개 | 거절 | 4, 8, 16 |
| 4 | 2개 | 거절 | 2, 4, 8, 16 |
| 5 | 1개 | 거절. message floor 가 넘긴다 | 1, 3, 7, 15 |
| 6 | 1개 | 커밋 | 2, 6, 14 |
| 7 | 2개 | 커밋 | 4, 12 |
| 8 | 4개 | 커밋 | 8 |
| 9 | 8개 | 커밋 | 없음 |

지금 규칙이면 2회차에 한 턴으로 떨어지고, message floor 가 그 턴을 넘긴 뒤 남은 15개를 15회차에 걸쳐 한 턴씩 읽는다.

라벨.

- 원본에 적는 폭 라벨은 값을 더하기만 한다. `all_unread` 와 `first_cut` 의 뜻과 표기는 그대로다. n = 1 은 `first_cut` 으로 쓴다. 배포할 때 기다리던 원본이 그대로 읽히고 digest 도 같다.
- message floor 의 후보 조건은 "한 턴을 읽은 원본"이다. n = 1 인 원본이 그것이고 조건은 바뀌지 않는다.

어떤 거절이 폭을 줄여야 하는지는 이 RFC 에서 정하지 않는다(§9 Q3). 연속성 회차의 좁히기도 바꾸지 않는다.

## 4. 논증

### 4.1 불변식

- I1. 접수의 답은 요청 하나의 크기로만 정해진다. 다른 요청이 얼마나 기다리는지는 답을 바꾸지 않는다.
- I2. 한 cycle 은 시작할 때 worker 가 기다리던 `exact_output` 요청을 모두 한 번씩 시도한다. 다른 요청이 끝났는지와 상관없다. 걷는 동안 접수된 요청은 늦어도 다음 cycle 에 시도된다.
- I3. 거절된 범위 안에서 시작하는 회차는 그 범위의 끝을 넘지 않고, 그 범위 전체를 다시 내지도 않는다. 서버가 도는 동안의 일이다.
- I4. 폭은 한 번의 거절에 절반보다 더 줄지 않는다. 거절된 범위를 벗어난 회차는 전부를 읽는다.
- I5. 읽은 위치는 Memory 커밋 뒤에만 움직인다. 접은 회차도 가장 오래된 쪽부터 읽으므로 건너뛰는 턴이 없다. 지금과 같다.

### 4.2 진행

- 접수된 요청은 다음 cycle 에 시도된다. 요청의 크기와 다른 요청의 상태가 이것을 막지 않는다. 지금은 접수된 요청만 그렇다.
- 폭은 거절마다 절반이 된다. cut point n개에서 시작하면 ⌊log2 n⌋번 안에 1 에 닿는다. 4,229개면 12번이다. 1 에서는 지금의 message floor 가 이어받는다.
- 커밋은 적어 둔 수를 모두 줄인다. 거절된 범위는 유한하므로 그 범위에 묶인 좁은 폭은 유한한 커밋 뒤에 풀린다.

### 4.3 산수와 한계

아래는 중앙값 717.5초로 한 어림이다. 상한이 아니다.

- 함께 3개가 돌면 한 시간에 끝나는 요청은 3 × 3,600 / 717.5 = 15.1개쯤이다.
- 모든 회차가 한 턴이면 시간당 15턴쯤 읽는다. 들어오는 양은 90.3턴이다.
- 전체로 따라가려면 요청 하나가 평균 90.3 / 15.1 = 6.0턴 이상을 읽어야 한다.
- Keeper 하나는 원본 하나가 끝나야 다음을 낸다. 요청 q개가 기다리면 한 바퀴가 q × 717.5 / 3 초다. q 가 26 이면 6,218초이고 하루 13.9바퀴다.
- 그때 code-reviewer 는 요청 하나가 351 / 13.9 = 25턴을 읽어야 제자리다. pr-updater 는 19턴이다. 전체 평균이 6.0 을 넘어도 이 둘은 밀릴 수 있다.
- D1 과 D2 는 요청 하나가 읽는 턴 수를 받는 쪽이 허락하는 만큼으로 되돌린다. 그 값이 위 숫자를 넘는지는 설치 뒤에 Keeper 별로 잰다.
- 요청 하나의 717.5초와 lane 성공 호출의 p50 454.8초 사이에 약 260초 차이가 있다. 어디서 쓰이는지는 따지지 않았다.
- 함께 실행하는 수와 lane 구성은 운영자가 재고 정하는 값이다. 이 RFC 는 건드리지 않는다.

### 4.4 대가

- worker 저장소가 받는 양의 상한이 frame 하나에서 디스크로 바뀐다. 지금 원본 기록 27개의 요청은 약 37.7 MB 다. worker 는 처음 불릴 때 기다리는 기록을 하나씩 검증한다. 그 시간이 host 의 호출 한도에 걸리는지는 확인하지 않았다(§7.2).
- 접수된 기록이 나중에 혼자서 frame 에 안 들어가게 되는 길은 frame 을 줄인 package 하나다. 그때는 그 기록이 든 장의 목록이 오류로 끝난다. 지금도 같다. #51278 의 설계가 새 package 는 `max_reply_bytes` 를 줄이지 않는다고 요구한다(그 문서 7절).
- 적어 둔 수는 서버가 재시작하면 사라진다. 재시작 뒤 첫 회차는 전부 읽기라, 이미 거절된 범위를 한 번 더 내 본다. 재시작이 잦으면 그만큼 거절을 더 받는다.
- 거절 없이 끝난 pass 는 폭을 줄이지 않는다. 넓은 범위에서만 나는 예외나 취소가 있다면 같은 범위에서 되풀이된다. 지금은 한 턴으로 떨어져 가려진다(§9 Q6).
- 큰 요청이 처음으로 공급자에 닿는다. 시간 초과와 rate limit 은 요청을 끝내지 않는다. 그런 답만 받는 큰 요청은 cycle 마다 다시 시도되고, 그 Keeper 는 새 범위를 고르지 못한다. 지금 접수되지 못하는 것과 그 Keeper 에게는 같은 결과지만, cycle 마다 실행 자리 하나를 쓴다. 빈도는 모른다(§9 Q2).
- 공용 worker 를 고치므로 네 package 의 revision 이 모두 바뀐다. revision 이 바뀌면 그 설치에서 기다리던 Librarian 원본이 막힌다(#51278).
- D2 는 거절된 범위를 다 읽을 때마다 더 넓은 범위를 다시 내 본다. 밀린 양이 받는 쪽의 한도보다 계속 큰 Keeper 는 커밋 한 번에 거절을 한 번쯤 받는다. frame 에서 받는 거절은 host 가 본문을 보내지 않고 낸다. 공급자에서 받는 거절은 걸음 한 번의 시간이 든다(§9 Q1).
- 새 폭 라벨이 생긴 뒤 이전 빌드로 돌아가면, 그 라벨을 가진 원본에서 그 Keeper 의 pass 가 막힌다.
- 여러 장 worker 는 기다리는 요청이 있는 pass 마다 빈 장을 한 번 더 읽는다. 목록 호출이 하나 는다.
- 앞 서버는 `host_request_pages` 가 든 manifest 를 읽지 못한다. 그렇다고 서버를 먼저 올리면, `capacity_wait` 를 답하는 worker(0.2.6 전)의 원본이 멈춘다. 새 서버는 그 답을 읽지 않고, 원본은 `Dispatch_pending` 에 남아 다시 보내지지 않는다(#52762). 그래서 서버를 멈추고 선언을 새 package 로 바꾼 뒤 새 서버를 띄운다. 0.2.6 이 도는 설치만 서버를 먼저 올려도 잃는 것이 없다.

### 4.5 여러 장 목록이 닫히는 이유

P(r) 를 "기록 r 하나만 실은 장 `{"requests": [r]}` 이 frame 에 들어간다"로 둔다.

- 기다리는 기록은 모두 P 를 지킨다. 새 접수가 P 를 그대로 잰다. 앞 worker 의 접수도 첫 검사가 같은 식이었다. 그래서 설치할 때 남아 있던 기록도 P 를 지킨다.
- 장에 키를 더하지 않는 이유가 이것이다. `next` 같은 키를 더하면 장이 P 가 잰 것보다 길어진다. 그러면 frame 에 바짝 붙은 앞 기록 하나가, 그 뒤에 기록이 들어온 순간 장을 만들지 못한다.
- 장 i 는 커서 a(i-1) 위의 첫 기록부터 싣는다. 그 기록이 P 를 지키므로 장은 비지 않는다.
- 다음 커서 a(i) 는 장 i 의 마지막 id 다. 그래서 a(i-1) < a(i) 다. 커서가 커지기만 하므로 두 장이 같은 요청을 싣지 않는다. host 가 장마다 이것을 확인한다.
- 기록은 유한하고 커서는 커지기만 한다. 그래서 목록은 빈 장에서 끝난다. 걷는 동안 새 기록이 계속 들어오면 그만큼 늦게 끝난다.
- 걷는 동안 계속 기다린 요청은 빠지지 않는다. 마지막 빈 장은 마지막 커서 위에 기다리는 요청이 없다는 답이다. 그러니 그 요청의 id 는 어떤 장 i 의 구간 (a(i-1), a(i)] 에 든다. worker 는 장을 앞에서부터 잘라 내므로, 장 i 는 그 구간에서 기다리던 요청을 모두 실었다.
- 같은 입력에는 같은 답이 나온다. 장은 기다리는 기록, `after`, frame 셋으로만 정해진다. 접수의 답은 요청 하나와 frame 으로만 정해진다(I1).
- host 가 혼자 확인하는 것은 겹치지 않음까지다. 빠짐없음은 worker 가 장을 앞에서부터 잘라 낸다는 계약에 기댄다.

## 5. 고르지 않은 길

| 길 | 고르지 않은 이유 |
|---|---|
| 거절된 요청에 host 쪽에서 순서만 매긴다 | 기다릴 수 있는 양이 frame 하나인 채로 남는다. 거절될 때마다 본문을 다시 읽고 보내는 일도 남는다 |
| 목록을 받은 순서의 앞부분 한 장만 준다 | 끝나지 않는 요청이 맨 앞에 서면 뒤의 요청이 목록에 나오지 못한다. 지금 접수된 요청끼리는 서로 막지 않는데 그것을 잃는다 |
| worker 기록에 받은 순서를 적는다 | 기다리는 기록의 필드가 바뀌어 새 worker 가 앞 기록을 읽지 못한다. 모든 요청을 cycle 마다 시도하면 순서가 필요 없다 |
| frame(`max_reply_bytes`)을 키운다 | 숫자를 고르는 일이다. 기다리는 양은 frame 9.0개였고, 요청 하나가 frame 을 넘는 Keeper 도 있다 |
| `max_exact_in_flight` 를 올린다 | 접수되지 못한 요청은 목록에 없어서 실행되지 않는다. 값은 운영자가 전후를 재고 정하기로 했다 |
| 답에 `next` 를 실어 다음 장을 알린다 | 장이 `{"requests": [r]}` 보다 81바이트(기록 이름 69자를 담은 키) 길어진다. 앞 worker 는 짧은 장으로 접수했다. 그래서 frame 에 그만큼 붙은 기록이 남아 있으면, 그 뒤에 기록이 들어온 순간 장을 만들지 못한다 |
| 모든 worker 를 여러 장으로 답하게 한다 | operator-quiz 계열은 ask 를 만들 때 frame 에 재지 않는다. 여러 장 규약에서는 혼자 frame 을 넘는 ask 하나가 그 설치의 목록을 막는다 |
| 요청이 frame 에 맞도록 미리 잘라 보낸다 | 바이트 숫자로 미리 자르는 기준을 두지 않는다(2026-10-06 운영자 결정). 받는 쪽의 이름 붙은 거절에 반응한다 |
| 접은 폭을 밀린 범위가 빌 때까지 유지한다 | 가장 오래된 턴 하나가 혼자서도 거절되면 반드시 한 턴까지 내려가고, 그 뒤 남은 턴을 모두 한 턴씩 읽는다(§3.2 의 예) |
| 커밋할 때마다 전부 읽기로 돌아간다 | 커밋마다 맨 위에서 다시 내려간다. `LibrarianContinuityWidth.tla` 의 `release-on-commit` 버그 모델이다 |
| 크기와 무관한 거절은 폭을 줄이지 않게 한다 | 출력 한도처럼 줄여야 나아가는 거절이 전부 읽기에서 되풀이될 수 있다. 얼마나 자주인지 잰 값이 없다(§9 Q3) |
| 목록에 본문을 싣지 않고 host 가 가진 본문을 digest 로 쓴다 | 요청 크기가 frame 에 묶이지 않게 되지만 공용 host-request 규약 전체가 바뀐다. frame 이 공급자의 창보다 먼저 걸리는지 잰 값이 없다 |

## 6. 층

L1 이 먼저다. L2 를 먼저 넣으면 접은 범위가 frame 안에 처음 들어오는 단(예: 12.7 → 6.4 → 3.2 MB)에서 거절도 접수도 받지 못하고 지금의 아홉 요청처럼 굶는다.

| 층 | 내용 | 닿는 곳 |
|---|---|---|
| L1 | D1. 접수, 여러 장 목록과 그 manifest 선언, 모든 장을 걷는 pass, `capacity_wait` 삭제, 네 package revision | `addons/exact_worker.py`, 네 Add-on package, `lib/lane_addon/lane_addon_manifest.ml`, `lane_addon_types.ml`, `lib/lane_addon/lane_addon_runtime.ml`, `lane_addon_host_walk.ml`, `lane_addon_host_request.ml`, `lane_addon_submit_once.ml`, `lane_addon_types.mli`, §3.1 "지우는 것"의 파일 |
| L2 | D2. 폭 타입, 합쳐 고르는 함수, 절반 접기와 풀기, 접은 뒤 다음 회차 걸기 | `lib/keeper/keeper_librarian_range.ml`, `keeper_librarian_durable_consumer.ml`, `keeper_librarian_durable_execution.ml`, `keeper_librarian_durable_capture.ml`, `keeper_librarian_floor_descent.ml`, `bin/masc_librarian_replay.ml` |

- L1 은 package 를 올린다. 기다리던 원본이 막히는 문제(#51278)는 #52622·#52674·#52695 가 풀었다. 그래도 기다리는 원본은 업그레이드 절차에서 따로 다룬다.
- L2 는 host 코드만 바꾼다. package 를 올리지 않는다.
- L1 은 서버를 멈추고 선언을 바꾼 뒤 새 서버를 띄운다(§4.4).
- L1 은 처음에 `next` 판(#52728·#52729·#52731, keeper-librarian 0.2.6)으로 병합됐다. 그 판은 장에 `next` 를 더해서 §4.5 의 논증이 닫히지 않았다. 요청 id 커서 판(0.2.7)이 그 뒤를 잇는다.
- L1 을 설치한 뒤 §7.2 를 재고 L2 를 넣는다.

## 7. 검증

### 7.1 시험과 모델

- worker(`addons/tests/test_keeper_librarian.py`, 다른 세 Add-on 의 시험): 기다리는 요청이 frame 을 넘겨도 혼자 들어가는 요청은 접수된다. 장을 이어 받으면 기다리는 요청이 빠짐없이 한 번씩 나온다. 앞 버전이 쓴 기록을 그대로 읽는다. 혼자서도 frame 에 안 들어가는 기록에서는 오류로 답한다.
- host(`test/test_lane_addon_submit_once.ml`, host cycle 시험): 접수의 답은 받음, 크기 거절, 보내지 못함 셋이다. 끝나지 않는 요청이 첫 장을 채워도 뒤 장의 요청이 같은 cycle 에 시도된다. 함께 실행하는 수가 장의 경계에서 줄지 않는다.
- 폭(`test/test_keeper_librarian_range.ml`, `test_keeper_librarian_durable_consumer.ml`, `test_keeper_librarian_durable_execution.ml`): atom 과 official 이 섞인 범위에서 n개를 고른다. 저장된 라벨로 같은 범위가 다시 골라진다. §3.2 의 예가 표대로 돈다. 접은 뒤 다음 회차가 걸린다. 거절 없이 끝난 pass(읽기 오류, 예외) 뒤의 폭은 그 pass 앞과 같다. `Original_publication_blocked` 로 끝난 pass 뒤에도 같다.
- TLA+: `LibrarianContinuityWidth.tla` 와 같은 틀로 durable 폭을 모델링한다. 고친 `Next` 는 I3 과 I4 를 지키고, 턴이 더 들어오지 않으면 밀린 범위를 비운다. 버그 모델은 둘이다. 거절에 곧바로 1 로 떨어지고 밀린 범위가 빌 때까지 두는 것(지금의 코드)은 I4 를 어겨야 한다. 커밋마다 전부 읽기로 돌아가는 것은 I3 을 어겨야 한다.

### 7.2 배포 뒤 측정

같은 길이의 창을 전후로 잰다.

| 층 | 재는 것 | 기대 |
|---|---|---|
| L1 | 원본 기록의 `admission_declined` 사건 | `not_sent` 말고는 0 |
| L1 | 접수된 요청의 크기 분포 | frame 까지 고르게. 지금은 16% 이하뿐이다 |
| L1 | 1 MB 넘는 요청이 받은 결과의 종류와 걸린 시간 | 처음 재는 값이다. §9 Q1, Q2 를 정한다 |
| L1 | `running_at_start` 가 2 인 시도의 비율 | 줄지 않는다 |
| L1 | worker 가 목록 한 장을 답하는 데 걸린 시간 | host 의 호출 한도 안이다. 넘으면 L1 을 되돌린다 |
| L2 | "범위를 읽지 못함" 보고의 종류와, 같은 범위에서 되풀이된 횟수 | 거절 없는 종류가 되풀이되지 않는다(§9 Q6) |
| L2 | Keeper 별 커밋 하나가 읽은 턴 수 | §4.3 의 Keeper 별 숫자와 비교한다 |
| L2 | Keeper 별 커밋 하나당 거절 수 | 1 이하. 그 거절이 쓴 시간 |
| 전부 | 안 읽은 턴의 합과 Keeper 별 가장 오래된 턴 | 줄어든다. 줄지 않으면 §4.3 의 값을 본다 |

## 8. 바꾸는 문장

- `docs/rfc/RFC-librarian-lifecycle.md`: §4.3 의 "두 턴 이상을 읽다 실패했으면…" 문단(314행), 연속성 문단 안의 durable 설명(315행), "durable 회차는 실패 종류를 보지 않는다. 바닥이 한 턴이라…" 문단(317행), §4.4 표의 3a(434행). 한 턴으로 좁힌다는 설명을 절반 접기와 풀기로 바꾼다. "실패 종류를 보지 않는다"는 "거절의 종류를 보지 않는다. 거절 없이 끝난 회차는 폭을 바꾸지 않는다"로 바꾼다.
- `lib/lane_addon/lane_addon_types.mli` 의 `host_requests_tool` 설명: §3.1 의 계약 문장.
- `docs/guides/lane-addon-toml.md` 의 `[world]` 키 목록과 `lane_host_requests` 문단.
- `docs/rfc/RFC-librarian-ends-waiting-requests-of-a-replaced-declaration.md` 3.4: "지금처럼 좁힌다"가 가리키는 폭.
- `addons/workspace-curator/README.md`, `addons/candle-appraiser/README.md` 의 `capacity_wait` 문장.
- `lib/keeper/keeper_librarian_range.mli` 의 `extent` 설명.

## 9. 열린 질문

- Q1. D2 의 다시 넓혀 보기가 쓰는 시간. 큰 요청이 공급자에서 거절되는 데 걸리는 시간을 L1 뒤에 잰다. 짧으면 D2 그대로 간다. 길면 "거절된 폭을 한동안 한도로 믿는다"는 가정을 더할지 정해야 한다. 그 가정은 §5 의 "접은 폭을 밀린 범위가 빌 때까지 유지한다" 줄의 문제를 다시 부른다. 재기 전에는 가정 없는 D2 를 권한다.
- Q2. 끝나지 않는 큰 요청. 시간 초과만 받는 요청은 지금 설계에서 끝나지 않는다. L1 뒤에 그런 요청이 있는지, 어느 slot 에서 어떤 한도에 걸리는지 잰다. 있으면 그 원인이 다음 설계의 입력이다. 횟수 상한을 두는 것은 권하지 않는다.
- Q3. 어떤 거절이 폭을 줄여야 하는가. 지금은 종류를 보지 않는다. 연속성 회차는 이름 붙은 크기 거절일 때만 줄인다(2026-10-10). durable 쪽을 맞출지는 거절의 종류별 횟수를 잰 뒤에 정한다. L2 뒤에 폭 라벨이 `first_cut` 이나 n 인 원본의 앞 원본이 어떤 거절로 끝났는지 센다.
- Q4. L1 의 설치 순서. #51278 구현을 먼저 넣는 쪽을 권한다. 대가는 L1 이 그만큼 늦어지는 것이다. 그 전에 넣으면 설치할 때 기다리던 원본이 pass 마다 거절된다.
- Q5. worker 가 11-16 21:00:23 KST 에 종료 코드 137 로 끝난 원인은 확인하지 않았다. 선언된 memory 는 134,217,728 B 다. D1 은 목록 한 장이 드는 본문을 frame 하나로 묶지만, 그 종료의 원인이라고 말할 근거는 없다.
- Q6. 거절 없이 끝난 회차. 본문은 폭을 줄이지 않는 쪽으로 정했다(§3.2). 받는 쪽의 거절이 없으면 줄일 근거가 없어서다. 대가는 넓은 범위에서만 나는 예외나 취소가 같은 범위에서 되풀이되는 것이다. 그런 경우가 있는지는 재지 않았다. L2 뒤에 §7.2 의 값으로 본다. 있으면 그 원인을 고친다. 한 턴으로 되돌려 가리는 것은 권하지 않는다.
