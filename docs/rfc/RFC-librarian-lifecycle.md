---
rfc: "librarian-lifecycle"
title: "Librarian 생명주기 — 끝난 턴을 빠짐없이 순서대로 읽고, 읽은 위치를 남긴다"
status: Superseded
created: 2026-09-18
updated: 2026-11-26
author: vincent
supersedes: []
superseded_by: "librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line"
related: ["keeper-context-window-in-tokens", "memory-os-bounded-context-and-librarian-curator", "0456", "0363"]
implementation_prs: ["#37020", "#37024", "#37027", "#37030", "#37028", "#37031", "#37208", "#37653", "#38477", "#46926"]
---

# RFC: Librarian 생명주기

> Librarian 이 언제 무엇을 읽고 Memory 에 어떻게 반영하는지는 RFC librarian-call-only-proposes 가 정한다. 이 문서는 코드와 다른 RFC 가 번호로 부르는 절과 아직 하지 않은 목표를 적는다. 번호로 불리는 절은 Librarian 이 뒤처져 있을 때 Keeper 요청이 어디서 시작하는지(§4.10), Librarian 레인의 수명(§4.3), 하던 일과 창이 보는 위치(§7 (라)), Keeper purge 의 순서(§8), 공식 클라이언트 턴 조각(§10 의 3)이다.

- 상태: Superseded
- 코드는 origin/main `a26795cff182c` 에서 확인했다. 날짜가 붙은 실측은 그 날 라이브 `<base-path>/.masc` 에서 잰 값이다.
- 관련: 창 RFC(`keeper-context-window-in-tokens`), RFC-0363, RFC-0521
- 구현 위치: §4.10 의 규칙별 코드 위치는 그 항목 끝에 적는다.

## 읽기 전에 — 말의 뜻

- **atom**: User 메시지 하나, 또는 Assistant 메시지와 그것에 답한 Tool 메시지들의 묶음이다. 이력을 자르는 자리는 atom 경계에만 온다(`Runtime_model_input_tail_window`).
- **회차**: Librarian 이 모델을 한 번 불러 Memory 를 고치는 일 하나다.
- **읽은 자리**: Librarian 이 턴 로그를 어디까지 읽었는가. Memory 커밋 기록의 마지막 줄이 갖는다(§4.6).
- **Librarian 지점**: 읽은 자리를 이 이력의 atom 번호로 바꾼 읽기 끝이다(`covered` 의 `end_atom`, `librarian_point_of`).

## 2. 결함

### 2.5 생명주기 밖의 결함

| # | 결함 | 근거 | 어디서 닫나 |
|---|---|---|---|
| D8 | 보낸 요청이 한 슬롯에서 실패하면 같은 입력이 선언된 다음 슬롯으로 넘어간다. 거절의 종류와 상관없이 같다. 성공 상태인데 본문이 기한을 넘긴 답, JSON 이 아니거나 내용이 빈 답, 보낸 뒤 시간 초과, 보낸 뒤 결과를 모르는 전송 실패도 같다. exact 요청에는 도구가 없어서 다음 슬롯이 효과를 두 번 내지 않는다. 걸음이 멈추는 것은 masc 자신의 기록·callback 이 실패한 경우(`Flow_before_dispatch_callback_failed` 등)와 취소뿐이다 | `exact_output.ml` `flow_execution_terminal_kind` | `RFC-exact-lane-walks-one-slot-list.md` §3.3, Q1 |

## 4. 설계

### 4.3 루프

- **Librarian 은 Keeper 마다 따로 돈다.** Keeper 마다 실행 줄이 하나다. 한 Keeper 의 일은 차례로 돌고, Keeper 끼리는 따로 돈다(`Keeper_memory_lane`).
- 레인의 수명은 서버가 쥔다. 서버가 뜰 때 서버 스위치로 한 번 연다(`Keeper_memory_lane.init ~sw`, `server_runtime_bootstrap.ml`). Keeper 기동은 레인을 열지 않는다. Keeper 가 끝나도 레인을 막거나 취소하지 않는다. Keeper 종료는 레인을 기다리지 않는다(I7).
- 회차는 Keeper 상태를 디스크에서 읽는다. 읽은 자리를 옮기는 것은 그 회차의 Memory 커밋뿐이다(I2). 그래서 회차가 도중에 끊겨도 잃는 것이 없다.
- 레인은 도는 회차 하나와 가장 새 제출 하나만 둔다. 더 새 제출이 오면 기다리던 제출을 바꾼다(`Coalesced`).
- 회차를 일찍 멈추는 것은 Keeper purge 하나다(§8).

### 4.5 지켜야 할 것

- **I2 기억 먼저, 위치는 맨 끝** — Memory 커밋 줄이 디스크에 써진 뒤에만 읽은 자리가 옮겨진다. 읽은 자리는 그 줄이 갖는다(`Librarian_log`). 커밋 전에 멈춘 회차의 단위는 다음 회차가 다시 읽는다.
- **I4 밀림이 보인다** — 읽은 자리 뒤에 닫힌 턴 로그 단위가 남아 있으면, 그 사실이 typed 값으로 TUI 와 대시보드에 뜬다. Gate 가 아니다. 창 RFC §13.7 이 이것을 선행 조건으로 둔다.
- **I7 Keeper 는 Librarian 을 기다리지 않는다** — Keeper 기동, 재기동, 턴 진행 어디에도 Librarian 완료를 기다리는 자리가 없다. 턴의 성패도 Librarian 이 따라왔는지에 달려 있지 않다(§4.10).

### 4.6 새 파일 셋

Librarian 이 읽고 쓰는 Keeper 별 저장소는 셋이다. 배포 전 검사는 셋을 모두 엄격하게 디코딩한다(`Keeper_durable_store`).

1. **턴 로그**(`Keeper_turn_log_store`). 턴마다 `Opened` 줄과 `Closed` 줄을 쓴다. 턴은 실패하거나 취소돼도 `Closed` 를 쓴다(`Keeper_turn_log_turn.around`). Librarian 은 이 단위를 읽는다.
2. **Memory 커밋 기록**(`<keeper>.memory-log.jsonl`, `Librarian_log_store`). 반영 한 번에 한 줄이다. 마지막 줄이 읽은 자리와 하던 일(working state)을 싣는다(`Librarian_log`).
3. **공식 클라이언트 턴 조각**(`Keeper_turn_fragments`). §10 의 3 이 정한다.

### 4.10 읽지 못할 때

Librarian 이 읽지 못해도 Keeper 는 계속 돈다(I7). Librarian 이 어디에 서고 무엇을 남기는지는 RFC librarian-call-only-proposes §5.4 와 §12 가 정한다. 아래는 Librarian 이 뒤처져 있을 때 Keeper 요청이 어디서 시작하는지 정한다.

- **Librarian 이 서도 Keeper 는 턴을 계속 돈다**(#37793 이 물은 (가)/(나) 중 (가)를 택한다. 경위는 #37793 issuecomment-5788668419 에 있다). 규칙별 구현 상태는 이 항목 끝에 적는다. 요청이 읽은 위치부터 시작하면, Librarian 이 서 있는 동안 요청이 턴마다 커진다. 그 끝은 provider 의 거절이고, 그 뒤로는 매 턴 같은 거절이다. Keeper 가 턴을 돌지 못하니 I7 이 사실상 깨진다. Librarian 이 읽는 자리와 Keeper 요청이 시작하는 자리는 묶여 있지 않다. 그래서 이렇게 한다.
  1. 판정은 추정이 아니라 일어난 일이다. 시작점이 이번 턴의 경계보다 앞인 요청을 provider 가 크기 때문에 거절하면, 그 턴은 마지막으로 끝난 턴의 경계부터 같은 후보에 한 번 더 보낸다. 시작점이 Librarian 지점이든 아래 2의 받아들여진 시작점이든 같다. 크기 거절로 보는 것은 typed 생성자 넷이다(`boundary_resend_on`): `ContextOverflow`, `InvalidRequest { Request_body_refused_by_provider }`, `Unknown_invalid_request`, `Unclassified_status`. 뒤의 둘은 사유를 모르는 거절인데, 그 사유를 문장으로 읽는 것은 문자열 분류라 하지 않고 크기 거절과 같게 다룬다(창 RFC §10.4). 실제로 크기 거절이 이 모양으로 온다. 2026-09-23 01:41Z msx-retro-mania 의 glm-5.3-flash 턴은 `Invalid request (unknown): Prompt exceeds max length` 로 끝났다. 없이 두면 그런 Keeper 는 매 턴 거절된다. 크기와 무관한 400 이면 경계부터 한 번 더 보내고, 그것도 거절되면 턴이 끝난다(6). 잃는 것은 그 턴에 경계 앞을 싣지 못한 것뿐이다. 받아들여진 시작점도 기록되지 않는다. 크기 문제였다면 빠진 구간은 Librarian 이 읽고, 따라잡으면 시작점이 돌아온다(5). 이 넷은 경계 재전송에만 쓰는 판정이다. 범위를 줄이는 다른 걸음(carrier·memory, 6, 8)은 typed 크기 거절 둘(`ContextOverflow`, `Request_body_refused_by_provider`)에서만 돈다(`is_size_refusal`, #38286). 두 판정은 코드에서도 따로 둔다. 2026-09-23 운영자 결정이고, 경위는 #38286 댓글에 있다. 크기를 미리 재는 문턱도, 시간도, 실패 횟수도 쓰지 않는다. 지점이 없는 Keeper 의 씨앗이 거절될 때(`Turn_start_after_refusal`, #38046)와 같은 모양이다.
  2. 받아들여진 요청의 첫 atom 은 턴 기록(`response_observed_model_input`)에 남는다. 이것을 "받아들여진 시작점"이라 부른다. 다음 턴은 Librarian 지점이 받아들여진 시작점보다 앞이면 받아들여진 시작점부터 싣는다. 그래서 같은 거절을 매 턴 다시 올려 보내지 않는다. 턴 기록은 파일이므로 서버를 다시 띄워도, 레인 걸음에서 다른 후보로 넘어가도 같은 값을 읽는다. 받아들여진 시작점이 Librarian 지점보다 앞이어도, ledger 의 마지막 요청이 연 창이 그 자리에 머물러 있으면 그 시작점을 그대로 쓴다(`held_window`, `from_librarian_point`). 지점은 창이 움직일 때만 창을 옮기므로, provider 가 캐시한 앞부분이 남는다.
  3. gap 은 Keeper 요청에도 기억에도 아직 없는 구간이다. Librarian 의 읽기 끝(`covered` 의 `end_atom`)부터 받아들여진 시작점 직전까지다. 받아들여진 시작점이 읽기 끝보다 뒤일 때만 요청이 그 시작점에서 열린다(`from_librarian_point` 의 `Past_librarian_point`). 아니면 요청은 읽기 끝에서 열리고(`From_covered`) gap 은 없다. gap 은 따로 저장하지 않고, 읽기 끝과 턴 기록의 받아들여진 시작점에서 매번 계산한다. 이 경로는 Librarian 의 읽은 위치를 옮기지 않고, 새로 쓰는 것은 턴 기록 하나뿐이다. 그래서 "시작점은 옮겼는데 gap 기록은 못 남긴" 상태가 없다. 빈 구간을 지나며 진행을 커밋해 거절을 영구 손실로 바꾸는 모양(#37941)과 다른 점이 이것이다.
  4. 요청에는 gap 의 범위(시작 atom, 끝 atom, 바이트)를 typed 블록으로 싣는다. 모델이 그 구간을 없던 일로 읽지 않게 하려는 것이다. 블록은 Librarian working state 메시지 바로 뒤에 둔다(`working_state_message`). Librarian 지점이나 받아들여진 시작점이 움직일 때만 바뀌므로, 그 앞부분의 prompt cache 는 그대로다. working state 는 그대로 싣는다. gap 앞까지를 정리한 것이기 때문이다.
  5. Librarian 은 gap 의 단위도 차례로 읽는다. 읽은 위치가 받아들여진 시작점에 닿으면 gap 이 사라진다. 그 뒤로는 창이 움직일 때 읽은 위치부터 싣는다(2).
  6. 경계부터 보낸 요청도 typed 크기 거절(`ContextOverflow`, `Request_body_refused_by_provider`)로 거절되면, 이번 턴의 도구 결과를 마커로 바꿔 같은 후보에 한 번 더 보낸다(창 RFC §10.4, #38109). 블록으로 온 결과는 `content` 와 안쪽 텍스트 블록 가운데 그 레인의 요청을 줄이는 본문이 마커가 되고, 이미지·문서는 그대로다(RFC-0363 §3.1.2). 사유를 모르는 거절이면 여기서 턴이 끝난다(1). 바꿀 것이 없거나 그것도 거절되면 그 턴은 그 거절로 끝난다. 그때 넘치는 것은 이력이 아니라 매 턴 붙는 부분이다(창 RFC §13.9 첫 항목). 이 장치가 닫는 것은 이력이 자라서 나는 거절 하나다. facts 는 Librarian 의 `absorbs`·`dropped` 로만 줄어드는데, Librarian 이 서 있으면 그것도 멈춘다. 그래서 facts 가 이미 부푼 Keeper 는 gap 이 넓어져도 계속 거절된다.
  7. 받아들여진 시작점은 이번 턴의 경계보다 뒤로 가지 않는다. 경계보다 뒤인 시작점은 경계로 되돌린다(`within_turn_boundary`). 그래서 마지막으로 끝난 턴 뒤의 atom 은 늘 실린다. 예외는 하나다. 8 이 이번 턴 안에서 옮긴 앞머리는 경계와 이번 턴의 시작 중 뒤쪽까지 둔다(`Int.max`). 그 앞머리는 이름이 따로 있다(`Keeper_carried_front.This_turn_start_after_refusal`). 8 은 경계부터 연 범위가 크기로 거절된 뒤에만 돌므로, 그 앞머리를 경계로 되돌리면 거절된 범위를 다시 보낸다. 이번 턴의 시작은 턴 기록에서 이 턴의 `Opened` 줄이 적은 닫힌 메시지 수를 atom 번호로 바꾼 값이다(`Keeper_turn_driver_try_provider.turn_starts`, RFC librarian-call-only-proposes §11.2). digest 는 견주지 않는다. 지금 이력이 닫힌 메시지를 그만큼 갖고 있는지만 본다. 보통은 이번 턴의 경계와 같다. 턴은 실패하거나 취소돼도 `Closed` 줄을 쓰기 때문이다(`Keeper_turn_log_turn.around`). 다른 것은 앞 단위가 닫힌 뒤 이번 턴이 열리기 전에 닫힌 메시지가 있을 때다(`Closed` 의 `unattributed`). 열린 턴이 없거나, `Opened` 뒤에 `Reset` 이 있거나, 다른 trace 의 줄이거나, 이력이 그보다 짧으면 이번 턴의 시작을 모른다. 그때 8 의 앞머리도 경계로 되돌린다. 이어 가는 checkpoint 로 시작한 턴(native resume, direct resume, HITL)은 이번 턴의 시작을 모르는 것으로 본다. 그 checkpoint 는 이미 이번 턴의 입력과 진행을 담고 있고, 앞선 run 의 끝 저장이 그것을 닫았다. 그래서 이 run 이 쓴 `Opened` 의 닫힌 메시지 수는 이번 턴의 입력 뒤다. 그 자리에서 다시 보내면 이번 턴의 요청이 빠진다. driver 는 이 run 이 `Opened` 를 입력보다 먼저 썼을 때만 그 줄을 읽는다(`Keeper_run_prompt.this_turn_opening`, `Keeper_turn_driver.run_named ?this_turn_opening`). 그 값을 넘기지 않는 호출은 시작을 모르는 쪽이다.
     - 상한을 모든 받아들여진 시작점에 넓히지 않는 이유. 턴 기록에서 읽은 시작점은 어느 규칙이 정했는지 남기지 않는다(`Turn_record`). Librarian 지점이 있는 새 턴에서 그 시작점 A 가 경계 B 와 이번 턴의 시작 S 사이에 있다고 하자(B < A ≤ S). 경계만 쓰면 A 는 B 로 돌아오고 [B, A) 가 실린다. `Int.max` 를 모든 시작점에 쓰면 A 가 그대로 남고, 거절도 없이 [B, A) 가 요청에서 빠진다. 그래서 넓힌 상한은 이번 턴이 8 로 잡은 앞머리에만 건다. 그 대가는 8 에 적었다.
     - 경계 재전송도 8 의 재전송도 이번 턴 입력은 늘 싣는다. 그래서 요약과 gap 블록만 있고 답할 입력이 없는 요청은 만들어지지 않는다. 매 턴 붙는 부분과 이번 턴 입력만으로 한도를 넘으면 gap 을 넓혀도 줄일 이력이 없고, 거절이 그대로 난다. 답할 입력 없는 요청보다 거절이 낫기 때문에 정한 결과다. 이 규칙을 깎아 시작점을 이번 턴 안으로 옮기지 않는다. 이 거절은 턴의 마지막 오류로 보인다.
  8. 6 이 바꿀 것이 없거나 6 으로 다시 보낸 요청도 typed 크기 거절(`is_size_refusal`)이면, 그리고 이번 턴의 시작이 거절된 요청의 시작점보다 엄격히 뒤면, 이번 턴의 시작부터 같은 후보에 한 번 더 보낸다(2026-11-06 개정). 이번 턴의 시작과 경계 사이에 있는 것은 두 턴 사이에 닫힌 메시지다(7). 1 은 그 구간을 이번 턴으로 보고 남긴다. 6 은 그 구간의 결과를 마커로 바꾼다. 그래도 넘치면 8 이 그 구간을 뺀다.
     - 실패한 턴이 도중에 저장한 메시지는 그 턴의 끝이 닫고 그 턴의 `Closed` 줄이 싣는다(2026-11-28, RFC librarian-call-only-proposes §5.2, #55349). 그래서 경계는 실패한 턴 뒤에 서고, 그 메시지는 이 구간이 아니라 경계 아래에 있다. 끝난 턴의 결과처럼 마커로 실리고, 1 이 경계부터 다시 보낼 때 빠진다. 이 구간에 남는 것은 줄 없이 닫힌 메시지다. `Opened` 를 못 쓴 턴의 끝이 닫은 것이 그렇다. 아래 B1·B3 의 「실패한 턴의 atom」은 그 모양을 줄로 직접 쓴 것이다. checkpoint 에서 이어 가도록 넘긴 작업의 턴은 닫지 않는다. 이어 가는 턴은 메시지를 더하지 않으므로, 그 입력이 열려 있어야 경계가 입력 앞에 선다.
       - 11-20(#53461)부터 11-28 까지는 실패한 턴의 메시지가 열린 채 남았다. 경계도 이번 턴의 시작도 그 앞에 서서 1 과 8 에 걸음이 없었다. 11-24~27 에 크기 거절로 끝난 345턴에서 8 은 한 번 돌았다(#55349 의 표).
     - 이번 턴의 시작은 7 의 그 값이다. driver 가 턴마다 한 번 턴 기록의 꼬리를 읽어 턴 경계와 같이 얻는다(`Keeper_turn_driver_try_provider.turn_starts`, `try_provider_ctx.this_turn_start`). 새로 저장하는 것은 없다. 시작을 모르면 이 걸음이 없다. 다음 요청 예측은 다음 턴이 아직 열리지 않았으므로 wake 줄을 붙이기 전 이력의 atom 수를 쓴다(`Keeper_next_request_forecast.read_range`).
     - 판정은 6 과 같은 typed 크기 거절 둘이다. 사유를 모르는 거절은 6 에서 이미 턴을 끝냈으므로 여기 오지 않는다.
     - 8 은 `this_turn_start_resend_sequence` 다. 1 과 6 의 사다리(`current_turn_demotion_sequence`)를 감싼다. 거절된 요청의 시작점은 마지막으로 보낸 요청의 `first_atom` 이다.
     - 다시 보내는 요청도 6 의 강등을 유지한다. 옮긴 앞머리는 그 턴의 것이다(1 의 `hold_front`). 다시 보낸 요청이 크기와 무관한 이유로 거절되면 앞머리를 되돌린다(1 의 `restore_front`). 받아들여지면 그 요청의 첫 atom 이 받아들여진 시작점이 된다(2).
     - 빠진 구간은 checkpoint 에 남는다. 그 atom 은 이번 턴이 쓰는 `Closed` 줄에 든다(`unattributed`). Librarian 은 턴 로그의 단위를 읽으므로 그 구간도 읽는다. 읽기 끝이 그보다 뒤처져 있으면 3 의 gap 이 그대로 남는다. 읽기 끝이 없는 턴(`No_read_end`)에서는 그 구간이 요청에서 빠질 뿐이다. 그 턴의 다른 앞 atom 과 같다.
     - 6 이 8 보다 먼저인 이유: 두 턴 사이에 닫힌 메시지도 이번 턴이 이어받는 일일 수 있다. 6 은 그 결과를 마커와 preview 로 남기고 `artifact_read` 로 다시 열 수 있게 한다. 8 은 그 구간을 요청에서 뺀다. 남길 수 있으면 남긴다. 2026-11-06 msx-retro-mania 는 6 만으로 들어간다(RFC-0363 §3.1.2). 8 이 답하는 것은 6 이 줄인 뒤에도 그 구간이 넘칠 때다. 이미지만 든 결과나 마커보다 작은 결과가 많을 때가 그렇다. 지금 그런 Keeper 가 있는지는 재지 않았다.
     - 사다리는 횟수를 세지 않고 끝난다. 1·6·8 은 한 턴에 많아야 한 번씩이다. 1·8 은 시작점을 엄격히 뒤로 옮기고, 6 은 실린 바이트를 엄격히 줄일 때만 다시 보낸다. 8 뒤에도 거절되면 넘치는 것은 매 턴 붙는 부분과 이번 턴 입력이다(7, 창 RFC §13.9 첫 항목). 시간·실패 횟수·크기를 미리 재는 문턱은 쓰지 않는다.
     - 공식 클라이언트 레인은 바뀌지 않는다. 그 레인은 7 을 쓰지 않는다(아래 Claude Code·Codex 항목과 ACP·Antigravity 항목).
     - 시험. 각 시험은 아래 변형을 넣으면 실패해야 한다. `dispatch` 는 `test/test_keeper_continuity_dispatch.ml`, `eviction` 은 `test/test_keeper_carried_range_eviction.ml` 의 `this turn's start` 묶음이다.

       | # | 시험 | 보는 것 | 잡는 변형 |
       |---|---|---|---|
       | B1 | dispatch: a refused boundary resends from where this turn began | 끝난 경계 6, 실패한 턴의 atom 6·7, 이번 턴의 시작 8, Librarian 지점 2. 받아들여진 시작점 6 부터 보낸 요청이 거절되고, 1 은 걸음이 없고, 6 은 바꿀 도구 결과가 없다. 같은 peer 에 8 부터 한 번 더 보내 받아들여지고, 다음 후보는 부르지 않는다 | 8 이 없음. driver 가 턴 기록의 `Opened` 를 읽지 않음. 입력을 기록하는 턴이 `Opened_before_its_input` 를 넘기지 않음 |
       | B3 | dispatch: a refused boundary demotes before it moves past the failed turn | 실패한 턴이 도구 호출과 8,000 B 결과를 남겼고 `artifact_read` 가 있다. 다시 보낸 요청은 경계 6 부터 싣고("ask 3"), 그 결과는 마커다 | 8 을 6 보다 먼저 둠 |
       | B4 | eviction: a refused ladder resends from where this turn began | 앞 걸음이 크기 거절로 끝나면 한 번 다시 보내고, 앞머리를 이번 턴의 시작에 둔다 | 걸음을 빼먹음. `hold_front` 를 빼먹음 |
       | B5 | eviction: no resend without a start after the refused one | 이번 턴의 시작이 거절된 시작점과 같거나 앞이거나, 모르거나, 보낸 요청이 없으면 다시 보내지 않는다 | `>` 를 `>=` 로 바꿈. 비교를 지움 |
       | B6 | eviction: no resend after a refusal not about size | 사유를 모르는 거절, 같은 run 재시도가 막힌 run 에서는 다시 보내지 않는다 | `is_size_refusal` 이나 `same_run_retry_authorized` 를 건너뜀 |
       | B7 | eviction: an accepted ladder asks nothing more | 앞 걸음이 받아들여지면 더 보내지 않는다 | 성공 뒤에도 보냄 |
       | B8 | eviction: a refused resend gives the front back only when not about size | 다시 보낸 요청이 사유를 모르는 거절이면 앞머리가 8 이전 값으로 돌아오고, 크기 거절이면 이번 턴의 시작에 남는다 | `restore_front` 를 빼먹음. 크기 거절에도 되돌림 |
       | B9 | turn log: the open turn's baseline is where this turn began | 열린 `Opened` 의 닫힌 메시지 수를 atom 으로 바꾼다. 닫힌 메시지를 고쳐 써도 그대로다(`test/test_keeper_turn_start_from_turn_log.ml` 의 `where this turn began` 묶음) | 경계를 이번 턴의 시작으로 씀. 닫힌 메시지 수 대신 atom 수를 씀 |
       | B10 | turn log: no open turn names no start. eviction: a resumed turn names no start. dispatch: a resumed turn does not resend past its own request | 줄이 없거나, 열린 턴이 없거나, 다른 trace 의 `Opened` 거나, 이력이 그보다 짧거나, `Opened` 뒤에 `Reset` 이 있으면 시작이 없다. 입력을 기록하는 턴은 `Opened_before_its_input`, 이어 가는 checkpoint 의 턴은 `Opened_after_its_input` 를 넘긴다. 뒤의 것은 `Opened` 가 있어도 다시 보내지 않고 다음 후보로 넘어가며, 모든 요청이 이번 턴의 요청을 싣는다 | 모르는 시작을 0 이나 가장 새 atom 으로 접음. `reset_since` 를 건너뜀. trace·길이 확인을 건너뜀. `this_turn_opening` 의 두 갈래를 바꿈 |
       | B11 | eviction: an accepted start is bounded by the turn boundary | 끝난 경계 8, 이번 턴의 시작 14, Librarian 지점 2. 턴 기록의 시작점 12·14, ledger 의 시작점 12, 1 의 두 앞머리 12 는 8 로 가고, 턴 기록의 시작점 6 은 그대로다. 8 의 앞머리는 12·14 가 그대로, 16 은 14 로 간다. 시작을 모르거나 시작이 경계보다 앞이면 8 의 앞머리도 8 로 간다 | 모든 시작점에 `Int.max` 를 씀(위 7 의 회귀). 다른 이름 하나를 8 의 갈래로 옮김. 8 의 앞머리도 경계로 자름. 상한을 이번 턴의 시작만으로 둠 |
       | B13 | forecast: a known start leaves a recorded start bounded by the boundary | 예측도 이번 턴의 시작을 알 때 B11 처럼 턴 기록의 시작점 12 를 경계 8 로 되돌린다(`test/test_keeper_next_request_forecast.ml`) | 예측이 `choose_range_start` 를 거치지 않고 턴 기록의 시작점을 그대로 씀 |

       시험이 잡지 않는 변형도 있다.

       - 턴이 `Opened` 줄을 쓰는 것(`Keeper_turn_log_turn.around`)과 driver 가 그 줄을 읽는 것 사이의 연결. B1·B3 은 줄을 직접 써서 읽는 쪽만 본다. `run_turn` 이 `prompt_user_turn_record` 로 `this_turn_opening` 을 골라 driver 에 넘기는 것도 같다. B10 은 그 변환과 driver 쪽만 본다. `around` 가 쓴 줄에서 driver 가 경계를 읽는 쪽은 `test/test_keeper_turn_log_turn.ml` 의 `the next request starts after the failed turns` 가 본다(2026-11-28). 나머지 연결을 보려면 Agent Core 레인의 `Keeper_agent_run.run_turn` 을 가짜 공급자까지 돌려야 한다. 그 fixture 는 아직 없다. Agent Core 레인의 `run_turn` 시험은 prompt 를 만들기 전에 멈춘다(`test/test_keeper_checkpoint_stale_guard.ml`). `run_turn` 을 끝까지 도는 Codex app-server 시험은 공식 클라이언트 레인이라 7·8 을 쓰지 않는다.
       - 예측이 wake 줄을 붙인 이력에서 시작을 읽거나 시작 없음을 넘기는 것. 예측은 턴 기록의 시작점만 보고 8 의 앞머리는 보지 않으므로, 그 값은 지금 예측 결과를 바꾸지 않는다.

       요청 사다리에는 TLA+ 모델이 없다. 만들면 생존 속성을 "이번 턴 입력과 매 턴 붙는 부분이 한도에 들면 언젠가 받아들여진다"로 둔다. `Next` 는 이를 지키고, 블록 결과 강등과 8 을 뺀 `NextBuggy` 는 msx 의 상태에서 어겨야 한다.
  - Tick 으로 따라가면 이렇다. Librarian 이 P 에 선다. T1 은 P 부터 보내 거절되고, 경계 B1 부터 다시 보내 받아들여진다. T2 부터는 B1 부터 싣고 요청이 다시 자란다. Tk 에서 B1 부터 보낸 요청이 거절되면 1 에 따라 경계 Bk 부터 다시 보낸다. Librarian 이 P' < Bk 까지 오면 시작점은 Bk 그대로이고, P'' ≥ Bk 가 되면 P'' 부터 싣는다. 어느 회차에도 같은 거절이 되풀이되는 고리가 없다.
  - 이것은 마지막 방어선이다. Librarian 이 서는 원인은 따로 고친다.
  - Claude Code·Codex 레인은 typed 넘침이 턴을 줄인 크기로 시작 씨앗을 자른다. host 는 그 자리를 `own_first_atom` 으로 받는다(`Keeper_official_client_host`). 받아들여진 시작점이 그 컷보다 앞이면, 컷과 턴 경계 중 뒤의 것부터 싣는다(`Lane_cut`). 그 컷으로 받아들여진 요청도 받아들여진 시작점이 된다(2).
  - ACP·Antigravity 레인의 첫 씨앗에는 바이트 창이 없다. 그 씨앗은 범위의 시작점부터 지금까지를 싣는다(`Keeper_official_client_host.start_range_projection`). 시작점은 Librarian 지점과 받아들여진 시작점 중 뒤의 것이다. 둘 다 없거나 그 자리가 이 이력의 atom 과 맞지 않으면, 마지막으로 끝난 턴의 경계다. 그 경계를 모르면 가장 새 atom 이다(창 RFC §13.4). 같은 런타임의 거절 표시가 더 새면 아래 규칙으로 고른다. ACP 레인은 토큰 장부가 다음 요청이 입력 한도를 넘는다고 보면, 다음 시작점을 Agent Core 처럼 더 뒤로 옮긴다(`keeper_acp_runtime.ml` 의 `seed_past_max_context`). ACP 레인은 계획된 rollover 나 새 세션 재시도에서 저장된 handoff 문맥이 있으면 그것으로 시작한다(`hydrate_start_messages`). 두 레인은 받아들여진 시작점을 atom 수로만 자르고, Agent Core 처럼 이번 턴의 경계로 자르지 않는다(7). 두 레인도 1 을 따라야 하지만 같은 턴 안에서 경계부터 다시 보내지는 않는다. 그 대신 typed 크기 거절이 오고 같은 run 재시도가 허락되면, 새 세션으로 다시 보낸다(`Keeper_turn_driver_try_provider.context_overflow_shrink_sequence`). 거절된 요청이 새 세션의 씨앗이었으면 그보다 작은 바이트 창으로 줄인다. 이어 간 세션이 거절됐으면 첫 재시도는 씨앗을 자르지 않는다. Antigravity 레인은 memory 전달을 다시 짤 수 있으면, 줄이기 전에 같은 크기로 한 번 더 보낸다. 효과가 있었거나 효과를 모르는 시도에는 재시도가 허락되지 않는다. 턴 드라이버는 그 시도를 다른 후보로도 넘기지 않는다(`provider_attempt_effect_fenced`). ACP 레인은 `Native_full` 이면 보내기 직전부터 효과를 모르는 것으로 본다. 활동 전에 온 context overflow 만 효과가 없던 것으로 되돌린다(`keeper_acp_runtime.ml`). Antigravity 레인은 413 거절(`Request_body_refused_by_provider`)을 줄여서 다시 보내지 않는다. 활동 전에 온 `Context_window_exceeded` 에만 재시도를 허락한다(`keeper_antigravity_runtime.ml`). 그래서 같은 턴에 풀리지 않은 typed 크기 거절에는 1 을 다음 새 세션에서 적용한다. 거절 표시는 공식 클라이언트 레인 넷(Codex·Claude Code·Antigravity·ACP)이 모두 남긴다. 판정은 typed 크기 거절이다(`Keeper_turn_driver_try_provider.is_size_refusal`).
    - 새 세션의 요청이 typed 크기 거절을 받고 같은 턴에 풀리지 않으면, 그 턴의 턴 기록에 거절이 남는다(`refused_model_input`: 런타임, 보낸 범위, 거절 종류). 보낸 범위는 `model_input_window` 에도 남는다. 거절 표시는 "공급자가 이 범위를 거절했다"는 typed 사실이다. 모양은 `response_observed_model_input` 에 거절 종류를 더한 것이다.
    - 같은 런타임으로 새 세션을 열 때 가장 새 관측이 그 런타임의 거절이면, 시작점은 거절된 시작점보다 엄격히 뒤여야 한다. 이번 턴의 경계가 거절된 시작점보다 뒤면 그 경계부터 싣는다. 아니면 가장 새 atom 부터 싣는다. 가장 새 atom 도 거절된 시작점보다 뒤가 아니면 더 뺄 이력이 없다. 그때 넘치는 것은 매 턴 붙는 부분이나 이번 턴 입력이고(6, 7), 이 규칙으로는 풀리지 않는다. Agent Core 의 경계 재전송도 새 시작점이 거절된 시작점보다 엄격히 뒤일 때만 보낸다(`keeper_turn_driver_try_provider.ml` 의 경계 재전송 갈래).
    - 실패한 공식 클라이언트 턴도 다른 턴처럼 턴 로그 단위를 닫는다(`Keeper_turn_log_turn.around`). 그래서 다음 턴의 경계는 그 턴이 닫힌 자리다.
    - 그 세션이 받아들여지면 그 턴 기록의 `response_observed_model_input` 이 가장 새 관측이 되고, 받아들여진 시작점이 된다(2). Librarian 이 따라잡을 때까지(5) 이후의 새 세션도 거기서 시작한다.
    - 거절 표시는 같은 런타임의 새 세션에만 쓴다. 한 모델의 창이 거절했다는 사실은 다른 후보의 창을 말해 주지 않는다. 다음 경우에도 쓰지 않는다. Librarian 지점이 거절된 시작점보다 뒤로 갔을 때다. 그 범위는 거절된 범위를 포함하지 않는다. 이력이 바뀌어 거절된 시작 atom 의 digest 가 맞지 않을 때다. 한도 거절은 크기 거절이 아니라서 표시를 남기지 않는다(`Keeper_turn_driver_try_provider.is_size_refusal`).
    - 판정은 런타임의 typed 크기 거절이고(`Keeper_turn_driver_try_provider.is_size_refusal`), 오류 문장은 읽지 않는다. 이어 쓰던 세션의 요청이 거절되면 표시를 남기지 않는다. 그 요청에는 씨앗이 없었다.
    - 표시를 세션 저장소에 두지 않는다. 세션 저장소는 Keeper 마다 `session.json` 하나이고, 거절을 담는 `Recovery_required` 는 다음 claim 이 `Start` 로 바꾼다. 그 claim 이 다른 이유로 실패하거나, 그 사이 서버가 다시 뜨거나, 다른 런타임이 claim 하면 거절 사실이 사라진다. 그러면 다음 새 세션이 거절된 씨앗을 다시 보낸다. 턴 기록은 턴마다 쌓이고 덮어쓰지 않는다.
    - 턴 기록 디코더는 키를 정확히 요구한다(`Turn_record.of_json`). 새 키를 더하면 새 디코더는 배포 전 줄을 읽지 못한다. 옛 줄을 읽는 코드는 만들지 않는다(hard cut). 그래서 배포 직후 각 Keeper 의 첫 새 세션은 배포 전에 받아들여진 시작점 없이 Librarian 지점에서 시작한다.
    - 거절 뒤 다음 턴이 새 세션을 여는 것은 이 규칙이 만드는 일이 아니다. 다음 claim 은 남은 복구(`Recovery_required`)를 모두 새 세션 계획으로 바꾼다(`Keeper_official_client_session_store.plan_claim`, #54398). 거절된 입력(`Input_rejected`)도 운영자 결정 없이 다음 턴에 새 세션으로 넘어간다. ACP 레인(`Runtime_acp_client.Muse_code` 포함)은 활동 전에 온 context overflow 를 같은 턴에 줄여서 다시 보낸다. 활동을 본 뒤의 overflow 는 `Effect_fenced` 로 남고(`Keeper_acp_runtime.classify_prompt_error`), 다음 턴이 새 세션으로 연다. Codex·Claude Code·Antigravity 는 `Bootstrap_floor_exceeded` 거절 뒤의 다음 턴을 anchor 만 실은 작은 새 세션으로 연다(`superseded_input_rejection`).
  - 구현 전 측정(2026-09-16~23 일별 로그, 읽기 전용). 크기 거절로 끝난 Keeper 턴은 09-21 48 건, 09-22 8 건, 09-23 4 건이다. 이 60 건 중 59 건은 거절 당시 Librarian 이 밀려 있었다. 09-21 48 건은 배포 직후 한 번 따라잡은 것이다. 09-23 msx 4 건은 한도를 67~1,331 토큰 넘었으니 1 의 재전송 한 번이면 들어간다. 매 턴 붙는 부분만으로 넘친 거절은 09-18 critic 30 건이다(`undroppable_bytes` 168~175 KB, 한도 131,072). 이것은 6·7 이 말하는 구간이고 이 장치로는 풀리지 않는다. 모델이 gap 구간을 찾으려 한 증거는 찾지 못했다. 로그에는 `keeper_memory_search` 의 입력 모양만 남고, `search_history` 결과에는 atom 위치가 없어서 잴 수도 없다. 그래서 구현은 1(경계 재전송)부터 했다. 4 의 gap 블록은 아래 측정이 차이를 보일 때까지 싣지 않는다.
  - 코드 위치: 1 의 경계 재전송은 Agent Core 레인에 있다(`keeper_turn_driver_try_provider.ml` 의 `boundary_resend_on`, `range_answer`). 2 의 받아들여진 시작점은 `Keeper_carried_front.read_seed` 가 가장 새 `response_observed_model_input` 에서 읽고, 두 레인이 같이 쓴다(Agent Core 는 `Past_librarian_point`, 공식 클라이언트는 `Keeper_official_client_host.carried_start_range_on_source`). 6 은 `current_turn_demotion_sequence` 다. 6 은 블록으로 온 결과의 `content` 와 텍스트 블록도 바꾼다. 7 은 Agent Core 의 `within_turn_boundary` 이고, 공식 클라이언트 레인은 쓰지 않는다. 7 의 상한은 이번 턴의 경계다. 8 의 앞머리만 경계와 이번 턴의 시작 중 뒤쪽까지 둔다. 8 은 `this_turn_start_resend_sequence` 다. 다음 새 세션 규칙의 거절 표시는 `Turn_record.refused_model_input` 이고, 판정은 `Keeper_turn_driver_try_provider.is_size_refusal` 이다. 씨앗을 읽을 때 응답 관측보다 새 거절이 있으면 `Keeper_carried_front.read_seed` 가 `refused_start` 로 돌려주고, `Keeper_official_client_host.carried_start_range_on_source` 가 `Past_refused_start` 로 시작점을 고른다. 더 뺄 이력이 없으면 범위를 거절된 시작점에 두고 WARN 을 남긴다. 더 앞의 시작점으로 넓히지 않는다. 같은 씨앗으로 연 새 세션 수와, 거절 뒤 첫 완료 턴까지 걸린 claim 수를 잰다. 더 뺄 이력이 없어 같은 씨앗을 다시 연 경우는 따로 센다.
  - 4 의 gap 블록은 싣지 않는다. 싣기 전에 블록이 모델 답을 실제로 바꾸는지 잰다. 답을 아는 양 끝(gap 없음, 이력 전부 gap)에서 "gap 구간에 있던 일을 물으면 모른다고 답하는가"를 블록이 있는 요청과 없는 요청으로 비교한다. 양 끝에서 차이가 없으면 블록은 싣지 않는다. gap 구간을 다시 읽는 도구는 만들지 않는다. 먼저 로그에서 모델이 gap 구간을 찾으려 한 적이 있는지 센다.

## 7. 단계

- **(나) 턴 도중에도 읽는다.** 도구 경계 checkpoint 가 저장될 때도 Librarian 을 깨운다. 창이 보는 위치는 턴 끝에서만 옮긴다. 턴 도중에 옮기면 Keeper 가 방금 받은 결과를 잃고 접두사 캐시가 깨진다.
- **(다) 한가할 때도 정리한다.** 읽을 것이 없으면 아직 다시 보지 않은 기억 묶음을 하나씩 본다. 묶음마다 "이 revision 에서 봤다"를 남긴다. 새 정보 없이 같은 기억을 되풀이 판정하지 않기 위해서다. 통째 재작성은 내용이 무너진다(RFC-0456 §4.4, 창 RFC §6.4 의 ACE). 다 봤으면 쉰다.
- **(라) 하던 일과 창이 보는 위치.** 창이 보는 위치는 Librarian 의 읽기 끝이다. Keeper 요청은 읽기 끝에서 열고, 그 앞의 atom 대신 Librarian 이 적은 하던 일(working state)을 싣는다(`Keeper_turn_driver_try_provider.covered`, `working_state_message`). 읽은 자리와 하던 일은 Memory 커밋 기록의 한 줄에 같이 남는다(`Librarian_log`). 그래서 위치까지는 하던 일이 말하고, 위치 뒤는 원문이 말한다. 둘은 겹치지도 비지도 않는다. 읽기 끝이 없는 턴(`No_read_end`)은 하던 일을 싣지 않고 씨앗이나 턴 경계에서 연다.
- **(마) 일을 셋으로 나눈다.** 턴 읽기(facts 전부를 싣지 않는다), 기억 접기(facts 만 본다), 받은 일 정리(지금의 `working_contexts`). 일마다 프롬프트 키, 스키마, 디코더를 따로 둔다. 회차 시간과 실패율을 줄이는 것이 목적이다. 나눌지와 나누는 모양은 하네스가 잰 값으로 정한다. 그때 같이 풀어야 하는 것이 셋 있다. 접기 회차의 커밋이 자기를 다시 깨우지 않아야 한다. `supersedes` 와 "대체할 말 없이 틀렸다고 밝혀진 사실"을 뺄 자리가 남아야 한다(턴 읽기는 facts 를 못 보고 접기는 대화를 못 본다). 일의 종류를 registry 행에 남기려면 그 행의 엄격한 디코드와 lane 단위 보존을 같이 봐야 한다.

## 8. 이행

- **Keeper 를 지울 때의 순서.** `purge_keeper_artifacts` 는 `Keeper_memory_lane.with_librarian_purge` 안에서 파일을 지운다. `with_librarian_purge` 는 새 제출을 막고, 도는 회차를 취소하고 끝나기를 기다린 뒤, 같은 막음 아래에서 삭제를 부른다. 그 사이에 온 제출은 세고 버린다(`Dropped`). 동시 purge 는 거절된다. 삭제가 끝나거나 실패·취소되면 그 purge 의 막음만 푼다. 그래서 늦게 온 제출이 지운 파일을 다시 만들지 못한다. `request_cancel` 은 레인 소유 domain 의 요청만 받으므로 이 묶음 전체를 그 domain 에서 돌린다. Keeper 의 시작과 중지는 이 상태를 바꾸지 않는다.

## 10. 열어 둔 결정

3. **공식 클라이언트 턴을 어떤 자로 읽을지.** 그 턴의 내용은 trace 디렉터리의 `history.jsonl` 과 `history.internal.jsonl` 에 있다. 줄마다 그 줄을 쓴 턴의 `turn_ref` 와 `kind` 가 붙고, 줄 쓰기는 잠금 아래에서 내구성 있게 덧붙인다(`Keeper_context_core_history`). 회차는 누적 offset 이나 시각이 아니라 그 `turn_ref` 로 한 턴의 조각을 고른다(`Keeper_turn_fragments`). `turn_ref` 가 없는 줄은 어느 턴의 것도 아니어서 건너뛴다. `turn_ref` 를 디코더가 거절한 줄은 오류로 둔다(#37521, #37102). 남은 것은 한 턴 안에서 다른 attempt 로 넘어간 공식 클라이언트 호출이 남기는 조각이다(#38827).
