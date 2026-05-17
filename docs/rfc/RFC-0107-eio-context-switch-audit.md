---
rfc: "0107"
phase: C.0
status: Evidence
created: 2026-05-17
supplement_of: RFC-0107
---

# RFC-0107 Phase C.0 — `Eio_context.get_switch_opt` global access audit

> 본 문서는 RFC-0107 §3.3 (L3 Switch hierarchy) 의 *real complexity* 를 기록하기 위한 evidence supplement 다. 본문(`RFC-0107-outbound-http-stack-consolidation.md`) §3.3 작성 시 "run_turn 내부 fresh `Eio.Switch.run`" 한 줄로 처리됐으나, callsite inventory 결과 그 wrap *단독* 으로는 효과가 없음이 드러났다. wiring 결정은 Phase C.1 으로 분리하며 사용자 결정을 대기한다.

## 1. 발견 요약

- `lib/eio_context/eio_context.ml:84` `get_switch_opt ()` 가 `Atomic.t` 에 저장된 *전역 root switch* 를 반환.
- callsite 26 개 (lib/ + bin/), 9 모듈에 분산. 모두 이 atomic 을 통해 switch 에 fiber/resource 를 attach.
- 결과: `run_turn` body 를 `Eio.Switch.run` 으로 감싸도 *body 내부 호출 경로* 가 `get_switch_opt ()` 를 거치면 root switch 로 우회. **naïve wrap 무효**.

## 2. Callsite inventory (26)

`rg "Eio_context\.get_switch" lib/ bin/` 직접 측정 (2026-05-17).

### 2.1 Server/dashboard 계열 — *root-lifetime intent*

| 파일 | 라인 | 의도 |
|---|---|---|
| `lib/server/server_dashboard_http_runtime_info.ml` | 194 | runtime info 응답 시 background fetch 를 root_sw 에 fork |
| `lib/server/server_dashboard_http_core.ml` | 1357 | dashboard HTTP route handler 가 child fiber 를 root_sw 에 attach |
| `lib/server/server_routes_http_common.ml` | 88, 89 | route 공용 sw fallback |
| `lib/server/server_dashboard_http_namespace_truth_support.ml` | 31 | namespace truth fetch — Some/None 분기만 |
| `lib/dashboard/dashboard_mission_briefing.ml` | 269 | mission briefing background refresh |
| `lib/dashboard/dashboard_cache.ml` | 314 | stale-while-revalidate fork (`.mli:14` 가 명시) |
| `lib/board_dispatch.ml` | 184 | board task fork |
| `lib/relation_materializer.ml` | 49 | relation materialization fork |

총 **9 callsite**. 이들은 *root_sw 가 server 전체 lifetime 을 가짐* 을 전제로 fork. 만약 `current_sw` 가 turn_sw 로 swap 된 시점에 이 코드들이 동시 실행되면, 그들의 fiber 가 turn_sw 에 attach → turn 종료 시 *premature termination*.

### 2.2 Cascade/keeper turn-scoped — *turn-lifetime intent*

| 파일 | 라인 | 의도 |
|---|---|---|
| `lib/cascade/cascade_oas_runner.ml` | 23 | OAS runner sw fallback |
| `lib/cascade/cascade_runtime.ml` | 177 | cascade fiber attachment |
| `lib/cascade/cascade_catalog_runtime.ml` | 619 | catalog runtime fork |
| `lib/keeper/keeper_run_tools.ml` | 781 | tool execution sw |
| `lib/keeper/keeper_turn_liveness.ml` | 74 | liveness ping fork (turn 중에만 의미) |
| `lib/keeper/keeper_exec_voice.ml` | 25 | voice exec |
| `lib/keeper/keeper_unified_turn.ml` | 622 | event_bus subscription |
| `lib/keeper/keeper_tag_dispatch.ml` | 14, 140, 160 | tool task dispatch — `Tool_task.config.sw` 에 직접 박힘 |
| `lib/keeper/keeper_keepalive.ml` | 369 | grpc env keepalive |
| `lib/keeper/keeper_exec_task.ml` | 345, 465, 499 | exec task sw |
| `lib/keeper/keeper_memory_llm_summary.ml` | 216 | memory summary LLM fetch |

총 **16 callsite**. 이들은 *turn 단위로 자르고 싶은* 작업이지만 *현재는 root_sw 에 매달림* (Phase C 문제 진앙). wrap 이 도입되고 위 §2.1 의 server 계열과 분리되면 이들은 자연스럽게 turn_sw 로 흡수됨.

### 2.3 기타

| 파일 | 라인 | 의도 |
|---|---|---|
| `lib/autoresearch_codegen.ml` | 117 | code generation fork — net+sw 동시 필요 |

총 **1 callsite**.

**합계**: 26 callsite, 9:16:1 = server : keeper-turn : misc.

## 3. 기존 mechanism 재발견 — `with_test_env`

`eio_context.ml:63-76` 에 이미 snapshot/restore 패턴 존재:

```ocaml
let with_test_env ~net ~clock ~mono_clock ~sw f =
  Eio.Mutex.use_ro with_test_env_lock (fun () ->
    let snapshot = snapshot_state () in
    set_net net; set_clock clock; set_mono_clock mono_clock; set_switch sw;
    Fun.protect ~finally:(fun () -> restore_state snapshot) f)
```

- 의도: 테스트 격리. 한 번에 4-field 전부 swap, `with_test_env_lock` 으로 swap-restore 윈도우 직렬화.
- **race 한계**: swap 자체는 lock 안에서 직렬화되지만, lock *내부* 에서 `f` 가 실행되는 동안 *다른 fiber* 가 `get_switch_opt ()` 호출 시 swap 된 값을 봄. 단일 도메인 cooperative scheduling 에서도 fiber yield 가 일어나면 동시 가시성 발생.
- 테스트는 보통 단일 fiber + 동기 실행이라 안전. 프로덕션 `run_turn` 같이 *동시 dashboard fiber 와 같이 도는 환경* 에서는 §2.1 의 9 callsite 가 turn_sw 를 잘못 잡음.

## 4. 옵션 비교

### Option (1) — Naïve wrap (skip)

```ocaml
let run_turn ... =
  Eio.Switch.run @@ fun turn_sw ->
    <body>
```

`<body>` 내부 fiber 가 `Eio_context.get_switch_opt ()` 호출 시 여전히 root_sw 반환 → **wrap 무효**. 거부.

### Option (2) — `Eio_context.with_sw` (atomic swap, dynamic scope)

```ocaml
let with_sw sw f =
  Eio.Mutex.use_ro with_test_env_lock (fun () ->
    let prev = Atomic.get current_sw in
    Atomic.set current_sw (Some sw);
    Fun.protect ~finally:(fun () -> Atomic.set current_sw prev) f)

(* run_turn *)
Eio.Switch.run @@ fun turn_sw ->
  Eio_context.with_sw turn_sw (fun () -> <body>)
```

- **장점**: 기반 mechanism 이 이미 (`with_test_env`) 있으므로 4-field 중 sw 만 분리해 노출하면 됨. ~50 LoC.
- **race 위험**: §2.1 의 9 server/dashboard callsite 가 swap 윈도우 안에서 fork → premature termination. 단일 도메인이라도 fiber yield 가 일어나는 모든 await 지점에서 발생.
- **mitigation**: §2.1 callsite 들을 *명시적 root_sw 보관 reference* 로 분리 (e.g., `Eio_context.root_sw_ref : Eio.Switch.t option ref`, 서버 시작 시 1회 set, swap 영향 없음). 추가 ~30 LoC + 9 callsite refactor.
- **본질적 한계**: dynamic scope + global state. *원리적으로* 어디서 swap 발생 가능한지 caller 가 알 수 없어 디버깅 비용↑. 그러나 *현실적* 으로는 동작 가능.

### Option (3) — Fiber-local storage (Eio.Fiber)

Eio 0.x 기준 `Eio.Fiber.with_binding : 'a key -> 'a -> (unit -> 'b) -> 'b` 가 존재 (확인 필요, Phase C.1 에서 source 정독).

```ocaml
let sw_key : Eio.Switch.t Eio.Fiber.key = Eio.Fiber.create_key ()

let get_switch_opt () =
  match Eio.Fiber.get sw_key with
  | Some sw -> Some sw
  | None -> Atomic.get current_sw  (* fallback to root *)

(* run_turn *)
Eio.Switch.run @@ fun turn_sw ->
  Eio.Fiber.with_binding sw_key turn_sw (fun () -> <body>)
```

- **장점**: race-free by construction. fiber 가 자기 binding 만 봄. dashboard fiber 가 root_sw 에 살아 있는 한 자기 binding (없으면 fallback) 으로 root_sw 만 봄.
- **단점**: Eio.Fiber API 가 binding 을 지원하는지 (Eio 1.x) Phase C.1 확인 필요. 우리 cohttp-eio 6.1.1 + eio 0.x stack 에서 호환성 검증 필수.
- **추가 비용**: 26 callsite 그대로 유지 (`get_switch_opt` 내부 구현만 변경). ~80 LoC + Eio 버전 확인.

### Option (4) — 명시적 `~sw` propagation

26 callsite 의 caller chain 을 따라 `~sw:Eio.Switch.t` 인자를 propagate. 각 함수 signature 변경.

- **장점**: Eio 권고 best practice. 컴파일러가 누락 추적. anti-pattern (전역 atomic) 박멸.
- **단점**: signature 변경 transitive closure 가 *수십~수백* 함수. 1-2주 작업. 별도 RFC.

### Option (5) — Phase C 를 2 PR 로 분할 (★ 권장 ★)

**Phase C.0 (이번 PR, ~반일)**: 본 audit note + TLA+ spec + RFC §3.3 amend. wiring 없음.

**Phase C.1 (별도 PR, 결정 후)**: Option (2)/(3)/(4) 중 하나로 wiring.

## 5. 추가 race 시나리오 (Option (2) 채택 시)

T0: server 시작, root_sw set.
T1: dashboard fiber A 가 dashboard_cache.ml:314 의 stale-while-revalidate fork 시작. `get_switch_opt()` 호출 — root_sw.
T2: keeper fiber B 가 run_turn 시작, `with_sw turn_sw` 진입. `current_sw := turn_sw`.
T3: dashboard fiber A 가 *T2 이후* 두 번째 child fork (예: nested SWR refresh). `get_switch_opt()` 호출 — **turn_sw** ← 버그.
T4: run_turn 종료, `current_sw := root_sw`, `Eio.Switch.run` 종료, turn_sw close.
T5: T3 에서 fork 된 child fiber 가 turn_sw 에 attach 된 채 살아남음 → `Cancelled` 또는 FD leak.

이 시나리오는 §2.1 의 9 callsite 모두에 적용됨. 즉 *Option (2) 단독* 으로 wrap 도입하면 *새 종류의 버그* 가 생김. **Option (2) 채택 시 §2.1 callsite 9 개 root_sw_ref 분리 필수**.

## 6. 권장 wiring 결정 (Phase C.1, 사용자 결정 대기)

| | Option (2) atomic swap | Option (3) fiber-local | Option (4) explicit |
|---|---|---|---|
| 작업량 | 1-2일 (+ §2.1 refactor) | ~1일 (단 Eio.Fiber API 확인) | 1-2주 |
| race-free | △ (mitigation 필요) | ✓ | ✓ |
| 디버깅 cost | 중 | 저 | 저 |
| Eio 권고 부합 | △ | ◯ | ◎ |
| 후속 cleanup | §2.1 callsite 9개 refactor | 26 callsite 유지 가능 | 26 callsite 전부 변경 |
| Phase D pool 도입과 충돌 | 없음 | 없음 | RFC-0107 critical path 와 동시 신규 surface |

**Phase C.1 권장 순서**:
1. **먼저 Option (3) 의 Eio.Fiber API 가용성 확인** (Eio 0.x vs 1.x). 가용하면 (3) 1순위.
2. (3) 불가능 시 **Option (2) + §2.1 root_sw_ref 분리** 채택. 디버깅 부담은 audit note 로 documented.
3. (4) 는 별도 long-term RFC 로 분리. RFC-0107 critical path (Phase D pool) 와 무관.

## 7. Phase C.0 산출물

본 PR 에 포함:
1. `docs/rfc/RFC-0107-eio-context-switch-audit.md` (본 문서)
2. `specs/keeper-switch-hierarchy/KeeperSwitchHierarchy.tla` + `.cfg` + `-buggy.cfg`
3. `docs/rfc/RFC-0107-outbound-http-stack-consolidation.md` §3.3 amend (참조 추가)

본 PR 에 *포함하지 않음*:
- `keeper_agent_run.ml:196` 의 실제 wrap (Phase C.1)
- `Eio_context.with_sw` 또는 fiber-local key 신규 API (Phase C.1)
- 26 callsite refactor (Phase C.1 또는 별도 RFC)

## 8. 기존 패턴 — `try_provider.ml:406`

`lib/keeper/keeper_turn_driver_try_provider.ml:406` 의 `Eio.Switch.run (fun attempt_sw -> ...)` cascade attempt 패턴은 *작동 중*. 그 이유:

- `attempt_sw` 가 *명시적 인자* 로 try_provider 내부 함수 chain 에 전달됨 (Option (4) 의 작은 사례).
- 즉 **`get_switch_opt ()` 를 거치지 않음**.
- run_turn 레벨에서 동일 패턴을 흉내내려면 *run_turn body 내부 모든 함수* 가 `~sw` 받아야 함 → Option (4) 의 scope.

이 사실이 Option (3) (fiber-local) 의 매력을 높임 — 26 callsite 안 건드리고 attempt_sw 처럼 *암묵적 propagation* 만 추가.

## 9. 결론

- Phase C 의 "반일 작업" 가정은 *frame error*. 실제는 *전역 atomic vs fiber-local 결정* 이 핵심.
- 본 Phase C.0 는 evidence + TLA+ spec 만 commit. wrap 실제 도입은 Phase C.1 에서 Option 결정 후.
- **PR description 에 본 audit 첫 절 인용 + Option 결정 escalate 명시**.
