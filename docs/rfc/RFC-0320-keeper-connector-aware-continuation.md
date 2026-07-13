---
rfc: "0320"
title: "Keeper connector-aware continuation: carry the originating channel through wake so a resumed keeper replies where the conversation started"
status: Draft
created: 2026-07-08
updated: 2026-07-13
author: vincent (+ Claude Opus 4.8)
supersedes: []
superseded_by: null
related: ["0315", "connector-deferred-reply-via-chat-queue", "connector-ambient-attention-wake"]
implementation_prs: []
---

# RFC-0320: Keeper connector-aware continuation

wake는 발화되지만 keeper가 **어느 대화를 이어가야 하는지**를 모른다. 승인이 풀리고 mention이 와도 keeper가 자기 상태로만 진행하고 발화했던 채널로 돌아오지 않는 근원을, 직교하는 wake 계열 전체 관점에서 닫는다.

## 1. Problem — connector-blind wake

keeper 이벤트 큐의 wake payload는 id + 결과만 싣는다. 어느 커넥터(대시보드 채팅 / Discord / Slack 스레드)에서 대화가 시작됐는지가 제출 시점에 캡처되지 않아 resolve→wake까지 전달할 수가 없다. 그래서 keeper는 깨어나도 "proceed on its own state" — 발화했던 대화로 돌아오지 못한다.

### 1.1 실측 체인 (30초 내 승인했는데도 keeper가 채팅에서 멈춘 사례, `appr_7bf611289364`)

1. keeper가 대시보드 채팅 턴에서 외부 효과를 요청하고 Gate가 HITL로 넘긴다.
2. 승인 큐에 제출 — entry는 `turn_id` / `task_id` / `goal_id`만 캡처. chat connector / thread는 캡처 안 함.
3. keeper 턴이 "승인 대기 중" narration을 하고 종료.
4. operator가 30초 뒤 승인 → `resolve_entry` → composition-root hook이 `Hitl_resolved{approval_id, decision}`를 keeper 큐에 enqueue. wake는 분명히 발화됨.
5. keeper가 `Hitl_resolved`로 깨어남 — 그러나 payload에 커넥터가 없고, intake가 "unblock → proceed on its own state"로 처리. "채팅 스레드로 대화 이어가라"가 아님.
6. → keeper는 대시보드 채팅에 답하지 않고 자율 사이클로 진행. **채팅 관점에선 멈춘 것.**

### 1.2 증거 (adversarial 검증 완료, file:line)

| 사실 | 위치 | 확인 |
|---|---|---|
| wake payload에 커넥터 없음 | `lib/keeper_runtime/keeper_event_queue.ml:39-92` | 11개 wake variant 전수. `hitl_resolution={approval_id;decision}` (:119-126), `connector_attention={event_id}` (:132). 어느 payload도 outbound reply channel을 first-class 필드로 갖지 않음. |
| Hitl_resolved intake = 자기상태 | `keeper_heartbeat_stimulus_intake.ml:104-115` | `event_queue_trigger_of_stimulus`가 `None` 반환. 주석: "proceeds on its own state". |
| Hitl_resolved consume = 빈 관찰 | `keeper_heartbeat_stimulus_intake.ml:259-271` | `[]` 반환, reply-channel 라우팅 없음 ("no observation to inject"). |
| approval entry에 커넥터 없음 | `keeper_approval_queue` (`create_entry`) | `turn_id`/`task_id`/`goal_id`(+sandbox/runtime/model)만. chat connector/thread 필드 부재. |
| resolve→wake hook에 채널 없음 | `server_bootstrap_loops.ml:509-526` | `Hitl_resolved{approval_id,decision}` enqueue. entry 타입에도 hook에도 전달할 channel 필드 자체가 없음. |
| 커넥터 좌표는 존재하나 wake에 안 실림 | `keeper_external_attention.mli:15-29` | `surface_ref`가 Discord{channel_id;thread_id}/Slack{channel_id;thread_ts}/Webhook을 이미 모델링. `Connector_attention`은 `{event_id}` 포인터로 간접 참조만, 좌표는 store에서 재조회. |

### 1.3 유일한 예외 = 살아있는 turn의 in-place 재개

채널에 답이 도달하는 **단 하나의 경로**는 fast-approval resolver가 **원래 suspended turn을 in-place로 재개**할 때다 (원래 turn이 아직 살아있어야 함). 이는 wake path가 아니며, 턴이 종료된 뒤에는 성립하지 않는다. 턴이 끝나면 woken keeper는 자기 상태로 진행하고 발화 채널로 답하지 않는다.

### 1.4 인접 사실 — Dashboard continuation은 이미 push된다 (별개 개선)

adversarial 검증에서 교정된 사실: 대시보드-소스 queued 턴의 결과는 `process_single_turn`이 `Keeper_chat_broadcast.chat_appended`를 호출해 실시간 전달된다 (`server_routes_http_keeper_stream.ml:1288-1289` → `keeper_chat_broadcast.ml:82` → `sse.ml:1011`; 대시보드 `sse-store.ts:637` → `hydrateKeeperChatHistory(force)` `keeper-actions.ts:741-762`). 즉 **이 RFC의 주 대상이 아니다.** 남는 caveat 둘: (a) live token streaming은 유실되고 final message만 재-fetch로 나타남, (b) 해당 keeper 패널이 hydrate/active 상태일 때만 도착, 아니면 client-side drop되어 다음 open 시 보임. 이 둘은 §9 follow-up으로 분리한다. **이 RFC의 코어는 event-queue wake의 outbound continuation이다** (Dashboard chat inbound가 아니라).

### 1.5 기존 RFC와의 경계

- `RFC-connector-deferred-reply-via-chat-queue` — busy-path connector 메시지를 chat queue로 drain (구현: #22798/#23446, stale Draft/[] 메타에도 실질 구현됨). **Discord inbound 한정.**
- `RFC-connector-ambient-attention-wake` — idle keeper가 ambient connector 메시지 인지 (구현: #22818/#22825). **Discord ambient 한정.**
- 두 RFC 모두 **inbound** dispatch/ambient를 다루며, `Hitl_resolved` 및 나머지 event-queue wake의 **outbound continuation connector-blindness는 어느 쪽도 닫지 않는다.** 이 RFC가 그 gap을 닫는다.

## 2. 원칙 — continuation channel을 일급으로

깨우는 것(stimulus)과 어디서 대화가 시작됐는지(continuation channel)를
함께 보존한다. 판단(무엇을 말할지)은 LLM 경계에 남기고,
라우팅 좌표는 Connector가 발행한 opaque `Channel_ref.t`를 그대로
운반한다. 이벤트 큐와 Gate는 Discord, Slack 같은 제품 종류를 알지
않는다. 좌표가 없으면 `Unrouted`로 명시하고 지어내지 않는다.

## 3. 직교 wake 계열 매트릭스

이 gap은 HITL만이 아니다. keeper 이벤트 큐의 wake 계열 전체가 같은 결함을 공유한다 — "누가 특정 채널에서 응답/이어짐을 기다림"인데 채널이 안 실린다.

| Wake stimulus | 계기 | continuation 대상 | 현재 payload | 커넥터 필요 | 현재 동작 |
|---|---|---|---|---|---|
| `Hitl_resolved` | operator 승인/거부 | 발화했던 채팅 스레드 | `{approval_id, decision}` | 필수 | 자기상태 진행 |
| `Connector_attention` | keeper/유저 @mention·메시지 | 부른 채널·상대 | `{event_id}` | 필수 | 응답 루프 안 닫힘 |
| `Bg_completed` | 백그라운드 잡 완료 (RFC-0290) | 요청한 대화/보고처 | `{bg_run_id;…}` | 권장 | 보고처 유실 가능 |
| `Fusion_completed` | fusion 완료 | 요청 맥락 | `{run_id;…}` | 권장 | 동상 |
| `Schedule_due` | 예약 wake | 예약이 지정한 대상 | `{schedule_id;…}` | 선택 | 대상별 상이 |
| `Goal_assigned` | 목표 배정 | 배정자 | `{ga_goal_id;…}` | 선택 | typed wake payload |
| `Board_signal` | 보드 포스트 | 보드 스레드 | `{…author;hearth}` | 선택 | 보드 한정 |
| `Bootstrap` | 내부 부팅 | (대화 아님) | — | 불필요 | 해당 없음 |

→ continuation channel이 필요한 5계열(`Hitl_resolved`, `Connector_attention`, `Bg_completed`/`Fusion_completed`, `Schedule_due`)이 동일한 구조 수정으로 함께 닫힌다. 이것이 이 설계를 단발 패치가 아니라 직교 매트릭스로 다루는 이유다.

## 4. Goal Matrix

각 Goal은 독립 검증 가능한 슬라이스.

| Goal | 현재 | Gap | 목표 (측정 가능) | 접점 (파일) | 검증 | 경계·리스크 |
|---|---|---|---|---|---|---|
| **G1** provenance capture | entry/stimulus가 turn/task/goal만 | originating channel 미캡처 | Connector가 발행한 opaque `Channel_ref.t` 또는 `Unrouted`를 승인 제출·mention 접수 시점에 캡처 | `keeper_approval_queue`(create_entry), `keeper_chat_queue`, `connector_attention` | 제출 시 channel ref 왕복 테스트; 없으면 Unrouted | 제품별 좌표 해석은 Connector 소유 |
| **G2** carry-through | resolve→`Hitl_resolved{id,decision}` | wake payload에 채널 없음 | resolve/완료 hook이 `continuation_channel`을 wake payload에 실어 enqueue | `server_bootstrap_loops`(hitl hook), `keeper_event_queue`(payload 확장) | resolve→enqueue payload에 채널 보존; 직렬화 왕복 | payload 확장은 exhaustive; 미매핑 variant 컴파일 에러 |
| **G3** re-engagement | wake가 owning lane에만 전달됨 | 발화 대화로 복귀 안 함 | wake가 `continuation_channel`을 LLM context에 주입하고 Connector가 응답 대상을 해석 | `keeper_heartbeat_stimulus_intake`, `keeper_unified_prompt` | 승인→해당 Channel에 응답 도착; Unrouted면 자율진행 | continuation은 권한이 아님; 실제 외부 송신은 ordinary Gate |
| **G4** keeper↔keeper | `Connector_attention` wake만 존재 | 부른 채널로 응답 루프 안 닫힘 → "서로 안 도와줌" | A가 B를 mention→B가 A가 부른 채널에서 응답. G1–G3를 mention 경로에 적용 | `connector_attention`, reactive wake 경로 | A@B→B가 같은 채널 응답 관측; 무응답률 지표 하락 | 각 Keeper lane과 event queue는 독립 |
| **G5** observability | resolve만 audit | wake→continuation 전달/누락 불가시 | 모든 wake→continuation을 attributed; Unrouted·dropped-continuation을 대시보드에 표면화(silent 금지) | `audit_approval_event`, `agent_timeline`, dashboard | continuation 전달률·Unrouted 카운트 노출 | telemetry-as-fix 금지 — 카운트는 알람이지 fix 아님 |
| **G6** Gate invariant | — | continuation이 권한으로 오해될 위험 | continuation은 대화 provenance일 뿐이며 새 외부 효과는 exact Always Allowed / configured LLM Auto Judge / non-blocking HITL의 ordinary Gate를 다시 통과 | `keeper_gate` / Connector dispatch | TLA+ must-fail: `ContinuationNeverAuthorizesOperation` | one-shot grant와 channel ref를 분리; 이중 실행 방지 |

## 5. 데이터 모델 델타

커넥터 provenance는 Connector-owned opaque reference로 운반한다. 코어에
제품별 variant를 추가하지 않는다. 미분류는 `Unrouted`로 명시한다.

```ocaml
(* NOW — id만: wake payload에 대화 채널이 없다 *)
and hitl_resolution = { approval_id : string; decision : hitl_resolution_decision }
and connector_attention = { event_id : string }
(* 승인 entry: turn/task/goal만, chat connector 필드 없음 *)

(* TO-BE — continuation_channel 관통 *)
type continuation_channel =
  | Routed of Channel_ref.t
  | Unrouted of { reason : string }

and hitl_resolution =
  { approval_id : string; decision : hitl_resolution_decision; channel : continuation_channel }
and connector_attention =
  { event_id : string; channel : continuation_channel }
(* create_entry … ~turn_id ~task_id ~goal_id ~channel  (제출 시점 캡처, resolve까지 관통) *)
```

## 6. Wake 턴 재개 — before / after

```ocaml
(* NOW — heartbeat intake *)
| Hitl_resolved _ ->
  (* approval left the queue; keeper no longer skips on
     Approval_pending and proceeds ON ITS OWN STATE *)
  []   (* → 발화 대화로 안 돌아옴 *)

(* TO-BE — connector-aware *)
| Hitl_resolved r ->
  (match r.channel with
   | Routed channel -> resume_conversation ~channel ~note:(approval_outcome r)
   | Unrouted { reason } -> log_unrouted reason; proceed_on_own_state ())
```

판단(무엇을 말할지)=LLM. 라우팅(어디로)=결정론적 channel 매치. 둘의 경계가 이 설계의 핵심.

## 7. 불변식 & 검증

- **Explicit unrouted state**: 커넥터를 결정 못 하면 `Unrouted` — 임의 채널로 보내지 않고 자율진행 + 표면화.
- **Exhaustive 매치**: `continuation_channel`·wake variant는 catch-all(`_ ->`) 금지. 새 wake는 라우팅 지점에서 컴파일 에러.
- **No authorization carry-over (G6)**: 재개는 대화 계속일 뿐이다. 재개 턴의 새 외부 효과는 ordinary Gate를 통과한다. TLA+ `ContinuationNeverAuthorizesOperation` must-fail 모델로 one-shot grant와 channel provenance가 합쳐지지 않음을 고정한다.
- **At-most-once continuation**: 한 resolution이 두 번 재개하지 않음(중복 wake 멱등).
- **Observable**: continuation 전달률 + Unrouted 카운트가 대시보드에 노출 — dropped continuation이 silent가 아님.
- **Regression**: `appr_7bf611289364` 시나리오 재현 — 대시보드 채팅 발화→gated→30초 승인→같은 스레드에 응답 도착.

## 8. 경계

- **MASC 전용** — OAS 무관.
- **LLM 경계** = 재개 턴에서 무엇을 말할지. 라우팅(어디로)은 typed channel로 결정론적. 커넥터를 LLM/문자열로 추론하지 않음.
- **No fabrication** — 커넥터 미상은 `Unrouted`. 편의 기본값(예: 항상 Dashboard) 금지.
- **Keeper Gate와 직교** — continuation은 Channel provenance이고 Gate는 외부 효과 결정을 소유한다. 둘을 합친 permission envelope를 만들지 않는다.
- **독립 lane 유지** — continuation은 이미 있던 대화의 재개이지 fleet-wide pause나 global wake source가 아니다.

## 9. 롤아웃 웨이브

- **W1** — G1 provenance capture. `continuation_channel` 타입 + 승인 제출/mention 접수 시 캡처. 저장 형식 변경은 명시적 version으로 수행하며 legacy 값을 추측하지 않는다.
- **W2** — G2 carry-through. resolve/완료 hook이 채널을 wake payload에 실음. 직렬화 왕복 + audit.
- **W3** — G3 re-engagement. intake가 채널로 대화 재개. HITL 먼저(가장 명확한 계기), 그다음 `Connector_attention`(G4).
  - **구현 노트 (2026-07-08 조사)**: `Connector_attention`은 `keeper_heartbeat_stimulus_intake.ml:226-269`에서 `external_attention` item(surface_ref 포함)을 turn observation으로 이미 주입한다. 따라서 Connector 계열의 실제 gap은 wake payload가 아니라 **turn 결과를 channel로 delivery하는 라우팅**이다(현재 heartbeat turn 결과가 원 채널로 가지 않음). `Hitl_resolved`는 `external_attention`이 없어 wake payload의 `channel`이 유일한 provenance이며, 그 provenance 캡처가 W2b다. 즉 W3의 핵심 난도는 delivery 라우팅(keeper turn 아키텍처)이고 W2b는 approval entry provenance 배선이다 — 두 축이 독립적으로 진행 가능.
  - **W3 delivery 청사진 (Explore 조사, SMALL-to-MEDIUM — from-scratch 아님)**:
    - **송신 인프라는 이미 존재·재사용**: `keeper_surface_post`가 Connector adapter로 send + `Keeper_chat_store` persist + `Keeper_chat_broadcast`한다. adapter가 제품별 좌표와 transport를 소유하며 코어 Gate는 이를 알지 않는다.
    - **현재 자동 미전달 이유**: chat 경로(`Keeper_chat_consumer` → `handle_turn`)는 `Keeper_chat_events` stream + adapter로 커넥터에 전달하지만, wake 경로 `Keeper_unified_turn.run_keeper_cycle`(`keeper_unified_turn.mli:199-209`)은 **events/channel/connector 파라미터가 없다**. wake-turn `response_text`는 `keeper_agent_run_finalize_response.ml:418,447,528`에서 checkpoint/session + post-turn memory로만 가고, autonomous prose는 `keeper_unified_turn_success.ml:129-131`에서 `Internal_prose`로 분류된다.
    - **구현 seam**: `keeper_agent_run_finalize_response.finalize`(response_text 생산) 또는 `Keeper_unified_turn_success` 성공 핸들러에 post-turn routing seam을 추가. wake의 `continuation_channel`과 `response_text`를 Connector adapter에 전달하되 실제 외부 송신은 ordinary Gate를 거친다. Unrouted면 기존대로 internal 유지하며 명시적으로 관측한다.
    - **관통 필요**: `continuation_channel`을 wake stimulus → `run_keeper_cycle`(현재 param 없음) → `finalize`까지 전파. `run_keeper_cycle` 시그니처 변경이 호출자 관통을 유발(컴파일러가 강제). 정책: routable channel일 때만 delivery, autonomous internal prose는 그대로.
    - **두 해석**: (a) "keeper가 채널로 답할 수 있다" = `keeper_surface_post`로 이미 가능(SMALL, self-description에 channel + 지시만); (b) "결정론적 auto-deliver(모델이 도구 안 골라도)" = MEDIUM(위 seam). RFC-0320 §2 "라우팅=결정론적" 원칙상 (b)가 정합.
- **W4** — G5 observability + G6 safety invariant + TLA+ + regression 픽스처. `Bg`/`Fusion`/`Schedule`로 채널 확장 및 Dashboard streaming/패널-drop caveat(§1.4)은 opt-in follow-up.

## 10. Open questions

- 재개 타이밍: resolve 즉시 directed wake vs owning lane의 다음 cycle?
- 턴 종료 후 재개: `submit_and_await`가 여전히 블로킹이면 fiber 재개 vs 새 continuation 턴 — 어느 것이 SSOT?
- 커넥터 만료: 대화 스레드가 닫힌 뒤 승인되면? (`Unrouted` + 보드 fallback?)
- 다중 대기: 한 keeper가 여러 채널에서 대기 시 continuation 우선순위.

---

근거: `keeper_approval_queue.ml` · `keeper_event_queue.ml` · `keeper_heartbeat_stimulus_intake.ml` · `server_bootstrap_loops.ml` · `keeper_external_attention.mli` · `server_routes_http_keeper_stream.ml`. 인접 RFC-0290. 설계 원본: `reports/masc-keeper-connector-aware-continuation-goal-matrix.html`. 근본원인 매핑 및 adversarial 검증(H1 교정 / H2 확정)은 7-agent understand workflow(2026-07-08)로 수행.
