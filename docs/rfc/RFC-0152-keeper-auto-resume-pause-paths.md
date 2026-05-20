# RFC-0152: Keeper Auto-Resume for All Pause Paths

**Status**: Draft
**Owner**: vincent (yousleepwhen)
**Created**: 2026-05-20
**Supersedes**: —
**Superseded-by**: —
**Related**: RFC-0002 (state machine), RFC-0072 (sub-FSM transitions typed), RFC-0093 (keeper-N-emit), RFC-0137 (host fd pressure poller)

## 1. Background

Keeper pause emit은 5 site에서 자동 발동되지만, 그 중 **3 site는 auto-resume 없이 Manual_resume_required** 상태에 영구 정착시킨다. 2026-05-20 fleet-wide silent failure (16 keeper 중 15명이 turn=0)의 영구화 메커니즘이며, 사고 보고서: `/tmp/masc-keeper-fleet-pause-investigation-2026-05-20.html` §3.

## 2. 현재 상태 (Pause emit + auto-resume 매트릭스)

| Source | File | Auto-resume? | 정책 |
|---|---|---|---|
| **S1** operator manual | `keeper_keepalive.ml:116` | N/A (manual) | — |
| **S2** operator removal | `keeper_turn_lifecycle.ml:74` | N/A (manual) | — |
| **S3** overflow + compact_retry_exhausted | `keeper_turn_cascade_budget.ml:546` | **❌** | (없음) |
| **S4** resilience_retry/fallback_unbound | `keeper_turn_cascade_budget.ml:599` + `keeper_unified_turn_failure.ml:65` + `keeper_unified_turn.ml:1445` | **❌** | (없음) |
| **S5** turn livelock block | `keeper_unified_turn_livelock_block.ml:88` | **❌** | (없음) |
| S6 oas_timeout_budget | `keeper_supervisor_pause_policy.handle_oas_timeout_budget_pause` | ✅ | `Auto_resume_with_backoff` |
| S7 stale storm | `keeper_supervisor_pause_policy.handle_stale_storm_pause` | ❌ | `Manual_resume_required` (의도적) |

S3/S4/S5는 *cascade routing failure* 또는 *resilience executor 부재* 같은 transient 상태에서 발동되는데도 영구 pause로 떨어지는 비대칭이다. S6는 같은 cascade 영역인데도 auto-resume — 일관성 부재.

## 3. 사고 evidence

2026-05-19 fleet attrition timeline:
- 12:01Z garnet/imseonghan auto-paused (S3 or S4)
- 12:55Z rondo/ramarama auto-paused
- 13:18Z executor/lifecycle-worker/nick0cave/qa-king/sangsu/umberto 동시 auto-paused (cascade_exhausted)
- 20:11Z analyst auto-paused (required-tool contract violation, S4)
- 21:05Z albini auto-paused (same)

→ S3/S4/S5 pauses 누적 13명이 자정 직전까지 paused. ENFILE storm 회복 후에도 keeper들은 *수동 unpause* 없이는 깨어나지 않음. 2026-05-20에는 verifier 1명만 활성 (turn 1616/1616).

## 4. 결함

### 4.1 의미적 비대칭
S6 (oas_timeout_budget)는 transient cascade health 문제로 분류하여 backoff resume. 그러나 같은 *cascade routing 영역*의 S3/S4/S5는 manual 강제 — 사용자가 의도적으로 분리한 *없음*. 근거: `keeper_supervisor_pause_policy.mli`에 정책 enum (`Auto_resume_with_backoff` / `Manual_resume_required`)이 있지만 S3/S4/S5는 이 enum을 거치지 않고 직접 `dispatch_event_unit Operator_pause` + `set_keeper_paused_state ~paused:true` 호출.

### 4.2 메커니즘 부재
`auto_resume_after_sec`을 set하는 코드 site는 `handle_crash_auto_pause` (`keeper_supervisor_pause_policy.ml:43-48`) 단일. S3/S4/S5는 이 함수를 호출하지 않음. supervisor Phase 3.5 sweep (`keeper_supervisor.ml:1517-1608`)은 `auto_resume_after_sec=Some sec`만 보므로 S3/S4/S5 pauses는 sweep에 *invisible*.

### 4.3 정책 결정 부재
어떤 pause condition이 *transient* vs *terminal-like*인지 SSOT가 없다. S6는 transient 분류, S7는 terminal-like 분류. S3/S4/S5는 분류 없이 manual default.

## 5. 제안

### 5.1 정책 enum SSOT 확장 (RFC-0002 §state machine 영역)

`keeper_supervisor_pause_policy` 에서 `crash_pause_resume_policy` enum을 모든 자동 pause path에 적용:

```ocaml
type crash_pause_resume_policy =
  | Manual_resume_required
  | Auto_resume_with_backoff of { initial_sec : int; max_sec : int }
```

S3/S4/S5/S6/S7 모두 이 enum을 거쳐 pause 발동:
```ocaml
val handle_pause :
  source:[ `Overflow | `Resilience | `Livelock | `OasTimeoutBudget | `StaleStorm ] ->
  agent_name:string ->
  reason:string ->
  unit
```

이 함수가:
1. `set_keeper_paused_state ~paused:true`
2. policy에 따라 `auto_resume_after_sec` 설정 (또는 None)
3. `dispatch_event_unit Operator_pause`
4. metric emit + audit log

### 5.2 source별 정책 매핑 (제안 default)

| Source | 정책 | 근거 |
|---|---|---|
| Overflow + compact_retry_exhausted | Auto_resume_with_backoff (300s → 3600s) | compact retry exhaustion은 transient context size 문제. 다음 turn에서 context가 자연 축소될 수 있음. |
| Resilience retry/fallback unbound | Auto_resume_with_backoff (60s → 600s) | provider unavailability는 보통 transient. backoff로 cascade rotation 시도. |
| Turn livelock | Auto_resume_with_backoff (180s → 1800s) | cascade routing 실패는 cascade 자체가 회복되면 자동 해결 가능. |
| oas_timeout_budget | Auto_resume_with_backoff (현재 정책 유지) | 변경 없음. |
| Stale storm | Manual_resume_required (현재 정책 유지) | stale storm은 운영자 진단 필요 — 의도적 manual. |

### 5.3 supervisor sweep 확장

`keeper_supervisor.ml:1517-1608` Phase 3.5 self-healing circuit breaker가 이미 `auto_resume_after_sec=Some sec` 인 keeper를 깨움. 본 RFC는 *입력 확장*만 — sweep 로직 변경 없음.

### 5.4 cascade health gate (이미 존재)

sweep은 `cascade health probe ≠ Unhealthy`를 검사. 본 RFC는 이 gate를 그대로 사용. cascade 자체가 unhealthy면 resume 안 함 (재발 방지).

## 6. 트레이드오프

**찬성**:
- fleet-wide silent failure 영구화 차단.
- 운영자 부담 감소 (현재 13명 manual unpause 필요).
- 정책 enum SSOT로 5 site 일관성.

**반대 / 우려**:
- backoff 시간 결정이 비결정적 (workload에 따라 다름) — 보수적 default + per-keeper override 옵션.
- transient ↔ terminal 분류가 미세하게 잘못되면 *영원히 resume 시도 → 영원히 실패* livelock 가능. → 단조 증가 backoff + max 시간 제한으로 완화. 또한 retry budget exhaust 시 `Manual_resume_required`로 전환하는 escalation path 필요.
- "transient" 가정이 깨질 때 운영자 가시성 떨어짐. → audit log + dashboard 표면 강화 (별도 PR).

## 7. 비대상

- S1/S2 (operator manual): 변경 없음. 의도적 pause는 manual unpause 유지.
- Stale storm S7: 정책 유지 (의도적 manual).
- albini case의 `completion_contract_violation`: 별개 영역 (cascade contract layer). cascade가 mention-only keeper(albini)에 `require_tool_use`를 강제하는 mismatch — 본 RFC 범위 외, 별도 RFC 필요.

## 8. Phase

| Phase | 산출물 | Gate |
|---|---|---|
| **Phase A** (본 RFC) | 정책 enum SSOT 함수 + 5 site 통합 | dune build clean + 기존 test green |
| **Phase B** (별도 PR) | source별 정책 매핑 적용 | metric `keeper_auto_resume_*` 추가 + audit log |
| **Phase C** (별도 PR) | escalation: N회 auto-resume 실패 시 `Manual_resume_required` 전환 | retry budget exhaust path |
| **Phase D** (별도 PR) | dashboard 표면화 — auto-resume timer remaining, escalation 상태 | dashboard JSON 확장 |

Phase A만 본 RFC. Phase B-D는 follow-up RFC 또는 PR.

## 9. 미정 (Open Questions)

1. Overflow의 default backoff (300s → 3600s)이 합리적인가? compaction이 자동 trigger되는 cycle이 5-15분이므로 5분으로 시작? — 실측 필요.
2. Resilience pause의 `resilience_retry/fallback_unbound`가 단순히 *callback 누락* 의미인지 *모든 retry 소진* 의미인지 의미 확정 필요 — 코드 audit 별도.
3. cascade health probe가 *Unhealthy* 판정 기준이 본 정책에 적합한가? per-source override 필요한가?

## 10. 검증

- albini regression test (PR #16940의 4 named test)는 Operator_resume *수동* 호출 시 transition만 검증. 본 RFC가 도입하는 *자동* resume sweep은 별도 integration test 필요:
  - `test_keeper_supervisor_auto_resume_overflow_path`
  - `test_keeper_supervisor_auto_resume_resilience_path`
  - `test_keeper_supervisor_auto_resume_livelock_path`
  - 각 test에서 pause source 시뮬레이션 → backoff 시간 advance → sweep 실행 → resume 확인.
- property: ∀ source ∈ {Overflow, Resilience, Livelock, OasTimeoutBudget}. pause 후 sweep N cycle 안에 resume *또는* escalation 발생 (livelock 차단).

## 11. 비용 추정

- Phase A: ~200 LoC change. 5 site 통합 + enum SSOT 함수. 1-2 PR.
- Phase B-D: 추가 ~500 LoC. 별도 PR cluster.

## 12. References

- 사고 보고서: `/tmp/masc-keeper-fleet-pause-investigation-2026-05-20.html`
- FSM hotfix: PR #16934 (Paused row matrix gap)
- 즉시 unstuck: 13 JSON disk edit (이미 적용, 2026-05-20)
- FD leak source fix: PR #16942 (storm trigger 차단)
- 관련 spec: `spec/KeeperStateMachine.tla`, `spec/KeeperCompactionLifecycle.tla`

---

본 RFC는 **Phase A draft**. 사용자 승인 후 구현 시작.
