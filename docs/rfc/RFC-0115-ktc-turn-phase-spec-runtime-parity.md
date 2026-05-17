---
rfc: "0115"
title: "KTC turn_phase spec ← runtime parity — backfill spec for Turn_routing / Turn_exhausted"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0002", "0042", "0072", "0113", "0114"]
implementation_prs: []
---

# RFC-0115: KTC turn_phase spec ← runtime parity — backfill spec for Turn_routing / Turn_exhausted

## §1 Problem (caller-context)

`specs/keeper-state-machine/KeeperTurnCycle.tla` (KTC) §110 `TurnPhaseSet` 가 5 phase 만 정의:

```tla
TurnPhaseSet == {"idle", "prompting", "executing", "compacting", "finalizing"}
```

OCaml `lib/keeper/keeper_registry.ml` 의 `turn_phase` variant 는 **7 phase**:

```ocaml
type turn_phase =
  | Turn_idle [@tla.idle]
  | Turn_prompting [@tla.active]
  | Turn_routing [@tla.active]        (* 1 missing in spec *)
  | Turn_executing [@tla.active]
  | Turn_compacting [@tla.active]
  | Turn_finalizing [@tla.active]
  | Turn_exhausted [@tla.terminal]    (* 2 missing in spec *)
```

OCaml 본문 주석 (`keeper_registry.ml:169-172`) 가 drift 를 *명시적으로 자백*:

> "Turn_routing and Turn_exhausted were added to the normal variant on main while this PR was in flight; the GADT tracks them too so the transition matrix below stays compile-time exhaustive."

즉, **OCaml 가 spec 을 앞서감** (PR #14395). RFC-0114 (KSM precondition gap) 와 *반대 방향* drift:

| RFC | OCaml vs Spec | 손실 |
|---|---|---|
| RFC-0114 (KSM) | OCaml < spec | precondition silent 통과 — runtime corruption |
| **RFC-0115 (KTC)** | OCaml > spec | invariant coverage gap — spec 가 2 phase 모르는 동안 *어떤 corruption 도 spec-detectable 아님* |

### 7 invariant silent-omission

`KeeperTurnCycle.tla` §316-352 의 7 invariant 모두 `\A keeper : turn_phase[keeper] = "..." => ...` 패턴. 모두 5-element `TurnPhaseSet` 위에서 quantify. `Turn_routing` / `Turn_exhausted` 진입 시 *spec universe 밖* — invariant 가 *vacuous truth* 로 통과.

7 invariant (audit doc §"How 7 invariants currently behave"):

1. `NoLiveTurnClearsState`
2. `IdleRequiresNotLive`
3. `GateRejectedRequiresFinalizing`
4. `SelectingRequiresToolPolicy`
5. `ExecutingRequiresTrying`
6. `CompactingRequiresTrying`
7. `TerminalCascadeRequiresFinalizing`

`Turn_routing` 에서 cascade_state corruption 발생해도 — `ExecutingRequiresTrying` 가 *`turn_phase = "executing"`* 만 검사 → spec silent.

### `[@tla.idle|active|terminal]` PPX attribute 의 한계

OCaml 가 *spec classification intent* 를 type 자체에 embed:

```ocaml
| Turn_routing [@tla.active]
```

이것은 *forward-looking metadata* — "이 phase 는 spec 의 active 분류에 속해야 한다" 는 claim. 하지만 **spec 본문은 이 claim 을 확인하지 못함**. attribute 가 *문서화 레벨* 에 머묾.

### Why this needs an RFC

1. **RFC-0114 의 자매**: KSM safety + KTC vocabulary, 같은 family. 단일 RFC 로 합치기엔 deliverable 분리 (KSM 은 OCaml fix, KTC 는 spec fix).
2. **PR #14395 가 *spec PR 없이* phase 추가**: 새 phase 도입 시 spec 동시 PR 강제 없음 → drift 누적. 본 RFC 가 그 *동시-PR 정책* 을 명시.
3. **`[@tla.*]` PPX → spec lint 자동화 후보**: attribute 를 *spec generator* 로 활용, OCaml 가 spec 의 `TurnPhaseSet` enumerate 자동 생성 가능. CLAUDE.md §"AI 코드 생성 안티패턴 §4 FSM Sparse Match" 정확히 같은 문제.
4. **audit doc 가 3 invariant candidate 제공**: `RoutingRequiresToolPolicy`, `ExhaustedRequiresTerminalCascade`, +1. RFC 가 spec PR 의 source-of-truth 정리.

근본 원인: **TLA+ spec 가 OCaml 의 closed-sum 보다 *수동* 관리 — 새 variant 추가 시 spec update 자동 trigger 없음.**

## §2 Approach

3 layer:

**Layer A — Spec backfill (PR-1 deliverable, 별도 PR)**

`KeeperTurnCycle.tla` §110 의 `TurnPhaseSet` 확장:

```tla
TurnPhaseSet ==
    {"idle", "prompting", "routing", "executing",
     "compacting", "finalizing", "exhausted"}
```

7 invariant 의 quantification 범위 확장 + audit doc 의 3 candidate invariant 추가 (`RoutingRequiresToolPolicy`, `ExhaustedRequiresTerminalCascade`, `RoutingRequiresLiveTurn`).

KTC.cfg / KTC-buggy.cfg 양쪽 TLC PASS 확인. 새 invariant 가 *실제로* mutation 잡는지 buggy.cfg 가 검증.

**Layer B — `[@tla.*]` PPX 의 *spec generator* 승격**

`scripts/gen-tla-phaset-from-ocaml.ml` (또는 dune `(rule (action ...))` 안의 codegen):

1. `lib/keeper/keeper_registry.ml{,i}` 의 `turn_phase` variant parse
2. 각 constructor 의 `[@tla.idle|active|terminal]` attribute 추출
3. `specs/keeper-state-machine/_generated/KeeperPhaseSets.tla` 생성:

```tla
\* AUTO-GENERATED from lib/keeper/keeper_registry.ml @ <commit-sha>
\* DO NOT EDIT — modify the OCaml variant + [@tla.*] attribute instead.
TurnPhaseSet == {"idle", "prompting", "routing", ...}
TurnIdlePhases == {"idle"}
TurnActivePhases == {"prompting", "routing", "executing", "compacting", "finalizing"}
TurnTerminalPhases == {"exhausted"}
```

4. `KeeperTurnCycle.tla` 가 `EXTENDS KeeperPhaseSets` 로 import. spec 본문이 OCaml type 의 *closed-sum* 를 *single source* 로 추종.

5. CI 가 generated file 과 committed file diff 확인 → drift 시 fail.

**Layer C — 변경 정책 RFC**

새 `turn_phase` variant (또는 `decision_stage`, `cascade_state`) 추가 시 의무:
1. `[@tla.idle|active|terminal]` attribute 부착
2. spec generator regenerate
3. spec invariant 가 새 phase 처리 (vacuous 아닌 명시적 `=> _`)
4. 같은 commit 에 `KeeperPhaseSets.tla` regenerate + KTC.tla invariant 보강

이 정책은 OCaml↔spec drift 의 root-fix.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | spec PR — `KeeperTurnCycle.tla` §110 `TurnPhaseSet` 7 element 로 확장 + 3 새 invariant (`Routing*`, `Exhausted*`) | TLC clean PASS, buggy PASS (mutation detect) |
| P3 | `scripts/gen-tla-phaset-from-ocaml.ml` PPX-based codegen + `KeeperPhaseSets.tla` 신설 | `dune build` 가 generated 파일 정렬 확인 |
| P4 | KTC + KSM + KAQ + KRL + KCR spec 가 `EXTENDS KeeperPhaseSets` | 5 spec 모두 single source dependence |
| P5 | CI workflow `tla-phaseset-drift-check.yml` — generated vs committed diff 비교 | drift PR 자동 fail + auto-suggest regenerate |
| P6 | 변경 정책 문서 (`docs/spec/keeper-phase-evolution-policy.md`) + PR template 가 `[@tla.*]` 부착 강제 | 새 variant PR 가 모두 정책 적용 |

P2 가 spec-only PR (deliverable 최소). P3-P5 가 codegen + 자동화. P6 가 정책.

## §4 Open questions

1. **Q1**: `decision_stage` 와 `cascade_state` 도 같은 정책? 두 type 은 *현재* spec 과 1:1 정렬 — audit doc 가 ✅ aligned 표기. 그래도 codegen 적용 시 future drift 차단 가능. **잠정**: P3 의 codegen 가 3 type 모두 처리.

2. **Q2**: `[@tla.idle|active|terminal]` 외 추가 attribute (e.g. `[@tla.transient]`)? KTC 의 5 phase 분류가 *3 카테고리* 만 — 새 카테고리 필요 시? **잠정**: P2 이후 spec PR 이 새 category 도입. PPX attribute 도 같은 PR 에서 추가.

3. **Q3**: KTC-buggy.cfg 가 *vacuous truth* mutation 을 어떻게 catch? `Turn_routing` 에 일부 invariant 가 vacuous → mutation 가 *허위 안전* 표시 가능. **잠정**: P2 의 3 새 invariant 가 vacuous 아님 보장. mutation testing 가 *실제로* mutation 잡는지 P2 acceptance.

4. **Q4**: PR #14395 의 commit message 가 spec PR 없이 OCaml only — 이걸 *retroactive* 으로 spec PR 추가? **잠정**: P2 가 그 retroactive spec PR. PR body 에 `Spec backfill for PR #14395`.

## §5 Non-goals

- **새 phase 추가** (`Turn_pausing`, `Turn_waking` 등): 본 RFC 는 *기존 OCaml 7 phase* 의 spec parity. 새 phase 는 별도 PR + 본 RFC 의 정책 따름.
- **다른 spec 의 vocabulary drift** (KAQ, KCR, KSM): 별도 audit. 본 RFC 의 codegen 패턴은 family 확장 가능.
- **runtime ↔ disk JSONL schema drift**: 별도 RFC. 본 RFC 는 *in-memory variant ↔ spec* 만.

## §6 Risk & rollback

- **Risk 1**: `KeeperPhaseSets.tla` codegen 가 OCaml parse error 시 build break — 모든 `dune build` 가 spec 의존. → codegen 의 fallback 은 *기존 committed file 유지 + warning*. fail-closed 보다 fail-soft.
- **Risk 2**: P2 의 3 새 invariant 가 *실제* mutation 잡는다는 보장? → buggy.cfg 가 `BuggyRouting` action 으로 invariant 위반 trigger 강제. TLC 가 violation 확인.
- **Risk 3**: P5 CI lint 가 *생성 파일* diff 확인 — generated 파일이 commit 안 됐을 때 PR fail. → developer onboarding 에 codegen 실행 명령 명시 (`dune build` 자동 실행).
- **Risk 4**: 본 RFC 의 *policy* (P6) 가 향후 PR 에 의무 부담 → 단순한 PR 도 spec touch 필요. **잠정**: P6 정책이 *attribute 만 강제*, spec PR 은 새 phase 추가 시만 필요.

Rollback: P3 codegen 비활성 시 spec 정합성 변경 0 (manually committed file 유지). P5 lint 비활성 시 future drift 가능 — 단지 *지금까지 닫힌 상태* 는 무영향.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: spec PR — `TurnPhaseSet` 7 element 확장 + 3 새 invariant. TLC clean PASS + buggy PASS.
- [ ] P3: PPX-based codegen + `KeeperPhaseSets.tla`.
- [ ] P4: 5 keeper spec 가 `EXTENDS KeeperPhaseSets`.
- [ ] P5: CI drift-check workflow.
- [ ] P6: variant-evolution policy doc + PR template 강제.

## §8 Number allocation note

Allocated as RFC-0115. Ledger advanced 0109 → 0116 (skip 0109-0114 due to inflight #15902 RFC-0109 CDAL × GOAL + #15924 RFC-0110 tool-pair atomicity (iter-2) + #15927 RFC-0111 goal mint atomicity (iter-3) + #15933 RFC-0112 typed JSON parse boundary (iter-4) + #15937 RFC-0113 KeeperReactionLiveness runtime (iter-5) + #15939 RFC-0114 KSM precondition (iter-6)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
