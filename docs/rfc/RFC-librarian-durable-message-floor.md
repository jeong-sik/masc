---
rfc: "librarian-durable-message-floor"
title: "Librarian durable 경로도 메시지 바닥까지 나눠 읽고, 그래도 못 읽는 메시지는 기록하고 지나간다"
status: Implemented (L2~L5 병합 2026-10-29, 맨 위 #46690. 긴 턴의 비용은 3.10, #46717)
created: 2026-10-27
updated: 2026-10-29
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
| L3d | 단계를 worker 로 돌리고 사슬로 잇는다. 첫 층은 단계 owner(retain·discover·resume)이고, host 의 Exact 권한 검사와 wake 가 단계를 알아본다. 둘째 층은 단계 gate 저널(`Keeper_librarian_original_gate.Make`), gate 만 거친 단계 판정, 사슬 구동(`Keeper_librarian_floor_chain.run`)이다. 구동은 단계를 찾거나 만들고, 답을 판정해 기계에 넣고, 크기로 거절된 메시지는 구멍으로 두고 넘어가고, 그 밖의 거절에서 멈춘다 | #46596, #46607 |
| L3e~L5 | 5절. 부르는 곳이 없는 두 층(L3e, L4)을 먼저 쌓고, 마지막 층(L5)에서 `consume_one` 에 연결한다 | 예정 |

확정한 것.

- **Add-on 을 바꾸지 않는다.** `durable` 출력은 요청마다 스키마를 싣는 정책(`Consumer_request_schema`)이다. 단계는 같은 `durable` 출력에 연속성 스키마(working state 필수)를 싣는다.
- **단계는 Runtime 바닥과 같은 질문이다.** 프롬프트의 continuity 칸에 앞 단계의 working state 와 읽지 못한 메시지를 싣는다. 단계의 결정도 Runtime 바닥의 결정처럼 `Memory_plan`·`Memory_program` 검증을 지나야 하기 때문이다. `Keeper_memory_os_program.create` 는 결정마다 비지 않은 `working_state` 를 요구하므로, 단계가 모델에게서 실제 working state 를 받아야 한다. 빈 값으로 채우면 조용한 허용이 된다.
- **`memory_step` 은 Runtime 이 찍는다.** 이 타입은 `private` 이다(게이트를 통과한 결정만 Runtime 이 만든다는 경계). durable 결과는 `Runtime.durable_memory_step` 입구로만 `memory_step` 이 되고, 그러면 `Memory_plan`·`Memory_program` 의 검증을 그대로 쓴다.
- **단계가 보는 Memory 는 앞 단계까지 반영한 값이다.** `Machine` 은 단계가 끝날 때마다 그 결정의 결과를 다음 질문의 `current` 로 넘기고, 저장소에는 아무것도 쓰지 않는다. 사슬 전체를 게시할 때 `Program.replay` 가 이 결정들을 잠긴 실제 Memory 에 다시 적용해 본다. 그사이 관련 없는 항목이 더해진 것은 허용하고, 기대한 항목이 없어졌거나 결과가 달라지면 거절한다.

**L3d 복구가 지켜야 할 조건.** 리뷰에서 나온 조건이다. #46607 이 아래 "맞춘 방법"으로 지킨다.

- 재시작해 사슬을 다시 먹일 때는 처음의 `transaction_id` 와 초기 `Memory_plan` snapshot 을 복원해 같은 기계에서 시작한다. 현재 Memory 를 새 anchor 로 잡거나 새 ID 를 만들면 같은 단계 결과여도 질문이나 program 이 달라질 수 있다. 최초 사슬에서 이 두 값은 첫 단계 요청에 저장해 보존한다. 시작 `current` 는 아래 "L3d 에서 정한 것"에 있다.
- 크기 거절로 만든 `unreadable` hole 은 처음 만든 동일한 값을 복원해 먹인다. 성공한 단계는 원래 `run_id` 와 gate 판정을 보존해 `durable_memory_step` 에 넘긴다. 복구 시점의 Memory 로 gate 를 다시 판정하거나 새 ID 를 만들지 않는다.
- 사슬의 각 결과가 현재 기계의 질문에 속하는지 request ID·position 과 질문 내용으로 확인하고, 이미 반영한 결과를 다음 질문에 다시 먹이지 않는다. 같은 position 의 다른 질문도 구분해야 한다. `matches_question` 은 단계 request 를 대조하는 입구이고 결과 재생의 중복 방어 자체는 아니다.
- 복구 시험에는 초기 anchor 가 바뀐 재시작, hole 값 보존, gate 판정 이후 Memory 가 달라진 재시작, 중복 결과와 다른 position·질문의 결과를 넣는다. 같은 근거로 복구할 때 원래 질문과 program 을 얻고, 맞지 않는 근거는 거절하는지 확인한다.

맞춘 방법(#46607).

- `transaction_id` 는 모든 단계 요청에 저장한다. 시작 facts, 이어받은 working state, 읽지 못한 메시지는 첫 단계의 입력과 컨텍스트에 있다. 단계가 하나라도 있는 사슬은 호출자가 준 시작값을 버리고 첫 단계에서 읽는다.
- 구멍은 메시지 좌표·해시와 거절 이름뿐이고 시각이나 ID 가 없다. 거절된 단계 기록과 호스트가 보관한 실행 영수증에서 같은 값을 다시 만든다.
- `run_id` 는 단계 gate 저널의 root 요청 ID 다. 한 번 정해지면 바뀌지 않는다. 끝난 저널은 보관된 평가에서 다시 읽는다. 모델을 다시 부르지 않고, 지금 Memory 로 다시 판정하지 않는다.
- 위치마다 단계는 하나다. 같은 위치에 둘이 있으면 거절한다. 단계는 기계가 지금 묻는 질문과 맞아야 하고, 기계가 묻지 않은 단계가 남아 있어도 거절한다.
- 변이 시험이 잡지 못하는 검사가 셋 있다. 구멍 조건의 줄여 읽기 판정(`message_descent`) 확인, 앞 단계 링크 비교, transaction 비교다. 이 검사만 걸리는 입력을 만들려면 다른 검사가 먼저 걸리는 단계가 필요하다.

L3d 에서 정한 것.

- **served slot.** `Machine.answered` 의 `served_by` 는 선택 인자다. 슬롯 이름(`Runtime.served_slot`: API 슬롯 또는 CLI 슬롯, id 공간이 서로 다르다)이 있는 곳은 Runtime 경로뿐이고, 읽는 쪽도 Runtime 경로의 `queue_refresh` 뿐이다. durable 답은 호스트가 보증할 슬롯이 없다. 사슬은 이 값을 넣지 않는다. 지어낸 값을 넣으면 사슬이 거짓 근거를 갖는다(#46607).
- **시작 `current`.** 사슬의 첫 단계가 시작 facts 를 입력에 담는다. 재시작한 구동은 호출자가 준 값을 버리고 첫 단계에서 읽는다. 처음 사슬을 시작할 때의 값은 그 시점에 잡은 Memory 다. 범위 original 입력의 `current` 가 아니다(3.9 의 7번). 이 값은 첫 단계 요청에 저장되어 재시작이 같은 값에서 이어진다. `Memory_plan.create_over` 가 facts 로 시작한다(#46607).
- **host 가 단계를 알아본다.** 요청 ID 분류를 `Keeper_librarian_request_namespace` 하나로 합쳐서, 새 종류가 두 곳 모두 컴파일 오류로 드러난다. host 의 Exact 권한 검사는 단계 요청을 record 하나로 복원해 답을 도메인 검증한다. wake 는 단계 결과 알림에서 단계의 Keeper 를 찾는다(#46596).
- **gate 저널은 단계마다 돈다.** 단계 하나는 답 하나와 gate 저널 하나다. 결정은 gate 를 거친 뒤에만 `memory_step` 이 되어 program 에 들어간다. Runtime 바닥도 단계마다 gate 를 거친다(`Runtime.infer_memory_step`). 합친 program 을 gate 에 다시 보내지 않는다(#46607).

열린 것.

- **게시 때 Memory 가 달라졌을 때.** `Program.replay` 가 그사이 바뀐 Memory 때문에 거절하면 사슬을 어떻게 할지는 L4 에서 정한다. 3.9 의 6번이 현재 안이다.
- **단계 gate 저널의 inventory 검증.** history 원본은 consume pass 마다 inventory 로 gate 사슬을 검증한다(`Commit.validate_inventory`). 단계에는 아직 같은 검증이 없고, `judge` 가 저널을 돌릴 때만 확인한다. L5 에서도 넣지 않았다(3.10).
- **켜진 gate 의 모델 호출.** 시험은 gate 를 끈 상태로 돈다(history 시험과 같다). 켜진 gate 가 모델에게 묻는 부분은 단계 경로도 history 경로도 시험이 거치지 않는다.

### 3.9 하강에서 게시까지 정한 것 (2026-10-28)

L3e 이후를 쓰려고 `consume_one`, `Commit`, `Source_lock` 코드를 읽고 정했다. 3.1 의 트리거를 그대로 쓴다. 아직 구현한 것은 없다.

1. **하강 후보.** 아래를 모두 만족하는 원본만 하강한다. 하나라도 아니면 지금처럼 거절로 끝나고 같은 범위를 다시 고른다.
   - 호스트가 실행 단계의 거절을 보관했다(`Rejected`).
   - 범위가 한 턴이다. 원본의 `extent` 가 `To_first_cut_point` 이고, 출처가 atom 범위 하나(`Checkpoint_only`)이거나 공식 턴 하나(`Official_only`)다. `consume_one` 은 실패한 다음 pass 에서 가장 오래된 한 턴만 읽는다(`durable_consumer.ml` 의 "A narrowed round reads the oldest turn only"). 처음부터 한 턴이던 범위는 한 pass 늦게 하강한다. 그 한 번은 worker 가 모델을 부르기 전에 내는 frame 거절이거나 provider 의 거절 한 번이다.
   - 거절 증거가 3.1 의 크기 거절이다(`Request.refusal_evidence` 와 `may_descend_messages`).
   - 범위에 메시지가 있다.
   - 범위의 Memory 영수증이 아직 없다(`Commit.receipt_state` 가 거짓).
   - 원본을 만든 뒤 읽기 위치(atom 과 공식)가 움직이지 않았다. 움직였다면 다음 pass 가 고르는 범위는 원본의 범위가 아니다.
2. **후보 원본은 사슬이 끝날 때까지 보관소로 옮기지 않는다.** 지금은 `Rejected` 원본이 `Settled` 로 분류되어 다음 pass 에 보관소로 옮겨진다. 후보는 옮기지 않는다. 단계가 원본을 ID 와 digest 로 가리키기 때문이다. 후보는 frontier 로 세지 않는다. 다음 pass 의 새 선택(`Consumer.consume_one`)이 후보와 같은 범위를 고르면 `commit` 은 새 원본을 만들지 않고 후보의 사슬을 이어 간다. 범위가 다르면(표시가 사라진 재시작 뒤 등) 지금처럼 새 원본을 만든다. 후보의 영수증이 생기거나 읽기 위치가 움직이면 후보가 아니게 되어 `Settled` 가 되고 지금 방식대로 옮겨진다.
3. **게시는 `commit` 안에서 하고, 꼬리는 Consumer 가 한다.** 사슬이 끝난 pass 에서 `commit` 이 출처 잠금 아래 외부 커서를 후보가 읽은 `through` 와 구멍이 든 범위로 다시 준비하고 `Current.apply_program` 을 부른다. 그다음 영수증 확인, 외부 커서 ack, 위치 이동은 Consumer 의 기존 꼬리가 한다. Runtime 바닥이 쓰는 꼬리와 같다. 게시 도중에 죽으면 Consumer 의 "이미 저장된 범위는 모델 호출 없이 위치만 옮긴다" 경로(`is_committed_prefix`)가 이어 받는다. 이 경로는 구멍이 든 영수증을 이미 검증한다. 거절된 원본에 commit 의도 이벤트를 새로 만들지 않는다. `Rejected` 는 끝난 상태이고 최종 증거는 영수증이다.
4. **사슬이 멈추면 멈춘 단계 기록만 정리한다.** 앞 단계의 결과는 남는다. 다음 pass 는 그 위치에 새 단계를 만들어 다시 묻는다. pass 당 모델 호출이 하나라서 지금 history 경로의 재시도 비용과 같다. 횟수 상한이나 대기 시간은 두지 않는다. 크기로 거절되어 구멍이 된 단계는 program 의 일부라서 정리하지 않는다.
5. **단계 기록의 정리.** 영수증이 생긴 사슬의 단계는 다음 pass 가 정리한다. 범위 원본이 보관소로 옮겨졌거나 없는 단계, 읽기 위치가 움직여 후보가 아니게 된 원본의 단계도 같다. 날짜는 단계 ID 가 만들어진 날이다(단계 ID 의 nonce 가 uuid v7 이다).
6. **게시 때 Memory 가 달라졌으면** `Program.replay` 가 거절할 수 있다. 현재 안은 사슬의 단계를 모두 정리하고 지금 Memory 로 처음부터 다시 돌리는 것이다. 모델 호출이 단계 수만큼 다시 든다. 드물다고 보지만 재 보지는 않았다. L4 에서 확정한다.
7. **사슬의 입력은 원본에서 읽는다.** 입력과 메시지는 원본 캡처의 `Source.input` 이다. 공식 턴의 `sources` 와 구멍은 이 메시지만으로 만든다. atom 범위는 체크포인트 전체가 있어야 `sources` 에 번호를 붙일 수 있는데, 캡처는 체크포인트의 개수와 digest 만 가진다. 그래서 지금 체크포인트를 읽고 `Capture.confirm_sources` 로 원본과 맞는지 확인한 뒤 만든다. 처음 시작할 때의 값은 Runtime 바닥과 같다. 시작 facts 는 그때의 Memory, transaction 은 새 ID, 이어받는 상태는 없음, 읽지 못한 메시지는 누적 원장이다. 원본 입력의 `current` 는 쓰지 않는다. 원본을 만든 뒤 Memory 가 달라졌을 수 있고, 사슬이 짧을수록 게시 때 달라질 틈이 줄기 때문이다. 재시작하면 첫 단계에서 읽는다.
8. **provider 가 나중에 하는 크기 거절은 범위를 좁히지 않는다.** 한 턴으로 좁혀 읽는 표시(`failed_ranges`)는 `Consumer.consume_one` 이 동기 거절(`Memory_refused`)을 받을 때만 켜진다. provider 거절은 worker 가 나중에 돌려주고 `Execution.consume_one` 의 `resume_original` 로 들어와서 표시가 켜지지 않는다. 그대로 두면 worker frame 거절(동기)은 두 pass 뒤 후보가 되지만 provider 의 크기 거절은 후보가 되지 못한다. `resume_original` 이 거절을 받을 때 같은 표시를 켠다(L5).
9. **`Commit.receipt_state` 는 구멍이 있는 게시를 못 알아본다.** 영수증의 범위 식별자에 `unread_messages` 가 들어간다. 원본이 가진 값은 구멍이 없고 바닥이 게시한 영수증에는 구멍이 있어서, 비교가 거짓이 된다. 후보 판정의 5번과 게시 확인이 이 비교를 쓰므로 구멍을 뺀 범위로 비교한다(L4).

### 3.10 L5 에서 이은 방식과 알게 된 것 (2026-10-29)

`Execution.consume_one` 에 사슬을 이었다. 3.9 에서 정한 것은 바뀌지 않았다. 이으면서 알게 된 것과 하지 못한 것을 적는다.

1. **후보는 pass 마다 새로 고른다.** 이미 끝난(`Settled`) 원본마다 `Descent.candidate` 를 부르고, 후보는 보관소로 옮기는 원본 목록에서 뺀다. 후보를 따로 기억하지 않는다. 원본, 호스트의 거절 기록, Memory 영수증, 읽기 위치에서 매번 다시 가린다.
2. **단계 기록을 원본보다 먼저 정리한다.** 같은 pass 에서 후보가 소유하지 않는 단계를 먼저 옮기고, 그다음에 끝난 원본을 옮긴다. 도중에 죽어도 "단계가 있으면 그 원본도 있다"가 깨지지 않는다. 그래서 원본이 하나도 없는 pass 는 단계를 찾지 않는다. 단계의 gate 기록은 단계 다음에 옮긴다. 시험 fixture 에서도 단계마다 gate 기록이 하나 생기고, 정리가 끝난 뒤 그 기록이 남지 않았는지를 시험이 센다.
3. **후보가 있는 pass 는 한 턴씩 읽는 표시를 먼저 켠다.** 이 표시는 프로세스 안에만 있다(`failed_ranges`). 재시작하면 사라지고, pass 는 전체 범위를 한 번 읽어 거절당한 뒤에야 후보의 범위로 좁아진다. 후보가 있다는 것은 그 범위가 한 번에 너무 크다는 증거라서 표시를 켜고 시작한다.
4. **provider 의 크기 거절은 두 pass 뒤에 후보가 된다**(3.9 의 8번). 전부 읽기를 보낸다. 거절이 도착한 pass 가 표시를 켠다. 한 턴 읽기를 보낸다. 거절이 도착한다. 이제 후보다. worker frame 거절은 보낸 pass 안에서 바로 돌아온다.
5. **후보가 범위를 덮는다는 것은 읽는 방식과 영수증 식별자가 같다는 뜻이다**(`Descent.covers`). 한 턴짜리 백로그를 처음에 전부 읽은 원본(`All_unread`)은 후보와 같은 턴을 읽지만 후보를 덮지 않는다.
6. **atom 범위 식별자에서 로그 줄 번호 둘은 비교에서 뺀다.** `boundary_lines_seen` 은 pass 가 범위를 고를 때 경계 로그의 전체 줄 수다. 원본을 만든 뒤 Keeper 가 턴을 하나만 더 끝내도 줄 수가 늘어난다. 그대로 비교하면 후보가 범위를 덮지 못해서 사슬이 한 번도 돌지 않는다. 처음 구현이 이렇게 비교했다. 로그가 자란 경우의 시험을 넣다가 알았고, 시험이 실패하는 것을 본 뒤에 고쳤다. 범위의 끝을 적은 줄(`end_boundary_line`)도 같다. 나중 줄이 같은 위치를 다시 적으면 이 번호가 뒤로 간다. 별도 리뷰가 짚었고, 시험이 그 경계 줄을 직접 써서 같은 결함을 보인 뒤에 뺐다. 실제 턴이 같은 위치를 다시 적는 경우는 보지 못했다. 두 값 모두 어느 범위인지가 아니라 로그의 어디에 적혔는지를 말한다. 공식 범위의 식별자(`after_boundary_line`, `turns`)는 읽기 위치로 정해져서 자라지 않는다.
7. **멈춘 단계는 매 pass 다시 묻는다**(3.9 의 4번 그대로). 상한도 대기 시간도 없다. history 경로가 거절된 범위를 매 pass 다시 보내는 것과 같다. 크기 거절이 아니면서 매번 같은 결과인 거절(예: 구멍이 될 수 없는 호스트 관찰)이면 이 반복이 끝나지 않는다. 고치지 않았다.
8. **Memory 가 달라지면 사슬의 단계를 모두 정리하고 `wake` 로 다음 pass 를 부른다**(3.9 의 6번 확정). 다음 pass 가 그때의 Memory 로 처음부터 돌린다. 단계 수만큼 모델 호출이 다시 든다. 얼마나 자주 나는지는 재지 않았다.
9. **사슬을 버릴 때 단계는 위치가 높은 쪽부터 옮긴다.** 사슬은 위치 0부터 k까지의 단계에서 이어 가고, 위치를 건너뛴 남은 단계는 매 pass 거절한다. 위치 0이 없으면 새 사슬을 시작하는데, 남은 1번 단계가 앞 단계로 옛 0번을 가리키기 때문이다. 저장소는 단계를 ID 의 digest 순으로 나열해서, 나열 순서대로 옮기다 멈추면 위치를 건너뛴 단계가 남을 수 있다. 처음 구현이 이렇게 옮겼고, 별도 리뷰와 리뷰어 키퍼가 같은 곳을 짚었다. 순서가 필요한 곳은 후보가 있는 채로 사슬을 버리는 경로다. 후보가 없는 사슬의 단계는 어느 순서로 남아도 다음 pass 가 모두 옮긴다. 높은 쪽부터 옮기면 멈춘 자리에 0부터 k까지가 남고 사슬이 거기서 이어 간다. 이때 Memory 가 이미 달라진 상태면 사슬은 옛 Memory 로 잃은 꼬리를 다시 묻고 끝에서 또 `Superseded` 가 되어 다시 버린다. 남은 위치만큼 모델 호출이 더 들고, 수렴은 잃은 꼬리를 다시 답할 수 있다는 조건에서만 한다. 꼬리가 크기가 아닌 이유로 계속 거절되면 `Stopped` 가 그 단계만 정리하고 같은 옛 Memory 로 다시 묻는다. 7번과 같은 한계이고, 이 경우를 실행해 재현하지는 않았다. 시험은 단계 4개 사슬의 정리 함수를 2개째에서 멈춰 보이고, 프로세스를 죽이지는 않았다.

하지 못한 것.

- 단계 gate 저널을 pass 마다 inventory 로 검증하지 않는다. pass 는 단계 기록을 엄격히 읽고(`discover`), 도는 사슬의 저널은 사슬이 검증한다. 도는 사슬이 없는 pass 에서는 단계 저널을 검증하지 않는다. 필요한지는 모르겠다.
- `Floor_cleanup` 이 단계를 후보의 것으로 가리는 비교(원본 ID 와 digest)는 시험이 잡지 못한다. 변이로 바꿔도 시험이 통과했다. 이 비교가 가르는 것은 후보가 있는 pass 에 이미 끝난 사슬의 단계가 같이 남아 있는 경우인데, 정리가 후보 선택보다 먼저라서 이 경로로는 만들 수 없다.
- `Descent.covers` 가 atom 범위 식별자의 나머지 필드를 비교하는 것도 시험이 잡지 못한다. 읽기 위치가 그대로면 같은 방식으로 고른 범위는 같은 턴이라서, 이 비교가 가르는 것은 기록이 다시 쓰인 경우뿐이다.
- 단계가 n 개인 턴은 pass 가 n 번쯤 돌고, pass 하나의 비용은 n 의 제곱이라서 턴 하나를 끝내는 시간은 n 의 세제곱이다. pass 가 판정이 끝난 단계마다 `Judgment.judge` 를 다시 돌리고, 그 안에서 gate 사슬을 6번 읽는데(`read_chain`), 한 번 읽을 때 gate 범위의 기록 전체(단계 하나에 하나)를 읽는다. 이 경로는 한 턴이 frame 을 넘을 때만 타서 드물다고 보았다(3.5). 재 보니 16 KiB 메시지 약 330개짜리 턴(bench `1:5`)이 7,200초 제한까지 134단계에 도달하고 끝나지 못했다(부하 평균 15~95). 부하 평균 6~21 에서 단계별로 나눠 잰 pass 는 N=16 에 2.8초, N=44 에 11.2초였고, N=44 의 pass 에서 `judge` 가 90%, 그중 `read_chain` 이 8.7초였다. 맞춘 식은 pass 하나 ≈ 672 + 48.5·N + 4.51·N² ms (N ≤ 44)다. 식으로 N=134 전체는 약 70분, N=330 은 약 16시간이다(맞춘 범위 밖으로 늘린 외삽). 한가한 기계의 값은 모르고, bench `5:4`, `5:5` 는 끝까지 돌리지 못했다. 처음에 이 비용을 n 제곱으로 적었고, 단계별로 나눠 재서 고쳤다. 고칠 방향(한 pass 에 gate 범위를 한 번만 읽기, 또는 단계마다 범위를 나누기)은 이슈 #46717 에 적었고, 이 스택에서는 고치지 않았다.
- 사슬이 끝나지 못하는 경로(Memory 쓰기로 처음부터 다시, 전송 직전·직후에 멈춘 단계, cursor 가 움직인 뒤 게시 거절), 후보 판정 오류가 pass 를 막는 경우, purge 가 단계 기록을 모르는 것은 코드를 읽어서만 알았고 재현하지 못했다. 이슈 #46716.

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
| L3 | 3.8 의 L3a~L3d. 바닥의 상태기계, Runtime 입구, 단계 request, 단계 owner, 사슬 구동. 부르는 곳이 없다 | 단계 사슬 crash·재개, 같은 단계 재호출 없음, 구멍 보존 |
| L3e | 하강 후보 판정과 사슬 입력 읽기(3.9 의 1번, 7번). 부르는 곳이 없다 | 크기 거절은 후보. `Invalid_request`, 열린 host 기록, 여러 턴 범위, 영수증이 있는 범위, 읽기 위치가 움직인 원본은 후보가 아님. 체크포인트가 원본 출처와 다르면 거절. 외부 커서가 움직여도 읽는다 |
| L4 | 게시(3.9 의 3번, 5번, 6번, 9번). 끝난 사슬의 program 을 Memory 에 쓰고, 영수증에 구멍을 싣고, 위치를 옮기고, 단계 기록을 정리한다. 부르는 곳이 없다 | 구멍 하나와 나머지 메시지의 Memory, 위치 이동, crash 뒤 재개, 영수증이 있을 때 다시 쓰지 않음. `specs/bug-models/LibrarianRead.tla` 의 `NoAtomPassedUnread` 와 맞는지 |
| L5 | `consume_one` 에 연결(3.9 의 2번, 4번, 8번, 구현은 3.10). 후보 원본을 보관소로 옮기지 않고(frontier 로는 세지 않는다) 사슬을 돌린다. 후보가 아닌 사슬의 단계 기록을 정리한다. bench 는 `1:5` 만 7,200초까지 쟀고 `5:5` 는 끝까지 돌리지 못했다(3.10) | 실제 worker 와 실제 4 MiB frame 으로 5 MB 메시지 하나가 든 턴: 하강은 한 번, 구멍 하나, 나머지 메시지의 Memory, 위치 이동 |

L3e~L5 를 이렇게 나눈 이유는 연결을 마지막에 두려는 것이다. 게시가 없는 채로 `consume_one` 에 연결하면 사슬이 끝나도 쓸 곳이 없다. L3e 와 L4 는 부르는 곳이 없어서 L5 가 들어갈 때까지 동작이 바뀌지 않는다.

#46397(L3 하드컷)이 capture 와 request 형식을 바꾸므로 L3 이후 층은 그 위에 쌓는다. 바닥 단계는 새 request kind 라서, 그 자체로 하드컷을 하나 더 만들지 않는다.

## 6. 열린 질문

- **단계 크기.** 정했다(2026-10-28 운영자): 메시지 하나씩. lifecycle RFC 와 같다. 호출 수가 메시지 수이지만 이 경로는 한 턴의 글이 frame 을 넘을 때만 탄다.
- **absorb gate.** 정했다. durable 커밋은 제안마다 absorb gate 를 거친다(`Keeper_librarian_absorb_gate`). Runtime 바닥도 단계마다 거친다(`Runtime.infer_memory_step`). 단계 사슬도 단계마다 거친다(3.8, #46607).
- **공식 턴.** 공식 턴도 같은 바닥을 쓴다(`official_message_floor` 와 같은 범위). 공식 턴의 출처 확인은 trace 행 digest 로 한다.
- **우선순위.** 1.2절대로 드문 경우다. #46408 뒤 이 경우의 증상은 "그 턴 뒤로 Memory 가 멈추고 매 pass 거절이 기록된다"이다. 정했다(2026-10-28 운영자): #46408 병합 뒤 바로 한다. #46408 은 막음 1까지만 병합하고, 이 RFC 의 스택이 그 위에 쌓인다.

## 7. 확신도

- 1절의 원인과 경로: 높음. 코드와 재현(bench, #46408 시험)으로 확인했다.
- 2절의 "worker frame 거절은 슬롯과 무관하다": 높음. 요청은 실행 슬롯을 고르기 전에 worker frame 을 지난다(`addons/exact_worker.py` `invoke` 의 `submit`).
- 3.2~3.4 설계가 지금 durable 커밋·settle·inventory 와 맞물린다는 점: 중간. 단계 사슬과 program 게시는 새 경로다. L3·L4 에서 코드로 확인한다.
- 3.5 의 "드물다": 중간. 도구 결과가 크기에 들어가지 않는 것은 코드로 확인했다. 한 턴의 글이 4 MB 를 넘는 일이 얼마나 생기는지는 재 보지 않았다.
