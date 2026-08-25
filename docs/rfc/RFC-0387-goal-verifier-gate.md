---
rfc: "0387"
title: "Goal verifier 게이트 — 성공조건 필수화, 생성 시 실재성 검증, 완료의 2단계 증명"
status: Draft
created: 2026-08-19
updated: 2026-08-20
author: agent-16 + kimi
supersedes: []
superseded_by: null
related: ["0362", "0089", "0337", "0361"]
---

# RFC-0387: Goal verifier 게이트

## 0. Summary

constitution의 Goal 규칙 B1–B3는 문서만 있고 코드가 없었다. 이 RFC는 그 세 규칙을 기존 검증
프로토콜 위에 얹는 최소 설계다.

- **B1 (성공조건 필수)**: `Goal_store.upsert_goal`의 생성 경로가 `metric`과 `target_value`를
  요구한다. 둘 다 blank이면 생성은 typed error로 거절된다. 갱신(기존 goal의 메타데이터 수정)은
  게이트 대상이 아니다.
- **B2 (생성 시 Verifier 실재성 체크)**: goal 생성과 함께 criterion 검증 요청이
  `goal_verifications.json`에 durable하게 기록된다 (`Criterion_pending`). Verifier의 판정은
  `record_criterion_viable` / `record_criterion_unreachable` action으로 커밋되며, 판정
  결과는 goal record가 아니라 이 ledger에 보존된다. `Criterion_unreachable` 판정이 있는 goal은
  `request_complete`이 typed conflict로 거절된다.
- **B3 (완료 = Verifier 가 동작으로 증명)**: `Goal_phase`에 `Verifying` phase 하나와
  두 action(`record_proof_proven`, `record_proof_refuted`)을 추가한다.
  `request_complete`은 `Executing -> Verifying`으로 가고, `Completed`에 도달하는 유일한
  경로는 `Verifying -(record_proof_proven)-> Completed`다.

  **사람 확인 축은 철회한다 (2026-08-20).** 초안은 `Awaiting_confirmation` phase 와
  `human_confirm` / `human_reject` 를 두어 완료를 사람의 확인 뒤에 놓으려 했다. 실측이
  그 전제를 반증한다: 완료된 Goal 18건의 종결 주체는 Keeper 자신 8건(rondo·sangsu·
  kidsnote·analyst), admin 4건, operator·probe·mcp-client 6건이고 **"사람이 확인했다"는
  사건은 `goal_events.jsonl` 어디에도 없다**. 확인할 표면도 이 RFC 범위 밖으로 빠져 있다.

  게다가 action enum 은 `List.map action_to_string Goal_phase.all_actions` 로 생성되므로
  새 action 은 그대로 `masc_goal_transition` 스키마에 실린다. 즉 **Keeper 가 자기 Goal 의
  `human_confirm` 을 스스로 누를 수 있다.** 그러면 게이트는 이름만 남고 턴 수만 늘고,
  누르지 못하게 막으면 Goal 이 `Awaiting_confirmation` 에서 나올 길을 잃는다. 어느 쪽이든
  헌법의 게이트 조항("게이트로 얻는 실익이 크고 Feature 가 더 잘 돌아갈 때만")에 걸린다.

  사람의 확인이 필요한 국면은 관측·통지로 제공한다. 상태를 잡아두는 방식이 아니다.

이 PR이 만드는 것은 게이트·상태기계·ledger·관측 표면이다. pending된 criterion/proof 요청을
실제로 모델에 던지는 standalone verifier worker(Eio lane)은 **B7 후속**이다 — Task 도메인의
`completion_authority_agent`(`lib/completion_authority_agent.ml`)가 하는 일의 Goal 판으로,
기반은 이미 `Task.Anti_rationalization.review`(typed verdict, evaluator 미설정 시 typed
non-verdict)로 존재한다. 본 PR은 그 모델 호출 **전에** durable 요청이 영속화되는 지점까지만
만든다 (persist_before_model_call).

## 0.5 Staging

구현은 두 단계로 나뉜다 (adversarial review 지적 — 게이트에 caller 가 없으면 gate 에 들어선
goal 은 keeper 의 시야에서 사라지고 영원히 `Completed` 에 도달할 수 없다 — 에 따라 분할).

- **Stage 1 (PR #29152, 이 문서의 첫 구현)**: **B1 + ledger + 관측성만** 딴다.
  - B1: `Goal_store.upsert_goal`의 생성 경로가 `metric`/`target_value`를 요구한다 (§2).
  - `Goal_verification` ledger (`lib/goal/goal_verification.ml`) 는 **record-only 증거
    저장소**로 도입된다 — 이 단계에서는 writer 가 하나도 없다. verdict 커밋 API
    (`record_criterion_verdict` / `record_proof_verdict`) 와
    strict 디코더, fail-closed mutation, fail-loud read 만 갖춘다.
  - 관측성: `masc_goal_list` 와 `/api/v1/dashboard/planning` 의 goal 항목에 ledger
    `verification` 상태가 합류된다 (§6).
  - **Stage 1은 lifecycle 을 전혀 바꾸지 않는다**: `request_complete`은 여전히
    `Executing -> Completed` 로 곧장 완료된다. `Verifying` phase, gate action 들,
    criterion/proof 의 durable 요청 기록(`mark_*_pending`)은 전부 stage 2다.
- **Stage 2 (후속 PR)**: §3.2/§3.3/§4/§5 의 FSM 게이트 — phase 1종 + action 4종,
  `request_complete`의 `Verifying` 재라우팅, 생성 시 `Criterion_pending` durable 요청,
  `Criterion_unreachable`의 `request_complete` 차단 — 와 그 게이트를 실제로 부르는
  **verifier caller**(B7 standalone lane) 를 함께 딴다. 게이트는 caller
  없이 머지하지 않는다.

아래 §2–§6 은 최종 설계 전체를 기술한다. 각 절이 어느 stage 에 속하는지는 이 절의 분할을
따른다.

## 1. 원칙 → 설계 강제

| 원칙 | 이 RFC에서의 강제 |
|---|---|
| 닫힌 합타입 | 새 상태는 전부 닫힌 variant다: phase 2종(`Goal_phase.t`), criterion 4종, completion 5종(`Goal_verification`). 문자열 상태 금지 |
| strict parse | `goal_verifications.json` 디코더는 unknown 필드/unknown variant 문자열을 Error로 거절한다. 레거시 row(필드 부재)만 명시적 default(`Criterion_unchecked` / `Completion_idle`)로 읽힌다 |
| 권위 저장소 fail-closed | `Goal_verification`의 쓰기 경로는 `Goal_store.update_state`와 같은 discipline을 따른다: 읽기가 decode 실패하면 mutation 불승인(`.last-good` mirror 포함) |
| persist_before_model_call | `Criterion_pending`은 goal 생성 직후(모델 호출 전), `Proof_pending`은 `Verifying` phase 전이 전에 durable하게 쓴다. 영속화 실패 시 phase 전이/판정 커밋 모두 중단 |
| wall-clock 만료 금지 | `Criterion_pending`/`Proof_pending`에는 만료가 없다. 재시도는 명시적이다: `Verifying`에서의 `request_complete` 재호출이 `Already`를 답하며 pending 상태를 그대로 보고한다 |
| 실패 시 증거 보존 | `Refuted` 판정은 verdict(authority·evidence·recorded_at)째 ledger에 남고 goal 은 `Executing` 으로 돌아간다. 기각 사유는 `goal_events.jsonl` 에 남는다 |
| 매직 넘버/문자열 매칭 금지 | 게이트 판정은 전부 typed variant 매칭이다. 임계값·budget·문자열 substring 판정 없음 |
| 재사용 우선 | verdict provenance는 `Masc_domain.completion_authority`(`Human_operator` / `System_llm_agent`)를 그대로 쓴다. judge 호출은 B7에서 `Task.Anti_rationalization.review` 위에 얹는다 |

## 2. B1 — 생성 시 성공조건 필수 (stage 1)

`Goal_store.upsert_goal`은 오늘 `title`만 필수다(`metric`/`target_value`는 `string option`).
변경: 실제 생성(locked read 후 해당 id의 row가 없음)으로 확인되면 `metric`과 `target_value`
모두 non-blank를 요구한다. 기존 row 갱신은 요구하지 않는다 — B1은 생성 시 선언 의무다.

- 생성/갱신 판정은 **write lock 안**, 방금 decode된 state 위에서 이뤄진다. pre-lock
  `read_state` 휴리스틱은 쓰지 않는다: decode 불가 저장소는 `update_state`의 fail-closed
  거절이 먼저 잡으므로, B1 거절 메시지는 저장소를 실제로 읽고 row가 없음을 확인한 경우에만
  나간다 (corruption을 "metric/target_value 누락"으로 오보하지 않는다).
- 툴 스키마(`masc_goal_upsert`)는 create-or-update 겸용이라 JSON Schema `required`(무조건
  적용)로는 B1을 표현할 수 없다 — `required`에 넣으면 기존 goal의 메타데이터 갱신이 전부
  깨진다. 생성 경로 강제는 handler(`Goal_store.upsert_goal`)가 담당하며, 스키마는 두 필드의
  description에 "생성 시 필수"를 명시한다.

## 3. B2 — 생성 시 criterion 검증 (Verifier 실재성 체크)

> **Stage 2.** 저장소(§3.1)는 stage 1이 싣지만, 이 절의 writer(§3.2 생성 훅, §3.3 판정
> 커밋/게이트)는 verifier caller와 함께 stage 2에서 켜진다. Stage 1의 ledger는 writer 없는
> record-only 저장소다.

### 3.1 저장소: `Goal_verification` (lib/goal/goal_verification.ml)

`Goal_store.goal` record는 외부 caller가 literal로 구성하므로(goal_store.mli:16-23) 필드 추가의
파급이 크다. 따라서 `Workspace_goal_index`(goal-task link)와 같은 방식으로 **별도 ledger**
`.masc/goal_verifications.json`에 둔다.

```ocaml
type verdict =
  { outcome : Proven | Refuted of { reason : string }
  ; verification_run_id : string
  ; authority : Masc_domain.completion_authority
  ; evidence : string
  ; recorded_at : string
  }

type criterion_state =
  | Criterion_unchecked        (* RFC-0387 이전 row의 명시적 default *)
  | Criterion_pending of { requested_at : string }   (* durable 요청 기록됨, 판정 전 *)
  | Criterion_viable of verdict
  | Criterion_unreachable of verdict
```

### 3.2 생성 훅

`masc_goal_upsert`가 `created`를 답하면 곧바로 `mark_criterion_pending`으로 durable 요청을
쓴다. 이 쓰기가 실패해도 goal은 이미 커밋됐으므로(delete_goal의 cross-file best-effort
전례) 응답은 성공이지만 `criterion_check` 필드에 실패를 명시한다 — 모델 호출(B7)은 이
영속화가 선행된 요청만 처리한다.

### 3.3 판정 커밋과 게이트

Verifier(B7 worker)는 `masc_goal_transition`의 `record_criterion_viable` /
`record_criterion_unreachable` action으로 판정을 커밋한다. 이 action은 **phase-neutral**하다:
`decide_transition`은 비종료 phase에 대해 `Already <같은 phase>`를 답하고(§5), 핸들러는
phase 쓰기 없이 ledger만 갱신한다. `evidence` 인자는 필수(non-blank)다 — 근거 없는 판정은
validation error.

게이트: `request_complete` 시 criterion이 `Criterion_unreachable`이면 typed conflict로 거절.
`Criterion_pending`(미판정)은 막지 않는다 — 완료 시점의 proof 검증(§4)이 더 강한 게이트이며,
미판정 영구 차단은 wall-clock 없는 stall과 다름없기 때문이다.

## 4. B3 — 완료의 2단계 증명

> **Stage 2.** phase/action 추가와 `request_complete` 재라우팅은 게이트를 부를 verifier
> caller(B7)와 같은 PR에서만 머지한다 — caller 없는 게이트는 진입한 goal을 keeper 시야에서
> 지우고 완료 경로를 영구 차단한다 (adversarial review P0). Stage 1에서는
> `request_complete`이 종전대로 `Executing -> Completed`다.

### 4.1 상태기계 변경 (lib/goal/goal_phase.ml)

phase 1종 추가: `Verifying`(완료 요청 접수, proof 대기). action 2종 추가:

| action | from | to | 커밋 주체 |
|---|---|---|---|
| `record_proof_proven` | `Verifying` | `Completed` | Verifier(`System_llm_agent`) |
| `record_proof_refuted` | `Verifying` | `Executing` | Verifier — 반증 evidence 보존 |

`Awaiting_confirmation` / `human_confirm` / `human_reject` 는 §3 B3 의 근거로 철회했다.

`request_complete`의 유일한 이동은 이제 `Executing -> Verifying`이다. `Verifying` 진입 **전에**
`mark_proof_pending`이 durable하게 쓰인다(persist_before_model_call); ledger 쓰기 실패 시
phase는 움직이지 않는다.

completion 상태 (같은 ledger):

```ocaml
type completion_state =
  | Completion_idle
  | Proof_pending of { requested_at : string }
  | Proof_proven of verdict
  | Proof_refuted of verdict
```

`Completed` phase에 있는 goal의 ledger row는 `Proof_proven verdict`를 지니므로
"완료 = verifier 가 동작으로 증명"의 사슬이 durable하게 읽힌다 — 판정 주체와 증거,
기록 시각이 그 verdict 안에 있다.

`record_proof_verdict`는 ledger 쪽에서도 `Proof_pending`을 요구한다 — phase(FSM)와
ledger(저장소) 양쪽이 같은 전이를 이중으로 검증해 stale verifier 커밋 경합을 막는다.

### 4.2 직접 완료의 폐기

기존 `Executing -(request_complete)-> Completed` 직행은 사라진다. `Paused`/`Blocked`에서의
완료 요청은 종전대로 invalid다. `Completed`/`Dropped`에서 `reopen`/`drop` 동작은 불변이다.

### 4.3 신분 바인딩

`record_proof_*`는 public MCP action이 아니다. standalone verifier worker만 호출할 수 있는
typed application boundary가 고정된 `verifier_exact` authority를 만들며, caller는 authority를
인자로 공급하거나 Keeper/session 이름으로 가장할 수 없다. 각 verdict의
`verification_run_id`는 같은 시도의 durable evaluator/tool 관측 row와 결합한다.

## 5. `Already` 의미론 확장

> **Stage 2.** `decide_transition` 대각선 확장은 gate action들과 함께 들어온다.

`decide_transition`의 대각선 규칙("목표 phase에 이미 있는 요청은 Already")을 두 방향으로
확장한다:

- `Verifying`에서의 `request_complete` → `Already <현재 phase>`
  (완료 요청은 파이프라인에 진입해 있다). 핸들러는 이 응답에 verification 상태를 실어
  재시도 힌트로 쓴다 — wall-clock 만료 대신 명시적 재호출.
- `record_criterion_*` → 비종료 phase에서 `Already <현재 phase>`: "phase 불변, ledger만
  갱신"의 legality 판정. `Completed`/`Dropped`에서는 invalid — 종료된 goal의 생성 시점
  선언은 확정된 역사다.

proof action의 phase 밖 호출은 전부 invalid다(반증을 증거 없이 무시하는 Already를
만들지 않기 위해).

## 6. 관측성

Stage 1 (이 PR):

- `masc_goal_list` 응답의 goal 항목에 `verification`(criterion + completion 상태 JSON)을
  합류한다 (goal items의 출력 스키마는 additionalProperties: true라 계약 변화 없음).
- `/api/v1/dashboard/planning`의 goals 항목에도 동일한 `verification`을 합류한다.
- 두 표면 모두 ledger를 **요청당 한 번만** 적재해 메모리에서 join한다 (goal당 재 decode
  금지). Ledger가 decode되지 않으면 pre-verification default로 위장하지 않고 goal 항목에
  명시적 `{"state": "ledger_error", "detail": …}` 마커를 렌더한다.

Stage 2 (게이트와 함께):

- `Goal_store.rollup`에 `verifying_count` / `awaiting_confirmation_count` 필드 추가 —
  keeper 출력 계약(`keeper_tool_descriptor.ml`의 `goal_list_output_schema`, strict)에도 같은
  두 필드를 추가한다.
- goals-tree summary의 `phase_counts`에 `verifying` / `awaiting_confirmation`을 추가하고,
  phase 색상을 배정한다.
- 대시보드 프런트엔드(phase 색상 외의 렌더링)는 그 다음 PR로 미룬다.

## 7. 범위 밖 (후속 PR)

- **Stage 2 게이트 전체** — §3.2/§3.3/§4/§5: `Verifying` phase,
  gate action 4종, `request_complete` 재라우팅, `mark_*_pending` durable 요청,
  `Criterion_unreachable` 차단. 반드시 아래 caller와 함께 머지한다.
- **B7: standalone verifier lane** — `Criterion_pending`/`Proof_pending`을 drain해
  `Task.Anti_rationalization.review`로 판정하고 §3.3/§4.1 action으로 커밋하는 Eio worker.
  `completion_authority_agent.start`의 Goal 판.
- 대시보드 프런트엔드 렌더링(phase badge, verdict 카드).
- `Verifying` 중 `pause` — 현재는 invalid; 필요해지면 별도 RFC.

## 8. 수용 기준 (feature 수준)

Stage 1 (이 PR):

1. metric/target_value 없는(또는 blank인) 생성이 typed error로 거절되고, 기존 row 갱신은
   거절되지 않는다. 생성/갱신 판정은 write lock 안에서 이뤄지므로, decode 불가 goal
   저장소에서는 B1 메시지가 아니라 fail-closed persistence error가 나간다.
2. Ledger verdict 커밋(`record_criterion_verdict`)이 파일 저장소를 왕복하고, refuted
   판정의 reason이 보존된다.
3. Ledger decode 실패(unknown 필드/variant 포함) 시 모든 mutation이 거절되고, 모든 read가
   `Error`로 실패한다 — "미검증"으로 위장하지 않는다.
4. `masc_goal_list`가 goal 항목에 `verification`을 합류하고, ledger가 없는 goal은 명시적
   default(`unchecked`/`idle`), corrupt ledger는 `ledger_error`로 렌더된다.
5. Lifecycle 불변: `request_complete`은 `Executing -> Completed`로 곧장 완료된다.

Stage 2 (후속):

1. criterion `unreachable` 판정 후 `request_complete`이 conflict로 거절된다.
2. `request_complete → record_proof_proven` 으로만 `Completed`에 도달하고,
   ledger가 그 proof verdict 를 보인다.
3. `record_proof_refuted`는 goal을 `Executing`으로 되돌리고 refuted verdict가 ledger에
   남는다.
