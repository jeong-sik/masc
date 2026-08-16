---
rfc: "0213"
title: "Keeper sandbox/playground isolation model (fix sandbox_repo_not_ready + macOS-viable containment)"
status: Draft
created: 2026-06-03
updated: 2026-06-03
author: jeong-sik
supersedes: []
related: ["0001", "0208"]
implementation_prs: []
---

# RFC-0213 — Keeper sandbox/playground isolation

- Status: Draft. Triggered by a production failure (`sandbox_repo_not_ready`).
  Touches guarded subsystems (`lib/keeper/keeper_sandbox*`, `keeper_shell_*`,
  `lib/repo_manager/`) → RFC + human review required.
- Date: 2026-06-03.
- Builds on: RFC-0208 (3-layer shell exec authorization), RFC-0001
  (silent-substitution anti-pattern).
- **Currency caveat (evidence policy):** §3 competitive comparison is from model
  knowledge (cutoff Jan 2026), NOT freshly verified — the web-research pass for
  this RFC was lost to a session limit. Treat §3 as a design lens to re-verify,
  not as current product fact. §1–§2 (current masc model) are code-grounded.

## 0. Summary

A per-keeper playground at `.masc/playground/<keeper>/repos/<repo>` requires each
repo path to be an independent git checkout; a keeper's nested
`.worktrees/task-630` was not (`git_toplevel=<none>`), so the path gate rejected
all exec there (`sandbox_repo_not_ready`). The immediate fix is the git
provisioning model (§4-A). The deeper question — what isolation the `local`
profile actually provides — is the durable design (§4-B): today `local` is a
path-string gate on the host, not OS-level containment. The binding constraint
on the durable answer is that masc runs on **macOS (M3 Max)**, where the
Linux microVM/namespace primitives most agent-sandbox products use are
unavailable.

## 1. Problem (verified)

Production log (2026-06-03), keeper `umberto`:

```
tool=Execute (ls repos/masc/.worktrees/task-630)
error: sandbox_repo_not_ready: sandbox path is under repos/masc, but
  /Users/.../.masc/playground/umberto/repos/masc/.worktrees/task-630
  is not an independent git checkout (git_toplevel=<none>). Repair or reclone.
then: shell_ir path_reject keeper=umberto reason=sandbox_repo_not_ready
```

- Emitter: `lib/keeper/keeper_tool_execute_path.ml` `repo_cwd_not_ready_error`
  (`~repo_name ~path_root ~git_toplevel`), guarded by the readiness probe in
  `lib/playground_repo_readiness.ml` (runs `git rev-parse --show-toplevel`;
  `top.ok=false` → not ready).
- The check is correct in intent: a cwd under `repos/<repo>` must be a real
  checkout. It fired because a nested `.worktrees/task-630` inside the
  playground is not an independent checkout (no resolvable `git_toplevel`).
- The "Repair or reclone" remediation is named but (per audit) appears to have
  no automatic path — the keeper is just blocked.

## 2. Current model (as-built, code-grounded)

- **Provisioning:** each keeper gets `.masc/playground/<keeper>/repos/<repo>`.
  The telemetry shows `sandbox_profile=local`, `sandbox_root=.masc/playground/<keeper>/`,
  `allowed_paths=[".masc/playground/<keeper>/"]`.
- **Exec authorization (RFC-0208, 3 layers):** (1) risk-envelope pre-gate
  (`Shell_ir_risk.classify` → destructive/readonly), (2) `gate_typed`
  (allowlist + path + sandbox), (3) sandbox backend. The path gate is where
  `sandbox_repo_not_ready` is raised.
- **Sandbox profiles:** `local` vs container (Docker). `keeper_sandbox_read_backend.ml`
  mounts the repo read-only into a container path for the Docker profile;
  `keeper_sandbox_containment.mli` distinguishes local keepers (no-op containment)
  from container keepers. **Honest boundary:** for `local`, "containment" is
  path-string checking on the host — there is no kernel-enforced filesystem or
  process isolation. A tool path that bypasses the gate, or any host-level
  effect, is not confined.

Boundary classification (per CLAUDE.md product-boundary discipline):
- Deterministic: typed input, BasePath path jail, and sandbox confinement only.
- The host exposure: `local` profile = no OS confinement (the gap).

## 3. Competitive comparison (currency-caveated — re-verify)

| Product / primitive | Isolation primitive | Workspace/git model | Escape prevention | macOS-viable? |
|---|---|---|---|---|
| Claude Code (bash sandbox) | macOS `sandbox-exec`/seatbelt SBPL + Linux bubblewrap | host workspace, path allowlist | kernel FS/network allowlist | **yes (native seatbelt)** |
| OpenAI Codex CLI | seccomp/landlock (Linux); sandbox-exec (macOS) | host workspace | syscall + FS scoping | partial (macOS via seatbelt) |
| E2B | Firecracker microVM | per-session VM, provisioned FS | hardware VM boundary | **no (Linux/KVM)** |
| Modal sandboxes | gVisor / microVM | remote container/VM | userspace-kernel / VM | **no (Linux)** |
| Daytona | OCI containers / devcontainers | per-workspace container | container namespace | via Docker VM only |
| Devin (Cognition) | cloud Linux VM per agent | remote checkout | full VM | **no (remote Linux)** |
| Firecracker | KVM microVM | provisioned rootfs | VM boundary | **no (needs /dev/kvm)** |
| gVisor | userspace kernel (ptrace/KVM) | container | syscall interception | **no (Linux)** |
| Docker/OCI | namespaces+cgroups | container mount | namespace isolation | via Docker Desktop Linux VM (heavy) |
| nsjail / bubblewrap | Linux namespaces + seccomp | bind-mounted FS | namespace + seccomp | **no (Linux)** |
| macOS `sandbox-exec` (seatbelt) | kernel SBPL profile | host FS, profile-scoped | kernel FS/network deny | **yes (native, API deprecated but functional)** |

**Key constraint:** the strongest isolation in the ecosystem (Firecracker, gVisor,
namespaces) is **Linux-only**. On the masc host (macOS M3 Max) the only
*native* OS confinement is `sandbox-exec`/seatbelt; everything else requires
either a Docker-provided Linux VM (heavy, per-keeper) or moving keepers to a
remote Linux fleet.

## 4. Design options

**A — Fix the git provisioning (immediate, fixes the error).**
Make each per-keeper repo under `.masc/playground/<keeper>/repos/<repo>` an
*independent checkout*: either a per-keeper/per-task `git clone` (or
`git worktree add` that produces a valid linked `.git`), so
`git rev-parse --show-toplevel` resolves. Add a real "repair" path (re-provision
on `git_toplevel=<none>` instead of hard-blocking). Resolves
`sandbox_repo_not_ready`. Adds **no** isolation — `local` stays host-level.

**B — Real confinement viable on macOS (durable target).**
Replace the `local` profile's path-string gate with kernel-enforced confinement:
- **B1 — `sandbox-exec`/seatbelt profile per keeper:** generate an SBPL profile
  scoping FS read/write to the keeper's `sandbox_root` + deny network per
  `network_mode`. Native, low overhead. Risk: the `sandbox_exec` API is
  deprecated by Apple (still functional); future macOS could remove it.
- **B2 — Docker-per-keeper:** run each keeper's exec in a container with the
  playground bind-mounted. Stronger + portable, but requires Docker Desktop (a
  Linux VM) on the host — higher startup + memory cost per keeper.

**C — Off-host microVM (strongest, not macOS-native).**
Per-keeper Firecracker/gVisor microVM (E2B-style). Strongest isolation but
Linux-only → keepers move off the M3 Max to a remote Linux fleet (network,
latency, cost). Only sensible if/when keeper execution is relocated off-host.

## 5. Recommendation (trade-offs stated)

1. **Immediate: ship A.** Fix the checkout provisioning + add re-provision-on-not-ready.
   It directly clears the production block and does not weaken the (already
   weak) `local` isolation.
2. **Durable: B1 (seatbelt) as the macOS-native target**, with B2 (Docker) as
   the fallback if the deprecated-API risk is judged unacceptable. State plainly
   in code + docs that the `local` path-gate is *advisory*, not containment,
   until B lands — so no one over-trusts it.
3. **C only on relocation:** if keepers ever run on a Linux fleet, microVM is the
   strongest answer; on the current macOS host it is not available.

Cons / open risk: B1 ties confinement to a deprecated Apple API; B2 adds a Linux
VM dependency; A alone leaves the host exposed if a tool escapes the path gate.

## 6. Open questions (could not determine from code alone)

- Does provisioning use `git clone` or linked worktrees today, and why did a
  keeper end up with a nested `.worktrees/task-630` that is not a real checkout?
- Does the Docker profile actually run on the macOS host (Docker Desktop
  present), and what fraction of keepers run `local` vs `docker`?
- Is there ANY kernel-level confinement for `local` today, or is it purely the
  path-string gate (§2 reads as the latter)?
- Re-verify §3 against current product docs (this pass was lost to a session limit).
