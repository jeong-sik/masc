# Design: Off-host keeper execution over OpenSSH + microVM; local playground disabled

- Date: 2026-08-27
- Status: Draft (pending user review)
- Supersedes the recommendation of: `docs/rfc/RFC-0213-keeper-sandbox-isolation.md` §5.2 (B1 seatbelt as durable target)
- Activates: RFC-0213 §4 option **C — Off-host microVM**, gated on building the SSH transport first
- Strategy note: this is a guarded-subsystem change (`lib/keeper/keeper_sandbox*`, `lib/exec/*`). A formal RFC update/new RFC must accompany implementation (Phase 0 deliverable).

## 1. Context — current state (code-grounded, verified 2026-08-27)

Keeper tool execution today:

- Keepers run **in-process** in the server (`bin/main_eio.ml`). A tool call flows:
  `keeper_tool_runtime.ml` (`Tool_execute`) → `keeper_tool_execute_runtime.ml:265`
  (`effective_sandbox_profile`) → dispatch at `keeper_tool_execute_runtime.ml:332-365`
  (`Local -> local_dispatch_sandbox ()` / `Docker -> docker_sandbox_target ...`)
  → `lib/exec/exec_dispatch.ml` → `lib/process/process_eio.ml` (`Eio.Process.spawn`).
- Sandbox profiles: `Local | Docker` (`lib/keeper_types_profile_sandbox/keeper_types_profile_sandbox.ml:1-11`).
  **Default is `Local`** (`:74`). Per-keeper TOML `sandbox_profile` parsed at
  `lib/keeper/keeper_meta_contract.ml:349-411`, tool-arg override at
  `lib/keeper/keeper_turn_up_args.ml:375-385`.
- **`Local` has zero OS confinement** — a path-string gate
  (`lib/keeper/keeper_tool_execute_path.ml:133`, `lib/exec/path_scope.ml`) plus env
  scrubbing only. No sandbox-exec/seatbelt/chroot anywhere in the tree.
- `Docker` is real, implemented isolation (read-only rootfs, cap-drop=ALL, resource
  limits — `lib/config/env_config_sandbox.mli:13-54`) but depends on a local Docker
  Desktop Linux VM and still executes on-host.
- SSH/microVM: **absent in code, docs-only**. `lib/transport.mli` is a message-shape
  abstraction, not a connection/spawn seam. Auth is bearer-token only
  (`lib/auth/auth.mli`); no SSH key management.
- `~/.masc` (21 GB) currently holds model files, `config/keepers/polisher.toml`,
  reports — no active playground content.
- Host constraint: macOS (Apple Silicon). Linux microVM primitives (KVM/Firecracker/
  gVisor) are unavailable; nested virtualization is not supported, so true microVMs
  require a **remote Linux host**.

The one existing seam that fits a remote lane: `Masc_exec.Sandbox_target.t`
(`lib/exec/sandbox_target.mli:37-39`):

```ocaml
type t =
  | Host
  | Docker of { image : string; runner : runner; pipeline_runner : pipeline_runner option }
```

`Docker` carries an injected `runner` closure so `lib/exec` stays keeper-agnostic.
An SSH target follows the same pattern.

## 2. Goals / non-goals

Goals:

1. **G1 — local playground impossible, not merely unused.** The `Local` sandbox
   profile is fail-closed disabled: rejected at config validation, at `keeper_up`
   tool-arg resolution, and (defense in depth) at the dispatch branch itself.
2. **G2 — OpenSSH remote execution.** Keeper `Execute` (and workspace read ops)
   run on a remote host over OpenSSH with streaming, timeouts, and cancellation
   semantics equal to the current host path.
3. **G3 — microVM isolation.** On a remote Linux host, each keeper's exec lands in
   a per-keeper Firecracker microVM; the SSH endpoint becomes the VM.
4. **G4 — no silent fallback.** Unreachable/unready remote ⇒ keeper turn fails
   closed (RFC-0001 silent-substitution anti-pattern applies to execution lanes too).

Non-goals:

- Moving the MCP server, LLM provider calls, or the dashboard off-host.
- Removing the `Docker` profile (kept as an interim/fallback lane).
- Windows remote hosts; multi-host scheduling/bin-packing; VM snapshot pooling
  (noted as follow-ups).
- Replacing `Process_eio` — it stays the spawn substrate (the SSH runner itself
  spawns the local `ssh` client through it).

## 3. Assumptions (declared because this plan was written without a Q&A round)

- No remote Linux host exists yet; provisioning one is part of the plan (Phase 2
  prerequisite, operator-owned).
- "microVM" means **Firecracker on remote Linux** (RFC-0213 option C). macOS-local
  VMs (tart/Virtualization.framework) are documented as an interim fallback only.
- "local playground 아예 안되게" means the `Local` *sandbox profile* is disabled.
  `Process_eio` itself remains — tests, build tooling, and the SSH runner's local
  `ssh` client subprocess all depend on it.
- A dev/test escape hatch (`MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1`) is acceptable and
  required, since the test suite exercises the host path directly.

## 4. Architecture

Three phases, each independently shippable:

```
Phase 0                Phase 1                     Phase 2
--------------------   -------------------------   -------------------------
Local profile          Sandbox_target.Ssh          SSH endpoint becomes
fail-closed disabled   runner over OpenSSH         per-keeper Firecracker VM
(+ RFC update)         + remote shim + path map    (VM lifecycle over SSH)
```

### 4.1 Phase 0 — disable the local playground (fail-closed)

Touch points (all verified):

1. `keeper_types_profile_sandbox.ml:74` — `default_sandbox_profile = Local`
   must stop resolving to `Local` when the gate is off. Keep the `Local`
   constructor (type/TLA stability) but make it unusable.
2. `lib/keeper/keeper_meta_contract.ml:349-411` — config-time validation:
   `sandbox_profile = "local"` → config error naming the keeper and the gate.
3. `lib/keeper/keeper_turn_up_args.ml:375-385` — `resolve_sandbox_profile`
   rejects `"local"` from the `masc_keeper_up` tool arg.
4. `keeper_tool_execute_runtime.ml:332-334` — the `Local ->` dispatch branch
   returns a structured `local_playground_disabled` error instead of calling
   `local_dispatch_sandbox ()` (defense in depth; catches any path that slipped
   past 1–3).
5. `lib/config/env_config_sandbox.ml` — new gate reader, e.g.
   `module Gate : sig val allow_local_playground : unit -> bool end`,
   env `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND`, **default `false`**, registered in
   `lib/config/feature_flag_registry.ml`. When the escape hatch is set, log a
   loud startup warning.
6. Tests that assume local (`test_keeper_local_profile_docker_playground.ml`,
   `test_keeper_sandbox_root_by_profile.ml`, etc.) set the escape hatch
   explicitly — the test suite documents the gate rather than bypassing it.
7. `config/keepers/issue_king.toml` (`sandbox_profile = "local"`) must migrate to
   `docker` before/with the gate flip.
8. RFC: update RFC-0213 (or new RFC) recording the strategy change: B1 seatbelt
   rejected (deprecated Apple API, still a shared host kernel); C activated via
   SSH relocation.

### 4.2 Phase 1 — SSH remote execution lane

**Target type.** Extend `lib/exec/sandbox_target.ml(i)`:

```ocaml
| Ssh of { endpoint : ssh_endpoint; runner : runner; pipeline_runner : pipeline_runner option }
```

`lib/exec` stays dependency-clean; the keeper layer injects the runner, exactly
like `Docker`. `Exec_dispatch` routes `Ssh` to its runner the same way.

**Profile.** `sandbox_profile` += `Remote_ssh` (`keeper_types_profile_sandbox.ml`,
`keeper_sandbox_config` strings, TLA `ProfileSet` in
`specs/boundary/SandboxDispatch.tla` — the Variant SSOT comment at
`keeper_types_profile_sandbox.ml:52-56` makes exhaustiveness do the work).

**Runner.** New module (e.g. `lib/keeper/keeper_sandbox_ssh.ml`, mirroring
`keeper_sandbox_docker.ml`) that:

- spawns the OpenSSH client via the existing `Process_eio` substrate;
- reuses connections: `ControlMaster=auto`, `ControlPersist=120`,
  `ControlPath=<base>/.masc/run/ssh/%C`;
- pins trust: `BatchMode=yes IdentitiesOnly=yes IdentityFile=<dedicated key>`
  `StrictHostKeyChecking=yes UserKnownHostsFile=<pinned file>`;
- reproduces the `dispatch_result` contract: `on_output_chunk` streaming from
  ssh stdout/stderr, per-bucket timeouts (`Env_config_sandbox.Shell_timeout`),
  cancellation = kill local ssh client → channel teardown → remote shim reaps
  the child process group (no orphan processes on the remote).

**Remote shim.** A small static binary/script `masc-exec-shim` installed on the
remote host. The ssh command is `ssh <opts> <endpoint> masc-exec-shim <request>`,
where `<request>` is a base64-encoded JSON `{argv, env, cwd, timeout_sec}`.
Rationale:

- argv/env/cwd never pass through a remote shell — no quoting/injection class of
  bugs;
- the shim re-applies the path jail server-side (defense in depth against a
  compromised keeper);
- the shim starts the child in its own process group and kills the group on
  SIGHUP — this is what makes cancellation semantics hold;
- in Phase 2 the same shim runs *inside* each microVM unchanged.

**Path mapping.** Today the path gate validates host paths under
`.masc/playground/<keeper>/` (`keeper_sandbox_config.ml:75`,
`playground_paths.ml`). For `Remote_ssh`, introduce a playground location
concept: keeper-visible logical paths stay unchanged; the dispatch boundary
translates to the remote root (e.g. `/home/masc/playground/<keeper>/`). All
translation lives in one module — no scattered string rewriting. Workspace read
ops (`lib/keeper/keeper_workspace_read_ops.ml:71`) route through the shim too.

**Provisioning.** `masc_keeper_up` preflight (extends
`Env_config_sandbox.Preflight`) gains remote readiness: ssh reachable, shim
present, playground root exists, repo checkouts present (clone/rsync over ssh on
first up). Unready ⇒ `keeper_up` fails with a named error — no local fallback.

**Config surface.** Per-keeper TOML: `sandbox_profile = "remote_ssh"` +
`remote_endpoint = "<name>"`. Endpoint registry in runtime config (new
`[exec.ssh.endpoints.<name>]` tables: `host`, `user`, `port`, `identity_file`,
`remote_root`, `capabilities`). Dedicated keypair generated under
`<base>/.masc/ssh/` (0600, not committed; `config/identity/` conventions apply).

**Secret policy.** `Keeper_secret_projection` currently projects host env into
local exec. Over SSH the default inverts: **no host secrets cross the wire**.
An explicit per-endpoint allowlist is the only path (e.g. none initially; GitHub
auth happens via a remote-side `gh` login, not forwarded tokens).
`keeper_tool_execute_runtime.ml:268-330` (local identity/env projection) is
skipped entirely for the SSH branch.

### 4.3 Phase 2 — microVM backend (Firecracker on remote Linux)

Prerequisite: operator-provisioned remote Linux host with KVM + Firecracker.

- One Firecracker microVM per keeper (jailer-on), each running `sshd` +
  `masc-exec-shim`. The Phase 1 machinery is unchanged — the endpoint registry
  entry simply points at the VM's IP:port. **This is the payoff of doing SSH
  first: microVM adoption is a config change, not a new transport.**
- VM lifecycle v1: controlled over SSH to the host (Firecracker API socket via
  `ssh ... curl --unix-socket`). A host-side agent daemon is a documented
  follow-up, not v1.
- Rootfs: minimal (alpine-class userland + git + build toolchain + sshd +
  shim), built by a script under `infrastructure/microvm/`; per-keeper
  copy-on-write disks.
- Networking: per-VM tap device with an egress policy reproducing
  `Network_none`/`Network_inherit` semantics (`network_mode` already exists in
  the profile type — the VM backend must honor it).
- Keeper ↔ VM assignment recorded in `<base>/.masc/run/vm-registry.json`;
  startup reconciliation destroys orphans, boots missing.
- macOS-only interim fallback (no Linux host yet): local Linux micro-VMs as SSH
  endpoints — concretely **Gondolin** (earendil-works, QEMU-backed; mounts the
  host cwd at `/workspace` with write-through) or tart/Virtualization.framework.
  Documented, not the target — Apple Silicon has no nested virtualization, so
  Firecracker-in-VM is impossible.

## 4.4 Prior art — pi.dev ecosystem (surveyed 2026-08-27)

The pi.dev (Pi coding agent, earendil-works/pi-mono) ecosystem has shipped the
exact patterns this design needs. What we adopt, and where we deliberately
differ:

- **`examples/extensions/ssh.ts`** — delegates read/write/edit/bash to a remote
  host via pluggable per-tool "operations" objects. This validates our Phase 1
  seam: `Sandbox_target.Ssh` carrying an injected runner is the same shape.
  Deliberate upgrades over the example: it spawns one ssh process per operation
  (we reuse connections via ControlMaster/ControlPersist); it quotes through a
  remote shell with `JSON.stringify` (our shim receives base64 JSON and execs
  without a shell); its path mapping is naive string replace (ours is a single
  typed translation module).
- **`examples/extensions/gondolin/` + the Containerization doc** — Gondolin is
  a local Linux micro-VM (QEMU) that routes built-in tools into the VM while
  auth stays on the host. This is the concrete macOS-local microVM option for
  the Phase 2 interim fallback (§4.3).
- **`code-yeongyu/pi-sandbox`** — policy-aware sandbox with justbash/docker/
  seatbelt/bwrap/QEMU backends plus an SSH transport profile. Independently
  confirms three of our security decisions: strict host-key verification by
  default, env scrub before remote execution, and the explicit doctrine that
  **SSH is transport-only — process/network isolation is whatever the remote
  side provides** (which is why microVM is Phase 2, not optional). Its
  per-backend capability objects are a good model for a future
  `keeper_capability_probe` extension (each sandbox profile advertising what it
  enforces) — noted as a follow-up, not Phase 0–2 scope.
- **OpenShell (NVIDIA), via the Pi containerization doc** — keeps raw model API
  keys *outside* the sandbox; code inside calls a local inference endpoint and
  the gateway injects credentials upstream. Prior art for §4.2's secret-policy
  inversion (no host secrets cross the wire; remote-side auth instead of
  forwarded tokens).

## 5. Security model

- Trust boundary moves from "path strings on a shared host" to "SSH channel to a
  remote machine" to "hardware VM boundary on a remote Linux host".
- Host key pinning (`StrictHostKeyChecking=yes`, committed known_hosts per
  endpoint); dedicated, non-reused keypair; `IdentitiesOnly=yes` so the agent
  never leaks other keys.
- No agent forwarding (`ForwardAgent=no`, explicit).
- Secrets never cross by default (§4.2).
- Fail-closed everywhere: gate off + Local requested → error; endpoint
  unreachable → error; VM unready → error. No silent downgrade to host exec.
- The shim re-validates paths server-side; the host-side path gate remains as
  the first layer.

## 6. Testing strategy

- Phase 0: gate tests — Local rejected at config/tool-arg/dispatch layers;
  escape-hatch tests prove the hatch works and warns.
- Phase 1: unit tests for shim request encoding (round-trip argv/env/cwd,
  hostile bytes), path translation, timeout mapping, cancellation. Integration
  test against a local Linux sshd fixture (Docker container running sshd +
  shim) exercising Execute end-to-end, including mid-command cancel.
- Phase 2: VM lifecycle tests on a Linux CI runner (or manual gated runbook if
  CI lacks KVM); shim-in-VM Execute parity test reusing the Phase 1 suite.
- TLA: extend `specs/boundary/SandboxDispatch.tla` `ProfileSet`; existing
  exhaustiveness gates (`#8467` Variant SSOT) force the updates.

## 7. Rollout

1. Phase 0 PR: gate + RFC update + `issue_king.toml` → docker. Independently
   shippable; local playground dead from this point (escape hatch excepted).
2. Phase 1 PR(s): `Sandbox_target.Ssh` + profile + runner + shim + path mapping
   + endpoint config. Keepers migrate one TOML at a time to `remote_ssh`.
3. Phase 2 PR(s): host provisioning runbook, rootfs build script, VM registry,
   endpoint resolution to VM IPs.
4. Docs: `docs/rfc/` strategy RFC; operator runbook for endpoint/VM management;
   `AGENTS.md` updates where conventions change.

## 8. Success criteria

- Boot with any keeper at `sandbox_profile = "local"` fails with a named config
  error (unless `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1` is set, which logs a
  warning).
- A `remote_ssh` keeper's `Execute` output contains the remote hostname; cancel
  mid-command leaves no remote process (verified by integration test).
- `ps`/`lsof` on the masc host shows no keeper *payload* processes — only the
  `ssh` client transports spawned by the runner (Phase 1+).
- Phase 2: two keepers execute in distinct VMs; compromising one VM's shim
  cannot see the other keeper's playground (isolation test on the Linux host).

## 9. Risks / open questions

- **Remote host ownership**: who provisions/operates the Linux host, its network
  reachability, and key custody. (Blocks Phase 2; Phase 1 can start against any
  sshd, including a localhost fixture.)
- **Latency**: interactive turns pay an SSH round-trip per tool call; Control*
  reuse + shim keep it to ~tens of ms on a LAN, but a WAN fleet needs
  measurement before migrating latency-sensitive keepers.
- **Large-repo read ops**: workspace reads over ssh may be slower than host FS;
  may need batching/compression in the shim (measure first).
- **Docker dependency for dev**: Phase 0 makes `docker` the only on-host lane;
  dev machines without Docker lose keeper execution entirely (intended — but
  document it).
- **Firecracker alternative**: if the remote host cannot do KVM, Cloud Hypervisor
  or QEMU-microvm are drop-in equivalents at the lifecycle layer; the design only
  assumes "VM exposes sshd".
