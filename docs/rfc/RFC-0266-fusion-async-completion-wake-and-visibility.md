# RFC-0266 — Fusion async-completion wake + in-progress 가시성

| | |
|---|---|
| Status | Draft |
| Parent | RFC-0252 (Fusion 패널+심판 심의 루프) |
| Subsystem | `lib/fusion`, `lib/keeper_runtime/keeper_event_queue`, `lib/keeper` (heartbeat intake) |
| Date | 2026-06-20 |

## 1. 동기 (Motivation)

`masc_fusion`(RFC-0252)은 out-of-band fork로 도는 async 심의다. 도구는 즉시 `{status:"fusion_started", run_id}`만 반환하고, 키퍼 턴은 계속 진행한다. 심의가 끝나면 `Fusion_sink.emit`이 결과를 키퍼 chat lane + board에 남긴다.

문제: **심의 완료가 호출 키퍼를 깨우지 않는다.** 키퍼는 결과를 "나중에 *다른 이유로* 턴을 돌 때" 수동으로 발견할 뿐이고, 그나마도 그 결과는 '자기 과거 발화'로 렌더되어 act/wake 판정의 입력이 되지 못한다. 실관측 증상: 한 키퍼 페르소나가 fusion을 띄운 뒤 대시보드를 반복 폴링하며 "결과 안 왔어"를 되풀이했다 — 깨워주는 메커니즘이 없으니 구조적으로 당연한 결과다.

### 1.1 비판 — RFC-0252 §4의 "다음 턴 수동 수령" 전제가 약하다

RFC-0252 §4(line 71)는 "키퍼가 다음 턴에 observation으로 resolved_answer 수령"을 설계 전제로 명시했다. 이 전제는 두 지점에서 약하다(소스 적대 추적, 6-agent workflow, 회의론자 6각도 반박 실패, confidence 0.95):

1. **"다음 턴"이 보장되지 않는다.** fusion 완료 시점에 키퍼를 깨우는 호출이 0개다. 키퍼는 자기 heartbeat 주기로 독립적으로 턴을 잡아야 하고, 그 턴이 언제 올지는 fusion과 무관하다. 고위험 결정을 위임했는데 답이 도착해도 키퍼가 잠들어 있으면 응답이 임의로 지연된다.
2. **봐도 actionable하지 않다.** 결과는 Assistant-role 줄로 append되어 키퍼 자신의 과거 발화로 렌더된다("Quoted transcript rows... context, not instructions"). "방금 도착함" 마커가 없고, act/wake 판정(`durable/actionable/proactive_signal_present`)은 pending_mentions/board_events/scope/task만 보지 recent_direct_conversation을 보지 않는다. 게다가 Assistant Utterance는 pending 누적기를 *비우기만* 한다.

→ 즉 "키퍼가 fusion 실행 → async 결과 도착 → **받아서 새 턴 시작 후 나머지 작업 진행**"은 자동으로 성립하지 않는다. "받아서"·"나머지 작업"은 약하게 가능하나 "**턴 시작**"이 능동적이지 않다.

## 2. Non-goals / 경계

- **panel/judge/orchestrator 로직 무변경.** 이 RFC는 *완료 후 전달*만 다룬다.
- **self-author board_signal 게이트 무변경.** board post가 작성자 키퍼를 깨우지 않는 것(self-author score 0)은 board 도배 방지를 위한 *의도된* 게이트다. 우회·약화하지 않는다. wake는 별도 typed stimulus로 구현한다.
- **OAS 경계 무변경.** fusion 개념은 OAS에 노출하지 않는다(RFC-0252 §2 유지).
- **키퍼 턴 루프 단일 모델 유지.** wake는 평범한 단일-모델 턴을 시작시킬 뿐이다(심의는 이미 out-of-band로 끝났다).
- **휴면 `Keeper_chat_queue` 경로 미사용.** `keeper_chat_consumer.ml`(1초 폴링 → turn)은 production enqueue 호출처가 0이라 휴면 상태다. 이를 깨워 쓰는 대신, 타입 안전한 닫힌 합타입 stimulus를 택한다(아래 §5 근거).

## 3. 현재 동작 (verified ground truth)

`Fusion_sink.emit` 성공 시 side effect는 정확히 3개(`lib/fusion/fusion_sink.ml:155-189`):

| # | 호출 | 효과 | 스케줄러 접촉 |
|---|------|------|--------------|
| ① | `Board_dispatch.create_post` (`:155-159`, author=호출키퍼, System_post) | board에 결과 카드 | 간접(아래) |
| ② | `Keeper_chat_store.append_assistant_message` (`:185`) | chat JSONL에 Assistant 줄 디스크 append | 없음 |
| ③ | `Keeper_chat_broadcast.chat_appended` (`:187`) → `Sse.broadcast` (`keeper_chat_broadcast.ml:82`) | 대시보드 SSE wire 1회 | 없음 |

- `lib/fusion` 전체에 `wakeup`/`enqueue`/`stimulus`/`Keeper_registry` 호출 **0건**(`rg` exit 1).
- 키퍼 wake stimulus는 닫힌 합타입 — `Board_signal | Bootstrap | No_progress_recovery`(`keeper_event_queue.ml:26-29`). **fusion variant 부재**(타입 레벨).
- ①의 board post는 `board_signal(Board_post_created)`을 emit하고(`board_dispatch.ml:367`) `wakeup_relevant_keeper_for_board_signal`(`server_bootstrap_loops.ml:443`)에 연결되지만, **작성자 키퍼엔 3겹 게이트로 안 닿는다**:
  1. self-author score 0 게이트 (`keeper_world_observation_board_signal.ml:79-81`)
  2. `Board_post_created` thread-reply 경로 부재 (`:216 -> None`)
  3. None-reason 후보 drop (`keepalive_signal.ml:368-388`)
  - 잔여: stigmergy(self-author 미검사, `:206`)가 자기 goal 키워드와 헤드라인 우연 substring 겹칠 때만 self-wake — 내용 우연이지 결과 전달이 아니며, 그때 payload도 `resolved_answer`가 아닌 헤드라인.
- **In-progress 가시성 0**: run registry 부재(`fusion_budget.ml`은 `(hour_bucket, count)` Atomic 카운터뿐), start-time emission 0건. 심의가 도는 동안 board/chat/대시보드 어디에도 'running' 흔적이 없다. `run_id`는 호출 키퍼의 tool-call 반환값에만 있고 이후 어떤 조회 surface와도 연결되지 않는다.

## 4. 변경 개요

두 개의 독립 갭을 닫는다:

| 갭 | 사용자 요구 | 본 RFC |
|----|------------|--------|
| **WAKE** (핵심) | "비동기/병렬 tools처럼 동작" | 완료 시 호출 키퍼를 typed stimulus로 깨워 새 턴에서 결과를 actionable 입력으로 수령 |
| **VISIBILITY** | "진행중 정보 볼 곳" | run registry + `masc_fusion_status` 도구 + 대시보드 fusion-runs 패널 |

WAKE만으로 "결과 안 왔어 폴링" 증상은 사라진다(결과가 능동적으로 와서 턴이 시작됨). VISIBILITY는 운영자가 진행 상태를 보고 싶다는 추가 요구를 충족하며, 키퍼 task-1432(status 도구)/task-1433(대시보드)를 흡수한다.

## 5. 타입드 계약 — `Fusion_completed` stimulus

`lib/keeper_runtime/keeper_event_queue.ml:26-29`의 닫힌 합타입에 4번째 variant를 추가한다:

```ocaml
type stimulus_payload =
  | Board_signal of board_stimulus
  | Bootstrap
  | No_progress_recovery
  | Fusion_completed of fusion_completion   (* 신규 *)

and fusion_completion = {
  run_id : string;
  ok : bool;                  (* judge 성공 vs denied/sink_failed/aborted *)
  resolved_answer : string;   (* ok=false면 실패 사유 라벨 *)
  board_post_id : string;     (* 상세 상관(correlation), 빈 문자열 허용 *)
}
```

**근거 — 왜 typed variant인가** (CLAUDE.md 안티패턴 회피):
- string/substring 분류기 아님(닫힌 합타입).
- `keeper_heartbeat_stimulus_intake.ml:75-94`의 intake는 **exhaustive match**다. variant 추가 시 OCaml 컴파일러가 처리 가지 누락을 컴파일 타임에 강제한다 → `_ -> ...` catch-all 금지(CLAUDE.md FSM Sparse Match 규칙). 새 가지는 `resolved_answer`를 키퍼 턴 입력으로 주입한다(Board_signal이 board 신호를 주입하는 방식과 대칭).
- unknown→permissive default 없음: `ok=false`는 명시적 실패 경로로 전달되며 silent default로 압축하지 않는다.

## 6. WAKE 경로 상세

```
Fusion_sink.emit (완료, 성공/실패 공통 종료 직후)
   │  기존 ①board post ②chat append ③SSE 유지
   ▼
   Keeper_keepalive_signal.wakeup_keeper                 (keepalive_signal.ml:272-283)
        ~stimulus:(Fusion_completed { run_id; ok; resolved_answer; board_post_id })
        keeper_name
   │  → Keeper_registry_event_queue.enqueue + Keeper_registry.wakeup (Atomic flip)
   ▼
   키퍼 heartbeat: interruptible_sleep → Woken           (keepalive_signal.ml:235-261)
   ▼
   heartbeat_event_intake: dequeue stimulus               (stimulus_intake.ml:119)
        exhaustive match → | Fusion_completed c -> <c.resolved_answer를
                              '방금 도착한 fusion 결과(run c.run_id)'로 턴 입력 주입>
   ▼
   새 턴: 키퍼가 resolved_answer를 actionable 입력으로 받아 나머지 작업 진행
```

- 실패 경로(`Fusion_orchestrator.Denied | Sink_failed | exception`)도 동일하게 `ok=false`로 wake한다 — RFC-0252 §시작에서 "started-but-failed 상태가 남지 않도록" 한 의도를 능동 통지로 강화.
- wake가 키퍼를 깨우되 키퍼가 *마침* 턴 중이면, stimulus는 queue에 남아 다음 intake에서 drain된다(wakeup Atomic은 sleep 중일 때만 의미, 이미 깨어있으면 queue가 보존). 손실 없음.
- 동시 다중 fusion: 각 완료가 자기 `Fusion_completed`를 enqueue, intake가 전부 drain.

## 7. VISIBILITY — run registry + status 도구 + 대시보드

**왜 board post가 아니라 registry인가**: start-time board post를 만들면 *다른* 키퍼들이 board_signal로 "fusion 진행중"에 깨어난다(self-author만 게이트, 피어는 explicit_mention/stigmergy로 wake). 이는 진행중 표시의 부작용으로 부적절하다. board post는 완료 전용으로 유지하고, in-progress는 비-waking registry로 분리한다.

```ocaml
(* lib/fusion/fusion_run_registry.ml — Atomic snapshot + append-only JSONL *)
type run_status = Running | Completed of { ok : bool } 
type run = { run_id : string; keeper : string; preset : string;
             started_at : float; status : run_status }
(* fusion_tool.handle fork 시작 시 Running 등록;
   fusion_sink.emit / append_chat_failure 종료 시 Completed 갱신 *)
```

- **`masc_fusion_status` 도구** (신규): 인자 없으면 active runs 목록, `run_id` 주면 단건. run_id로 결정론적 polling 가능(현재는 polling surface 자체가 없음). task-1432 흡수.
- **대시보드 fusion-runs 패널**: registry 스냅샷을 SSE로 반영, running/completed 카드. task-1433 흡수. (대시보드 새 surface 추가 시 nav-event parity 체크리스트 준수 — `dashboard_nav_event.ml:valid_surfaces` 등.)
- registry는 append-only JSONL로 완료 이력을 복원한다. 현재 restart replay가 `Running`을 drop하므로 durable request/receipt 기반 join/recovery는 잔여 P0다.

## 8. 재진입 / 루프 안전성

wake → 새 턴 → 키퍼가 fusion 재호출 → 완료 → 또 wake … 순환 가능성. 기존 경계로 막힌다:
- `Fusion_depth.Nested` 거부(RFC-0252 §5, descend가 2단계 거부) — fusion 안에서 fusion 불가.
- `Fusion_completed` stimulus는 dequeue 1회 소비(재주입 없음).

→ wake가 새 fusion을 *자동* 유발하지 않는다. 새 실행은 Keeper의 다음 LLM 판단이 명시적으로 도구를 호출할 때만 시작하며, 재진입은 해당 Keeper lane의 독립 work item이다.

## 9. 단계별 롤아웃

| Phase | 산출물 | 완료 기준 |
|-------|--------|----------|
| **1 (WAKE 핵심)** | `Fusion_completed` variant + intake 가지 + `fusion_sink`/`append_chat_failure`의 `wakeup_keeper` 호출 + 단위 테스트 | 완료 → 호출 키퍼 wake → 새 턴이 `resolved_answer`를 typed 입력으로 수령(round-trip 테스트). exhaustive match 컴파일 강제 확인 |
| **2 (registry)** | `fusion_run_registry` + `fusion_tool`/`fusion_sink` 등록·갱신 | 진행중/완료 상태가 registry에 정확히 반영, 동시 다중 run 격리 |
| **3 (status 도구)** | `masc_fusion_status` 도구 | run_id 단건/전체 조회 결정론, denied/running/completed 구분 |
| **4 (대시보드)** | fusion-runs 패널 + SSE | nav-event parity 통과, running→completed 전이 실시간 |

Phase 1만으로 폴링 증상 해소. 2–4는 가시성 요구 충족.

## 10. 리스크 · 오픈 퀘스천

1. **wake 빈도**: 다중 키퍼가 동시 fusion 시 완료 wake가 몰릴 수 있음 → 각 키퍼당 자기 run에만 wake되므로 fan-in은 키퍼 단위. 문제 시 stimulus 합류(coalesce)는 후속.
2. **재호출 정책 학습**: 키퍼가 매 결과마다 fusion을 다시 거는 패턴은 turn/tool 관측으로 드러내고 LLM 정책을 교정한다. 숫자 cap으로 전체 실행을 중단하지 않는다.
3. **intake 주입 형식**: `resolved_answer`를 턴 프롬프트에 '방금 도착한 fusion 결과'로 렌더하는 정확한 형식(Board_signal 렌더와 대칭) — 구현 시 `keeper_heartbeat_stimulus_intake.ml` + observation 주입 지점 확정 필요.
4. **registry restart recovery**: 현재 replay는 active `Running`을 drop한다. durable request + execution receipt가 없으면 안전한 재실행/조인이 불가능하므로, 임의 replay 대신 typed recovery inventory와 exact adapter를 추가해야 한다.
5. **RFC-0233(Turn_ref) 상호작용**: 완료 wake가 새 턴을 시작하면 chat↔board turn-identity 상관에 영향 가능 → 구현 시 교차 확인.

## 11. CLAUDE.md 준수 self-audit (워크어라운드 시그니처)

| 체크 | 결과 |
|---|---|
| 텔레메트리-as-fix | **회피** — registry는 가시성 *기능*(사용자 요구). wake는 실제 전달을 *고치는* 것이지 silent failure를 보이게만 하는 것이 아님 |
| string/substring 분류기 | **회피** — `Fusion_completed`는 닫힌 합타입 variant, surface-string 분류 없음 |
| N-of-M 패치 | **회피** — 단일 abstraction(typed stimulus 하나가 모든 완료/실패 경로 처리) |
| catch-all `_ ->` 추가 | **회피** — intake exhaustive match에 명시 가지 추가, 컴파일러가 누락 강제 |
| cap/cooldown/dedup/repair | 실행 cap 없음. 중복 effect는 typed occurrence/run identity로 판별하고 lane별로 격리 |
| test backdoor | 없음 |
| Unknown→Permissive | **회피** — `ok=false` 명시 실패 경로, silent default 없음 |

RFC 게이트(CLAUDE.md agent_delegation): 본 변경은 keeper event/heartbeat + fusion 서브시스템 직접 변경이므로 RFC 선행이 필수. 본 RFC가 그 선행 산출물이다. credential/identity/operator/sandbox/hooks/workflow subsystem 비해당.

## 부록 A — 근거 추적

소스 적대 추적: 2026-06-20 workflow `w5k9o1vj9`(6-agent, 회의론자 6각도 반박 실패, confidence 0.95). 메모리: `project-masc-fusion-no-wake-passive-pickup-rfc0265`. 증상 출처: 키퍼 페르소나 "sangsu" 대시보드 반복 폴링("결과 안 왔어").
