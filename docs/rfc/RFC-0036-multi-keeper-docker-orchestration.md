# RFC-0036: Multi-Keeper Docker Orchestration & Lifecycle Cleanup

- **Status**: Draft
- **Author**: vincent (with Claude Opus 4.7)
- **Created**: 2026-05-06
- **Drives**: closes verification report items #30, #32, #34 (single coupled track)
- **Related**:
  - `RFC-0002-keeper-state-machine.md` — terminal state semantics (Dead/Zombie)
  - `RFC-0003-keeper-composite-lifecycle.md` — composite observer extension point
  - `RFC-0006-keeper-surface-and-sandbox.md` — `docker_hardened` profile, current sandbox boundary
  - PR #13848 — P0/P1/P3 docker cleanup scaffolding (compose, prune, timers, tmp purge)

## 1. Problem

The 2026-05-07 verification report (`docker_cleanup_code_verification.md`) identifies three remaining gaps that PR #13848 cannot close because each one crosses architecture boundaries that need explicit design:

| # | Symptom | Mechanism |
|---|---------|-----------|
| 30 | Keeper transitions to `Dead`/`Zombie`; the in-process registry tombstone is reaped, but no Docker container is ever removed because keepers run as Eio fibers inside the single masc-mcp container | `Keeper_supervisor.cleanup_dead_tombstone` only touches in-memory registry + meta JSONL. There is nothing for it to talk to at the docker daemon level. |
| 32 | Subprocesses spawned by keepers (e.g., `keeper_bash` in `docker_hardened` mode → DinD container, or `keeper_shell` rg/cat) can outlive their parent if the keeper crashes mid-call | `Process_eio.reset_for_testing` exists, but it's a test helper for the worker pool. No production hook drains keeper-owned subprocess descriptors on Dead transition. |
| 34 | No `docker-compose.yml` per-keeper layout; smoke test (`keeper-docker-multikeeper-isolation-smoke.sh`) is the only place that runs `docker run` per keeper | The production architecture is "single container, many fibers." The smoke path proves isolation but is not the runtime model. |

**These three are one design problem, not three independent ones.** #30 is meaningless without a per-keeper container to remove (that's #34). #32 is the cleanup hook on which both #30's container removal and the existing fiber-cancellation path depend.

## 2. Goals / Non-Goals

**Goals**
- G1. Provide an opt-in `runtime_topology=multi-container` mode that runs each keeper in its own sandboxed container, gated on `Keeper_supervisor` FSM events.
- G2. Define a single `lifecycle_cleanup_hook : keeper_id -> Phase -> unit` extension point in `Keeper_supervisor` so #30 and #32 share the same plumbing (no parallel hook systems).
- G3. Make the `single-container` default unchanged for production. Multi-container is a host-level toggle, not a code-path replacement.
- G4. Preserve all RFC-0002 phase-transition invariants (terminal states still reject events; Dead is still a tombstone).

**Non-Goals**
- Replace `Keeper_registry` or `Keeper_supervisor` core. Lifecycle FSM stays exactly as-is; only the hook fires.
- Solve fleet-level scheduling (k8s/Nomad). This RFC stops at "compose can spawn N keeper containers locally."
- Multi-host distribution. Single host, possibly multiple keepers.
- Replace `docker_hardened` sandbox profile. Multi-container is orthogonal — a host can run `docker_hardened` keepers as fibers (today) or as containers (this RFC).

## 3. Design

### 3.1 Lifecycle cleanup hook (foundation, addresses #32)

`lib/keeper/keeper_supervisor.ml` exposes:

```ocaml
type cleanup_event =
  | Phase_transition of { from: Phase.t; to_: Phase.t }
  | Tombstone_reaped

type cleanup_hook = keeper_id:string -> cleanup_event -> unit

val register_cleanup_hook : cleanup_hook -> unit
```

Calls fire on:
- Every phase transition in `transition_to`, before the registry write commits.
- `cleanup_dead_tombstone` exit, after the registry unregister.

The hook is **synchronous, best-effort, non-throwing**. Implementations log + swallow exceptions; the supervisor never observes hook failure. This matches the same pattern as `Shutdown_hooks.run_all` (no timeout cliff that can preempt OCaml code). Hook list is `Atomic.t` ref-cell.

Default registration: a single hook that drains tracked subprocess pids (closes #32). Subprocess registration is added to `keeper_bash`, `keeper_shell`, and `keeper_fs_*` execution paths — every external `Eio.Process.spawn` records pid+keeper_id, the cleanup hook sends SIGTERM and then `waitpid`.

### 3.2 Multi-container topology (addresses #34)

New env knob `MASC_KEEPER_RUNTIME_TOPOLOGY` with values:
- `single-container` (default, current behavior — keeper = fiber)
- `container-per-keeper` (opt-in — keeper = docker container)

When `container-per-keeper`:
- `Keeper_supervisor.boot_keeper` calls `Docker_runtime.spawn_keeper_container ~keeper_id ~persona ~base_path` instead of starting a fiber.
- Container labels: `masc.keeper.id=<id>`, `masc.keeper.session=<server-uuid>`, `masc.keeper.runtime=container`.
- Returns a `keeper_handle` opaque type that wraps either `fiber_handle` (single) or `container_handle` (multi). All other supervisor ops route through this handle.

`docker-compose.multi-keeper.yml` (new file, NOT replacing the single-container `docker-compose.yml`):
- One service template + scaling instructions, OR
- One named service per keeper persona declared in `config/keepers/*.toml`.

Decision deferred to Phase B (see §4).

### 3.3 Dead → docker rm bridge (addresses #30)

In `container-per-keeper` mode, register a cleanup hook from `Docker_runtime`:

```ocaml
let docker_rm_hook ~keeper_id = function
  | Phase_transition { to_ = Phase.Dead | Phase.Zombie; _ } ->
    Docker_runtime.schedule_container_removal ~keeper_id ~grace:30s
  | Tombstone_reaped ->
    Docker_runtime.force_remove_if_exists ~keeper_id
  | _ -> ()
```

`schedule_container_removal` enqueues to a single-fiber queue so concurrent transitions don't issue racing `docker rm` calls. Removal uses `docker rm -f` only after the grace timeout; before that, `docker stop` (which sends SIGTERM honoring the new STOPSIGNAL contract from PR #13848).

In `single-container` mode the hook is a noop — no container exists to remove, but the in-memory tombstone path still runs.

## 4. Implementation Phases

| Phase | Scope | Touches | Estimated PRs |
|-------|-------|---------|---------------|
| A | Cleanup hook plumbing + subprocess pid tracking (closes #32 in single-container mode) | `lib/keeper/keeper_supervisor.ml`, `lib/keeper/keeper_subprocess_registry.ml` (new), call-site instrumentation in `keeper_bash`/`keeper_shell` | 2 PRs (foundation + instrumentation) |
| B | `Docker_runtime` module + topology env knob (no FSM changes; multi-container *option* only spawns, supervisor unaware) | `lib/docker_runtime.ml` (new), `bin/main_eio.ml` topology dispatch, `docker-compose.multi-keeper.yml` | 2 PRs (runtime + compose) |
| C | Dead/Zombie → docker rm hook wiring + container_per_keeper integration test | hook registration in topology bootstrap, `test/test_keeper_docker_lifecycle.ml` (new), TLA spec `KeeperDockerBridge.tla` (new) | 1 PR + 1 spec PR |
| D | Documentation + operator runbook | `docs/runbooks/multi-keeper-docker.md`, README pointer | 1 PR |

Phase A is non-architectural — it's a hook plumbing addition that single-container deployments benefit from immediately (subprocess leak prevention). Phases B+C+D are architectural; can be deferred until a host actually needs container-per-keeper.

## 5. Backward Compatibility

- Default `single-container` topology: no behavior change, no FSM change, no compose change.
- Hook registration is additive; existing code paths that don't register a hook see zero overhead (Atomic.get returns empty list).
- `docker_hardened` sandbox profile is unchanged; it's orthogonal to topology.
- Existing `keeper-docker-multikeeper-isolation-smoke.sh` continues to work; it's a smoke test, not the runtime path.

## 6. Risks / Mitigations

| Risk | Mitigation |
|------|------------|
| Hook callback throws → supervisor instability | Hook list is iterated under `try ... with _ -> log`. Supervisor never observes hook failure. Same pattern as `Shutdown_hooks.run_all`. |
| Subprocess pid registry leaks pids if keeper crashes between spawn and register | Spawn site uses `Fun.protect` to register-then-spawn-then-unregister-on-exit. Lost pids age out via OS process death detection in cleanup hook. |
| `docker rm -f` races with healthcheck or operator action | Single-fiber queue serializes removal; `docker rm` is itself idempotent on missing container (returns error code 1, swallowed). |
| Container-per-keeper × DinD nesting on `docker_hardened` keepers (DinD-in-DinD) | Out of scope for Phase B; Phase C decides whether to disallow that combination or document the requirement (host docker socket mount). |
| TLA spec coverage decay: RFC-0002 phase invariants vs new bridge | Phase C ships `KeeperDockerBridge.tla` mirroring the existing pattern (clean.cfg + buggy.cfg as in `KeeperOASAdvanced.tla`). |

## 7. Open Questions

1. Does `container-per-keeper` mode need its own admission controller, or can it reuse `keeper_turn_slot` semaphore? (RFC-0026 territory.)
2. How does `lib/cascade_routes` route turns when keepers are in different containers? Probably unchanged (HTTP → MCP socket), but worth confirming.
3. Multi-keeper compose: per-persona named services (declarative) vs `--scale keeper=N` (parameterized)? Phase B decision.

## 8. Migration Plan

1. PR #13848 lands (P0/P1/P3 cleanup scaffolding) — done.
2. Phase A foundation PR (this RFC's cleanup hook + subprocess registry).
3. Phase A instrumentation PR (call-site pid tracking).
4. Decide whether to proceed to Phase B based on host need (no rush — single-container default works).
5. If Phase B: ship `Docker_runtime` + compose template + topology knob (no FSM changes, easy revert).
6. Phase C: wire FSM hook to bridge, ship TLA spec.
7. Phase D: runbook.

## 9. Decision Criteria

This RFC is approved to proceed when:
- Phase A scope is acknowledged as non-architectural maintenance work.
- Phase B/C/D scope is acknowledged as architectural and can be deferred without blocking PR #13848 merge.
- Hook signature and topology env knob name are settled.

If the answer to "do we ever need container-per-keeper?" is "no, single container is enough," this RFC degrades cleanly to "ship Phase A only" — the cleanup hook still solves #32 even without #30/#34.
