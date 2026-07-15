# RFC-0290: Generic keeper background-work tool (spawn → wake-on-completion)

- Status: Draft
- Author: vincent (+ Claude Opus 4.8)
- Created: 2026-06-24
- Related: RFC-0020 (hint signal / data channel separation), RFC-0252 / RFC-0266 (masc_fusion — the existing instance of this pattern), RFC-0286 (exec / keeper boundary ownership), RFC-0287 (ws-direct, MASC-owned stack)
- Research basis: `knowledge/research/2026-06-24-keeper-background-wait-tool.md`
- Implementation PRs: (Phase 1 = this RFC's PR)

## 1. Summary

Add a keeper-callable tool that starts an arbitrary unit of background work, returns a handle immediately, and delivers the result by waking the keeper through the existing stimulus queue when the work completes. The keeper does not block its turn fiber waiting; it parks in the normal heartbeat sleep and resumes on the wake path it already uses for board signals and fusion completions.

This is **not a new capability**. The exact mechanism already ships once, as `masc_fusion` (RFC-0252/0266): `register_running` before fork, `Eio.Fiber.fork ~sw` on the server-lifetime switch, immediate `{status: "fusion_started", run_id}` return without awaiting, and completion delivered via `wakeup_keeper ~stimulus:(Fusion_completed ...)` or polled via `masc_fusion_status`. The fusion implementation is hardwired to judge-panel orchestration. This RFC generalizes the same fire-and-forget + wake skeleton into a task-generic surface, so background work other than fusion (subprocess execution, long-running tool calls) can use it without each caller reinventing the fork/registry/wake plumbing.

Honest framing: because the pattern already exists and is exercised in production by fusion, the risk here is not "does the approach work" but "does generalizing it past fusion's narrow shape (LLM-only fibers, bounded panel count) reintroduce resource bugs that fusion's narrowness happened to avoid." Section 7 names three such bugs found by adversarial review of the design and makes fixing them acceptance gates, not follow-ups.

## 2. Motivation

### 2.1 There is exactly one background-work pattern, and it is not reusable

A keeper turn is synchronous within a single sustained fiber (`keeper_keepalive.ml:650` forks one fiber per keeper; `keeper_heartbeat_loop.ml:738` is its `let rec loop ()`). Any work a tool does inline blocks that keeper's reactivity until it returns. The only escape hatch that does not block is `masc_fusion`, and its fork/registry/wake code lives inside `fusion_tool.ml` bound to `Fusion_orchestrator`. A keeper that wants to run, say, a long shell command and continue reacting to the board has no generic equivalent — it either blocks the turn (deaf to board/mention for the duration) or there is no tool at all.

### 2.2 The "wait" the user wants is already the heartbeat wake, not a new await

The intuition "run it in the background, then wait for it" maps onto two very different OCaml/Eio shapes:

- **Fiber blocking await** — the turn fiber calls `Eio.Promise.await`. This holds the keeper's single fiber. During the await the keeper does not re-enter its sleep loop, so it cannot consume board signals: head-of-line blocking by construction. `Promise.await` does yield the domain (other keepers are not starved, `keeper_supervisor_launch.ml:127`), but the *calling* keeper goes deaf.
- **Turn-yielding wake** — the tool returns immediately, the turn ends, the keeper parks in `interruptible_sleep` (`keeper_keepalive_signal.ml:235-261`), and completion sets `fiber_wakeup` (`keeper_registry.ml:357/365/385`) plus enqueues a stimulus. The keeper resumes on its next loop iteration with the result as turn input.

The second shape is what fusion already does and what RFC-0020 (hint signal `fiber_wakeup` vs data channel `Keeper_registry_event_queue`) is built for. This RFC adopts the second shape as the default and treats blocking await as a non-goal for v1 (§3).

### 2.3 Generalizing fusion is "mechanical" only if the resource model is identical — it is not

Fusion forks LLM judge fibers without owning OS file descriptors; transport backpressure belongs to the provider/runtime boundary. A generic background tool that runs subprocesses via `Autonomy_exec.run` (`cdal_runtime/autonomy_exec.ml:295`) does not inherit that resource model: the subprocess pipe FDs are registered with `Eio.Switch.on_release ~sw` (`autonomy_exec.ml:231-232`). Forking such work onto the server-lifetime root switch without correction leaks FDs for the server's whole lifetime. The generalization is sound only with the §5 switch-isolation design.

## 3. Non-goals (explicitly excluded from v1)

- **Inline blocking await as the default path.** A keeper turn must not `Eio.Promise.await` a background job as its primary way to get the result. (An optional short-budget inline mode may be added later behind a hard single-digit-second clamp; not in v1.)
- **A `task_wait`-style blocking re-await tool.** Re-awaiting a handle from a later turn requires a durable result store that survives registry pruning. The fusion registry prunes completed entries at `max_completed_retained=64` (`fusion_run_registry.ml:35,47-53`); a `wait` tool over it would silently lose results. Deferred until a durable store is specified.
- **Routing LLM/agent sub-jobs through OAS `async_agent`.** The research could not read the OAS `async_agent`/`approval` API (reader failed twice on transport errors). Any "LLM sub-jobs reuse OAS async_agent" claim is unverified and out of scope; v1 covers the subprocess job kind only.
- **Touching the OAS boundary.** OAS must not learn about `wakeup_keeper`, the keeper registry, the board, or the event queue. The result→wake bridge lives only in the MASC tool fiber's terminal callback (§5.4).

## 4. Surface inventory

### 4.1 New stimulus variant (Phase 1)

`Keeper_event_queue.stimulus_payload` (`keeper_event_queue.mli:54-65`) is a closed sum that already carries `Fusion_completed of fusion_completion`. Add:

```
| Bg_completed of bg_job_completion
```

where `bg_job_completion` is a typed record (`run_id`, `kind`, `outcome : Ok of string | Failed of string`, timestamps). No string-prefix encoding, no JSON round-trip through a string field.

### 4.2 New tools (Phase 3)

- `masc_bg_spawn { kind; payload }` → `{ ok; run_id }` | `{ ok = false; reason }`. Fire-and-forget. `kind` is a closed sum (v1: `Subprocess`); unknown `kind` is rejected (`ok = false`), never defaulted.
- `masc_bg_status { run_id? }` → keeper-scoped list/lookup over the generic run registry (mirrors `masc_fusion_status`).

No blocking-wait tool in v1 (see §3).

## 5. Design

### 5.1 Phasing

- **Phase 1 (this RFC's PR): wake path only.** Add the `Bg_completed` stimulus variant (§4.1) and fill every exhaustive consumer. No registry, no fork, no subprocess. The value is that the compiler now proves the completion type is handled everywhere a stimulus is matched, before any executor exists.
- **Phase 2: generic run registry.** A `Bg_run_registry` modeled on `fusion_run_registry` (Atomic + CAS, server-lifetime). The removed provider-admission mechanism must not be reused as a scheduler or capacity gate.
- **Phase 3: spawn tool + subprocess executor with FD isolation.** Wires `masc_bg_spawn` to `Autonomy_exec.run` with the real signature and the inner-switch FD fix (§5.2).

### 5.2 Switch selection and FD isolation (fixes §7 P0①)

Background work must outlive the turn, so it forks on the server-lifetime switch from `Eio_context.get_root_switch_opt()` — never the turn-scoped `ctx.sw`, which is cancelled when the turn ends (`keeper_tool_in_process_runtime.ml:392-399`). If the root switch is unavailable, `masc_bg_spawn` returns `ok = false` rather than forking on a wrong switch.

To prevent the subprocess pipe FDs from accumulating on the server-lifetime switch for the process lifetime, the executor body is wrapped in its own `Eio.Switch.run`, and that inner switch is passed to `Autonomy_exec.run`. On command completion the inner switch releases (running its `on_release` FD cleanup); only the fiber's own lifetime is bounded by the root switch. The root switch holds fibers, not FDs.

### 5.3 Concurrency cap (fixes §7 P0②)

A per-keeper and a global in-flight semaphore, sized by `MASC_BG_MAX_INFLIGHT` as an SSOT constant in `env_config_keeper.ml` (not a scattered literal). On cap exhaustion `masc_bg_spawn` returns `ok = false` with a backpressure reason. It does not silently queue and it does not just count drops — visibility without backpressure is the telemetry-as-fix anti-pattern (CLAUDE.md workaround bar); the cap is the backpressure.

### 5.4 Terminal-once and cancellation (mirrors fusion's verified invariant)

Each run carries a `terminal` flag settled by `Atomic.compare_and_set`. The fiber body, on every exit:

- success / failure (non-`Cancelled`): CAS-settle terminal, `mark_completed`, enqueue `Bg_completed` via `wakeup_keeper ~stimulus` — exactly once.
- `Eio.Cancel.Cancelled`: CAS-settle terminal, `mark_completed` in-memory only, **re-raise** (Eio contract), skip the suspending broadcast to avoid shutdown-cascade deadlock (mirrors `fusion_tool.ml:124-129`).
- all other exceptions: caught in the fiber body, recorded as `Failed`, never propagated to the root switch (propagation would fail the root switch and kill the gateway — the fork-fault-isolation hazard).

This is the same terminal-delivery discipline as the callback-to-blocking bridge contract (RFC-0287 follow-up): a terminal signal is delivered on every exit, exactly once.

### 5.5 Double-delivery guard (fixes the poll+wake race)

Because results are reachable by both wake (stimulus) and poll (`masc_bg_status`), the registry entry carries a typed `consumed` state transitioned by CAS. The heartbeat drain (`collect_keepalive_board_events`) and a poll read cannot both deliver the same completion as actionable turn input. The guard is a typed registry transition, not a counter or a substring check.

## 6. Acceptance criteria

- **Stimulus exhaustiveness (Phase 1):** adding `Bg_completed` and removing any one consumer arm fails `dune build` with a non-exhaustive match. Proven by construction; no test backdoor.
- **Terminal exactly-once:** a unit test drives the four exit branches (success, failure, cancellation, unexpected exception) and asserts exactly one terminal delivery per run and no propagation past the fiber body.
- **FD non-leak:** spawn N subprocess jobs to completion; assert the server process open-FD count returns to baseline (within a fixed delta) — pins the §5.2 inner-switch fix against regression.
- **Cap rejection:** with `MASC_BG_MAX_INFLIGHT` set low, the (cap+1)-th spawn returns `ok = false` with a backpressure reason and forks no fiber.
- **Wake gating:** `wakeup_keeper ~stimulus:(Bg_completed ...)` enqueues and flips `fiber_wakeup` when the keeper phase is Running, and drops when not-Running (`keeper_keepalive_signal.ml:272-283`) — the drop is asserted as intended behavior, with §7 R3 documenting the loss window.
- **No real signature drift:** the executor calls `Autonomy_exec.run ~sw ~clock ~config ~argv ~timeout_s` (Result record return), verified against `cdal_runtime/autonomy_exec.ml:295`, not an assumed signature.

## 7. Risks

- **P0① root-switch FD leak.** `Autonomy_exec.run` registers pipe FDs with `on_release ~sw` (`autonomy_exec.ml:231-232`); on the server-lifetime switch these never release until shutdown. Mitigation: §5.2 inner-switch wrap + the §6 FD non-leak test. This is the single highest-risk item and the reason Phase 3 is last.
- **P0② unbounded concurrency / scheduler starvation.** No cap means ~15 keepers × unbounded spawns × `Eio_unix.run_in_systhread` waitpid (`autonomy_exec.ml:310`) saturate the systhread pool. Mitigation: §5.3 cap with rejection. Note: adding more domains is not a fix (keepers are scheduler-bound, not core-bound).
- **R3 not-Running orphan window.** If the keeper is paused, in succession, or dead when a job completes, the `Bg_completed` stimulus drops. v1 treats this as intended (the keeper rereads state on resume); a durable result store is deferred with the `task_wait` non-goal. Documented so it is not mistaken for a delivery bug.
- **R4 behavior/observability gap.** No eval asserts on background-job outcomes yet. v1 ships the mechanism and the unit/FD/cap tests above; outcome-quality measurement is a separate harness concern.
- **R5 OAS boundary, checkpoint write contention.** Unverified: whether a root-switch task fiber and the turn fiber can race on checkpoint read/write. v1's subprocess jobs do not touch keeper checkpoints, sidestepping this; revisit before any in-process LLM job kind is added.

## 8. Rollout

1. Phase 1 PR: `Bg_completed` stimulus variant + consumer arms + the exhaustiveness and wake-gating tests. Behaviorally inert (nothing emits the stimulus yet); pure type-level groundwork. Low risk, mergeable alone.
2. Phase 2 PR: `Bg_run_registry` + `MASC_BG_MAX_INFLIGHT` cap + cap-rejection test.
3. Phase 3 PR: `masc_bg_spawn`/`masc_bg_status` + subprocess executor with §5.2 isolation + FD-non-leak and terminal-once tests.

Each phase is independently revertible. Phase 1 carries no runtime behavior change.

## 9. Why this is not a workaround

Checked against the CLAUDE.md workaround signatures:

- Not telemetry-as-fix: the cap (§5.3) applies backpressure (rejection), it does not merely count drops.
- Not a string classifier: completion is a closed-sum stimulus variant (§4.1), exhaustively matched; `kind` is a closed sum with unknown rejected, not defaulted.
- Not an N-of-M patch: the fork/registry/wake plumbing is extracted into one generic path, not copied per caller.
- Caps/terminal-once are typed transitions (CAS), not cooldown/dedup string hacks.

`Autonomy_exec` runs arbitrary argv and sits adjacent to the keeper-sandbox/credential boundary (RFC-0286), which is why this work is gated on this RFC rather than landing as a direct PR.
