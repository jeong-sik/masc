---
rfc: "0119"
title: "Observer spec mapping table drift lint — sentinel-marker validator for OCaml↔TLA+ collapse projections"
status: Draft
created: 2026-05-17
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0072", "0113", "0114", "0115", "0116", "0117", "0118"]
implementation_prs: [15967]
---

# RFC-0119: Observer spec mapping table drift lint — sentinel-marker validator for OCaml↔TLA+ collapse projections

## §1 Problem (caller-context)

`docs/tla-audit/kctxl-h1-phase-mapping-zombie-gap-2026-05-12.md` 가 KCtxL (`KeeperContextLifecycle.tla`) spec 의 mapping table 이 OCaml KSM `phase` type 의 13 constructor 중 12 만 cite — `Zombie` silently missing. **doc-staleness drift, not runtime bug**. 그러나 audit doc 가 명시:

> "iter 27/35/37/39 honest-doc pattern — 4 prior datapoints, R-H-1.a would be the 5th."

즉, **doc-staleness drift 가 5번째 recurrence**. 단발 fix 가 아닌 *class-level* 문제.

### Drift class — observer spec mapping table

KSM 의 13-phase `phase` type 은 *projection* 되어 다양한 observer spec 의 더 작은 phase set 으로 mapping:

| Observer spec | Phase set 크기 | 비고 |
|---|---|---|
| `KeeperStateMachine.tla` (KSM) | 13 (1:1) | source of truth |
| `KeeperContextLifecycle.tla` (KCtxL) | 7 | 6 collapsed + 1 explicit unmodeled list |
| `KeeperCacheAndForward.tla` (KCaf, iter 38) | 3 | 6:3 collapse |
| `KeeperReconcileLiveness.tla` (KRcL) | ? | mapping table 존재 가능 |
| `KeeperGenerationLineage.tla` (KGL) | ? | mapping table 존재 가능 |
| `KeeperCoreTriad.tla` (KCT, RFC-0118 §1) | 7 | 6 KSM phases collapsed to "Terminal" — Zombie missing |

5+ observer spec 가 *deliberate projection* (의도된 collapse). 새 KSM constructor 추가 (e.g. PR #14702 의 Zombie) 시 *모든* projection 의 mapping table 가 stale 됨. 현재 *수동* 추적.

### Why R-B-1.c validator chain 가 catch 못함

`R-B-1.c` (iter 19→43) 는 `[@@deriving tla]` PPX 가 OCaml constructor 와 spec set member 직접 비교. 하지만:

- KCtxL `Phases` set = `{idle, running, compacting, overflow_retry, done, error, dead}` — *projection* (e.g. `"error" ↔ Failing | Crashed` 2:1).
- 직접 비교 시 false-positive (의도된 collapse 를 drift 로 표시).
- 결과: 현재 validator 는 *bare drift* 만 catch, **deliberate-projection-with-stale-mapping** 못 catch.

### Why this needs an RFC

1. **5 instance 누적**: iter 27/35/37/39 + iter 47 KCTXL H-1 = 5 datapoint. CLAUDE.md 의 **"동일 영역 워크어라운드 시그니처 PR이 2회 등장하면, 3회차에는 RFC 작성 강제"** 룰을 *훨씬* 초과.
2. **Drift class 의 *6번째* 변형**: RFC-0114~0118 가 *typed* spec-runtime drift, **본 RFC 는 *doc-only* spec-runtime drift**. type level 에서 catch 불가 (PPX 가 못 봄), validator 가 *주석 + sentinel marker* parsing 필요.
3. **RFC-0118 의 spec mapping correction (P4 Zombie)** 가 단발 fix, 본 RFC 가 그 패턴의 *enforcement*. RFC-0118 = R-C-3.b 적용 instance, RFC-0119 = R-H-1.c family-level validator.
4. **audit doc R-H-1.c 가 "premature without recurrence evidence"** 라고 했지만, *5 instance* 가 그 evidence.

근본 원인: **observer spec mapping table 가 *자유 형식 주석* 으로 작성 — machine-parseable structure 없음.**

## §2 Approach

3 layer:

**Layer A — Sentinel marker convention**

모든 observer spec 의 mapping table 가 *sentinel block* 으로 둘러쌈:

```tla
\* MAPPING-TABLE-BEGIN <observer_name>
\* OCaml phase ↔ TLA+ projection
\* ---------- ↔ ----------
\* Offline    ↔ "idle"
\* Running    ↔ "running"            (* wire-format coincide *)
\* Failing    ↔ "error"              (* 2:1 collapse with Crashed *)
\* Crashed    ↔ "error"              (* 2:1 collapse with Failing *)
\* ...
\* Zombie     ↔ <unmodeled: terminal-terminal, no context events possible>
\* MAPPING-TABLE-END
```

또는 명시적 `MAPPING-UNMODELED-BEGIN ... MAPPING-UNMODELED-END` block:

```tla
\* MAPPING-UNMODELED-BEGIN <observer_name>
\* HandingOff   — covered by KeeperHandoffLifecycle.tla
\* Draining     — covered by KeeperDrainLifecycle.tla
\* Paused       — covered by KeeperPauseLifecycle.tla
\* Restarting   — covered by KeeperRestartLifecycle.tla
\* MAPPING-UNMODELED-END
```

**Layer B — Lint script `scripts/lint-spec-mapping-drift.sh`**

1. `lib/keeper/keeper_state_machine.ml` parse → KSM `phase` constructor list 추출.
2. `specs/keeper-state-machine/*.tla` 안 `MAPPING-TABLE-BEGIN/END` 또는 `MAPPING-UNMODELED-BEGIN/END` 블록 추출.
3. 각 observer spec 별로 *OCaml constructor 집합* vs *mapped + unmodeled 집합* 비교.
4. 누락 시 fail + suggest patch.

```bash
$ bash scripts/lint-spec-mapping-drift.sh
specs/keeper-state-machine/KeeperContextLifecycle.tla:
  ❌ Missing: Zombie
  Hint: add to MAPPING-UNMODELED-BEGIN block:
        \* Zombie       — terminal-terminal, no context events possible
```

**Layer C — CI workflow `.github/workflows/spec-mapping-drift.yml`**

PR 단계 lint 실행. KSM `phase` 변경 + observer spec mapping update 동시 commit 강제.

```yaml
on: [pull_request]
jobs:
  spec-mapping-drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash scripts/lint-spec-mapping-drift.sh
```

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | KCtxL spec — Zombie 추가 (R-H-1.a) — single-spec fix | doc-only PR, KCtxL §83 unmodeled list 에 Zombie line 추가 |
| P3 | Multi-spec sweep (R-H-1.b) — 모든 observer spec 가 KSM 13 phase 모두 cite | KCaf / KRcL / KGL / KCT 등 5+ spec audit + missing fix |
| P4 | Sentinel marker convention adoption — 모든 observer spec mapping table 가 `MAPPING-{TABLE,UNMODELED}-{BEGIN,END}` 블록 | TLA+ 주석 syntax 유효, 기존 reader 영향 0 |
| P5 | `scripts/lint-spec-mapping-drift.sh` — OCaml constructor 와 sentinel block 정합 검증 | 5+ observer spec 모두 lint PASS |
| P6 | `.github/workflows/spec-mapping-drift.yml` CI — drift PR 차단 | PR template 가 KSM phase 변경 시 observer spec 동시 update 강제 |

P2 가 단발 fix (audit doc 추천). P3 가 sibling instance. P4-P6 가 enforce.

## §4 Open questions

1. **Q1**: sentinel marker 가 TLA+ comment syntax 안 — 다른 reader (TLC, TLAPS) 무시? **잠정**: YES, comment 이므로 TLC 영향 0. P2 PR 가 검증.

2. **Q2**: P5 lint 가 *OCaml parse* 필요 — heavy dependency? **잠정**: 단순 `rg` + `awk` 로 constructor name 추출 (lib/keeper/keeper_state_machine.ml 의 `type phase` block grep). PPX-based 보다 fragile 하지만 lightweight.

3. **Q3**: Multi-spec sweep (P3) 가 *5+ observer spec* 모두 확인 — 일부는 mapping table 없을 수 있음 (e.g. only-KSM spec). **잠정**: P3 의 첫 commit 가 inventory (which observer specs have mapping tables) 부터.

4. **Q4**: `MAPPING-UNMODELED-BEGIN` 블록 안의 항목이 *어느 sibling spec 가 cover* 명시 의무? 또는 단순 unmodeled? **잠정**: 의무화 — operator reader 가 *어디서* 그 phase 가 다뤄지는지 알 수 있음.

## §5 Non-goals

- **새 observer spec 작성**: 본 RFC 는 *기존* spec 의 staleness 막기. 새 spec 도 본 convention 따라야.
- **PPX `[@@deriving tla]` 확장**: type-level validator 는 R-B-1.c chain 담당. 본 RFC 는 doc-only level.
- **TLC / TLAPS 자동화**: 본 RFC 는 *doc lint* 만. spec model checking 별도.

## §6 Risk & rollback

- **Risk 1**: sentinel marker convention 이 *기존 spec reader* 의 인지 부담 — 새 syntax 학습. → P4 의 doc commit 가 `docs/spec/MAPPING-TABLE-CONVENTION.md` (또는 `specs/keeper-state-machine/README.md` 안) 가이드 명시.
- **Risk 2**: P5 lint 가 *false positive* — PPX 비활성 build 또는 OCaml parse 실패 시. → fail-soft: lint skip + warn, hard fail 은 명시적 spec PR 만.
- **Risk 3**: P3 multi-spec sweep 가 *기존 spec 본문* 변경 — TLC re-verify 부담. → P3 의 각 PR 가 TLC PASS 확인 (sentinel marker 가 comment 라 결과 동일해야).
- **Risk 4**: CI workflow (P6) 가 *spec PR* + *OCaml PR* 분리 머지 시 *순간 drift* — KSM PR 머지 후 observer PR 머지 직전 사이. → CI lint 가 *PR diff* 만 봄 (main 무관, PR diff 안 정합).

Rollback: P6 CI 비활성. P5 lint 비활성. P4 sentinel block 그대로 남음 (해롭지 않음).

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: KCtxL spec Zombie line 추가 (R-H-1.a).
- [ ] P3: Multi-spec sweep — 5+ observer spec 모두 KSM 13 phase cite.
- [ ] P4: sentinel marker convention adoption — all observer spec.
- [ ] P5: lint script PASS for all observer spec.
- [ ] P6: CI workflow blocks drift PR.

## §8 Number allocation note

Allocated as RFC-0119. Ledger advanced 0109 → 0120 (skip 0109-0118 due to inflight #15902 RFC-0109 + #15924/15927/15933/15937/15939/15944/15947/15957/15963 RFC-0110~0118 (iter-2..10 of this loop)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
