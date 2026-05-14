# RFC-0051 — `run_named` closure decomposition

| 항목 | 값 |
|---|---|
| Status | Draft (design only) |
| Author | Claude Opus 4.7 (Vincent supervising) |
| Created | 2026-05-09 |
| Supersedes | — |
| Depends on | RFC-0047 (oas-adapter-decomposition, merged), RFC-0048 PR-1/PR-2 (helper + wrapper extraction, merged) |
| Implementation scope | `lib/keeper/keeper_turn_driver.ml` (1146 LOC) |

본 RFC는 `keeper_turn_driver.ml` 내 `run_named` 함수(현재 1109 LOC)의 내부 closure 3종 (`try_provider`, `try_cascade`, `cycle_loop`)을 분해하는 **설계 문서**다. 실제 구현 PR은 본 RFC 승인 후 별도 발행한다.

---

## 1. 배경

### 1.1 직전 작업 요약

| 단계 | 내용 | LOC delta | PR |
|---|---|---|---|
| RFC-0047 Phase 4 | `oas_worker_named.ml` → `keeper_turn_driver.ml` rename | 0 | #14301 |
| RFC-0048 PR-1 | top-level pure helper 10개 → `keeper_turn_driver_helpers.ml` | 1459 → 1347 (-112) | #14319 |
| RFC-0048 PR-2 | wrapper 3개 (`run_model_by_label` / `run_named_with_masc_tools` / `run_model_with_masc_tools`) → `keeper_turn_driver_wrappers.ml` | 1347 → 1146 (-201) | #14324 |

누적 -313 LOC (-21.5%). 그러나 이는 **mechanical extraction** — `run_named` 본체는 손대지 않은 "주변 noise 제거" 단계였다.

### 1.2 현재 상태 (post-PR-2)

`keeper_turn_driver.ml` 1146 LOC 내역:

| 영역 | 라인 | LOC | 비율 |
|---|---|---|---|
| Header + module includes | 1–33 | 33 | 2.9% |
| `run_named` 시그니처 + setup | 34–267 | 234 | 20.4% |
| `run_named` 내부 closure `try_provider` | 268–515 | 248 | 21.6% |
| `run_named` 내부 closure `try_cascade` | 516–1095 | 580 | 50.6% |
| `run_named` 내부 closure `cycle_loop` | 1096–1142 | 47 | 4.1% |
| `For_testing` 모듈 | 1143–1146 | 4 | 0.3% |

`run_named` body 단일 함수 1109 LOC가 파일 전체의 96.8%를 차지한다.

### 1.3 본 RFC가 풀려는 문제

RFC-0047 §4.1과 RFC-0048 본문이 명시한 **A/B/C 의미 결합도**:

- **A (Agent SDK invocation)**: 단일 provider에 대한 LLM 호출, response 파싱, error 분류 — `try_provider` 본체
- **B (Cascade strategy)**: provider 후보군 순회, retry 정책, exhaustion 판정 — `try_cascade` 본체
- **C (Keeper bookkeeping)**: turn 카운팅, idle 감지, checkpoint 발행, event broadcast — `run_named` setup + `cycle_loop`

세 관심사가 *동일 함수 body* 안에서 변수 이름 (~50+) 공유로만 연결되어 있다. 결과:

1. **변경 영향 범위 추정 불가** — A 수정이 B/C로 leak할지 *컴파일러가 잡지 못함* (closure 변수는 type-checked되나 *의도적 분리* 강제 불가).
2. **단위 테스트 불가** — A만 stub해서 B 로직만 테스트하려면 1109 LOC 전체를 caller-context로 끌고 와야 함.
3. **Trace/log span boundary 부정확** — 현재 OpenTelemetry span은 `run_named` 단일 boundary. A/B 별 latency 분리 측정 어려움.
4. **RFC-0029 (multi-cascade fanout) 차단** — fanout은 B 레이어 변경. B가 단일 closure에 박혀 있어 fanout site를 격리해 도입할 수 없음.

### 1.4 본 RFC가 *풀지 않는* 문제

- **`run_named` 시그니처 50+ 인자 자체의 인자 그룹화** — 별도 RFC 후보. 본 RFC는 호출 시그니처를 *불변 유지*.
- **Cascade strategy의 token bucket / deadline scheduler 도입** — RFC-0029 영역.
- **Agent SDK 자체의 streaming protocol 변경** — agent_sdk repo 영역.
- **`run_named` 외 다른 OAS-prefix 잔재 정리** — RFC-0047에서 완료.

---

## 2. 설계 옵션

### 옵션 A — Explicit args (closure-to-toplevel-fn 변환)

각 closure를 top-level 함수로 승격, captured 변수를 *모두 명시 인자*로 전달.

```ocaml
(* before *)
let run_named ~cascade_name (* ... ~50 args ... *) =
  let setup_state = ... in
  let try_provider ?resume_checkpoint provider_cfg =
    (* uses setup_state.foo, captured_arg_bar, ... *)
  in
  let rec try_cascade attempt_idx providers =
    (* uses try_provider, setup_state, ... *)
  in
  let rec cycle_loop n =
    (* uses try_cascade, ... *)
  in
  cycle_loop 0

(* after *)
type try_provider_ctx = {
  cascade_name : string;
  guardrails : ...;
  hooks : ...;
  on_event : ...;
  (* ~25 fields enumerated *)
}

let try_provider
    ~ctx:try_provider_ctx
    ?resume_checkpoint
    ?per_provider_timeout_s
    (provider_cfg : Llm_provider.Provider_config.t)
  : ... = ...

(* 같은 패턴으로 try_cascade, cycle_loop *)
```

**장점:**
- closure capture가 *type system에서 가시화*. 각 closure가 *어떤 변수에* 의존하는지 record field로 enumerate.
- 단위 테스트 가능 — `try_provider`만 격리해 mock context로 호출.
- Trace span boundary 자연 분리.

**단점:**
- record field 누락/오타 시 *런타임* 발견 (record는 nominal이라 컴파일러가 잡지만, *어떤 변수를 ctx에 넣을지* 결정은 사람 판단).
- 기존 50+ 인자 중 일부는 `try_provider`에서만 쓰이고, `try_cascade`에서만 쓰이고, 양쪽에서 쓰임. 분류가 *추측이 아닌 측정*이어야 함.
- 수정 LOC 큼 (record type 정의 + 3 함수 시그니처 변경 + body의 모든 변수 참조에 `ctx.` prefix 추가).
- `try_cascade` body 580 LOC에 분포된 변수 참조가 ~수백 곳, 검수 부담 큼.

**위험도:** 🟡 medium (mechanical하지만 분량 크고 silent type-correct 실수 가능)

### 옵션 B — Module functor

각 closure를 functor로 추상화, captured 변수를 functor argument로 전달.

```ocaml
module type RUN_NAMED_CTX = sig
  val cascade_name : string
  val guardrails : ...
  val on_event : ...
  (* ... *)
end

module Try_provider (Ctx : RUN_NAMED_CTX) = struct
  let run ?resume_checkpoint provider_cfg = ...
end
```

**장점:**
- 옵션 A와 같은 분리 효과.
- module signature가 dependency surface를 *문서화*.

**단점:**
- OCaml functor는 run-time application 비용 (각 `run_named` 호출마다 functor 인스턴스화).
- masc_mcp 코드베이스에 functor 사용 사례 많지 않음 — stylistic mismatch.
- record/struct 옵션 A와 표현력 차이 거의 없는데 ceremony만 늘어남.

**위험도:** 🟡 medium-high (codebase convention과 어긋남)

### 옵션 C — Defunctionalization (state machine)

`run_named` body를 state record + step function으로 변환.

```ocaml
type run_named_state =
  | Setup of setup_args
  | Try_provider of { ctx; provider_cfg; checkpoint }
  | Try_cascade of { ctx; attempt_idx; providers }
  | Cycle_loop of { ctx; turn_n; ... }
  | Done of run_result

let step : run_named_state -> run_named_state = ...
```

**장점:**
- A/B/C 분리가 *데이터 형태*로 강제 — `Try_provider` 변형 body를 잘못 건드리면 컴파일 에러.
- TLA+ spec과 1:1 대응 가능 (현재 KeeperTurnContract.tla가 state-based).
- 단위 테스트 가장 깨끗 — 각 transition을 독립 테스트.

**단점:**
- 변환 분량 *제일 큼*. 1109 LOC를 state machine으로 재구조화하는 건 사실상 rewrite.
- `Eio.Switch.run`, `Eio.Cancel`, `Switch.on_release` 등 *structured concurrency* 흐름이 state machine으로 mapping될 때 *cancel boundary* 재설계 필요. RFC-0036 keeper docker orchestration 같은 다른 RFC와 race 가능.
- 검증 비용 (TLA+ spec 추가/갱신 포함) 매우 큼.
- 기존 behavioral test가 동등성 보장하기 어려움 — 추적 표면이 함수 호출에서 state record 변형으로 바뀜.

**위험도:** 🔴 high (의미 보존 입증 비용 크고 cancel 흐름 재설계 동반)

### 옵션 D — Status quo + 명시적 boundary 주석

`run_named` 본체 분해 안 함. 대신:

- A/B/C 영역 위에 `(* === A: provider invocation === *)` 주석 헤더 추가.
- `try_provider`/`try_cascade`/`cycle_loop` 위에 *captured variables* 주석 인벤토리 (수동) 추가.
- CI lint가 영역 헤더 누락/이동 감지.

**장점:**
- 변경량 거의 0. 회귀 위험 없음.
- 향후 RFC 작성자가 captured var 인벤토리를 *읽기만* 하면 되도록 둠.

**단점:**
- 진짜 분리 아님. *문서화*에 불과.
- Captured var 주석은 *코드와 sync 안 될* 위험 (workaround 거부 기준 §1: telemetry-as-fix). 본질 미해결.
- A/B/C 단위 테스트 불가능 그대로.

**위험도:** 🟢 low (변경 자체가 미미)

---

## 3. 권장안

**옵션 A를 단계적 PR 시리즈로 진행**한다. 옵션 C는 rewrite scope이므로 별도 RFC로 격상이 자연스러우며, 옵션 B는 stylistic 손실이 큰 비교에서 옵션 A 대비 이점 없음. 옵션 D는 본 RFC 목적 (실 분리) 미달.

### 3.1 단계적 PR 분할 (제안)

| PR | 작업 | 예상 LOC delta | 검증 |
|---|---|---|---|
| **PR-3a** | `try_provider`만 top-level 함수화 + `try_provider_ctx` record 도입. `try_cascade`/`cycle_loop`는 기존 closure 유지 (단, `try_provider` 호출만 외부 함수 이름으로 전환) | -200~-280, 신규 module +~350 | `dune build` + 기존 `test_keeper_turn_driver_*` 전부 pass |
| **PR-3b** | `try_cascade`를 top-level 함수화. `cycle_loop`는 closure 유지 | -500~-580, 신규 module +~650 | 동일 + 새로운 unit test for try_cascade exhaustion path |
| **PR-3c** | `cycle_loop`를 top-level 함수화. `run_named`는 setup + 3 함수 호출만 남김 | -40~-50, 신규 module +~60 | 동일 + idle-detection unit test |
| **PR-3d** (조건부) | `keeper_turn_driver.ml`을 facade로 축소 (200 LOC 미만), 새 모듈 `keeper_turn_runner.ml` 등으로 분리 | 분배 변경만 | godfile lint 재기동 |

각 PR은 *독립 머지 가능*. 한 PR이 회귀 시 단독 revert 가능한 단위.

### 3.2 PR-3a 사전 측정 (실 구현 시작 전 의무)

옵션 A의 silent risk는 ctx record field 분류 오류다. 따라서 PR-3a 시작 전:

1. `lib/keeper/keeper_turn_driver.ml` L268–515 (try_provider body) 안에서 *closure-captured* 변수를 grep으로 1차 enumerate.
2. 각 변수에 대해 다음 4분류:
   - **try_provider only** → ctx record field
   - **try_cascade only** → 분리 ctx record field (PR-3b ctx)
   - **양쪽 사용** → 공통 ctx record field
   - **cycle_loop only** → PR-3c ctx
3. 측정 결과를 PR-3a body에 *명시 인용* (변수명 + line 번호).
4. `try_provider_ctx` record가 그 인벤토리와 1:1 대응.

이는 RFC-0047 audit 메모리 (`feedback_audit_matrix_decays_with_main_drift`)의 fresh-grep 강제 규칙과 동일 패턴.

### 3.3 비목표 명시

- 본 RFC PR 시리즈는 *behavioral equivalence* 만 목표. 새 기능 추가 / cascade strategy 정책 변경 / token bucket 도입은 *전부 out of scope*.
- 단일 PR에서 기능 변경 + 구조 변경을 섞지 않는다. 회귀 발생 시 원인 분리 비용 폭증을 피한다 (3-Try Rule §"같은 영역 fix 2회 = 근본 수정" 적용 영역).

---

## 4. 검증 계획

### 4.1 행동 동등성 (Behavioral Equivalence)

기존 테스트 자산:

```bash
rg -l "Keeper_turn_driver\." test/ | sort -u
```

해당 테스트 셋이 PR-3a/b/c *각각 머지 직후* 100% 통과해야 한다. 차이는 자동 머지 거부 신호.

### 4.2 신규 단위 테스트 (각 PR 의무)

| PR | 신규 테스트 | 목적 |
|---|---|---|
| PR-3a | `test_try_provider_provider_rejection_classification` | A 영역의 error 분류 격리 검증 |
| PR-3a | `test_try_provider_per_provider_timeout` | A 영역의 timeout 경로 격리 검증 |
| PR-3b | `test_try_cascade_exhaustion_path` | B 영역의 exhaustion 종료 격리 검증 |
| PR-3b | `test_try_cascade_provider_filter_fanout_skip` | B 영역의 filter 분기 검증 |
| PR-3c | `test_cycle_loop_idle_termination` | C 영역의 max_idle_turns 종료 검증 |

### 4.3 Trace boundary 회귀 검사

PR-3a 머지 후 OpenTelemetry span name 변동을 *허용하지 않는다*. 새 boundary 도입 시 기존 span 이름 유지 + 새 child span 추가만 허용. 기존 dashboard/grafana query가 깨지지 않게 함.

### 4.4 TLA+ spec 적합성

`KeeperTurnContract.tla` 의 `Next` action set을 변경하지 않는다. 본 RFC는 implementation refactor이며, spec-level 구조는 보존한다. 만약 PR 진행 중 spec과 코드 사이 *드러나지 않은 차이*를 발견하면, 그 발견 자체가 별 RFC를 trigger한다.

---

## 5. 위험과 대응

| 위험 | 시그널 | 대응 |
|---|---|---|
| ctx record field 분류 오분류 → silent capture 누락 → 런타임 NPE/wrong-state | PR review에서 ctx field 인용 검증 | §3.2 사전 측정 의무화 |
| Eio cancel boundary가 closure 분해로 변경 → 기존 cancel propagation 깨짐 | `test_keeper_turn_driver_cancel_*` 회귀 | 옵션 A는 closure → top-level 변환만, control flow는 그대로 보존. cancel 변경 시 별 RFC. |
| ocamlformat-check 충돌로 main blocker | 직전 RFC-0047 시리즈에서 advisory였음 | 새 파일은 `ocamlformat -i` 미리 적용. 기존 파일 reformat 금지. |
| 동일 영역 다른 PR (RFC-0029 fanout 등)과 충돌 | `gh pr list --search "keeper_turn_driver"` | PR 시작 전 active PR sweep 의무. RFC-0048 PR-2 머지 패턴과 동일. |
| 본 RFC 시리즈 *중간*에 main blocker 발견 | CI red | 진행 중지, blocker 별 PR 우선 처리. PR-3 시리즈 머지 직진 금지. |

---

## 6. 의도적 비결정 (Open Questions)

다음 항목은 **본 RFC에서 결정하지 않는다**. PR-3a 시작 전 사용자 결정 필요.

1. **`try_provider_ctx` 명명** — `Keeper_turn_provider_ctx`? `Run_named_provider_ctx`? `keeper_turn_driver` 모듈 안 nested? 별 모듈?
2. **PR-3b 분기 시점** — PR-3a 머지 즉시 PR-3b 시작 vs PR-3a 안정성 1주 관찰 후?
3. **PR-3d (facade 축소)** 실행 여부 — `keeper_turn_driver.ml`이 PR-3c 후 ~200 LOC 미만이 되면 자연스러운 facade. 그러나 godfile lint 임계값 (현재 ?) 미달이면 강행할 이유 없음.
4. **For_testing 모듈 거취** — `For_testing.checkpoint_after_attempt`만 남아 있음. PR-3a/b/c 동안 *그대로 보존*이 default. 변경 필요 시 별도 결정.

---

## 7. 명시적 거부 (Explicitly Out of Scope)

본 RFC가 *고려했고 거부한* 항목 — 향후 누군가 같은 제안을 가져올 때를 위한 기록.

| 거부 항목 | 사유 |
|---|---|
| 옵션 C (state machine defunctionalization) | rewrite scope, 별 RFC 격상 필요 |
| `run_named` 시그니처 50+ 인자 그룹화 | 본 RFC scope 밖, 별 RFC 후보 |
| Cascade strategy 정책 변경 (token bucket / deadline) | RFC-0029 영역 |
| Agent SDK invocation surface 변경 | agent_sdk repo 영역 |
| Captured-var-as-comment-inventory (옵션 D) 단독 적용 | workaround 거부 기준 §1 (telemetry-as-fix). 분리 회피 |
| `try_provider`/`try_cascade`를 *동일 module* 안 sibling top-level fn으로만 두고 ctx 없이 진행 | OCaml은 top-level fn에서 전 closure 변수를 자동 캡처하지 않음. ctx record 필요 |

---

## 8. 승인 후 첫 실행 (Implementation kick-off checklist)

본 RFC 머지 후 PR-3a 시작 전:

1. [ ] 사용자 명시 승인 (`human-approved-ready` 또는 직접 합의 문구).
2. [ ] §6 open question 1 (ctx 명명) 결정.
3. [ ] 새 worktree (`rfc-0051-pr-3a-try-provider`).
4. [ ] §3.2 사전 측정 결과를 `.tmp/rfc-0051-pr-3a-capture-inventory.md`에 기록 후 PR-3a body에서 인용.
5. [ ] PR-3a Draft. ocamlformat 사전 적용.

---

## 9. References

- **선행 작업**:
  - `docs/rfc/RFC-0047-oas-adapter-decomposition.md` (Implemented)
  - `lib/keeper/keeper_turn_driver_helpers.ml` (RFC-0048 PR-1, #14319)
  - `lib/keeper/keeper_turn_driver_wrappers.ml` (RFC-0048 PR-2, #14324)
- **연관 RFC**:
  - RFC-0029 multi-cascade fanout (B 레이어 변경 후속작)
  - RFC-0036 multi-keeper docker orchestration (cancel 경로 race 가능성)
  - RFC-0046 keeper-detail FSM hub SSOT (trace boundary 영향)
- **메모리 (운영 규칙)**:
  - `feedback_audit_matrix_decays_with_main_drift` — 사전 측정 fresh-grep 의무
  - `feedback_masc_mcp_admin_merge_fast_track` — Draft 유지 + 사용자 라벨 대기
  - `feedback_check_open_prs_before_fixing_pasted_build_error` — PR 시작 전 active PR sweep
  - `feedback_split_brain_rfc_0022_pr_2_pr3_overlap` — 동일 영역 동시 PR 차단
  - 워크어라운드 거부 기준 §1 (CLAUDE.md `software-development.md`) — 옵션 D 단독 채택 거부 근거

---

## 10. 결정 이력

| 일자 | 결정 | 결정자 |
|---|---|---|
| 2026-05-09 | RFC-0051 Draft 발행, 옵션 A 권장 | Claude (Vincent supervising) |
