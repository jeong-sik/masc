---
rfc: "0118"
title: "KCT NoTerminalCascade S1 — typed Result at select_cascade boundary + Zombie mapping correction"
status: Draft
created: 2026-05-17
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0072", "0113", "0114", "0115", "0116", "0117"]
implementation_prs: [15963]
---

# RFC-0118: KCT NoTerminalCascade S1 — typed Result at select_cascade boundary + Zombie mapping correction

## §1 Problem (caller-context)

`docs/tla-audit/kct-c3-terminal-cascade-contract-gap-2026-05-12.md` 가 `KeeperCoreTriad.tla` (KCT, KSM/KTC 와 별개 spec) §S1 `NoTerminalCascade` 와 OCaml `keeper_cascade_routing.ml:32-34` 의 *dormant contract violation* 을 문서화. Spec-runtime drift family 의 5번째 변형.

### Spec contract

```tla
(* §106 *)
Phases == {"Running", "Failing", "Overflowed", "Compacting",
           "HandingOff", "Draining", "Terminal"}

(* §102 mapping comment *)
\*   "Terminal"    ↔ Offline | Paused | Stopped | Crashed | Restarting | Dead
\*   (Zombie omitted — doc lag or deliberate)

(* §361-363 *)
NoTerminalCascade ==
    phase = "Terminal" => effective_cascade = "none"
```

Spec 는 6 KSM phase 를 `"Terminal"` abstract phase 로 collapse 하고 *그 phase 에서는 cascade 가 "none"* 라고 단언.

### OCaml violation

`lib/keeper/keeper_cascade_routing.ml:32-34`:

```ocaml
| Offline | Stopped | Dead | Zombie | Crashed | Restarting ->
    { effective_cascade = base_cascade;        (* NOT "none" *)
      reason = "non-turn phase (blocked upstream)" }
```

OCaml 가 6 phase 모두에서 `base_cascade` (real cascade name) 반환 — *spec 명세 "none" 위반*. Reason string 가 "blocked upstream" 으로 자백.

추가: `Paused` 는 별도 arm 에서 `Draining | Paused -> base_cascade` (line 29-31), *같은 값* 반환 *다른 reason* ("winding down: complete in-progress work"). `Zombie` 는 spec mapping comment 에 *omit* — 의도 불분명.

### Why dormant (production stays correct today)

Audit doc 가 명시:

> The `base_cascade` return for terminal phases is *unreachable in production*, making this a paper contract gap rather than a runtime bug.

2 production caller 확인:
1. `keeper_unified_turn.ml:411` — turn execution path. KSM FSM 가 *upstream gate*: Dead/Stopped/Zombie keeper 는 turn cycle 진입 안함.
2. `server_dashboard_http_keeper_api.ml:1423` — dashboard render, read-only. S1 assertion downstream 없음.

즉, *현재* unreachable. 그러나:
- 새 caller (예: dashboard 신규 endpoint, MASC API 새 tool) 가 추가될 때마다 *upstream gating* 을 매번 확인해야 함.
- *contract* 가 *gating convention* 에만 의존 — type system 에 박혀있지 않음.

### Why this needs an RFC

1. **Spec-runtime contract family 의 *5번째 변형***:
   - RFC-0114 (KSM): OCaml < spec — active corruption
   - RFC-0115 (KTC): OCaml > spec — vocabulary undefined
   - RFC-0116 (KCR-C1): OCaml ≈ spec — cap side-effect
   - RFC-0117 (KCR-C2): OCaml ⟂ spec — state form distributed
   - **RFC-0118 (KCT-S1)**: OCaml violates spec — *dormant* contract gap

2. **Dormant ≠ safe**: 새 caller 도입 시 silent activation 위험. RFC 가 *type 으로 강제* 하면 caller 가 *반드시* 처리.

3. **Zombie omission 가 adjacent gap**: spec mapping comment 가 *6 phase enumerate* 하지만 OCaml 가 Zombie 포함 7 phase 처리. spec doc lag.

4. **Audit doc 가 3 RFC candidate 명시** (R-C-3.a/b/c). 본 RFC 가 그 셋 통합 + Zombie 보강.

근본 원인: **`select_cascade : phase -> cascade_result` signature 가 terminal-phase 경우 *Result.None* 또는 *Result.Error* 가 아닌 *real value*. 의미적 nullity 가 type 에 표현 안됨.**

## §2 Approach

3 layer:

**Layer A — Typed Result at `select_cascade` (R-C-3.a)**

```ocaml
module Cascade_selection : sig
  type t =
    | Active of { effective_cascade : string; reason : string }
    | None_terminal of { phase : string; reason : string }
    (* terminal phases: spec S1 honored at type *)
end

val select_cascade : phase -> ... -> Cascade_selection.t
```

호출자는 `match` 강제. terminal phase 시 `None_terminal _` 반환, *real cascade name 반환 불가* — type system 가 S1 enforce.

2 caller (`keeper_unified_turn:411`, `server_dashboard:1423`) 가 match arm 명시. `None_terminal` 인데 turn 시도 시 *컴파일러가 잡거나 runtime Result.Error* — silent silent activation 차단.

**Layer B — Spec mapping correction (R-C-3.c partial + Zombie)**

KCT spec §102 mapping comment 갱신:

```tla
\*   "Terminal"    ↔ Offline | Paused | Stopped | Crashed | Restarting | Dead | Zombie
\*                                                                              ^^^^^^
\*                                                                              added 2026-05-17
```

`Zombie` 가 *terminal* 임을 명시. OCaml 의 7 phase 처리 와 spec 7-phase abstract 정합.

**Layer C — Spec contract → call graph invariant (R-C-3.c full)**

기존 `NoTerminalCascade` 는 *function return* 에 관한 invariant. 이를 *call graph* 에 관한 invariant 로 보강:

```tla
\* Original (unchanged): caller must not query terminal phase
NoTerminalCascade ==
    phase = "Terminal" => effective_cascade = "none"

\* New: upstream gating documented as call-graph invariant
TerminalCascadeNeverQueried ==
    \A k \in Keepers, c \in CallContexts :
        keeper_state[k] \in {"Stopped", "Dead", "Zombie", "Paused",
                              "Offline", "Crashed", "Restarting"} =>
        c \notin {"TurnExecution"}
```

`TerminalCascadeNeverQueried` 가 OCaml 의 *실제 upstream gating* 을 spec 가 모델. dashboard caller 는 *read-only* 라서 violation 가능 — 그건 typed `None_terminal` 처리로 OK.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `Cascade_selection.t` typed module + `select_cascade` signature change | dune build PASS, 2 caller 모두 match exhaustive |
| P3 | Caller migration (`keeper_unified_turn`, `server_dashboard`) — `None_terminal` arm 명시 처리 | turn execution path: `None_terminal` 시 turn skip + telemetry. dashboard: terminal phase 표시 |
| P4 | KCT spec §102 Zombie 추가 + `TerminalCascadeNeverQueried` invariant 추가 | TLC PASS clean, KCT-buggy.cfg `BuggyTerminalCascade` mutation 가 violation 검출 |
| P5 | Telemetry counter `keeper_cascade_selection_terminal_total{phase}` — **Counter-as-Validator** | 4주 monitoring count == 0 (production 에서 dormant 유지) |
| P6 | `Paused` arm 통합 — 별도 reason 유지하지만 `None_terminal` 반환 (현 inconsistency 해소) | LoC -5, single arm in pattern match |

P3 가 core wiring. P4 가 spec side. P6 가 cleanup.

## §4 Open questions

1. **Q1**: `Cascade_selection.None_terminal` vs `option` 형 (`Cascade_selection.t option`)? typed sum 가 *phase 정보* 까지 carry — 호출자가 debugging 정보 활용 가능. **잠정**: typed sum (option 보다 정보 풍부).

2. **Q2**: Dashboard caller 가 *Read-only* — Spec `NoTerminalCascade` 만으로 dashboard 가 *None* 표시 가능, *real cascade name* 표시 가능. **잠정**: dashboard 가 typed `None_terminal { phase; reason }` 표시 — operator 가 더 informative.

3. **Q3**: `Zombie` 가 OCaml 에서 *truly terminal* 또는 *transient recovery* ? KSM spec 확인. **잠정**: terminal (현 OCaml arm 가 그렇게 분류). P4 의 spec PR commit message 가 명시적 검증.

4. **Q4**: P6 의 `Paused` arm 통합이 *behavior change* — reason 메시지 변경. operator 일관성 vs 메시지 의미 보존? **잠정**: `None_terminal { reason = "winding down: complete in-progress work" }` — typed sum 가 reason 보존 가능.

## §5 Non-goals

- **S2-S5 의 다른 invariant** (FailingUsesRecovery, BufferOpsUseLocalOnly, CapabilityGateHolds, SideEffectContainment, PhaseDecisionConsistency): 별도 audit 후 별도 RFC. 본 RFC 는 S1 만.
- **KSM phase set 변경** (e.g. Zombie 분리): KSM spec 가 owner. 본 RFC 는 *KCT spec 의 mapping comment* 만 정정.
- **Cascade routing 자체 변경**: 본 RFC 는 *terminal 처리* 만, normal cascade selection 무영향.

## §6 Risk & rollback

- **Risk 1**: P2 signature change 가 *기존 caller test* 의 fixture 깨짐. → P2 의 첫 PR 이 caller migration 도 같은 sprint (2 caller 만 — small surface).
- **Risk 2**: P4 spec PR 의 `TerminalCascadeNeverQueried` 가 *현재 production* 보다 강한 invariant — 향후 dashboard 새 endpoint 가 violation 가능. → invariant 가 `c \notin {"TurnExecution"}` 만 — read context 허용.
- **Risk 3**: P5 telemetry counter 가 *unexpected non-zero* — production 에서 dormant 가정 깨짐. → counter 0 보장 안 됨, *증거 수집* 으로만 사용. non-zero 시 operator alert + RFC re-eval.
- **Risk 4**: Zombie mapping (P4) 가 *기존 spec reader* 의 mental model 깨뜨림. → commit message + spec 본문 changelog 표시.

Rollback: P3 caller migration 만 revert 가능 (P2 typed module 남음, default 변환). P4/P5 spec 또는 telemetry 별도.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `Cascade_selection.t` typed module + signature change.
- [ ] P3: 2 caller (`keeper_unified_turn:411`, `server_dashboard:1423`) typed match.
- [ ] P4: KCT spec §102 Zombie + `TerminalCascadeNeverQueried` invariant.
- [ ] P5: telemetry counter Counter-as-Validator, 4주 monitoring.
- [ ] P6: `Paused` arm 통합 — `None_terminal { reason = "winding down..." }`.

## §8 Number allocation note

Allocated as RFC-0118. Ledger advanced 0109 → 0119 (skip 0109-0117 due to inflight #15902 RFC-0109 + #15924/15927/15933/15937/15939/15944/15947/15957 RFC-0110~0117 (iter-2..9 of this loop)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
