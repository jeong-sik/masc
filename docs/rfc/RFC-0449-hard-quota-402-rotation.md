---
rfc: "0449"
title: "402 는 429 가 아니다 — Hard_quota 는 운영자 행동과 즉시 회전"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: claude
supersedes: []
superseded_by: null
related: ["0433", "0370", "0440", "0216", "0445"]
implementation_prs: []
---

# RFC-0449: 402 는 429 가 아니다 — Hard_quota 는 운영자 행동과 즉시 회전 (hard-quota-402-rotation)

## 0. Summary

402(`PaymentRequired`, provider `HardQuota`)는 시간이 지나도 풀리지 않는다. 지금은 429 와 같은 arm 에 들어가 같은 후보를 다음 사이클에 다시 부른다. 이 RFC 는 402 를 route 에서 따로 세우고, 같은 턴에서 다음 후보로 넘어가며, 그 credential scope 가 "운영자 행동 필요" 상태임을 모든 표면에 보이게 한다. 회전 전에 후보가 이 프롬프트를 담을 수 있는지(바이트)와 이 매체를 받는지를 먼저 본다. 거부된 요청은 비용 원장에 행을 남긴다.

기존 RFC 와의 관계:

- RFC-0433 (Implemented, #33720) 을 **확장**한다. 0433 은 scope 표시(mark → 순서 뒤 → 다음 성공이 지움)를 만들었다. 이 RFC 는 그 표시를 같은 턴 회전의 입력으로 쓰고, 운영자 표면에 올린다. 지우는 규칙은 0433 그대로다.
- RFC-0370 (Draft) 을 **좁힌다**. 0370 §3.3 quota-as-state 는 `Usage_queryable` provider 의 사전 조회를 다룬다. 이 RFC 는 402 라는 사후 관측만 다루고 조회는 만들지 않는다.
- RFC-0440 (Draft) 과 **같은 규칙을 텍스트 걸음에 준다**. 0440 은 이미지 걸음에서 402 후보를 같은 걸음에서 뒤로 보낸다. 0440 §4 "provider 잔고 알림을 만들지 않는다" 와는 겹치는 듯 보이나 충돌이 아니다. 이 RFC 도 잔고를 폴링하지 않는다. 402 로 이미 온 사실을 typed 상태로 보여줄 뿐이다.
- RFC-0216 (Draft) 의 구조를 빌린다. 관측을 기록하고 선택에서 읽는다. cooldown 은 없다.

## 1. 배경 (실측)

창: `<base-path>/.masc/logs` 09-08..09-12 UTC. 출처: `<base-path>/.masc/evidence/audit-adversarial-20260912/merged.md` L2·L3·L4·B5·B8.

- **L4.** `pipeline stage failed stage=route error="[route] Payment required: Insufficient Balance"` WARN 1,145줄 (09-08T00:02Z..09-11T15:00Z). decisions.jsonl `api_error_payment_required` 796행. 09-10/11 `turn terminal (non-exhaustion error) — err=Payment required` 는 pr-updater 21, analyst 16, goo-yang-bong 15, code-reviewer 12, geek-scout 11, kidsnote-slack-context-collector 3. 전부 `deferred_next_runtime=none`. 여섯 keeper 가 3.6일 동안 매 사이클 잔고 없는 provider 를 먼저 불렀다. 같은 모양이 openai `insufficient_quota` 2,748줄, `keeper cycle FAILED … insufficient_quota` 94줄(gpt-5.6-luna 72, gpt-6-astra 22).
- **L2.** verifier 슬롯 루프가 `retryable` 을 OR 로 접고 detail 은 마지막 슬롯만 남긴다. `evaluator unavailable runtime=ollama_cloud… retryable=true; no verdict committed: Payment required` 67회 (09-09T01:31Z..09-10T02:32Z). `scheduled retry … interval_sec=60.0` 73회. task-1479 는 25시간 동안 판정 없이 60초마다 재시도.
- **L3.** `keeper cycle FAILED runtime=claude_code.claude-sonnet-5 … error=Payment required` 62줄 (09-10 56, 09-11 6). 실패한 후보는 deepseek 인데 lane 키를 적는다.
- **B8.** polisher 가 429 뒤 antigravity 128KB 런타임으로 회전했다. 후보의 쓸 수 있는 바이트(131,072 − 9,634 = 121,438)가 keeper 고정 프롬프트(122,102..136,951)보다 작다. typed overflow 56줄 (09-11T15:00:24Z..09-12T03:06:41Z). 09-11 15Z..23Z polisher 실패 50 : 성공 12. fit 검사는 #26551 로 열려 있다.
- **B5.** code-reviewer 가 2.61MB 요청을 20사이클 보냈다 (09-11T04:49:19Z..07:07:17Z). 400 은 `Unknown_invalid_request` 로 후보-로컬이 아니라서 회전 없음. 거부된 요청 ~52M 토큰은 비용 원장에 행이 없다.

기전 요약: route 는 `Hard_quota` 를 이미 구분한다 (`keeper_runtime_failure_route.ml:181`). 소비자 두 곳이 `Rate_limited | Hard_quota` 한 arm 으로 접는다 (`keeper_heartbeat_loop.ml:196`, `keeper_direct_runtime_continuation.ml:67`). `Runtime_attempt_fsm.should_try_next` 는 408·409·429·5xx 만 다음 후보로 보낸다 (`runtime_attempt_fsm.ml:21`). 402 는 거기서 멈춘다.

## 2. 설계

### 2.1 실패 분류 — 네 가지는 서로 다르다

| 관측 | typed 출처 | 시간이 푸는가 | 이번 턴 | 다음 사이클 |
|---|---|---|---|---|
| 일시 제한 | `Retry.RateLimited` (429, `error.code` 없음) | 예 | 같은 후보 유지, retry_after 힌트 | 그대로 |
| 잔고·쿼터 없음 | `Retry.PaymentRequired` (402), `Http_client.Hard_quota` → `Error.HardQuota` (`error.ml:279`), openai `error.code = insufficient_quota` | 아니오 | 다음 후보로 즉시 | scope 는 순서 뒤 + 운영자 표면 |
| 프롬프트 부적합 | `Candidate_fit.Cannot_hold_prompt`, `Cannot_take_modality` | 해당 없음 | dispatch 전에 제외 | 같은 계산 |
| 전송 실패 | `NetworkError`, `Timeout` | 예 | 기존 `Retry_after_observed` | 그대로 |

openai 의 `insufficient_quota` 는 HTTP 본문의 `error.code` 필드다. 어댑터 경계에서 이 필드를 닫힌 합으로 디코드한다. 메시지 prose 는 읽지 않는다. 지금 코드에는 이 필드를 읽는 곳이 없다 (`rg insufficient_quota packages lib` 0건). 400 `Unknown_invalid_request` 는 이 RFC 가 건드리지 않는다. prose 에서 overflow 를 추론하지 않는다 (`retry.ml:410` 테스트가 이미 막는다).

### 2.2 route — `Hard_quota` 를 `Retry_after_observed` 에서 뺀다

```ocaml
(* lib/keeper_runtime/keeper_runtime_failure_route.mli *)
type retry_class =
  | Rate_limited | Capacity_backpressure | Server_error
  | Network_transient | Provider_timeout          (* Hard_quota 삭제 *)

type quota_evidence =
  | Payment_required_402
  | Provider_hard_quota                            (* Llm_provider.Error.HardQuota *)
  | Provider_error_code_insufficient_quota         (* openai error.code, typed decode *)

type t =
  | Retry_after_observed of { retry_class; retry_after : float option }
  | Rotate_now of rotate_class
  | Quota_exhausted of
      { scope : Runtime_quota_window.scope
      ; candidate : Runtime_id.t
      ; evidence : quota_evidence
      ; observed_at : float }
  | Exhausted_visible_alive of terminal_class
```

`Quota_exhausted` 는 새 생성자다. `retry_class.Hard_quota` 를 읽는 자리는 넷이다. `keeper_heartbeat_loop.ml:196` 과 `keeper_direct_runtime_continuation.ml:67` 은 429 와 한 arm 으로 접는 소비자이고, `keeper_runtime_failure_route.ml:316`(wire 문자열)·`:370`(`response_observed`) 은 route 안의 자기 match 다. 넷 다 exhaustive match 라 새 arm 을 강제로 받는다. `_ ->` 는 추가하지 않는다.

`Keeper_error_classify.degraded_retry_reason.Hard_quota` 는 다른 합이다. 그 값은 degraded retry 의 사유 라벨이고 `keeper_error_classify.ml:320`(`core_error_is_hard_quota` 경유)·`:395`(`Error.HardQuota`) 에서 만들어진다. 이 RFC 는 그 라벨을 지우지 않는다. 생산 지점 두 곳이 `Quota_exhausted` route 에서 같은 라벨을 내도록 바꾼다. 읽는 곳(`keeper_error_classify.ml:504`, `keeper_turn_runtime_budget.ml:169`·`:194`)은 그대로다.

### 2.3 scope — credential 단위

scope 는 `Runtime_quota_window.scope_of_credential ~provider_id credential` 이다 (#28202 리뷰, 0433 구현). provider 층도 같은 답을 이미 적어 뒀다. `provider_failure_attribution.ml:ownership_of_provider_failure` (:208) 는 `Http.Hard_quota` 를 `credential_owned` 로 귀속한다. 키 하나가 scope 하나다. provider 행도, 모델도 아니다. 같은 credential 을 쓰는 행은 함께 뒤로 간다. provider 가 모델별 잔고를 따로 둔다면 이 scope 는 너무 넓다. 그 경우 형제 모델이 한 번 뒤로 갔다가 다음 성공에서 바로 앞으로 온다. 이 RFC 는 모델 단위 scope 를 만들지 않는다.

### 2.4 후보 자격 — dispatch 전에 계산한다

```ocaml
type candidate_fit =
  | Fits
  | Cannot_hold_prompt of { undroppable_bytes : int; usable_bytes : int }
  | Cannot_take_modality of { required : Runtime_schema.modality }

type candidate_admission =
  | Admitted of { fit : candidate_fit }
  | Held_quota of { scope; since : float; evidence : quota_evidence }
```

- `usable_bytes = max_prompt_bytes − reserved_bytes`. `reserved_bytes` 는 `keeper_antigravity_runtime.ml:190` 이 이미 계산한다. `undroppable_bytes` 는 system + tool surface 다. 계산은 `Cannot_hold_prompt` 인 후보를 이번 걸음에서 뺀다. 매 시도마다 발견하지 않는다.
- `Held_quota` 는 배제가 아니다. 0433 대로 순서만 뒤로 간다. 걸음이 거기까지 가면 시도한다. 그 시도가 리셋을 알아내는 유일한 방법이다.
- 걸음 순서: `Admitted { fit = Fits }` 를 선언 순서로, 그 뒤에 `Held_quota` 를 `since` 오름차순으로. `Cannot_hold_prompt`·`Cannot_take_modality` 는 걸음 목록에 없다. 대신 후보 id 와 사유가 비용 원장 행(§2.8 `Refused_before_dispatch`)과 `masc_keeper_status.unfit_candidates` 에 남는다.

### 2.5 걸음과 종료

- 후보 i 가 `Quota_exhausted` 를 내면 `note_observed_exhausted ~scope` 를 적고 i+1 로 간다. 같은 턴에서 같은 scope 를 두 번 부르지 않는다.
- 모든 후보가 `Quota_exhausted` 이거나 목록이 비면 `Exhausted_visible_alive (All_candidates_quota_exhausted { scopes : (scope * quota_evidence) list; unfit : (Runtime_id.t * candidate_fit) list })` 다. keeper 는 살아 있고 이번 사이클에 두 번째 호출을 하지 않는다. 다음 사이클은 cadence 대로 온다. 백오프 cap 은 쓰지 않는다.
- 다음 사이클의 걸음은 `Held_quota` scope 마다 후보 하나만 부른다. 같은 scope 를 공유하는 후보는 첫 후보만이다.

### 2.6 운영자 행동 필요 — 무엇이 지우는가

`Operator_action_required` 는 keeper 상태의 파생이다. 저장하지 않는다. `Held_quota` 인 scope 가 lane 에 하나라도 있으면 켜진다. 지우는 증거는 둘뿐이다.

1. 그 scope 로 어떤 호출이든 성공 → `note_succeeded` → 표시 소멸.
2. lane 설정에서 그 scope 의 후보가 사라짐 → 그 keeper 의 항목 소멸.

운영자 ack 만으로는 지워지지 않는다. ack 는 주장이지 증거가 아니다.

### 2.7 verifier 슬롯 — 결과를 접지 않는다

```ocaml
type slot_outcome =
  | Verdict of verdict
  | Invalid_verdict of { detail : string }
  | Unavailable of { route : Keeper_runtime_failure_route.t }

type evaluator_result =
  { slots : (Runtime_id.t * slot_outcome) list      (* 시도한 순서 전부 *)
  ; next : Retry_scheduled of { after : float option }
          | Operator_action_required of { scopes : scope list }
          | Verdict_committed }
```

`next` 는 slots 에서 파생한다. `Unavailable { route = Retry_after_observed _ }` 가 하나라도 있으면 `Retry_scheduled`. 나머지가 전부 `Quota_exhausted` 나 terminal 이면 `Operator_action_required`. `evaluator_error_retryable : bool option` 과 `fallback_reason` 은 삭제한다.

### 2.8 비용 원장 — 거부된 요청도 행이다

```ocaml
type usage =
  | Usage_missing
  | Usage_reported of { input_tokens; output_tokens; cost_usd }
  | Rejected_before_billing of { status : rejection_status; request_bytes : int }
  | Refused_before_dispatch of { fit : candidate_fit; undroppable_bytes : int }
and rejection_status = Payment_required | Invalid_request | Context_overflow
```

`Usage_reported` 를 만드는 지점(`cost_ledger.ml:usage_of_fields`, :166-188)과 같은 행 identity(keeper·turn·candidate·시각)로 거부된 시도와 dispatch 전 제외도 쓴다. `Rejected_before_billing` 은 provider 가 거부한 요청이고 `Refused_before_dispatch` 는 §2.4 계산이 걸음에서 뺀 후보다. 둘 다 USD 는 0 이 아니라 없음이다. 비용 표면은 `rejected` 열과 `refused` 열을 따로 센다. 이 행이 있어야 G1 이 시도마다 후보 id·typed 결과·usage 부재 사유를 원장에서 읽을 수 있다 (Codex `g1_revisions[5]`).

### 2.9 표면

| 표면 | 보이는 것 |
|---|---|
| 로그 | scope 전이(Admitted → Held, Held → cleared)마다 WARN 1줄: `quota scope held scope=<label> evidence=payment_required_402 candidate=<runtime_id> keeper=<name>`. 시도마다 INFO 1줄. `keeper cycle FAILED runtime=` 은 lane 키가 아니라 실패한 후보 id (L3). |
| dashboard | keeper 카드 chip `provider <label>: 402 — 운영자 행동 필요` + since + evidence. verification runs 는 슬롯마다 한 행. cost 화면에 `rejected` 열. |
| TUI | Keepers pane 에 같은 chip. Board 읽기 화면에 아래 post. |
| MCP `masc_keeper_status` | `quota_held : [{scope; since; evidence; candidates}]`, `unfit_candidates : [{runtime_id; reason}]`. `next_actor = Operator` 는 RFC-0445 (next-actor-sum) 의 합을 쓴다. 0445 전에는 그 필드를 내지 않는다. |
| board | scope 가 Held 로 바뀔 때 post 1건. 지우는 조건(§2.6) 두 줄 포함. 시도마다 post 하지 않는다. cleared 되면 같은 post 에 답글 1건. |

### 2.10 사슬

producer: `route_of_api_error` / `route_of_error` (`keeper_runtime_failure_route.ml`) → `Quota_exhausted`.
store: `Runtime_quota_window` (프로세스 메모리, 0433 그대로). 거부 행은 `Cost_ledger` dated jsonl.
consumer: `keeper_turn_driver` 걸음(§2.5), `keeper_heartbeat_loop`·`keeper_direct_runtime_continuation`(sleep 안 함, cadence), `anti_rationalization` 슬롯(§2.7), `keeper_error_classify`.
caller: `masc_keeper_status`, dashboard keeper-state normalizer, TUI Keepers pane, board post producer.

## 3. 판정 기준

- **P1.** 가짜 provider 가 후보 1 에 402 를 주면 같은 턴에서 후보 2 가 dispatch 된다. 로그에 `route=quota_exhausted` 뒤 같은 turn id 로 후보 2 시도 줄이 있다. 실패: `deferred_next_runtime=none` 이 402 뒤에 나온다.
- **P2.** 402 뒤 다음 사이클의 첫 후보는 그 scope 가 아니다. `rg 'quota scope held'` 1줄 뒤 같은 keeper 의 다음 `turn=` 줄의 runtime 이 다른 scope 다.
- **P3.** 모든 후보가 402 면 `Exhausted_visible_alive` 1줄, 두 번째 LLM 호출 0건, keeper phase 는 running 유지. `masc_keeper_status.quota_held` 길이 = scope 수.
- **P4.** 429 경로는 바뀌지 않는다. 기존 `test_keeper_rotation_eligibility_census` baseline 에서 `Rate_limited` 행은 그대로다.
- **P5.** fit 검사: max-prompt-bytes 131,072 런타임과 undroppable 122,102 바이트 keeper 로 걸음을 만들면 그 후보는 `unfit_candidates` 에 `Cannot_hold_prompt` 로 있고 dispatch 0건. 실패: `provider returned typed context overflow after runtime rotation` 이 나온다.
- **P6.** 슬롯 루프: 슬롯 1 이 429, 슬롯 2 가 402 면 `slots` 길이 2, `next = Retry_scheduled`. 둘 다 402 면 `next = Operator_action_required`, 60초 재시도 0건. `retryable=true: Payment required` 문자열은 로그에 없다.
- **P7.** 402 거부 시도마다 costs jsonl 에 `Rejected_before_billing` 행 1개, `request_bytes > 0`. P5 의 제외된 후보마다 `Refused_before_dispatch` 행 1개, `fit = Cannot_hold_prompt`. 두 행 모두 candidate 가 lane 키가 아니라 후보 id 다.
- **P8.** `keeper cycle FAILED runtime=` 의 값이 실패한 후보 id 와 같다. `claude_code.*` 로 적힌 `Payment required` 줄 0건.
- **P9.** 컴파일: `rg 'Keeper_runtime_failure_route.Hard_quota|retry_class = .*Hard_quota' lib` 0건. `keeper_heartbeat_loop.mli:146` 주석의 `[Hard_quota]` 도 사라진다. `Keeper_error_classify.Hard_quota` 는 남는다(§2.2). `_ ->` 추가 0건 (`check-determinism-contract.sh` PASS).

## 4. 단계

1. **PR-1 route.** `retry_class` 에서 `Hard_quota` 삭제, `Quota_exhausted` 추가, 세 소비자 arm 분리. 걸음은 `should_try_next` 가 `Quota_exhausted` 를 true 로. P1·P2·P4·P9.
2. **PR-2 종료와 상태.** `All_candidates_quota_exhausted`, `Operator_action_required` 파생, `masc_keeper_status` 필드, dashboard·TUI chip, board post. P3.
3. **PR-3 fit.** `candidate_fit` 계산과 걸음 제외. #26551 닫음. P5.
4. **PR-4 슬롯.** `anti_rationalization` 슬롯 결과 리스트, dashboard verification-runs 행 분리. P6.
5. **PR-5 원장.** `Rejected_before_billing` 행과 cost 화면 열. P7.
6. **PR-6 귀속.** FAILED 줄의 runtime 을 시도 manifest 에서. P8. (L3, RFC 없이도 가능한 작은 PR. 여기 두는 이유는 P1 검증이 이 줄을 읽기 때문이다.)
7. **PR-7 openai error.code.** 어댑터 경계에서 `error.code` 닫힌 합 디코드. 2,748줄이 `Quota_exhausted` 로 옮겨간다.

## 5. 반론과 답

- **"credential scope 가 어디까지인지 안 정했다."** (Codex missing 0) — §2.3. 키 하나가 scope 하나. `scope_of_credential` 이 이미 그 답이다. 모델 단위는 만들지 않고, 넓은 scope 의 비용은 다음 성공 한 번이다.
- **"후보 자격은 dispatch 전에 봐야 한다. 안 그러면 undersized 후보로 회전해 다른 루프가 된다."** (Codex missing 3, B8) — §2.4. fit 은 선언된 바이트의 뺄셈이다. 계산은 걸음 만들 때 한 번이고 시도마다 발견하지 않는다.
- **"무엇이 Operator_action_required 를 지우는가."** (Codex missing 0) — §2.6. 다음 성공 또는 lane 에서 제거. ack 는 안 지운다.
- **"모든 후보가 고갈되면."** (Codex missing 0) — §2.5. `Exhausted_visible_alive`, 두 번째 호출 없음, 다음 사이클은 scope 당 하나만 probe.
- **"일시 제한·프롬프트 부적합·전송 실패와 섞이면 안 된다."** (Codex missing 1) — §2.1 표. 네 줄이 네 생성자다. 429 는 이 RFC 가 손대지 않는다.
- **"슬롯 결과를 OR 로 접거나 마지막 오류만 보이지 마라."** (Codex missing 1, L2) — §2.7. 슬롯 리스트가 결과다. bool 과 마지막 문자열은 삭제.
- **"prose 에서 overflow 를 추론하지 마라. 4xx 를 다 같게 보지 마라."** (Codex missing 1) — §2.1. 400 은 그대로 `Unknown_invalid_request`. overflow 는 fit 검사로 보내기 전에 막는다. 400 회전 정책은 이 RFC 밖이다 (#27118).
- **"거부된 요청의 원장 행."** (Codex missing 1, B5) — §2.8.
- **"G1 재등록이 이 RFC 를 기다려야 하나."** (Codex `rfc_order[5]`) — 아니다. G1 은 402 실패를 정직하게 적으면 된다. 그 기록은 §2.8 원장 행과 PR-6 귀속 줄이다. 회전 성공(PR-1·2)은 G3 quota failover 수용 전에만 있으면 된다. PR-5·6 은 PR-1 과 독립이라 먼저 머지할 수 있다.
- **"`Keeper_error_classify.Hard_quota` 도 지워야 일관되지 않나."** — 그 값은 route 의 retry_class 가 아니라 degraded retry 사유 라벨이다. 지우면 `keeper_turn_runtime_budget.ml:169`·`:194` 와 `keeper_error_classify.ml:504` 의 exhaustive match 가 이유 없이 바뀐다. 이 RFC 는 라벨의 생산 지점만 `Quota_exhausted` 로 옮긴다 (§2.2).
- **"이건 cap 이나 cooldown 아닌가."** — 아니다. 기간을 지어내지 않는다. 표시는 순서에만 작용하고 다음 성공이 지운다 (0433 §6). 사이클은 cadence 그대로다. `budget_gate` 에 걸리지 않는다.
- **"provider 를 자동으로 빼면 되지 않나."** — 빼면 리셋을 알 방법이 없다. 0433 §3.2 와 같은 답이다. 뺄지 말지는 운영자가 lane 설정으로 정한다.
- **"0440 은 잔고 알림을 안 만든다고 했다."** — 폴링 알림을 안 만든다는 뜻이다. 이 RFC 도 안 만든다. 402 는 이미 온 사실이고 그것을 typed 로 보이게 한다.
- **헌법 forbidden.** `magic_number`: 숫자 임계값 없음. `string_matching`: 분류는 `PaymentRequired`·`HardQuota`·`error.code` 디코드 세 typed 값이다. `budget_gate`: 누적 숫자 게이트 없음. `greedy_shortcut`: `Hard_quota` 를 route 에 남기고 소비자만 고치는 길을 택하지 않고 생성자를 옮긴다. `hardcoded_path`: 없음. `env_var_sprawl`: 새 env 없음. `legacy_residue`: `Hard_quota` retry_class, `evaluator_error_retryable`, `fallback_reason` 은 삭제하고 주석도 남기지 않는다.
- **헌법 invariants.** `closed_sum_over_string`: §2.2·§2.4·§2.7·§2.8 모두 닫힌 합. `strict_parse_no_default`: `error.code` 의 미지 값은 `None` 이고 `Rate_limited` 로 기본 처리한다 (오늘과 같음). `failure_keeps_evidence`: scope 표시에 evidence·observed_at·candidate 가 남고, 거부된 요청은 원장 행으로 남는다.

## 6. 근거

- L4: `merged.md` §L4. WARN 1,145 (09-08T00:02Z..09-11T15:00Z), decisions 796행, 09-10/11 keeper 별 21·16·15·12·11·3, openai insufficient_quota 2,748줄·FAILED 94줄. 코드: `keeper_runtime_failure_route.ml:route_of_api_error` (:181), `keeper_heartbeat_loop.ml:196`, `keeper_direct_runtime_continuation.ml:retry_not_before` (:60-70, `Hard_quota` 는 :67), `keeper_runtime/keeper_terminal_reason.ml:is_config_or_auth_wire` (:59-66), `keeper_error_classify.ml:recoverable_runtime_failure_reason` (:320, :395), `provider_failure_attribution.ml:ownership_of_provider_failure` (:208).
- L2: `merged.md` §L2. 67 WARN (09-09T01:31Z..09-10T02:32Z), 재시도 73회, failover 줄 95. 코드: `anti_rationalization.ml` 슬롯 루프 (:578-616), `retry.ml:is_retryable` `PaymentRequired _ -> false` (:140).
- L3: `merged.md` §L3. 62줄 (09-10 56, 09-11 6). 코드: `keeper_unified_turn.ml:keeper_cycle_failed_runtime_attribution` (:1301-1313).
- B8: `merged.md` §B8. overflow 56줄 (09-11T15:00:24Z..09-12T03:06:41Z), 실패 50 : 성공 12. 코드: `keeper_unified_turn_execution.ml` (:455-477, `#26551` 주석), `keeper_antigravity_runtime.ml:capacity_bounded_model_input_projection` (:180-210).
- B5: `merged.md` §B5. 20사이클 (09-11T04:49:19Z..07:07:17Z), 요청 2,628,071..2,628,082 토큰, cost 행 0. 코드: `runtime_attempt_fsm.ml:should_try_next` (:20-28), `retry.ml` 400 → `Unknown_invalid_request` (:329), `cost_ledger/cost_ledger.ml:usage_of_fields` (:166-188).
- 402 걸음 정지: `runtime_attempt_fsm.ml:21` — 408·409·429·5xx 만 true.
- scope 정의: `runtime_quota_window.mli:scope_of_credential` (:78-87, #28202).
- 종합: `synthesis-adversarial.md` §1 표 8·9행, §2 L2·L3·L4, §4 "4xx/402 후보 회전" 행.
- 결정 메모: `masc-runtime-decisions-2026-09-12` 5번 — cap 과 cooldown 을 두지 않는다.
- Codex 검토: `codex-roadmap.json` `.missing[0]`(scope·자격·재활성 증거·전원 고갈), `.missing[1]`(네 분류 분리·슬롯 결과 보존·prose 추론 금지), `.missing[3]`(dispatch 전 자격); `.rfc_order[5]` (G3 quota failover 수용 전, G1 은 기다리지 않음); `.g1_revisions[5]` (시도·제외마다 후보 id·typed 결과·usage 부재 사유).
