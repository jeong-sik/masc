---
rfc: "0125"
title: "Bounded subprocess discipline: per-call Switch scope + Fiber.first timeout race"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0072", "0097", "0101", "0106"]
implementation_prs: []
---

# RFC-0125 — Bounded subprocess discipline

## 1. Context

2026-05-17 production observation. 16 keeper 중 5 (`taskmaster`, `nick0cave`, `tech_glutton`, `janitor`, `masc-improver`) 가 `last_social_transition_reason = failure:run_error` 상태로 일어나지 못함. `sangsu` 는 turn 진행 중 `stale_turn_timeout(mid_turn_no_progress active=312s since_progress=307s threshold=300s last=cascade_state)`. `masc-improver` 는 cascade resolve 후 첫 provider call 에서 `oas_timeout_budget(budget_sec=276.85 source=adaptive_wall_clock_retry)`.

공통 시그너처: `sandbox_profile = docker` + 한 turn 안에서 long-running subprocess (LLM provider HTTPS, docker exec) 가 응답 없음.

기존 처방 = `lib/keeper/keeper_supervisor.ml:1578` `Keeper_turn_slot.force_release_holder_for` — "bounded over-release of the reactive_turn_semaphore". 주석 자체가 *"only path that drains the semaphore short of a process restart"* 라고 자인한다. **process 자체는 살아있고 OS 차원에서 점유 중**. RFC-0097 (container reuse, MERGED) 도 이 stuck 을 풀지 못한다 — 그건 spawn churn 의 root 였고, 지금은 spawn 된 process 의 *lifetime* root 다.

## 2. Eio 공식 사실 (factual base)

`https://ocaml.org/p/eio/latest/doc/Eio/Process/` 명시:

> "The child process will be sent `Sys.sigkill` when the switch is released."

`https://ocaml.org/p/eio/latest/doc/Eio/Cancel/` 명시:

> "System calls and blocking C functions do not automatically observe Eio's cancellation model."

`https://ocaml.org/p/eio/latest/doc/Eio/Fiber/` 명시:

> "The switch cannot finish until the forked fiber completes."

`https://ocaml.org/p/eio/latest/doc/Eio/Switch/` 명시:

> `on_release` handlers "run within a cancellation-protected context, preventing interruption during cleanup."

이 4개 fact 의 합성:

1. `Eio.Process.spawn ~sw` 한 process 는 **`sw` 가 release 될 때만** 자동 `Sys.sigkill` 받는다.
2. process 의 `Eio.Process.await` 는 OS-level blocking — Eio Cancel 신호를 직접 받지 않는다.
3. fiber 가 `await` 안에서 stuck 이면 그 fiber 가 attach 된 switch 는 끝나지 않는다.
4. 결과: process 가 hang → fiber 가 unresolved → switch 가 finish 안 됨 → 자동 SIGKILL 영원히 발동 안 됨.

**Cancel 으로 process 를 죽이지 못한다. Switch 의 *scope 종료* 만이 process 를 죽인다.** 따라서 *bounded scope* 가 정답이다.

## 3. Problem (코드 site)

`lib/process/process_eio.ml:454-507` 의 두 함수:

- `spawn_and_drain_stdout ~sw pm ~cwd ?env ?stdin_source argv stdout_buf`
- `spawn_and_drain_both ~sw pm ~cwd ?env ?stdin_source argv stdout_buf stderr_buf`

두 함수의 결함:

1. **caller 의 `~sw` 를 그대로 spawn 에 attach** — `Eio.Process.spawn ~sw pm` (line 457, 484). caller sw 는 보통 keeper turn 또는 keeper lifetime — long-lived. process 자동 SIGKILL 영원히 발동 안 됨.
2. **inner `Switch.run` scope 부재** — process 의 lifetime 이 caller sw 의 lifetime 과 묶임. unbound.
3. **`timeout_sec` 파라미터 부재** — `with_unix_capture` (Unix fallback path, line 438) 는 받지만 Eio-native path 는 안 받음. 즉 Eio path = unbounded execution.

이 결함이 docker exec / LLM HTTPS client / git/gh subprocess 모두에 전파된다 (`keeper_docker_client_real.ml:245/251/273/456` 의 `gated_argv_with_status_split` 가 이 두 함수에 의존).

## 4. Proposed approach

### 4.1 Helper module (SSOT)

`lib/bounded_proc/bounded_proc.{ml,mli}`:

```ocaml
(** Run [argv] as a subprocess with hard wall-clock bound. Inner
    [Switch.run] scope ensures the process is SIGKILLed when the timeout
    fiber wins the race, regardless of whether the process honoured any
    earlier cancellation signal.

    Eio guarantees: per https://ocaml.org/p/eio/latest/doc/Eio/Process/
    "The child process will be sent Sys.sigkill when the switch is
    released." This helper relies on that single invariant. *)
val with_bounded_run :
  clock:_ Eio.Time.clock ->
  process_mgr:_ Eio.Process.mgr ->
  cwd:_ Eio.Path.t ->
  ?env:string array ->
  ?stdin_source:_ Eio.Flow.source ->
  timeout_s:float ->
  string list ->
  [ `Done of Unix.process_status * string * string
  | `Timeout of float (* elapsed *)
  ]
```

구현 핵심 (verifiable):

```ocaml
let with_bounded_run ~clock ~process_mgr ~cwd ?env ?stdin_source
    ~timeout_s argv =
  let start = Eio.Time.now clock in
  Eio.Switch.run @@ fun proc_sw ->
    let stdout_buf = Buffer.create 4096 in
    let stderr_buf = Buffer.create 1024 in
    let stdout_r, stdout_w = Eio.Process.pipe ~sw:proc_sw process_mgr in
    let stderr_r, stderr_w = Eio.Process.pipe ~sw:proc_sw process_mgr in
    let proc =
      Eio.Process.spawn ~sw:proc_sw process_mgr ~cwd ?env
        ?stdin:stdin_source ~stdout:stdout_w ~stderr:stderr_w argv
    in
    Eio.Flow.close stdout_w;
    Eio.Flow.close stderr_w;
    Eio.Fiber.first
      (fun () ->
        Eio.Time.sleep clock timeout_s;
        `Timeout (Eio.Time.now clock -. start))
      (fun () ->
        Eio.Fiber.both
          (fun () ->
            Eio.Flow.copy stdout_r (Eio.Flow.buffer_sink stdout_buf);
            Eio.Flow.close stdout_r)
          (fun () ->
            Eio.Flow.copy stderr_r (Eio.Flow.buffer_sink stderr_buf);
            Eio.Flow.close stderr_r);
        let status = Eio.Process.await proc in
        `Done (status, Buffer.contents stdout_buf, Buffer.contents stderr_buf))
```

핵심 invariant:

- `proc_sw` 는 helper 내부에만 존재. caller sw 와 독립.
- `Fiber.first` 가 끝나는 순간 (Done 또는 Timeout) `Switch.run` block 종료 → `proc_sw` release → spawn 된 process 자동 SIGKILL (Eio 공식 보장).
- Timeout 분기는 `Sys.sigterm` 보내고 grace period 기다리지 않는다. 즉시 scope 종료 → 즉시 SIGKILL. 사용자 keeper 는 fail-fast 가 retry 보다 가치 크다.

### 4.2 Migration plan (phased, 사이트별 PR)

| Phase | 범위 | 산출 | PR 크기 |
|---|---|---|---|
| **P0** (본 RFC body) | helper module 추가 + unit test (TLA+/property 아닌 OCaml test) | `lib/bounded_proc/` + `test/test_bounded_proc.ml` | ~200 LoC |
| **P1** (canary) | `process_eio.spawn_and_drain_{stdout,both}` 를 helper 기반으로 재작성 + `?timeout_sec` 시그너처 추가 (caller 전파) | `lib/process/process_eio.ml` patch + caller 수정 | ~150 LoC |
| **P2** | `keeper_docker_client_real` 가 모든 `docker exec`/`docker run` 호출에 keeper meta `per_provider_timeout_s` 전파 | 사이트별 patch | ~100 LoC |
| **P3** | `cascade_event_bridge` LLM HTTPS client 호출에 attempt-level budget 전파 | provider 별 patch | ~150 LoC |
| **P4** | `keeper_supervisor` 의 fiber fork 도 `Fiber.first (max_turn_timer) (heartbeat_loop)` 패턴 적용 → keeper-level watchdog | supervisor patch | ~100 LoC |
| **P5** | `force_release_holder_for` deprecation — P1~P4 적용 후 *fiber_unresolved* 발생률 측정 → 0 이면 helper removal | semaphore over-release 제거 | ~50 LoC |

각 Phase 의 PR 은 root-fix loop 와 분리하여 *atomic* 으로 머지한다.

### 4.3 Non-scope

- `Eio.Domain_manager` 기반 isolation (keeper-per-domain) — 별도 RFC 후보. 본 RFC 는 fiber-level scope discipline 만.
- Actor model migration (riot, eio-actor) — 같은 이유로 별도.
- RFC-0106 (cancel-safe try-with) 와 orthogonal — 0106 은 *cancel 예외가 도달했을 때 막지 마라*, 본 RFC 는 *cancel 예외가 도달하지 못해도 scope 종료로 죽여라*.
- Cross-process race protection (PIPE_BUF, fcntl lock) — RFC-0107 (jsonl_atomic) 가 다룬다.

## 5. Acceptance

P0 머지 조건:

1. `Bounded_proc.with_bounded_run` 가 Alcotest 4 케이스 통과:
   - 정상 종료 (timeout 안 발동)
   - timeout 발동 후 process 가 OS 차원에서 종료됨 (`Unix.waitpid` 또는 `/proc` 검증)
   - stdout/stderr 모두 capture 됨
   - stdin 주입 동작
2. `dune build --root . @check` PASS.
3. `ocamlformat --check` PASS.

P1+ 머지 조건 (각 Phase 별):

1. 해당 site 의 기존 test 가 동일 동작 (regression 0).
2. timeout 발동 시 process 가 OS 차원에서 사라지는 integration test (`pgrep -f <argv>` 0 결과).
3. Prometheus `metric_keeper_oas_timeout_budget_watchdog_termination` 30일 trend 감소.

## 6. Evidence

- sangsu keeper status (`masc_keeper_status sangsu`, 2026-05-17 11:08Z):
  - `blocker.klass=stale_turn_timeout`, `detail=mid_turn_no_progress(active=312s since_progress=307s threshold=300s last=cascade_state)`
  - `last_reason: unified:tools=[keeper_bash×15]`
- masc-improver keeper status (2026-05-17 11:16Z, after cascade fix):
  - `blocker.klass=oas_timeout_budget`, `budget_sec=276.85, keeper_turn_timeout_sec=600, source=adaptive_wall_clock_retry`
- 5/16 keeper `failure:run_error` (taskmaster, nick0cave, tech_glutton, janitor, masc-improver).
- `keeper_supervisor.ml:1567-1577` 주석 — 자체 root 자인:
  > "when a keeper fiber is stuck inside an LLM subprocess that does not honour [Eio.Cancel.Cancelled], the natural [Fun.protect] release in [with_keeper_turn_slot] never runs and its [reactive_turn_semaphore] permit is leaked."

## 7. Anti-pattern self-check

| 시그너처 | match? | 근거 |
|---|---|---|
| Counter-as-fix | No | `force_release_holder_for` 는 counter 아니라 semaphore release. helper 는 process 자체를 죽임 (Eio 공식 보장) |
| String classifier | No | 타입 boundary 만 |
| N-of-M | No — risk | P1 = `spawn_and_drain_{stdout,both}` 두 함수 *동시*. P2~P4 는 별 PR 이라 sites 누락 가능 → 매 Phase 검수 시 `rg 'Eio\.Process\.spawn'` 결과로 잔존 carve-out 확인 |
| Cap/cooldown/dedup/repair | No | `Switch.run + Fiber.first` 는 *bounded scope* 패턴. cap 은 carrier value 를 강제 *변경*, scope 는 *lifetime 종료*. Eio 의 공식 idiom (`Switch.run` 자체가 bounded scope) |
| Test backdoor | No | helper 자체에 test-only path 없음 |

## 8. Open questions

- helper 의 timeout 발동 시 stdout/stderr buffer 의 *부분 결과* 를 caller 에 surface 해야 하는가? 현재 시그너처는 `\`Timeout of float` 만 — diagnosis 용으로 partial buffer 도 넘겨야 할 수도. P0 review 시 결정.
- supervisor 의 `Fun.protect ~finally` (line 401) 를 `Switch.on_release` 로 migrate 하는 것은 P4 에 포함시킬지, 별도 RFC 로 분리할지. memory `software-development.md` 의 "Fun.protect는 finally 예외가 원래 예외를 덮을 수 있음" 원칙과 직결.
- `with_unix_capture` (Unix fallback path) 도 같은 invariant 가 적용되어야 하는가? `Stdlib.Unix.fork+execv` 기반이라 SIGKILL 직접 보내야 — Phase 별도.

## 9. Related

- RFC-0072 — keeper sub-FSM transitions typed.
- RFC-0097 — long-running container reuse (MERGED 2026-05-17). 본 RFC 는 그 *후* 의 subprocess lifetime 을 다룬다.
- RFC-0101 — (해당 영역).
- RFC-0106 — cancel-safe try-with discipline (Draft). 본 RFC 와 orthogonal: 0106 = cancel 예외 도달 시 막지 마라, 본 RFC = cancel 예외 도달 못 해도 scope 종료로 죽여라.

## 10. References

- Eio.Switch: https://ocaml.org/p/eio/latest/doc/Eio/Switch/index.html
- Eio.Process: https://ocaml.org/p/eio/latest/doc/Eio/Process/index.html
- Eio.Cancel: https://ocaml.org/p/eio/latest/doc/Eio/Cancel/index.html
- Eio.Fiber: https://ocaml.org/p/eio/latest/doc/Eio/Fiber/index.html
- OCaml 5.4 manual: https://ocaml.org/manual/5.4/index.html
