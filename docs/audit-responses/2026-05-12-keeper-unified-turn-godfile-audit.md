# keeper_unified_turn.ml 갓파일 분할 감사

- 일자: 2026-05-12
- 대상: `lib/keeper/keeper_unified_turn.ml`
- 모드: READ-ONLY 감사 (코드 변경 없음, 본 문서 1개 파일만 생성)
- 트리거: CLAUDE.md §software-development.md 300/500줄 임계, 최근 200 PR 중 9회 touch, self-eval가 "godfile-pressure-ignored"로 표시.

> Memory `feedback_explore_agent_dead_code_triage_oversells.md` 경고를 따라, "사용되지 않음" 주장은 직접 grep cross-check 후에만 기록한다.

## §1 Scope & metrics

### LOC / 구조

| 메트릭 | 값 | 측정 명령 |
|--------|-----|----------|
| 총 LOC (`.ml`) | **3037** | `wc -l lib/keeper/keeper_unified_turn.ml` |
| `.mli` LOC | 317 | `wc -l lib/keeper/keeper_unified_turn.mli` |
| 최상위 `let` 바인딩 | **13** | `rg "^let " lib/keeper/keeper_unified_turn.ml \| wc -l` |
| `mli` 공개 `val` | **30** | `rg "^val " lib/keeper/keeper_unified_turn.mli \| wc -l` |
| 최상위 `type` | 1 (`turn_tool_event_tracker`, line 128) | `rg "^type " lib/keeper/keeper_unified_turn.ml` |
| `let rec` | 0 | `rg "^let rec " lib/keeper/keeper_unified_turn.ml` |
| `include` 라인 | 3 (lines 13–15) | `keeper_turn_helpers`, `keeper_turn_liveness`, `keeper_turn_cascade_budget` |

`mli`(30 val) > `.ml`(13 let)인 이유는 line 13–15의 `include`로 이미 분할된 helper 모듈 3개를 *재노출*하기 때문이다. 즉 30개 공개 API 중 17개는 helper 모듈이 본체이며, `keeper_unified_turn.ml` 자체에 정의된 공개 함수는 13개에 한정된다.

```ocaml
(* lib/keeper/keeper_unified_turn.ml:13-15 *)
include Keeper_turn_helpers           (* 395 LOC *)
include Keeper_turn_liveness          (* 248 LOC *)
include Keeper_turn_cascade_budget    (* 952 LOC *)
```

### 커밋 빈도 (cohort)

| 메트릭 | 값 |
|--------|-----|
| 전체 commit (mainline) | **453** (`git log --oneline --all -- lib/keeper/keeper_unified_turn.ml`) |
| 최근 2개월 commit | **105** |
| 최근 200 PR 내 touch 수 (요구자 측정) | 9 |

### 최근 9회 touch (mainline, SHA + 1-line summary)

`git log --oneline -200 -- lib/keeper/keeper_unified_turn.ml` 상위 9건:

1. `b5a3bb8e3` feat(telemetry): 4 single-variant *_site sums for keeper_unified_turn (4 sites) (#14851)
2. `ea896ec45` feat(telemetry): Turn_cleanup + Write_meta_cycle + Cascade_sync extend (5 sites) (#14836)
3. `95ee74e06` feat(telemetry): typed phase variant for oas_execution_errors metric (#14737)
4. `cddab45e7` refactor(keeper): remove is_ollama_cfg variant match (RFC-0058 Phase 5.6 leak 1/4) (#14691)
5. `8486a142b` refactor(keeper): typed receipt.outcome — string → outcome_kind (polymorphic variant) (#14661)
6. `6dd3e16c8` refactor(keeper): typed degraded_retry.fallback_reason — closed sum type (#14660)
7. `a5b84ce22` refactor(keeper): typed cascade_rotation_attempt.outcome — string → closed sum type (#14657)
8. `850614564` refactor(keeper): typed slot_release_at_phase — closed sum type w/ [@@deriving tla] (#14656)
9. `f97b088f3` fix(keeper): replace rollover substring match with typed blocker_class (#14613)

**관찰**: 최근 9건 중 3건이 텔레메트리 확장(#14851/#14836/#14737), 5건이 typed-variant 마이그레이션(#14691/#14661/#14660/#14657/#14656), 1건이 string→variant 분류기 교체(#14613). *기능 확장*이 아니라 *기존 표면을 typed화*하는 정비성 작업이 다수다. 갓파일 압력이 새 기능 추가에서 오는 것이 아니라 *이 파일을 통과하는* RFC-0042/0047/0058 변환 작업에서 누적되고 있다.

### 책임 centroid (responsibility centroids)

13개 최상위 `let`을 의미 그룹으로 묶으면 다음과 같다 (line 번호는 `keeper_unified_turn.ml`).

| 그룹 | 함수 | LOC (대략) |
|------|------|-----|
| **A. Error/disposition classification** | `registry_failure_reason_of_terminal_reason` (line 25), `should_auto_pause_required_tool_contract_violation` (line 53), `sdk_error_of_retry_slot_reacquire_timeout` (line 109) | ~85 |
| **B. Tool-event tracker** (state struct + 7 ops) | `type turn_tool_event_tracker` (line 128), `create_turn_tool_event_tracker` (line 134), `turn_tool_event_integrity_error` (line 141), `committed_mutating_tools_from_events` (line 143), `push_turn_tool_input` (line 147), `pop_turn_tool_input` (line 159), `record_unmatched_tool_completed` (line 165), `record_turn_tool_events` (line 198) | ~110 |
| **C. Pre-dispatch observation** | `record_streaming_cancelled_observation` (line 64) | ~45 |
| **D. Turn cycle orchestration** (godfile core) | `run_keeper_cycle` (line 239), `run_unified_turn = run_keeper_cycle` (line 3037, 알리아스) | **~2800** |

핵심 비대 부위는 **단일 함수 `run_keeper_cycle`** (line 239→3036, 약 2800 LOC). 파일 전체 LOC의 ≈92%다. 갓"파일"이라기보다 **갓"함수"**가 더 정확하다.

### `run_keeper_cycle` 내부 단계 마커 (코드 주석 기준)

`run_keeper_cycle` 본문에는 명시적으로 번호가 매겨진 단계 주석이 있다. `rg "^\s*\(\* [0-9]\." lib/keeper/keeper_unified_turn.ml`:

| 단계 | line | 코드 주석 (원문) |
|------|------|------|
| 0. Phase gate + cascade routing | 291 | "Phase gate + state-aware cascade routing" |
| 2. Build unified prompt | 728 | "Build unified prompt — diversity entropy recorded" |
| 4. Build turn prompt callback | 753 | "Build turn prompt callback: use our unified system prompt" |
| 5. Run via OAS Agent.run() | 776 | "Run via OAS Agent.run() with transient-error retry" |
| 6. Observe result & metrics | 2557 | "Observe result and update metrics" |
| 7. Persist updated meta | 2942 | "Persist updated meta — RMW retry" |
| 8. Handle stop reason | 2984 | "Handle stop reason" |

단계 1과 3 번호는 코드 주석에서 누락되어 있다 (line 725 `Yield before CPU-bound prompt construction`, line 739 `Ensure session dir tree for filesystem fallback` 가 그 자리를 차지). 즉, 의도된 8단계 파이프라인이 6개 명시 + 2개 암묵으로 흩어져 있다.

## §2 Cohesion analysis

### 공유 상태

`run_keeper_cycle` 내부에서 closure로 캡처되어 단계 간 공유되는 `ref`/mutable 상태:

- `cycle_completed = ref false` (line 290) — 함수 진입부에 선언, 최종부 line 3032에서 `:= true` 후 `post_turn_complete_task ~cycle_completed` 콜백에 전달. spec navigation 주석(line 252–289)이 이 ref를 TLA+ `TurnComplete` action에 매핑한다.
- `cascade_rotation_attempts := attempt :: !cascade_rotation_attempts` — 내부 `record_cascade_rotation_attempt` (line 953) 헬퍼가 closure로 캡처. cascade-rotation telemetry 누적용.
- `tracker : turn_tool_event_tracker` — line 134에서 생성, OAS event_bus subscriber에 전달되어 ToolCalled/ToolCompleted 이벤트로 mutation. 같은 turn 동안 partial commit 추적.

closure로 캡처되는 ref들은 *같은 turn 사이클 동안의 누적 상태* — 외부 모듈로 끌어내면 인터페이스가 invasive해진다.

### 외부 API surface (cross-check)

`rg "Keeper_unified_turn\." lib/ test/ bin/ --type ml`은 비-주석 caller 5개를 보인다 (총 7 hits, 그중 4건은 doc 코멘트 인용):

- `lib/keeper/keeper_heartbeat_loop.ml:481` — `Keeper_unified_turn.run_keeper_cycle` (실제 call)
- `lib/keeper/keeper_heartbeat_loop.ml:1127` — `Keeper_unified_turn.run_keeper_cycle` (실제 call)
- `lib/keeper/keeper_turn_slot.ml:868` — doc 주석 안의 함수 인용 (코드 X)
- `lib/keeper/keeper_run_tools.ml:1576` — doc 주석 안의 `retry_loop` 역사적 인용 (코드 X)
- `test/test_keeper_fsm_joints.ml:22` — doc 주석 안의 `{!run_unified_turn}` 인용 (코드 X)
- `test/test_keeper_sub_fsm_guards.ml:213, 249` — doc 주석 안의 `retry_loop` 역사적 인용 (코드 X)

**실제 함수 호출은 단 2곳** — 둘 다 `keeper_heartbeat_loop.ml`에서 `run_keeper_cycle`을 호출 (rg evidence: 2 hits for `Keeper_unified_turn.run_keeper_cycle\b`).

`run_unified_turn` (line 3037 alias)은 코드에서 호출 0건 (rg evidence: 1 hit, `Keeper_unified_turn.run_unified_turn\b`, 그것도 test doc 주석). 즉, alias는 *역사적 호환*만 유지하고 있다.

`include`된 helper 모듈의 API는 `module UT = Masc_mcp.Keeper_unified_turn` 별칭으로 `test/test_keeper_unified.ml` (12334 LOC)에서 **123회** 사용된다 (rg evidence: `UT\.` 123 hits in test/test_keeper_unified.ml). 즉 `.mli`의 30개 val은 *대부분 테스트 진입점*이고, production caller는 `run_keeper_cycle` 1개에 수렴한다.

### `mli`에 있지만 production caller 0인 (테스트 전용) 함수 — cross-check 결과

직접 grep으로 검증한 항목 (`Keeper_unified_turn.<name>\b`):

| 함수 | production hits (lib/keeper, bin/) | test hits |
|------|-----:|------:|
| `run_keeper_cycle` | 2 | 0 |
| `run_unified_turn` (alias) | 0 | 1 (doc comment) |
| `resolve_bounded_oas_timeout_budget_with_turn_budget` | 1 (`keeper_turn_slot.ml` doc) | (테스트 via UT 별칭) |
| `attempt_watchdog_timeout_sec` | 0 | 2 (test_keeper_unified.ml:7909, 7928) |
| `summarize_turn_event_bus` | 0 | 2 (test_keeper_unified.ml:6705, 11899) |
| `create_turn_tool_event_tracker` | 0 | 3 (test_keeper_unified.ml:7320, 7362, 7396) |
| `next_fail_open_cascade_for_turn` | 0 | (테스트만) |
| `should_auto_pause_required_tool_contract_violation` | 0 | (테스트만) |
| `record_streaming_cancelled_observation` | 0 | (테스트만) |
| `bounded_oas_timeout_for_turn_budget` | 0 | (테스트만) |

⚠️ 주의: "production hits 0"은 **외부에서 호출 0**일 뿐이다. 이들 함수는 모두 `run_keeper_cycle` 내부에서 closure 캡처 또는 직접 호출로 사용되므로 dead code가 *아니다*. memory `feedback_explore_agent_dead_code_triage_oversells.md` 따라 명시한다.

### 응집도 평가

- **Cohesive**: A(error classification), B(tool-event tracker)는 각각 한 가지 개념을 다룬다. include로 끌어온 helper 3종 (helpers/liveness/cascade_budget)은 이미 cohesive하게 분할됨.
- **Coincidental collocation**: `run_keeper_cycle` 자체는 *8단계 파이프라인을 한 함수로 펼친 결과*. 단계 간 공유 상태는 `cycle_completed`, `tracker`, `cascade_rotation_attempts` 정도이지만, *제어 흐름* 자체가 깊은 `match … with | Ok _ -> match … | Error e -> …` 중첩(예: line 982 `Cancel-safe cleanup`, line 1142 `external cancellation that escapes the…`, line 1518 `Budget gate: check whether there is enough wall-clock`)으로 응집되어 있어 함수 단위 추출 비용이 크다.

요약: **파일 단위 응집은 OK, 함수 단위 응집은 깨졌다**. 분할 대상은 *파일이 아니라 `run_keeper_cycle` 함수의 단계*다.

## §3 Split proposal

### Option A — 파일을 2~3개로 분할

후보:
- `keeper_turn_runner.ml` — `run_keeper_cycle` 본체만 보유 (~2800 LOC).
- `keeper_turn_tool_events.ml` — Group B (tool-event tracker, type + 7 ops, ~110 LOC).
- `keeper_turn_classification.ml` — Group A + C (error/disposition classification + pre-dispatch observation, ~130 LOC).

**Tradeoff**:
- ➕ 파일당 LOC 감소: 2800 / 110 / 130. CI 임계(300/500줄) 통과는 *Group B/C만* 통과, runner는 여전히 godfile.
- ➖ runner 파일 = `run_keeper_cycle` 단일 함수 → 파일이 함수 자체가 됨. 분할 이득 미미.
- ➖ `include Keeper_turn_helpers/liveness/cascade_budget`가 runner로 따라가야 함 (or 도로 별 모듈로 노출). mli 30 val을 재배치하는 비용.
- ➖ TLA+ spec 8개 파일이 `keeper_unified_turn.ml`을 line 번호와 함께 인용 중 (line 318, 1640 등). 분할 시 spec 주석 mass-update 필요.

**점수**: 표면 LOC는 줄지만 **실제 godfile (단일 함수 2800 LOC)는 그대로**. cosmetic.

### Option B — 닫힌 helper를 private companion module로 추출

후보:
- `keeper_unified_turn__internal.ml` (또는 `keeper_turn_runner_helpers.ml`) — `run_keeper_cycle` *내부에서만* 사용되는 closed helper들을 함수 외부로 끌어올린다.
- 1차 후보: `record_cascade_rotation_attempt` (line 953, 내부 `let`). closure ref `cascade_rotation_attempts`를 명시 인자로 받도록 변환하면 깔끔히 분리됨.
- 2차 후보: line 728 prompt build 블록, line 776–950 retry-loop entry 블록 — closure 의존이 무거워 invasive.

**Tradeoff**:
- ➕ `run_keeper_cycle` 자체가 줄어든다 (현재 ≈2800 → 단계당 -50~200 LOC).
- ➕ 각 추출 단위가 *순수 함수* 또는 *명시 ref 인자*가 되면 단위 테스트 추가가 쉬워진다.
- ➕ TLA+ spec이 가리키는 line 번호는 anchor 주석(line 252–289)이 함수명 기준이라 재정렬에 강건.
- ➖ closure 캡처가 깊을수록 신호 비대(다수 인자). 추출의 ROI가 단계별로 다르다.
- ➖ helper의 visibility를 잘못 정하면 dead-code 경고나 over-export 발생.

**점수**: 갓"함수" 문제를 *직접* 푼다. 점진적, 작은 PR로 분할 가능. TLA+ spec 영향 최소.

### Option C — 그대로 두고 문서화만

**Tradeoff**:
- ➕ 위험 0. 최근 9회 touch가 모두 typed-variant 마이그레이션(즉, *수렴*하는 작업)이므로 자연 안정화 가능성 있음.
- ➕ TLA+ spec 8 파일에 line-anchored 주석이 살아 있음. 분할 비용 절약.
- ➖ `wrong_approach` 누적 신호 — CLAUDE.md `software-development.md` "파일이 임계값을 넘으면 분할 검토" 기본 원칙 위반.
- ➖ 105 commits / 2 months 빈도는 *touch surface*가 넓다는 신호.

### 권고 — **Option B**

이유:
1. 갓파일의 실체는 **`run_keeper_cycle` 단일 함수 2800 LOC** (파일 전체의 92%). Option A는 LOC를 옮길 뿐, 함수 비대를 못 푼다.
2. `include` 헬퍼 3개(395 + 248 + 952 LOC)가 이미 cohesive boundary로 분할되어 있다. 다음 자연스러운 step은 *`run_keeper_cycle` 내부 helper의 hoist*.
3. TLA+ spec 매핑(`KeeperTaskAcquisition` `KeeperTurnCycle` `KeeperContextLifecycle` 등 8 파일)이 *함수명* 단위로 anchor되어 있어, B는 spec 마이그레이션 비용 최소.
4. 점진성: 매 PR이 한 helper만 hoist. RFC 없이 진행 가능 (closed helper, public API 변동 없음).

신뢰도: **Medium-High**. Option A는 cosmetic이라 강하게 비추천(High confidence). B vs C는 *진행 의지*에 달려 있으며, B 첫 PR(§5 sketch)을 작은 ROI 실험으로 측정한 후 확장 결정을 권한다.

## §4 Migration risk

### 외부 caller 영향

- 실제 외부 caller 2건 모두 `Keeper_unified_turn.run_keeper_cycle` (`keeper_heartbeat_loop.ml:481, 1127`). Option B는 이 시그니처를 *건드리지 않는다* → caller 영향 0.
- Option A는 `run_keeper_cycle`을 `Keeper_turn_runner.run_keeper_cycle`로 옮기게 되어 2 caller 수정 필요. 그러나 mli 30 val의 재배치가 `test/test_keeper_unified.ml`(123 UT 별칭 호출, 12334 LOC) 전체 sweep을 강제 — non-trivial.

### `mli` 시그니처 영향

- Option B: 외부 export 변화 없음. private helper만 internal module로 hoist (또는 동일 .ml 내 toplevel `let`로 lift 후 .mli에 노출하지 않음).
- Option A: 30 val을 새 .mli 3개로 split + re-export 또는 caller 마이그레이션. 부수 비용 큼.

### TLA+ implications

`rg "keeper_unified_turn" specs/keeper-state-machine/`:

| TLA+ spec | hits |
|-----------|-----:|
| `KeeperTurnCycle.tla` | 7 |
| `KeeperContextLifecycle.tla` | 3 |
| `KeeperPostTurnOrchestration.tla` | 2 |
| `KeeperReactionLiveness.tla` | 2 |
| `KeeperTaskAcquisition.tla` | 1 |
| `KeeperCascadeRouting.tla` | 1 |
| `KeeperTurnSlot.tla` | 1 |
| `KeeperCoreTriad.tla` | 1 |

`KeeperPostTurnOrchestration.tla`는 구체적 라인 인용까지 한다: "blocker_klass | current_turn_blocker_info.klass (Track A typed enum) | lib/keeper/keeper_unified_turn.ml:1640". 즉, **TLA+ spec이 line 번호로 anchored**되어 있어 Option A의 파일 분할 시 spec 본문 다중 수정 필요. Option B는 helper 명만 유지하면 line drift만 발생하며 (anchor가 함수명 위주라 견딜만함).

`run_keeper_cycle` 본체 라인 252–289에는 **TLA+ → OCaml 매핑 anchor 주석**이 이미 들어가 있어 reverse-direction citation 유지. 분할 시 이 anchor를 새 위치로 옮길 의무 발생.

### Test 영향

- `test/test_keeper_unified.ml` (12334 LOC, 123 UT 별칭 호출): Option B는 영향 없음 (외부 시그니처 동일). Option A는 별칭 재바인딩 또는 import 추가.
- `test/test_keeper_sub_fsm_guards.ml:213, 249`의 doc 주석 ("Pre-fix [Keeper_unified_turn.retry_loop] line 1138 era")은 이미 *역사적 인용*이므로 분할과 무관. 단, 새 line drift가 일어나면 주석의 "line 1138 era"가 추가로 stale해질 수 있다 — read-only 정보이므로 합의 후 maintenance.

## §5 Next-step PR sketch (분할 진행 시)

권고: **가장 작은 분리 가능 단위인 `record_cascade_rotation_attempt`를 closure ref(`cascade_rotation_attempts`) 명시 인자로 변환 후 toplevel `let`로 hoist**.

근거:
- 현재 위치: `lib/keeper/keeper_unified_turn.ml:953` (run_keeper_cycle 내부 `let`).
- closure 의존: `cascade_rotation_attempts : Keeper_execution_receipt.cascade_rotation_attempt list ref` (line 953 `cascade_rotation_attempts := attempt :: !cascade_rotation_attempts`).
- 명시 인자화: `~cascade_rotation_attempts:Keeper_execution_receipt.cascade_rotation_attempt list ref` 추가만으로 closed.
- 다른 closure 의존 0 (확인: `now_iso`, `Keeper_execution_receipt.*`, `sdk_error_kind`는 모두 module-level 함수).

**최소 PR 형태** (감사 단계에서는 *수행 금지*):
1. `record_cascade_rotation_attempt`를 file-toplevel `let`로 hoist (private — `.mli`에 노출하지 않음).
2. `cascade_rotation_attempts` ref를 호출 시 명시 인자로 패스.
3. `dune build --root . @check` 통과 + 기존 test green 확인 후 Draft PR.
4. mli/외부 API 변화 0 → caller 마이그레이션 0 → revert risk 최소.

이 PR은 갓파일의 첫 박편(slice)으로서 ROI 측정용 실험: hoist 후 가독성·테스트 가능성 개선이 있으면 B 옵션을 확장(다음 후보: line 728 prompt build 블록 hoist). 개선이 미미하면 Option C로 회귀 결정.

본 감사 PR에서는 **분할을 수행하지 않는다**. sketch는 다음 PR을 위한 anchor 문서일 뿐이다.

---

## 부록 — 검증 명령 재현 가이드

```bash
# LOC
wc -l lib/keeper/keeper_unified_turn.ml
wc -l lib/keeper/keeper_unified_turn.mli

# Top-level let 개수
rg "^let " lib/keeper/keeper_unified_turn.ml -n

# mli 공개 val 개수
rg "^val " lib/keeper/keeper_unified_turn.mli | wc -l

# 외부 caller
rg "Keeper_unified_turn\." lib/ test/ bin/ --type ml -n

# 단계 마커
rg "^\s*\(\* [0-9]\." lib/keeper/keeper_unified_turn.ml -n

# 9회 touch (최근)
git log --oneline -200 -- lib/keeper/keeper_unified_turn.ml | head -9

# TLA+ spec 참조
rg "keeper_unified_turn" specs/keeper-state-machine/ -c

# include된 헬퍼 LOC
wc -l lib/keeper/keeper_turn_helpers.ml \
      lib/keeper/keeper_turn_liveness.ml \
      lib/keeper/keeper_turn_cascade_budget.ml
```
