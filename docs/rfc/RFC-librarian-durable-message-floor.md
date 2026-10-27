---
rfc: "librarian-durable-message-floor"
title: "Librarian durable 경로도 메시지 바닥까지 나눠 읽고, 그래도 못 읽는 메시지는 기록하고 지나간다"
status: Draft
created: 2026-10-27
updated: 2026-10-27
author: claude
related: ["librarian-lifecycle", "librarian-history-original-holds-what-it-read"]
---

# Librarian durable 경로도 메시지 바닥까지 나눠 읽고, 그래도 못 읽는 메시지는 기록하고 지나간다

## 0. 요약

Librarian 이 Add-on 으로 도는 durable 경로는, 한 턴이 그 자체로 worker frame(4 MiB)을 넘으면 그 턴을 영영 읽지 못한다. 매 pass 같은 턴을 잡아 거절되고, 그 Keeper 의 Memory 는 그 턴 뒤로 나아가지 않는다.

Runtime 직통 경로에는 이미 답이 있다(`RFC-librarian-lifecycle` §4.3, I3, 2026-09-22 운영자 결정). 턴을 메시지 하나씩 읽고, 메시지 하나만으로도 typed 크기 거절을 받으면 그 메시지를 "읽지 못한 메시지"로 기록하고 지나간다. 이 RFC 는 같은 바닥을 durable 경로에 만든다. 각 메시지 단계는 durable original 로 남겨 crash 뒤에도 이어 가고, 끝에서 Memory program 하나로 게시한다.

## 1. 문제

### 1.1 지금 일어나는 일

#46408 이 머지되면 이렇게 된다.

1. pass 가 읽을 범위를 렌더링한 요청이 worker 의 `max_reply_bytes`(Librarian `addons/keeper-librarian/lane.toml`, 4,194,304)를 넘는다.
2. worker 가 `input_refused/request_body_refused` 로 거절하고, original 은 `Rejected(Execution)` 로 끝난다.
3. 다음 pass 는 실패 뒤라 첫 턴만 읽는다(`To_first_cut_point`, `Keeper_librarian_durable_consumer.consume_one_with_progress_writer_and_floor`). 여러 턴 범위는 여기서 풀린다.
4. 첫 턴 하나가 이미 frame 을 넘으면 같은 거절이 매 pass 되풀이된다.
   - production durable 경로는 `Consumer.consume_one` 으로 `No_message_floor` 다(`keeper_librarian_durable_execution.ml`).
   - durable `refusal_report` 는 `message_descent=No_descent_evidence` 로 고정이다.

#46408 전에는 2에서 커밋이 막혀, 여러 턴 범위도 같은 자리에 멈췄다(#46398).

### 1.2 라이브

2026-10-27 16시 KST, 읽기 전용 확인이다.

- Librarian history Exact 요청(`output=durable`) 897개: p50 117 KB, p90 252 KB, 최대 2.72 MB. 3 MB 초과 0개.
- 지금 이 문제로 멈춘 Keeper 는 없다. 최대값은 frame 의 약 65% 다.
- 도구 결과는 프롬프트에 원문이 아니라 한 줄 표시(`[tool result omitted: id=… is_error=…]`)로만 들어간다(`Keeper_librarian.text_of_content`). 그래서 한 턴이 frame 을 넘으려면 그 턴의 글(사용자·assistant 텍스트)이 4 MB 를 넘어야 한다. 큰 파일을 대화창에 그대로 붙여 넣은 턴 같은 경우다. 여러 턴 범위가 frame 을 넘는 경우는 #46408 로 풀린다.

### 1.3 측정

`bench_keeper_librarian_pass`(#46371) `5:4`·`5:5`(이미 읽은 5 MB, 읽을 4·5 MB 한 턴)가 #46394·#46397 모두에서 모델을 부르지 못하고 끝난다. `5:3` 은 정상이다.

## 2. 이미 정해진 것

- **바닥과 기록 (`RFC-librarian-lifecycle` §4.3, I3).** 위치는 읽은 턴만 지나간다. 예외는 바닥까지 나눠도 걸음의 모든 슬롯이 비일시 거절을 준 메시지다. 그 메시지는 원문 좌표·원문 해시·명명된 원인과 함께 기록되고, 위치가 지나간다. 판정 근거는 구조(더 나눌 수 없는 바닥)와 typed 거절이고, 크기 문턱이 아니다.
- **저장 계약.** Memory WAL 의 atom·공식 턴 영수증(스키마 2)은 `unread_messages` 를 늘 싣는다. 누적 원장 `<keeper>.librarian-unread.json` 이 구멍을 보존한다.
- **Runtime 바닥 구현.** `Keeper_librarian_message_floor.infer` 는 메시지 하나씩 `Runtime.infer_memory_step` 을 부르고, `exhausted_input_refusals` 가 있으면 구멍(`Keeper_librarian_unread.for_atom`/`for_official_turn`)을 만든다. 끝에서 `Keeper_librarian_memory_program` 하나를 `Current.apply_program` 으로 게시한다(`Keeper_librarian_durable_consumer.checkpoint_message_floor`, `official_message_floor`).

worker 의 frame 거절은 이 조건에 맞는다. 어느 슬롯이 실행하든 요청은 같은 worker frame 을 지나므로, 메시지 하나짜리 요청이 frame 을 넘으면 모든 슬롯에서 같은 거절이다. 일시적이지 않다.

## 3. 설계

### 3.1 들어가는 조건

durable pass 가 첫 턴 하나(`To_first_cut_point`)의 범위에서 typed 크기 거절로 끝나면, 다음 pass 는 그 범위를 바닥 단계로 읽는다.

- typed 크기 거절은 `Input_refused Request_body_refused`(worker frame), `Input_refused Input_capacity`, `Input_refused Context_overflow` 다. 앞의 것은 슬롯과 무관하다. 뒤의 둘은 host Exact 가 모든 슬롯을 거친 소진 증거(`exhausted_input_refusals`)가 있을 때만 크기 거절로 본다.
- `Invalid_request`, `Invalid_output`, `Output_limit_reached`, `Outcome_unknown` 같은 다른 거절은 지금처럼 바닥으로 가지 않는다.
- durable `refusal_report` 는 위 조건일 때만 `message_descent=Smaller_input_may_help` 와 `provider_input_refusals` 를 싣는다.

### 3.2 바닥 단계는 durable original 사슬이다

바닥은 범위의 메시지(공식 턴은 그 턴의 메시지)를 원래 순서로 하나씩 읽는다. 단계마다 durable original 하나를 남긴다.

- 단계 요청에는 다음이 들어간다.
  - 메시지 하나와 그 귀속(`historical_task_contexts` 를 그 메시지로 좁힌 것, Runtime 바닥의 `contexts_for_input` 과 같다)
  - 앞 단계까지 반영한 현재 사실
  - 앞 단계의 working state
  - 지금까지의 구멍
- 단계 original 은 앞 단계 original 을 digest 로 가리킨다(#46247 의 gate 요청과 같은 방식). 첫 단계는 거절된 범위 original 을 가리킨다.
- 단계 original 도 dispatch 전에 붙잡히고, 결과는 지금 durable 경로와 같은 host Exact 증명을 거친다. 모델 호출은 단계마다 한 번이고, 같은 단계를 다시 부르지 않는다.
- 단계가 typed 크기 거절로 끝나면 그 메시지는 구멍이 된다. 다른 이유로 끝나면 바닥 전체가 멈춘다. Runtime 바닥의 `refused` 와 같고, 위치는 움직이지 않는다.

### 3.3 게시

마지막 단계가 끝나면 단계들의 Memory 결정과 구멍으로 `Keeper_librarian_memory_program` 하나를 만든다. 이 program 을 `Current.apply_program` 으로 게시하고, 영수증 `unread_messages` 에 구멍을 싣는다.

- 게시 직전 확인은 `Keeper_librarian_durable_source_lock` 이 한다. 거절된 범위 original 의 출처 digest(#46397 의 `confirm_sources`)로 지금 출처를 확인한다. 단계 original 들은 출처를 따로 담지 않는다. 범위 original 의 범위 안 메시지와 단계의 메시지가 같은지는 메시지 해시(`Keeper_librarian_unread.message_digest`)로 본다.
- 게시가 끝나면 위치가 그 턴을 지나간다. 구멍은 누적 원장에 남는다(lifecycle RFC 의 저장 계약 그대로).

### 3.4 중단과 복구

- inventory 가 끝나지 않은 바닥 사슬을 찾으면 마지막으로 붙잡힌 단계부터 이어 간다. 끝나지 않은 frontier 는 Keeper 마다 하나라는 지금 규칙(`Keeper_librarian_durable_execution` "multiple unfinished original frontiers")에 사슬 전체가 하나로 들어간다.
- 사슬이 끝났는데 게시가 확인되지 않았으면, 지금 durable 커밋처럼 Memory WAL 영수증으로 확인한 뒤 위치를 옮긴다.
- 끝난 사슬은 settle 한다(#46244). 단계 original 은 체인 root 의 날짜 아래로 간다.

### 3.5 비용

바닥 단계 수는 그 턴의 메시지 수다. 이 경로는 한 턴의 글이 frame 을 넘을 때만 탄다. 도구 결과가 크기에 들어가지 않으므로 드물다고 본다(1.2절). 드물기 때문에, 이 경로의 비용보다 그 Keeper 의 Memory 가 영영 멈추는 것을 막는 쪽이 이 RFC 의 이유다.

## 4. 다른 안

- **턴 전체를 구멍으로 기록하고 지나가기.** 고르지 않는다. 읽을 수 있는 메시지까지 잃는다. lifecycle RFC 는 지나가는 자리를 바닥의 메시지 하나로 좁혔다.
- **큰 메시지 내용을 잘라 보내기.** 고르지 않는다. 문턱으로 내용을 줄이는 안이고, 잘린 것이 기록되지 않는다. lifecycle RFC 는 판정 근거를 문턱이 아니라 typed 거절로 정했다.
- **`max_reply_bytes` 올리기.** 고르지 않는다. 벽이 옮겨갈 뿐이다. worker 메모리 상한(128 MiB)과 목록 응답 크기도 함께 커진다.
- **durable 경로에서 Runtime 바닥을 직접 부르기.** 고르지 않는다. 모델 호출 전에 original 을 붙잡는 durable 경로의 규칙을 벗어난다. crash 뒤에 같은 메시지를 다시 부를 수 있다.
- **메시지 하나가 아니라 frame 에 맞게 여러 메시지를 묶어 단계로 보내기.** 열어 둔다(6절). 모델 호출이 줄지만, 묶음 경계를 정하는 규칙이 하나 더 생긴다.

## 5. 층

| 층 | 내용 | 시험 |
|---|---|---|
| L1 | 이 RFC | — |
| L2 | durable `refusal_report` 가 3.1 의 크기 거절에만 `Smaller_input_may_help`·`provider_input_refusals` 를 싣는다. 바닥은 아직 없다 | 크기 거절과 다른 거절의 보고 차이 |
| L3 | 바닥 단계 request kind, 앞 단계 digest 연결, inventory·복구 | 단계 사슬 crash·재개, 같은 단계 재호출 없음 |
| L4 | program 게시, 구멍 영수증, source lock, settle | 실제 worker 와 실제 4 MiB frame 으로 5 MB 메시지 하나가 든 턴: 구멍 하나와 나머지 메시지의 Memory, 위치 이동. `specs/bug-models/LibrarianRead.tla` 의 `NoAtomPassedUnread` 와 맞는지 |
| L5 | bench `5:5` 측정, RFC status 갱신 | — |

#46397(L3 하드컷)이 capture 와 request 형식을 바꾸므로 L3 이후 층은 그 위에 쌓는다. 바닥 단계는 새 request kind 라서, 그 자체로 하드컷을 하나 더 만들지 않는다.

## 6. 열린 질문

- **단계 크기.** Runtime 바닥처럼 메시지 하나인가, frame 에 맞게 묶은 창인가. 메시지 하나는 lifecycle RFC 와 같고 단순하지만 호출 수가 메시지 수다.
- **absorb gate.** durable 커밋은 제안마다 absorb gate 를 거친다(`Keeper_librarian_absorb_gate`). Runtime 바닥 단계가 gate 를 어떻게 거치는지 코드로 확인하고 같게 한다.
- **공식 턴.** 공식 턴도 같은 바닥을 쓴다(`official_message_floor` 와 같은 범위). 공식 턴의 출처 확인은 trace 행 digest 로 한다.
- **우선순위.** 1.2절대로 드문 경우다. #46408 뒤 이 경우의 증상은 "그 턴 뒤로 Memory 가 멈추고 매 pass 거절이 기록된다"이다. 이 RFC 를 #46397 배포 직후에 할지, 실제로 생긴 뒤에 할지는 운영자가 정한다.

## 7. 확신도

- 1절의 원인과 경로: 높음. 코드와 재현(bench, #46408 시험)으로 확인했다.
- 2절의 "worker frame 거절은 슬롯과 무관하다": 높음. 요청은 실행 슬롯을 고르기 전에 worker frame 을 지난다(`addons/exact_worker.py` `invoke` 의 `submit`).
- 3.2~3.4 설계가 지금 durable 커밋·settle·inventory 와 맞물린다는 점: 중간. 단계 사슬과 program 게시는 새 경로다. L3·L4 에서 코드로 확인한다.
- 3.5 의 "드물다": 중간. 도구 결과가 크기에 들어가지 않는 것은 코드로 확인했다. 한 턴의 글이 4 MB 를 넘는 일이 얼마나 생기는지는 재 보지 않았다.
