---
rfc: "0120"
title: "Cross-spec set-name divergence — 3-class classification framework (STALE / DELIBERATE / NAME COLLISION)"
status: Implemented
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0072", "0113", "0114", "0115", "0116", "0117", "0118", "0119"]
implementation_prs: []
---

# RFC-0120: Cross-spec set-name divergence — 3-class classification framework (STALE / DELIBERATE / NAME COLLISION)

## §1 Problem (caller-context)

`docs/tla-audit/cross-spec-3-divergences-classify-2026-05-12.md` 가 iter 40 scanner (`scripts/audit-tla-annotation-drift.sh --check-cross-spec`) 결과 7 divergence instance 를 3 set name 에서 6 spec 에 걸쳐 발견. 본 RFC 는 이 audit 의 classification framework 를 *RFC-level commit*.

### Scanner output (실측, iter 41)

```
── TurnPhaseSet (5 specs, 3 unique signatures) ──
  KRuntimeL:        5 (compacting executing finalizing idle prompting)
  KMC:              4 (compacting executing idle prompting)
  KCompositeL:      7 (... + exhausted + routing)              ← canonical
  KDP:              5 (compacting executing finalizing idle prompting)
  KTC:              7 (... + exhausted + routing)              ← canonical

── DecisionSet (6 specs, 3 unique signatures) ──
  KRuntimeL:        4 (gate_rejected guard_ok tool_policy_selected undecided)  ← canonical
  KMC:              3 (without gate_rejected)
  KCompositeL:      4 ← canonical
  KDP:              4 ← canonical
  KEQ:              3 (emit skip tick)                          ← NAME COLLISION
  KTC:              4 ← canonical

── RuntimeSet (5 specs, 2 unique signatures) ──
  KRuntimeL:        5 (done exhausted idle selecting trying)   ← canonical
  KMC:              2 (idle trying)
  KCompositeL:      5 ← canonical
  KDP:              5 ← canonical
  KTC:              5 ← canonical
```

총 **6 divergence**: 2 STALE + 3 DELIBERATE + 1 NAME COLLISION.

### Why this needs an RFC

1. **Iter 42 implementation plan 가 "bundle all 7 fixes in a single PR" 제안** — 자체 audit 가 RFC 수준 합의 필요 인정 (3 class 가 *다른 fix shape* 요구).
2. **RFC-0115 (KTC turn_phase parity, iter-7) 가 *1 instance only* 다룸** — KTC 의 7-phase. 본 RFC 는 *7 instance 전부* + 3 class framework 일반화.
3. **RFC-0119 (mapping table drift lint, iter-11) 가 *doc-level* drift**, 본 RFC 는 *spec set-name level* drift — 자매 RFC.
4. **3 class 가 명확히 다른 fix shape**:
   - STALE → sync (직접 widen)
   - DELIBERATE → rename to distinct identifier (e.g. `KMC_TurnPhaseSet`)
   - NAME COLLISION → rename to vocabulary-aligned identifier
   - 분류 없이는 *4 STALE 만 fix* 하면 future drift 가 NAME COLLISION 사이트에서 재발.

근본 원인: **TLA+ 가 *spec-local* identifier 만 — cross-spec identifier *의미 합의* 없음.** 같은 이름 (`DecisionSet`) 가 서로 다른 spec 에서 *다른 vocabulary* 를 carry 할 수 있음.

## §2 Approach

3 layer:

**Layer A — 3-class classification 공식화**

```
| Class | 정의 | Fix |
|-------|------|-----|
| STALE | observer spec 가 canonical spec 의 stale snapshot - 같은 vocabulary 의도 | 1-line widen (e.g. add missing members) |
| DELIBERATE | observer spec 가 *의도된 부분 projection* — 같은 vocabulary 의 부분 집합 | rename to `<Spec>_<SetName>` (e.g. `KMC_TurnPhaseSet`) + header §"Out-of-scope" 명시 |
| NAME COLLISION | 다른 vocabulary 가 같은 이름 점유 — 의도 collision 아님 | rename to a vocabulary-aligned domain name |
```

**Layer B — Audit 7 instance 적용**

| Instance | Class | Action |
|---|---|---|
| KRuntimeL.TurnPhaseSet (5) | STALE | widen to 7 |
| KDP.TurnPhaseSet (5) | STALE | widen to 7 |
| KMC.TurnPhaseSet (4) | DELIBERATE | rename `KMC_TurnPhaseSet` |
| KMC.DecisionSet (3) | DELIBERATE | rename `KMC_DecisionSet` |
| KMC.RuntimeSet (2) | DELIBERATE | rename `KMC_RuntimeSet` |
| KEQ.DecisionSet (historical emit/skip/tick layer) | REMOVED | adaptive heartbeat decision layer hard-cut on 2026-07-13 |
| (다른 5 spec 의 `DecisionSet` 4) | canonical | unchanged |

**Layer C — Scanner CI 활성화**

`scripts/audit-tla-annotation-drift.sh --check-cross-spec` 가 iter 40 #14828 에서 *audit-only* 로 추가됨. iter 42 *implementation plan* 가 ready 인 후 *CI workflow* 로 승격. 새 spec 추가 시 cross-spec divergence 자동 검출 → STALE / DELIBERATE / NAME COLLISION classifier 강제.

```yaml
on: [pull_request]
jobs:
  cross-spec-divergence:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash scripts/audit-tla-annotation-drift.sh --check-cross-spec
```

`--strict` 모드: 새 divergence instance 발견 시 fail + classification 추가 요청.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | spec PR: 2 STALE sync (KRuntimeL.TurnPhaseSet + KDP.TurnPhaseSet widen to 7) | TLC re-verify PASS clean for both |
| P3 | spec PR: 3 KMC DELIBERATE rename (TurnPhase/Decision/Runtime) — `KMC_*` prefix + header note | TLC PASS, sibling spec reference 정정 |
| P4 | ~~KEQ NAME COLLISION rename~~ | SUPERSEDED: the whole adaptive heartbeat decision layer was removed on 2026-07-13 |
| P5 | `scripts/audit-tla-annotation-drift.sh --check-cross-spec --strict` activation. CI workflow `.github/workflows/cross-spec-divergence.yml` | 7 fix 후 0 divergence — new PR 가 0 유지 |
| P6 | `docs/spec/cross-spec-divergence-policy.md` — 3-class framework + 새 spec 추가 정책 | 새 observer spec PR template 가 classification 강제 |

P2/P3/P4 가 spec-only fix. P5 가 enforce. P6 가 policy 문서.

## §4 Open questions

1. **Q1**: KMC 의 DELIBERATE rename 시 KMC 내부 reference (e.g. `\A p \in TurnPhaseSet`) 도 함께 변경 — 단순 sed 가능? **잠정**: YES — spec-local identifier 이므로 sed safe.

2. **Q2**: KEQ NAME COLLISION rename 후 *downstream tooling* (e.g. dashboard, validator) 의 regex 정정? **잠정**: P4 의 첫 commit 가 inventory + 정정. KEQ.DecisionSet 가 다른 곳 referenced 가능성 낮지만 grep.

3. **Q3**: P5 의 `--strict` 가 *기존 audit-only* 와 backwards-compat? **잠정**: audit 시 별도 flag — default 가 audit-only 유지. CI 만 `--strict`.

4. **Q4**: RFC-0115 (KTC turn_phase parity) 와 본 RFC 의 *관계*? RFC-0115 가 PPX codegen SSOT, 본 RFC 가 3-class classification framework. 둘 다 같은 family. **잠정**: RFC-0115 의 P3-P5 가 본 RFC 의 P5 codegen 와 *동일* — RFC-0115 P5 가 본 RFC P5 의 *implementation*. RFC-0115 가 *forward-looking*, 본 RFC 가 *immediate*.

## §5 Non-goals

- **새 cross-spec set name 추가**: 본 RFC 는 *기존* 3 set name (`TurnPhaseSet` / `DecisionSet` / `RuntimeSet`) 의 divergence. 새 cross-spec set name 도 같은 framework 적용.
- **spec body 의 invariant 변경**: 본 RFC 는 *set name level* 만. invariant 보강 별도.
- **OCaml side 변경**: 본 RFC 는 *spec only*. OCaml ↔ spec drift 는 RFC-0114~0118 family 담당.

## §6 Risk & rollback

- **Risk 1**: STALE widen (P2) 가 *기존 invariant* 의 quantification scope 변경 — 일부 invariant 가 vacuous true 였다가 vacuous false 또는 true 로 바뀌. TLC re-verify 필수. → P2 의 PR body 가 *각 invariant* 별로 quantification scope 변경 영향 명시.
- **Risk 2**: DELIBERATE rename (P3) 가 *기존 spec reader* 의 mental model 깨뜨림. 익숙한 이름 → 새 이름. → P3 의 commit message + header §"Renaming history" 명시.
- **Risk 3**: NAME COLLISION rename (P4) 가 *downstream tooling* 깨뜨림 (e.g. dashboard regex). → P4 의 첫 commit 가 inventory + 정정 (대부분 PR 안에서).
- **Risk 4**: P5 의 `--strict` lint 가 *false positive* — 신규 spec 의 의도된 divergence 표시. → P6 의 PR template 가 classification 명시, lint 가 *기존 ledger* 와 비교 (e.g. `docs/spec/cross-spec-divergence-ledger.md`).

Rollback: P5 lint 비활성. P2/P3/P4 spec 변경 revert 가능 (TLC 재검증).

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: 2 STALE spec sync (KRuntimeL + KDP) — TLC PASS.
- [ ] P3: 3 KMC DELIBERATE rename — TLC PASS.
- [ ] P4: 1 KEQ NAME COLLISION rename — TLC PASS + downstream tooling 정정.
- [ ] P5: `--strict` CI workflow active — 0 divergence.
- [ ] P6: `docs/spec/cross-spec-divergence-policy.md` + PR template.

## §8 Number allocation note

Allocated as RFC-0120. Ledger advanced 0109 → 0121 (skip 0109-0119 due to inflight #15902 RFC-0109 + #15924/15927/15933/15937/15939/15944/15947/15957/15963/15967 RFC-0110~0119 (iter-2..11 of this loop)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
