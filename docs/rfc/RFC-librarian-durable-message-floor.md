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

- typed 크기 거절은 `Input_refused Request_body_refused`(worker frame), `Input_refused Input_capacity`, `Input_refused Context_overflow` 다. 앞의 것은 두 곳에서 올 수 있다. worker 가 host 에 닿기 전에 낸 frame 거절은 host 기록이 없고 슬롯과 무관하다(`Lane_addon_exact.refused_before_host`, #46408). provider 가 본문을 거절한 것은 host 기록이 있다. host 기록이 있는 거절(`Request_body_refused` 포함)과 `Input_capacity`, `Context_overflow` 는 host Exact 가 모든 슬롯을 거친 소진 증거(실행 영수증의 `Keeper_exact_walk_failure`)가 있을 때만 크기 거절로 본다. admission 의 `check_size` 가 같은 증거를 요구한다.
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

### 3.6 L3 착수 전에 코드로 확인한 것 (2026-10-28)

3.2~3.4 는 "gate 요청과 같은 방식"으로 단계 사슬을 쓴다고 했다. L3 을 쓰려고 코드를 읽어 보니 그대로 되지 않는 곳이 있다. 아래는 읽은 사실이고, 구현 방식은 3.7 에서 고른다.

1. **후속 original 장치는 이미 있다.** `Lane_addon_request_progress` 는 `Rejected` → `Subdividing(거절, 후속)` → `Subdivided` 와 `Successor_intended/observed` 를 가진다. 실행 거절된 original 이 더 좁은 후속을 잇는 일반 장치이고 admission 이 쓴다. 반면 history 의 `predecessor`(`Keeper_librarian_durable_execution.validate_lineage`)는 기준이 낡은(`is_superseded`) 원본의 후속만 허용한다. 단계 사슬은 앞의 것 위에 올릴 수 있고 뒤의 것으로는 안 된다.
2. **한 메시지짜리 original 을 표현할 수 없다.** `Keeper_librarian_durable_capture.create` 는 `source` 가 범위를 고르고 `input` 으로 투영되는지 확인한다. 그 `source` 는 턴 범위 전체의 길이와 digest 를 쥔다. 메시지 하나만 담은 `input` 은 이 확인을 통과하지 못한다. 메시지로 좁힌 capture 형태가 새로 필요하다.
3. **게시는 한 덩어리다.** `Keeper_librarian_durable_commit.publish` 는 gate journal(root, retries, leaf), 영수증 검증, `settle_positions`(atom·official·external cursor)를 한꺼번에 한다. "Memory 만 게시하고 위치는 나중에 옮기기" 모드는 없다.
4. **위치 단위는 턴이다.** atom 과 official 위치는 턴 단위로 움직이고 메시지 단위가 아니다. 한 턴 안의 중간 단계가 위치를 옮길 수는 없다.
5. **Runtime 바닥의 단계는 휘발성 계약을 가진다.** `Keeper_librarian_message_floor.infer` 는 매니페스트를 모든 메시지에 먼저 묶고, Memory 를 한 번 캡처하고, 앞 단계의 staged facts 와 working state 를 다음 단계에 넘기고, 도구·상대 관찰은 한 Memory 단계가 받을 때까지 보존한다. 관찰만 남으면 관찰 단독 단계를 요구한다. durable 단계는 이 계약을 durable 하게 옮겨야 한다.
6. **durable 제안은 입력 하나에 대한 완결된 Memory 답이다.** `durable_proposal` 은 `absorption`(facts, new_claims, superseding, absorbed)을 싣고, 한 입력의 현재 Memory 기준 위에서 검증된다. 앞 단계 결과 위에서 다음 단계를 검증하는 형태는 없다.

### 3.7 구현 방식 두 가지

| | A. 3.2~3.3 그대로: 단계 original + 끝의 program | B. 단계마다 일반 durable 게시, 위치는 마지막에 |
|---|---|---|
| 단계 | 메시지 하나짜리 새 request kind. 결과(결정, working state)를 original 에 쥔다 | 메시지로 좁힌 source 를 가진 일반 original. 단계마다 정상 게시 |
| 게시 | 끝에 단계들의 결정과 구멍으로 program 하나. gate 와 source lock 을 합친 program 에 맞게 다시 쓴다 | 기존 `publish` 의 gate journal·검증·복구를 그대로 쓴다. `settle_positions` 를 마지막 단계까지 미루는 모드를 더한다 |
| 새로 만드는 것 | 메시지 capture, 단계 결과 보존, program 조립, 합친 gate 와 복구, 구멍 영수증 | 메시지 capture, 위치 미루기 모드, 구멍 영수증, "이번 턴의 다음 메시지" 판정 |
| 위험 | 3.3·3.4 의 게시와 복구를 새로 짠다. 휘발성 계약(3.6의 5)을 그대로 옮겨야 한다 | 중간 단계 Memory 가 위치보다 앞서 보인다. crash 뒤 "이 턴의 어디까지 했나"를 기존 original 들의 목록에서 도출해야 한다. 관찰 합류 규칙이 단계마다 달라질 수 있다 |
| 확인 못 한 것 | gate 가 program 한 개를 받는지 | (확인함) 구멍은 범위 영수증 필드라 마지막 커밋에만 실린다. 중간 단계의 정상 게시는 `receipt_state` 가 범위 전체 소비로 읽는 영수증을 남긴다 |

B 의 성립을 정하던 두 가지를 코드로 확인했다.

- **구멍의 저장 경로.** `unread_messages` 는 `Keeper_memory_os_current.durable_range_id`·`official_range_id` 의 필드다. 이 둘은 "한 Memory 커밋이 소비한 범위"의 영수증이다. 구멍은 그 범위를 소비하는 커밋 한 번에만 실을 수 있다.
- **`receipt_state` 전제.** `Keeper_librarian_durable_commit.receipt_state` 는 이 범위 영수증이 있으면 범위 전체가 Memory 에 반영됐다고 증명한다.

그래서 B 의 중간 단계가 정상 게시를 하면 첫 단계가 범위 전체를 소비했다는 영수증을 남긴다. 영수증 의미가 깨지고, 영수증 없이 Memory 만 쓰는 새 커밋 종류가 따로 필요하다. 이 새 커밋 종류가 `settle_positions` 미루기보다 크다. B 는 A 보다 작지 않다.

**A 로 간다.** 단계 결과는 단계 original 이 쥐고, 끝의 Memory 커밋 하나가 범위 영수증과 `unread_messages` 를 함께 싣는다. 아직 확인하지 못한 것은 하나다: gate journal 이 단계들의 결정을 합친 program 하나를 받는지. L3 은 단계 original 과 그 결과 보존까지만 하고, 이 질문은 L4(게시) 전에 코드로 확인한다.

### 3.8 L3 를 나눈 모양과 확정한 것 (2026-10-28)

L3 을 한 PR 로 쓰지 않고 아래로 나눠 L2(#46568) 위에 쌓는다.

| 층 | 내용 | PR |
|---|---|---|
| L3a | 바닥의 규칙을 입출력 없는 상태기계 `Keeper_librarian_message_floor.Machine` 으로 뽑는다. Runtime 바닥(`Floor.infer`)은 이 기계에 답을 넣어 주는 쪽이 된다. 각 답을 기록해 두었다가 다시 넣으면 같은 다음 질문이 나온다 | #46577 |
| L3b | Runtime 이 durable 단계를 준비·복원·검증하고, 보관된 답과 gate 판정으로 `memory_step` 을 찍는 입구 | #46580 |
| L3c | 단계 request: 일반 history original 과 다른 scope·ID·kind. 자기 입력(메시지 하나, 그 시점의 facts, 이어받는 상태)을 담아 record 하나로 복원한다. 거절된 범위 original 과 앞 단계를 ID 와 digest 로 가리킨다. 호스트 증명과 질문 코덱은 history 요청과 같은 모듈을 쓴다 | #46587 |
| L3d | 단계 gate 저널(`Keeper_librarian_original_gate.Make`)과, 기계에 답을 넣어 주는 쪽: 사슬 찾기·검증·복구, `Submit.resume` 로 실행 | 예정 |
| L3e | `consume_one` 진입: 거절된 한 턴 범위 + L2 증거 → 사슬. 하강 시험(한 번만 하강, `Invalid_request`·열린 기록은 하강 없음)을 이 층에 둔다 | 예정 |

확정한 것.

- **Add-on 을 바꾸지 않는다.** `durable` 출력은 요청마다 스키마를 싣는 정책(`Consumer_request_schema`)이다. 단계는 같은 `durable` 출력에 연속성 스키마(working state 필수)를 싣는다.
- **단계는 Runtime 바닥과 같은 질문이다.** 프롬프트의 continuity 칸에 앞 단계의 working state 와 읽지 못한 메시지를 싣는다. 단계의 결정도 Runtime 바닥의 결정처럼 `Memory_plan`·`Memory_program` 검증을 지나야 하기 때문이다. `Keeper_memory_os_program.create` 는 결정마다 비지 않은 `working_state` 를 요구하므로, 단계가 모델에게서 실제 working state 를 받아야 한다. 빈 값으로 채우면 조용한 허용이 된다.
- **`memory_step` 은 Runtime 이 찍는다.** 이 타입은 `private` 이다(게이트를 통과한 결정만 Runtime 이 만든다는 경계). durable 결과는 `Runtime.durable_memory_step` 입구로만 `memory_step` 이 되고, 그러면 `Memory_plan`·`Memory_program` 의 검증을 그대로 쓴다.
- **단계가 보는 Memory 는 앞 단계까지 반영한 값이다.** `Machine` 은 단계가 끝날 때마다 그 결정의 결과를 다음 질문의 `current` 로 넘기고, 저장소에는 아무것도 쓰지 않는다. 사슬 전체를 게시할 때 `Program.replay` 가 이 결정들을 잠긴 실제 Memory 에 다시 적용해 본다. 그사이 관련 없는 항목이 더해진 것은 허용하고, 기대한 항목이 없어졌거나 결과가 달라지면 거절한다.

열린 것.

- **served slot.** `Machine.answered` 는 단계를 처리한 슬롯(`Runtime.served_slot`: API 슬롯 또는 CLI 슬롯, id 공간이 서로 다르다)을 받는다. `Runtime.durable_memory_step` 은 슬롯을 받지 않는다. durable 답에서 슬롯을 어떻게 얻을지, 사슬에 이 값이 꼭 필요한지를 L3d 에서 정한다.
- **gate 저널이 단계마다 도는 비용.** 단계 하나는 답 하나와 gate 저널 하나다. L4 전에 저널이 단계들의 결정을 합친 program 하나를 받는지 확인한다.
- **사슬을 다시 세울 때의 시작 `current`.** 단계는 자기 입력을 담으니 단계 하나를 복원하는 데는 시작 Memory 가 필요 없다. 다만 재시작한 구동은 기계에 처음부터 단계 결과를 다시 먹여 다음 질문을 얻는다. 그때 기계의 시작 `current` 는 사슬 안에서 한 값이어야 질문이 단계와 맞는다. 후보는 범위 original 입력의 `current` 다. 기계가 쓰는 `Memory_plan.create` 는 전체 `Current.t` 를 받는데 범위 original 에는 facts 와 revision 만 있으므로, 생성자 인자를 facts 로 바꿔야 한다. 게시 때 `Program.replay` 가 그사이 바뀐 Memory 때문에 거절하면 사슬을 어떻게 이을지는 L4 에서 정한다.
- **host 가 단계를 알아보지 못한다.** `server_librarian_addon_wake.ml` 과 `server_librarian_addon_validation.ml` 이 요청 ID 를 각자 복사한 `namespace` 함수로 분류하고, 둘 다 단계 ID 를 `Other` 로 본다. host 의 Exact 권한 검사는 단계 요청을 `not_allowed: lacks its original host identity` 로 거절하고, wake 는 단계 결과 알림(`Exact_result_delivered`)을 "no original execution namespace" 로 거절한다. 단계는 입력을 담으니 host 가 record 하나로 복원해 답을 도메인 검증할 수 있다. 분류 함수를 하나로 합쳐 새 종류가 두 곳 모두 컴파일 오류로 드러나게 한다. L3d 에서 한다.

## 4. 다른 안

- **턴 전체를 구멍으로 기록하고 지나가기.** 고르지 않는다. 읽을 수 있는 메시지까지 잃는다. lifecycle RFC 는 지나가는 자리를 바닥의 메시지 하나로 좁혔다.
- **큰 메시지 내용을 잘라 보내기.** 고르지 않는다. 문턱으로 내용을 줄이는 안이고, 잘린 것이 기록되지 않는다. lifecycle RFC 는 판정 근거를 문턱이 아니라 typed 거절로 정했다.
- **`max_reply_bytes` 올리기.** 고르지 않는다. 벽이 옮겨갈 뿐이다. worker 메모리 상한(128 MiB)과 목록 응답 크기도 함께 커진다.
- **durable 경로에서 Runtime 바닥을 직접 부르기.** 고르지 않는다. 모델 호출 전에 original 을 붙잡는 durable 경로의 규칙을 벗어난다. crash 뒤에 같은 메시지를 다시 부를 수 있다.
- **메시지 하나가 아니라 frame 에 맞게 여러 메시지를 묶어 단계로 보내기.** 고르지 않는다(2026-10-28 운영자 결정, 6절). 모델 호출이 줄지만, 묶음 경계를 정하는 규칙이 하나 더 생긴다.

## 5. 층

| 층 | 내용 | 시험 |
|---|---|---|
| L1 | 이 RFC | — |
| L2 | durable `refusal_report` 가 3.1 의 크기 거절에만 `Smaller_input_may_help`·`provider_input_refusals` 를 싣는다. host 기록이 없는 frame 거절은 final 만으로, 기록이 있는 거절은 실행 영수증의 소진 증거로 판정한다. 바닥은 아직 없다 | 크기 거절과 다른 거절의 보고 차이, 영수증 증거가 없는 `Input_capacity` 는 근거 없음 |
| L3 | 3.8 의 L3a~L3e. 3.7 에서 고른 방식의 바닥 단계, 앞 단계 연결, inventory·복구 | 단계 사슬 crash·재개, 같은 단계 재호출 없음, 하강은 한 번 |
| L4 | program 게시, 구멍 영수증, source lock, settle | 실제 worker 와 실제 4 MiB frame 으로 5 MB 메시지 하나가 든 턴: 구멍 하나와 나머지 메시지의 Memory, 위치 이동. `specs/bug-models/LibrarianRead.tla` 의 `NoAtomPassedUnread` 와 맞는지 |
| L5 | bench `5:5` 측정, RFC status 갱신 | — |

#46397(L3 하드컷)이 capture 와 request 형식을 바꾸므로 L3 이후 층은 그 위에 쌓는다. 바닥 단계는 새 request kind 라서, 그 자체로 하드컷을 하나 더 만들지 않는다.

## 6. 열린 질문

- **단계 크기.** 정했다(2026-10-28 운영자): 메시지 하나씩. lifecycle RFC 와 같다. 호출 수가 메시지 수이지만 이 경로는 한 턴의 글이 frame 을 넘을 때만 탄다.
- **absorb gate.** durable 커밋은 제안마다 absorb gate 를 거친다(`Keeper_librarian_absorb_gate`). Runtime 바닥 단계가 gate 를 어떻게 거치는지 코드로 확인하고 같게 한다.
- **공식 턴.** 공식 턴도 같은 바닥을 쓴다(`official_message_floor` 와 같은 범위). 공식 턴의 출처 확인은 trace 행 digest 로 한다.
- **우선순위.** 1.2절대로 드문 경우다. #46408 뒤 이 경우의 증상은 "그 턴 뒤로 Memory 가 멈추고 매 pass 거절이 기록된다"이다. 정했다(2026-10-28 운영자): #46408 병합 뒤 바로 한다. #46408 은 막음 1까지만 병합하고, 이 RFC 의 스택이 그 위에 쌓인다.

## 7. 확신도

- 1절의 원인과 경로: 높음. 코드와 재현(bench, #46408 시험)으로 확인했다.
- 2절의 "worker frame 거절은 슬롯과 무관하다": 높음. 요청은 실행 슬롯을 고르기 전에 worker frame 을 지난다(`addons/exact_worker.py` `invoke` 의 `submit`).
- 3.2~3.4 설계가 지금 durable 커밋·settle·inventory 와 맞물린다는 점: 중간. 단계 사슬과 program 게시는 새 경로다. L3·L4 에서 코드로 확인한다.
- 3.5 의 "드물다": 중간. 도구 결과가 크기에 들어가지 않는 것은 코드로 확인했다. 한 턴의 글이 4 MB 를 넘는 일이 얼마나 생기는지는 재 보지 않았다.
