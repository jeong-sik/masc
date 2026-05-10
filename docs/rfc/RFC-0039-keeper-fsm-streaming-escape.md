# RFC-0039: Keeper Turn FSM — Streaming Escape & Cross-Axis Synchronization

> **Status**: Draft
> **Authors**: vincent (with Claude)
> **Created**: 2026-05-07
> **Related RFCs**: RFC-0001 (det/nondet boundary), RFC-0026 (work-conserving keeper admission), RFC-0027 (capability-typed cascade catalog), **RFC-0038 (cascade routing intent preservation)** — RFC-0038 §3.2 NG6/NG7/NG8 가 본 RFC scope 로 분리됨. 두 RFC 가 함께 진행되어야 2026-04-28 executor incident 가 자율 복구 가능.
> **Anchor evidence**: 2026-04-28 executor keeper 11분 streaming hang (Kimi Agent analysis, `~/Downloads/Kimi_Agent_Keeper FSM 고정/`).
> **Anchor spec**: `specs/keeper-turn-fsm/KeeperTurnFSM.tla` (PR #11190, commit `86de071019`).

## 1. Summary

RFC-0038 가 cascade routing layer (Axis 3) 의 silent substitution 을 다룬다. 본 RFC 는 keeper Turn FSM (Axis 1) 의 **streaming-state escape gap** 을 다룬다. 두 RFC 는 직교 layer 를 다루지만, Kimi 분석이 보여준 4월 28일 사고 같은 케이스에서는 양쪽 fix 가 모두 필요하다.

핵심 발견 4개:

- **F1 — TLA spec gap**: `specs/keeper-turn-fsm/KeeperTurnFSM.tla` 의 `streaming` state 에서 빠져나가는 transition 은 `StreamYieldsTool` (line 168-172, → `awaiting_tool`) 과 `StreamComplete` (line 182-186, → `completing`) 둘만 존재. **provider hang 시의 timeout-driven transition 자체가 spec 에 없음**. Liveness `SF_vars(StreamComplete)` (line 300) 는 "infinitely often enabled 면 fire" 를 보장하지만, provider 가 응답을 stop 하면 enabled 자체가 false 가 되어 vacuously satisfied.

- **F2 — Default 불일치**: `MASC_KEEPER_TURN_TIMEOUT_SEC` 의 default 가 `lib/config/env_config_keeper.ml:459` 에서 **600.0**, `lib/config/env_config_snapshot.ml:738` 에서 **3600.0**. 같은 env var 의 코드 default 와 documented default 가 6배 차이. Kimi 분석이 "1시간 hard cap" 으로 인용한 것은 documented default. 실제 코드 default 는 600.

- **F3 — Stale composition 의 blocker masking 은 fiction**: Kimi `executor_fsm_tla_analysis.md` §6 의 가설 ("`last_blocker_class ≠ NULL` 이면 stale 계산 mask") 은 실제 코드에 **존재하지 않음**. `lib/keeper/keeper_stale_watchdog.ml:464` 의 합성은 `let stale = idle_stale || in_turn_stale || failure_loop in` — `last_blocker_class` 미참조. Kimi 본인이 `executor_reanalysis.md` §1 에서 이 추측을 자기정정. 메모리 규칙 `feedback_self_audit_grep_only_false_positive_trap` 의 모범 사례.

- **F4 — `operator_disposition` ↔ `paused` desync**: 두 변수가 다른 layer (OAS scheduler vs keeper local) 에서 비동기 관리. Kimi `executor_reanalysis.md` §4 문제 3 인용. `pause_human` disposition 인데 `paused=false` 인 모순 상태가 수 분간 지속 가능.

## 2. Motivation

### 2.1 사고 사례 — 2026-04-28 executor keeper 11분 streaming hang

타임라인 (Kimi `executor_failure_chain_analysis.md` 인용):

| Time (KST) | Event |
|------------|-------|
| 17:21:02 | `local_with_kimi_coding_with_glm` cascade tool-use gate 에서 모든 provider reject (`codex_keeper_bound_actor_required`) |
| 17:21:39 | FSM `awaiting_provider → streaming` |
| 17:21:40 | OAS turn 35 시작, tool surface 133개 노출. ollama qwen3.6 으로 cross-cascade fallback (RFC-0038 L0 의 path) |
| 17:21:40+ | Provider 가 `end_turn`/`stop_reason` 미발생, tool call 도 없음. **TLA spec 의 어떤 transition guard 도 enabled 안 됨** |
| 17:25:57+ | watchdog grace 0 도달, 그러나 `in_turn_stale=false` 유지 (이유: §2.3 참조) |
| 17:30+ | 11분+ `streaming` 고착 |

**복구 메커니즘 부재**: spec 의 어떤 transition guard 도 trigger 안 되고, watchdog 의 `in_turn_stale` 도 timeout 까지 false 유지 → keeper 자율행동 정지.

### 2.2 RFC-0038 만으로 자율 복구 불가능한 이유

RFC-0038 L0 (cross-cascade fallback default-off) 가 step "ollama qwen3.6 으로 cross-cascade fallback" 자체를 차단해도, **이미 streaming 에 진입한 turn 의 hang** 은 별도 문제. 본 RFC 의 F1 (TLA spec gap) 와 F2 (timeout default 불일치) 가 같이 풀려야 자율 복구.

즉 RFC-0038 + RFC-0039 가 함께 머지/구현돼야 4월 28일 같은 사고가 (a) 발생 빈도 감소 + (b) 발생 시 자율 복구 가능.

### 2.3 Code path — 검증된 file:line citations

**TLA spec — streaming 진입/탈출**:
- `specs/keeper-turn-fsm/KeeperTurnFSM.tla:67-68` — `TurnStateSet` 에 "streaming"
- `specs/keeper-turn-fsm/KeeperTurnFSM.tla:151-156` — `ProviderResponded`: `awaiting_provider → streaming`
- `specs/keeper-turn-fsm/KeeperTurnFSM.tla:168-172` — `StreamYieldsTool`: `streaming → awaiting_tool`
- `specs/keeper-turn-fsm/KeeperTurnFSM.tla:174-178` — `ToolReturned`: `awaiting_tool → streaming`
- `specs/keeper-turn-fsm/KeeperTurnFSM.tla:182-186` — `StreamComplete`: `streaming → completing`
- `specs/keeper-turn-fsm/KeeperTurnFSM.tla:300` — `SF_vars(StreamComplete)` Strong Fairness
- `specs/keeper-turn-fsm/KeeperTurnFSM.tla:353-356` — `EveryTurnEventuallyTerminates` liveness, `Liveness == EveryTurnEventuallyTerminates`

**Watchdog stale composition**:
- `lib/keeper/keeper_stale_watchdog.ml:443-457` — `in_turn_stale` 계산: `elapsed > active_turn_timeout_sec && fiber_age >= grace_period_sec ()`
- `lib/keeper/keeper_stale_watchdog.ml:452-457` — `idle_stale` 계산: `last_turn > 0.0 && now - last_turn > threshold && fiber_age >= grace_period_sec () && not skip_observed`
- `lib/keeper/keeper_stale_watchdog.ml:463` — `failure_loop = noop_count >= noop_threshold ()`
- `lib/keeper/keeper_stale_watchdog.ml:464` — `let stale = idle_stale || in_turn_stale || failure_loop in` ← `last_blocker_class` 미참조 (F3 의 핵심)
- `lib/keeper/keeper_stale_watchdog.ml:372` — `stale_threshold_sec ()` 정의

**Timeout default 불일치 (F2)**:
- `lib/config/env_config_keeper.ml:451-459` — `MASC_KEEPER_TURN_TIMEOUT_SEC`, `get_float ~default:600.0`. 코멘트: "Range: [60, 600]". 실제 default 600 (10분).
- `lib/config/env_config_snapshot.ml:738` — 같은 env var 의 documented default 가 `"3600.0"` (1시간). 6배 차이.

**Disposition / paused 관리 위치 (F4)**:
- `lib/operator/operator_control_snapshot.ml` — disposition snapshot
- `lib/keeper/keeper_unified_turn.ml` — turn-level disposition handling
- `lib/keeper/keeper_execution_receipt.ml` — pause_human reason 기록

### 2.4 Kimi 분석의 자기정정 — RFC-0039 의 file:line 검증으로 강화

Kimi `executor_fsm_tla_analysis.md` §6 (초기 진단) 가 가설 3개로 watchdog 의 `last_blocker_class` masking 을 추측. 이를 Kimi `executor_reanalysis.md` §1 에서 자기정정:

> "Watchdog 관련 'invariant'들도 추측에 불과: 이전 분석에서 `grace_rem < 0 → stale = TRUE` 등의 'invariant 위반'을 주장했으나, 이것들은 실제 코드의 watchdog 로직을 확인하지 않고 내린 **추측**입니다. `last_blocker_class` masking 가정 역시 검증되지 않았습니다."

본 RFC §2.3 의 file:line citation 은 이 자기정정을 grep 으로 ground-truth 확인한 결과. 메모리 `feedback_self_audit_grep_only_false_positive_trap` 의 모범 사례.

## 3. Goals / Non-Goals

### 3.1 Goals

| # | Invariant / Outcome | 대응 Finding |
|---|---------------------|---------------|
| G1 | TLA spec 에 `streaming` state 의 timeout-driven failed transition 도입 (`StreamProviderHang` action 후보). spec liveness 가 enabled-condition 가정 없이 항상 progress 보장. | F1 |
| G2 | `MASC_KEEPER_TURN_TIMEOUT_SEC` default 일관화 (코드 default = documented default). | F2 |
| G3 | Streaming-state provider-level timeout 도입 (`MASC_STREAM_HANG_TIMEOUT_S`, default 60s 후보). 별도 env var 로 keeper-turn timeout 과 분리. | F1 |
| G4 | Watchdog stale composition 명시화 — 코드 코멘트로 `last_blocker_class` 가 stale 계산에 들어가지 않음을 명시 (F3 의 향후 false-positive 진단 방지). | F3 |
| G5 | `operator_disposition` ↔ `paused` 동기화 — 두 변수의 single source of truth 또는 atomic update primitive 도입. | F4 |
| G6 | Cross-axis trace correlation — cascade audit observation (RFC-0038 §4.3) 와 keeper turn FSM transition 이 같은 `turn_id` 로 묶임. RFC-0038 의 `substituted_from_cascade` audit 와 본 RFC 의 turn timeline 이 single trace 로 결합. | F1+F4 |

### 3.2 Non-Goals

| # | 분리 |
|---|------|
| NG1 | Cascade routing 자체 — RFC-0038 |
| NG2 | Permission-aware filtering (keeper credential ↔ model permission match) — 별도 RFC, RFC-0026 통합 |
| NG3 | Automatic retry policy / recovery escalation (timeout 발생 후 keeper 가 어떻게 재시도하는가) — 별도 RFC |
| NG4 | TLA model checking 의 CI 자동화 (TLC integration) — 별도 chore PR scope |
| NG5 | Provider-level streaming protocol 변경 (e.g., ollama 의 keep-alive 표준화) — upstream 영역 |
| NG6 | Keeper FSM 의 다른 state (idle, completing, done) 의 invariant — 본 RFC 는 `streaming` 만 다룸 |

## 4. Design

### 4.1 G1 — TLA spec extension: `StreamProviderHang`

**Code surface**: `specs/keeper-turn-fsm/KeeperTurnFSM.tla` lines 168-186 (existing streaming transitions).

**Spec change** (도입 후보):

```tla
\* Provider stops responding mid-stream — observable timeout signal.
\* Driven by external timer state variable `stream_hang_timeout_elapsed`.
StreamProviderHang ==
    /\ turn_state = "streaming"
    /\ stream_hang_timeout_elapsed = TRUE
    /\ turn_state' = "failed"
    /\ receipt_outcome' = "stream_hang_timeout"
    /\ UNCHANGED << stop_signaled, ... >>

\* Add to Next ==
Next ==
    \/ ...
    \/ StreamProviderHang
```

**Fairness 변경**: `WF_vars(StreamProviderHang)` 추가. SF 가 아닌 WF 인 이유: hang timeout 은 timer 기반이라 항상 결정적, "infinitely often enabled" 가 아닌 "continuously enabled while timer expired".

**Liveness 강화**: `EveryTurnEventuallyTerminates` 가 provider hang 시에도 vacuously 가 아닌 actively terminated 보장.

### 4.2 G2 — Timeout default 일관화

**Code surface**: `lib/config/env_config_keeper.ml:459`, `lib/config/env_config_snapshot.ml:738`.

**Behavior change**: 두 default 를 일치. 권장값: 600.0 (코드 default 유지). snapshot 의 3600.0 documented default 를 600.0 으로 정정. 또는 두 default 의 의미가 다르면 (e.g. snapshot 은 hard cap, env_config 은 soft warn) 두 별도 env var 로 분리.

**Backward compatibility**: 사용자가 env var override 안 했으면 600s default 적용 — Kimi 분석이 가정한 3600s 와 차이. 운영 영향 모니터링 필요.

### 4.3 G3 — Streaming hang detection

**Code surface**: `lib/oas_worker_*` 또는 `lib/keeper/keeper_stale_watchdog.ml`.

**New env var**: `MASC_STREAM_HANG_TIMEOUT_S` (default 60).

**Implementation sketch**:
- Provider stream 시작 시점부터 last activity (token / tool call / status) 까지의 idle interval 측정
- Idle > `MASC_STREAM_HANG_TIMEOUT_S` 면 `StreamProviderHang` action trigger (G1 의 OCaml 매핑)
- Existing `MASC_KEEPER_TURN_TIMEOUT_SEC` (G2 일관화 후 600s) 는 하드 cap 으로 유지

**Trade-off**: 60s 가 너무 짧으면 normal slow generation (e.g. 27B+ local model) 에 false positive. 별도 cascade-level override 필요 (e.g. ollama cascade 는 longer timeout, cloud cascade 는 짧은 timeout).

### 4.4 G4 — Stale composition 명시화

**Code surface**: `lib/keeper/keeper_stale_watchdog.ml:464`.

**Doc change** (코드 코멘트 추가):

```ocaml
(* Stale = idle_stale ∨ in_turn_stale ∨ failure_loop.
   Note: last_blocker_class is intentionally NOT a factor here.
   Past hypotheses (Kimi 2026-04-28 §6) suggested blocker masking;
   that hypothesis was self-corrected in the reanalysis. The blocker
   class affects log enrichment but does not gate stale judgment. *)
let stale = idle_stale || in_turn_stale || failure_loop in
```

순수 docs change. 향후 같은 false-positive 진단 방지.

### 4.5 G5 — Disposition / paused atomic update

**Code surface**: `lib/operator/operator_control_snapshot.ml`, `lib/keeper/keeper_unified_turn.ml`, `lib/keeper/keeper_execution_receipt.ml`.

**Design options**:

| 옵션 | 내용 | trade-off |
|------|------|-----------|
| A | `paused` 를 derived field 로 — `disposition = pause_human` 일 때 derive | 단일 source. 그러나 derive 의 lazy evaluation 이 race 유발 가능 |
| B | Atomic update primitive — disposition 변경 시 paused 함께 update (transaction-like) | 명시적, 검증 가능. 그러나 모든 update site 변경 필요 |
| C | Invariant assertion + warn — 두 값의 desync 발견 시 운영 로그 + Prometheus counter | 점진적, 기존 코드 보존. 그러나 fix 가 아닌 detection only |

권장: **B + C** 조합. B 는 새 코드, C 는 기존 코드의 transition 점검.

### 4.6 G6 — Cross-axis trace correlation

**Code surface**: `lib/oas_worker_cascade.ml:220-258` (RFC-0038 §4.3 의 cascade observation), `specs/keeper-turn-fsm/KeeperTurnFSM.tla` (transition 의 turn_id 변수).

**Design**: cascade observation 의 `turn_id` 와 keeper turn FSM 의 transition log 가 같은 ID 로 묶임. RFC-0038 의 `substituted_from_cascade` audit 와 본 RFC 의 streaming hang detection 이 single trace 로 결합 — 4월 28일 사고 같은 case 의 forensic 이 한 query 로 가능.

**Implementation**: 기존 `cascade_observation.turn_id` 필드 (이미 존재) 를 turn FSM transition log 에 propagate. 신규 schema 변경 없음, 단지 logging side 의 enrichment.

## 5. PR Sequence

| PR | Goal | 변경 surface | RFC 인용 |
|----|------|-------------|---------|
| **PR-A** | G2 + G4 (docs only) | `lib/config/env_config_keeper.ml`, `lib/config/env_config_snapshot.ml`, `lib/keeper/keeper_stale_watchdog.ml` (comment) | RFC-0039 §4.2, §4.4 |
| **PR-B** | G1 (spec) | `specs/keeper-turn-fsm/KeeperTurnFSM.tla` — `StreamProviderHang` action 추가 + Fairness `WF_vars(StreamProviderHang)` + state variable `stream_hang_timeout_elapsed` | RFC-0039 §4.1 |
| **PR-C** | G3 (impl) | OCaml 측 `MASC_STREAM_HANG_TIMEOUT_S` 도입, stream activity tracking, hang detection trigger | RFC-0039 §4.3 + PR-B |
| **PR-D** | G6 (cross-axis trace) | cascade observation turn_id 의 turn FSM log propagation | RFC-0039 §4.6 + RFC-0038 §4.3 |
| **PR-E** | G5 (disposition sync) | atomic update primitive + invariant assertion + Prometheus counter | RFC-0039 §4.5 |

PR-A 는 가장 작고 안전 — 즉시 진행 가능. PR-B 는 spec change, TLC 검증 필요. PR-C 는 PR-B 의존. PR-D 는 RFC-0038 PR-A 의존 (cascade observation schema). PR-E 는 architectural change, 별도 deep review.

## 6. Compatibility / Migration

- 모든 PR backward-compatible 설계.
- G2 default 변경 600 → 600 (코드 default 유지) + documented default 정정. 사용자 운영 변경 없음.
- G3 의 `MASC_STREAM_HANG_TIMEOUT_S` 신규 env var, default 60. unset 시 disabled (legacy 행동).
- G6 의 trace correlation 은 logging-only, schema 변경 없음.
- G5 의 disposition sync 가 invariant violation 시점에 expose 될 수 있음 — Phase 1 default = `warn` mode (counter 만), Phase 2 = `assert` mode.

## 7. Verification

| Goal | Test |
|------|------|
| G1 | TLC 검증: `EveryTurnEventuallyTerminates` 가 `StreamProviderHang` 도입 후에도 hold. provider hang fixture 에서 spec 이 deadlock 없이 terminal 도달. |
| G2 | Unit test: `Env_config_keeper.default_keeper_turn_timeout_sec ()` ≡ `Env_config_snapshot.documented_default "MASC_KEEPER_TURN_TIMEOUT_SEC"` |
| G3 | Integration test: streaming 시작 후 N 초 hang 시 `Stream_hang_timeout` 에러로 transition. fixture: 4월 28일 audit 재현 |
| G4 | Diff check: `keeper_stale_watchdog.ml:464` 의 코멘트가 staleness 합성 명시 |
| G5 | Property test: disposition transition 후 paused 가 same atomic step 에서 동기화. invariant `disposition = pause_human ⇔ paused = true` 항상 hold |
| G6 | E2E test: cascade observation 의 turn_id 가 keeper turn FSM transition log 와 join 가능 |
| Cross-RFC | 4월 28일 audit replay (RFC-0038 §7 verification fixture 와 동일) — RFC-0038 + RFC-0039 둘 다 머지된 상태에서 substitution 차단 + streaming hang 자동 detect |

## 8. Risks

| Risk | Mitigation |
|------|------------|
| G3 의 60s default 가 normal local 27B+ generation 에 false positive | cascade-level override (capability profile 별 다른 timeout). benchmarking 후 default 조정. |
| G2 default 일관화로 사용자 운영 변경 (600s vs 3600s) | release note 명시. snapshot 의 3600 default 를 deprecation warn 으로 한 cycle 운영 후 변경 |
| G1 spec 변경이 기존 TLC proof 깨뜨림 | spec 변경 시 TLC 재실행, model checking 결과 RFC PR 에 첨부 |
| G5 atomic update 가 hot path 성능 영향 | invariant assertion mode 를 production 에서 default off, debug build 에서만 on |
| RFC-0038 author 와 split-brain | 본 RFC 는 RFC-0038 §3.2 NG6-NG8 가 명시 분리한 scope. PR body 에 #13913 (RFC-0038 PR) 직접 cross-link. memory `feedback_split_brain_rfc_0022_pr_2_pr3_overlap` 회피 |

## 9. Memory rule 준수

- `feedback_rfc_section_1_4_caller_context_unverified`: §2.3 의 모든 file:line citation 을 grep 으로 ground-truth 확인. KeeperTurnFSM.tla:67/151/168/174/182/300/353, keeper_stale_watchdog.ml:443-457/464/372, env_config_keeper.ml:459, env_config_snapshot.ml:738.
- `feedback_self_audit_grep_only_false_positive_trap`: F3 의 `last_blocker_class masking` 가설을 코드 grep 으로 fact-check 후 false 로 판정. Kimi reanalysis 의 자기정정과 동일 결의 검증.
- `feedback_split_brain_rfc_0022_pr_2_pr3_overlap`: RFC-0038 와의 scope 분리를 §1 / §3.2 NG1 에 명시. 두 RFC 가 같은 author (vincent + Claude) 라 RFC-0038 PR (#13913) 와 본 RFC PR 의 cross-reference 필수.
- `feedback_audit_must_cross_reference_audit_responses`: Kimi 5개 doc 모두 cross-reference, reanalysis 의 자기정정 evidence 우선.
- `feedback_keeper_hallucinated_audit_cascade`: 본 RFC §2 의 정량 주장 (line 번호, default 값) 모두 직접 grep. 다른 분석의 인용을 재인용하지 않음.

## 10. Open Questions

- Q1: G1 의 `StreamProviderHang` 이 TLA 표준 idiom 인가? aux variable `stream_hang_timeout_elapsed` 가 spec 외부 timer 를 모델링하는데, TLA+ community 의 더 정석적 idiom 이 있는가?
- Q2: G3 의 `MASC_STREAM_HANG_TIMEOUT_S` default 값 — 60s 가 정말 합리적? local 35B+ MoE 의 first token latency 가 60s 이상인 케이스가 있는데. cascade-level override 만으로 충분한가, 아니면 model-id 별 default 가 필요한가?
- Q3: G5 의 disposition sync 가 RFC-0019 (keeper-credential-unification) 또는 별도 cross-axis sync RFC 와 통합돼야 하는가?
- Q4: PR-D (cross-axis trace) 가 RFC-0038 PR-A 의 의존 — 두 RFC 의 PR 머지 순서가 어떻게 강제되는가?
- Q5: 4월 28일 사고 같은 case 의 자율 복구 (operator 개입 없이 retry) 는 본 RFC NG3 (별도 RFC) 인데, 그 RFC 가 없는 상태에서 본 RFC 만 머지되면 사용자 경험 개선이 limited — RFC-0040 candidate 로 미리 framing 해야 하는가?

## 11. References

- RFC-0001: det/nondet boundary harness — silent substitution anti-pattern
- RFC-0019: keeper credential unification
- RFC-0026: work-conserving keeper admission
- RFC-0027: capability-typed cascade catalog
- RFC-0038: cascade routing intent preservation (PR #13913) — 본 RFC 의 sister RFC, 함께 4월 28일 사고 root-cause coverage
- KeeperTurnFSM TLA+ spec: `specs/keeper-turn-fsm/KeeperTurnFSM.tla` (PR #11190, commit `86de071019`) — line 67/151/168/174/182/300/353 검증
- Watchdog implementation: `lib/keeper/keeper_stale_watchdog.ml:443-464` — stale composition truth
- Env config truth: `lib/config/env_config_keeper.ml:451-459` (code default 600.0), `lib/config/env_config_snapshot.ml:738` (documented 3600.0) — F2 inconsistency
- 외부 분석 (Kimi Agent, 2026-04-28): `~/Downloads/Kimi_Agent_Keeper FSM 고정/`
  - `executor_failure_chain_analysis.md` — 5-stage timeline
  - `executor_fsm_tla_analysis.md` — 초기 진단 (가설 다수, 일부 추측)
  - `executor_keeper_diagnosis.md` — synthesized incident report
  - `executor_reanalysis.md` — **자기정정 보고서**, KeeperTurnFSM.tla 직접 검증, 본 RFC 의 TLA spec gap framing 의 main source
- 관련 분석 노트: 2026-05-07 5-track parallel investigation (RFC-0038 작성 시 수행)
