---
rfc: "0116"
title: "KCR fallback cap mechanism parity — explicit counter at spec ↔ visited-list at runtime"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0072", "0113", "0114", "0115"]
implementation_prs: []
---

# RFC-0116: KCR fallback cap mechanism parity — explicit counter at spec ↔ visited-list at runtime

## §1 Problem (caller-context)

`specs/keeper-state-machine/KeeperCascadeRouting.tla` (KCR) 와 `lib/keeper/keeper_cascade_selector.ml` 가 cascade fallback 종료를 *다른 metric* 으로 제한 — 양쪽 모두 *terminate* 하지만 *equivalent* 하지 않음. `docs/tla-audit/kcr-c1-fallback-cap-mechanism-gap-2026-05-12.md` 가 명시.

### Spec mechanism (TLA+)

```tla
VARIABLES
    fallback_count,        \* keeper → Nat
    group_path,            \* keeper → Seq(Groups)
    ...

(* I5: Fallback count stays bounded. *)
FallbackCountBounded ==
    \A keeper \in Keepers : fallback_count[keeper] <= MaxFallbacks

ItemDegrade(keeper) ==
    /\ keeper_state[keeper] = "Turning"
    /\ ...
    /\ fallback_count[keeper] < MaxFallbacks   \* explicit precondition
    /\ fallback_count' = [fallback_count EXCEPT ![keeper] = @ + 1]
```

`MaxFallbacks` 는 *CONSTANT*, cfg 별 tuning. PR #14668 (2026-05-11) 이 `<` precondition 을 *명시적* 추가 — 최근 spec-side tightening.

### Runtime mechanism (OCaml)

`lib/keeper/keeper_cascade_selector.ml:5-72`:

```ocaml
let rec try_group group_name visited =
  if List.mem group_name visited then
    Error `No_available_item    (* cycle detection only *)
  else
    match find_group cascade_profile group_name with
    | None -> Error `No_available_item
    | Some group ->
        match find_healthy items with
        | Some item -> Ok (group_name, item)
        | None ->
            (match group.fallback_group with
             | Some next -> try_group next (group_name :: visited)
             | None -> Error `No_available_item)
```

Implicit cap:
1. `visited` list 가 revisit 차단.
2. Recursion depth = `O(profile.groups)` — 명시적 counter 없음.

### 두 mechanism 가 not equivalent

| Mechanism | Cap source | Tunable |
|---|---|---|
| TLA+ `fallback_count <= MaxFallbacks` | explicit counter | ✅ cfg CONSTANT |
| OCaml visited-list cycle detection | distinct-group count | ❌ derived from profile shape |

**시나리오** (audit doc §"Three concrete drift scenarios" 인용):

profile 5 groups, `MaxFallbacks = 3`:
- **TLA+**: 3 fallback 허용, 4번째 시도 `fallback_count < MaxFallbacks` precondition 으로 차단
- **OCaml**: 4 fallback 허용 (`visited = [g1, g2, g3, g4]`, `g5` 시도 가능), 5번째에 visited 전체 cover 시 차단

`FallbackCountBounded` invariant 는 production 에서 *우연히* 만족 — *real cascade profile 이 typically MaxFallbacks 보다 적은 group 을 가짐*. 둘 중 하나만 변경 (e.g. `MaxFallbacks = 10`, profile 6 groups) 시 gap 노출.

### Why this needs an RFC

1. **Spec-runtime contract family 의 *3번째 변형***:
   - RFC-0114 (KSM): OCaml < spec, precondition silent-pass
   - RFC-0115 (KTC): OCaml > spec, vocabulary undefined
   - **RFC-0116 (KCR)**: OCaml ≈ spec, **equivalent only by side-effect**

2. **PR #14668 (2026-05-11) 이 *spec-only*** — 동시 OCaml PR 없음. 정책 부재 의 증거.

3. **`KCR-buggy.cfg` 의 mutation 이 *production gap* 잡지 못함**: spec model 가 `fallback_count` 만 알기 때문에, OCaml 의 visited-list overcount 시나리오 (5-group profile + MaxFallbacks=3 case) 는 spec model 안에서 *invariant 위반 안 함* (모델 자체가 그 상태 도달 안함).

4. **3 concrete drift scenario 가 audit doc 에 enumerated**: spec re-verification with larger MaxFallbacks / profile growth / config tuning. 한 시나리오라도 발생 시 silent overrun.

근본 원인: **두 mechanism 가 *같은 목적* 을 다른 representation 으로 — equivalence proof 도 enforce mechanism 도 없음.**

## §2 Approach

3 layer:

**Layer A — OCaml 가 explicit fallback counter 도입**

`Keeper_cascade_selector` 에 `fallback_count` 명시:

```ocaml
val try_group :
  ~max_fallbacks:int ->
  ~fallback_count:int ->
  string ->
  string list ->
  (group_name * item, [ `No_available_item | `Max_fallbacks_exceeded ]) Result.t

let rec try_group ~max_fallbacks ~fallback_count group_name visited =
  if fallback_count >= max_fallbacks then
    Error `Max_fallbacks_exceeded
  else if List.mem group_name visited then
    Error `No_available_item    (* keep cycle detection as defense in depth *)
  else
    ...
    | Some next ->
        try_group ~max_fallbacks ~fallback_count:(fallback_count + 1)
          next (group_name :: visited)
```

`max_fallbacks` 는 environment knob `MASC_CASCADE_MAX_FALLBACKS` 또는 cascade profile 의 명시적 field. Default = TLA+ cfg 의 `MaxFallbacks` 값.

**Layer B — Equivalence test**

`test/test_kcr_cap_equivalence.ml`: PBT 가 random (profile_size, max_fallbacks) 조합에 대해 OCaml runtime 의 종료 시점 = spec-faithful counter 종료 시점 확인.

**Layer C — KCR.cfg / OCaml config 동기화 lint**

`scripts/lint-kcr-max-fallbacks.sh`: `specs/keeper-state-machine/KeeperCascadeRouting.cfg` 의 `MaxFallbacks = N` 와 `lib/keeper/keeper_cascade_selector.ml` 의 default value 일치 확인. CI 가 drift 차단.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `Keeper_cascade_selector.try_group` 가 `~fallback_count` typed parameter 받음. Default 무한대 (backwards-compat — existing caller unchanged). | dune build PASS, alcotest PASS for existing scenarios |
| P3 | Caller (`keeper_unified_turn`) 가 `MASC_CASCADE_MAX_FALLBACKS` env (default = TLA+ cfg value) 로 호출 | PBT: profile=5/max=3 시 OCaml = TLA+ 정확히 같은 시점 종료 |
| P4 | Equivalence PBT (`test_kcr_cap_equivalence.ml`) — 100 random profile-shape × max_fallbacks 조합 | PASS rate 100% |
| P5 | KCR-buggy.cfg 에 `BuggyOvercountFallback` action 추가 — `fallback_count++` 없이 fallback | KCR.cfg PASS, KCR-buggy.cfg invariant violation (`FallbackCountBounded`) |
| P6 | `scripts/lint-kcr-max-fallbacks.sh` CI workflow, drift 차단 | KCR.cfg `MaxFallbacks` change PR 이 OCaml default 함께 update 필요 |

P3 가 핵심 — runtime cap 이 spec metric 으로 align. P5 는 spec-runtime mutation testing 확장.

## §4 Open questions

1. **Q1**: `MASC_CASCADE_MAX_FALLBACKS` default = ? TLA+ cfg `MaxFallbacks` 의 정확한 값 확인 필요. **잠정**: spec cfg grep + P3 의 첫 commit 에서 명시. 보수적 default 는 *현 OCaml behavior 보존* 위해 `Int.max_int` (P2 와 같이).

2. **Q2**: cascade profile 이 자체 `max_fallbacks` field 가질지? per-profile vs global env? **잠정**: 둘 다 — profile field 가 있으면 우선, 없으면 env, 없으면 default.

3. **Q3**: visited-list cycle detection 제거 vs 유지? defense-in-depth 로 유지 (audit doc 와 같은 의견). **잠정**: 유지. `fallback_count` 가 primary cap.

4. **Q4**: P3 default 가 `Int.max_int` 시 *기존 behavior 보존* 인데, 실제 production 에서 fallback_count 의 *현재 max* 측정? Telemetry counter `keeper_cascade_fallback_count_distribution`. **잠정**: P4 의 PBT 외에 production telemetry 추가 — 실제 cap 사이즈 측정 후 P3 default 조정.

## §5 Non-goals

- **KCR-C2 health_state representation gap**: 본 RFC 의 sibling 가능, 별도 RFC. C-1 만 우선 정합.
- **MaxFallbacks 의 *정책 변경***: TLA+ cfg 의 `MaxFallbacks = N` 가 *어떤 N* 이 옳은지는 별도. 본 RFC 는 OCaml-spec equivalent.
- **cascade profile schema 변경**: 별도. 본 RFC 는 *기존 profile* 의 fallback 종료 시점만.

## §6 Risk & rollback

- **Risk 1**: P3 의 default 변경이 production 에서 fallback 조기 종료 trigger — operator alert. → P3 의 첫 PR 이 default = `Int.max_int` (현 OCaml 동일), telemetry 측정 후 P3-second-PR 가 실제 값.
- **Risk 2**: KCR-buggy.cfg 의 새 action `BuggyOvercountFallback` 가 *실제 mutation* 잡는다는 보장? P5 의 acceptance 가 명시적: clean.cfg PASS + buggy.cfg invariant violation. 둘 다 통과해야 spec valid.
- **Risk 3**: lint (P6) 가 spec cfg vs OCaml default sync 강제 — 두 곳을 동시 변경해야 함, 단일 PR 부담. → lint 가 *suggest diff* 제공, automated PR comment.
- **Risk 4**: PBT (P4) 가 *random profile shape* 생성 시 cycle 없는 DAG 만들기 어렵 — generator 의 정합성. → P2 의 unit test 가 5 manually-crafted shape 으로 cover, P4 의 PBT 는 보조.

Rollback: P3 default 를 다시 `Int.max_int` 로 reset. P5 의 KCR-buggy.cfg 새 action 만 revert. P6 lint 비활성.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `Keeper_cascade_selector.try_group` 가 `~max_fallbacks ~fallback_count` typed parameter 도입. Backwards-compat.
- [ ] P3: Caller (`keeper_unified_turn`) 가 env knob 사용. PBT 5/3 케이스 PASS.
- [ ] P4: Equivalence PBT 100/100 PASS.
- [ ] P5: KCR-buggy.cfg `BuggyOvercountFallback`. clean PASS + buggy violation.
- [ ] P6: drift-check CI workflow.

## §8 Number allocation note

Allocated as RFC-0116. Ledger advanced 0109 → 0117 (skip 0109-0115 due to inflight #15902 RFC-0109 CDAL × GOAL + #15924 RFC-0110 tool-pair atomicity (iter-2) + #15927 RFC-0111 goal mint atomicity (iter-3) + #15933 RFC-0112 typed JSON parse boundary (iter-4) + #15937 RFC-0113 KeeperReactionLiveness runtime (iter-5) + #15939 RFC-0114 KSM precondition (iter-6) + #15944 RFC-0115 KTC turn_phase parity (iter-7)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
