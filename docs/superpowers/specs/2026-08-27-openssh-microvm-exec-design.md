# Design: Off-host keeper execution over OpenSSH + microVM; local playground disabled

- Date: 2026-08-27
- Amended: 2026-08-28 (§1 host constraint, §4.1a on-host microVM lane, §10 in-flight work)
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
- the live `<base-path>/.masc` (21 GB) currently holds model files, `config/keepers/polisher.toml`,
  reports — no active playground content.
- Host constraint: macOS (Apple Silicon). Linux microVM primitives (KVM/Firecracker/
  gVisor) are unavailable; nested virtualization is not supported, so true microVMs
  require a **remote Linux host**.
  **Amended 2026-08-28**: Apple's `container` CLI (Virtualization.framework,
  macOS 26+) provides on-host per-container lightweight VMs — each guest runs
  its own Linux kernel. This does not replace the off-host end state (the host
  still runs the server and holds credentials) but it invalidates "no on-host
  microVM lane exists" as a premise. See §4.1a.

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
   `lib/config/feature_flag_registry.ml`. When the hatch lifts the gate, the
   first local dispatch in the process logs a warning naming the keeper.
6. Tests that assume local (`test_keeper_local_profile_docker_playground.ml`,
   `test_keeper_sandbox_root_by_profile.ml`, etc.) set the escape hatch
   explicitly — the test suite documents the gate rather than bypassing it.
7. `config/keepers/issue_king.toml` (`sandbox_profile = "local"`) must migrate to
   `docker` before/with the gate flip.
8. RFC: update RFC-0213 (or new RFC) recording the strategy change: B1 seatbelt
   rejected (deprecated Apple API, still a shared host kernel); C activated via
   SSH relocation.

### 4.1a On-host microVM lane — Apple `container` CLI (added 2026-08-28)

Landed since this document was written:

- `Micro_vm` sandbox profile exists (#31253, merged 2026-08-28 12:20 KST) —
  "refuses rather than substitutes": a keeper that asks for a VM is never
  silently run under Docker with a docker label (#31225 is the incident that
  motivated this).
- `lib/keeper/keeper_sandbox_microvm.ml` — the Apple `container` argv builder,
  with measured numbers in its header (macOS 26.6.1 / M3 Max / container CLI
  1.3.0): **4.0–4.4 s VM start** vs Docker's 0.6–0.9 s, **~400 MB host memory
  per running VM**, guest kernel `Linux 6.18.35`. Its own doc comment states
  the remaining step: "Dispatch still refuses `Micro_vm` until a later change
  routes it here."
- Phase 0's dispatch gate is implemented and deployed: the `Local ->` branch
  returns `local_playground_disabled` unless `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND`
  lifts it (dev/test hatch, warns once per process, keeper named).

#### As-is / to-be

As-is: keeper cognition (turn loop, provider calls) runs in the server
process; only tool execution enters a sandbox. Docker containers are created
per turn (`masc-keeper-turn-*`), reused within the turn by a factory cache
(one runtime per playground/network/root/image), torn down at turn end
(#30604), with an orphan sweep at container creation
(`reap_prior_turn_containers`) and a TTL-labelled managed lane
(`masc_keeper_sandbox_start`) beside it. `Micro_vm` parses but never executes.

To-be, in two wiring steps that reuse that machinery:

| step | change | why it is wiring, not construction |
|---|---|---|
| W1 | Split the shared `Docker \| Micro_vm` dispatch branch (`keeper_tool_execute_runtime.ml:358`) and route `Micro_vm` to the existing argv builder | The builder, the refuse default, and the `Sandbox_target` runner-injection seam all exist; the branch split also removes the #31225 label-confusion class structurally |
| W2 | Give `Micro_vm` a keeper-lifetime managed VM instead of the per-turn lifecycle (start on first exec, reap on `keeper_down`/TTL) | Managed kind, TTL labels, expiry check, and the reaper exist for Docker; a 4-second boot per turn is unusable, per keeper it amortises to one boot |

Cost envelope: at ~400 MB per VM, all 10 current keepers on `Micro_vm` would
hold ~4 GB resident (3% of the 128 GB dev host). Network defaults to
`Network_none`; opening it is an explicit per-keeper TOML declaration.

Isolation delta: Docker shares the host kernel (a wall inside one building);
`Micro_vm` gives each keeper its own guest kernel (a separate building) — an
escape must cross the hypervisor, not a namespace boundary.

Relation to the off-host end state: W1/W2 exercise the same seam
(`Sandbox_target` with injected runners) and the same lifecycle contract
(create/reuse/reap with owner + TTL labels) that Phase 2's remote Firecracker
lane needs. Nothing here is throwaway; the off-host lane replaces the runner,
not the contract.

#### Sequenced follow-ups (orthogonal, in cost order)

1. **Deny decisions as typed evidence** — every policy allow/deny lands on the
   receipt plane with the rule that fired, so a keeper can read its own
   refusals (observed 2026-08-28: one keeper retried the same nonexistent
   path 12 times because denials only reach operator logs). In-flight work
   already points here — see §10.
2. **Inference gateway (credential exclusion)** — the OpenShell/pi.dev
   `inference.local` pattern (§4.4): sandboxed code calls a local endpoint,
   the gateway injects provider keys upstream, raw keys never enter the
   sandbox. Not urgent on-host (today almost nothing inside a sandbox calls
   a provider); becomes the enabling piece for Phase 1+ off-host.
   Subscription CLI runtimes (codex/claude OAuth) stay outside this pattern —
   that boundary must be stated, not assumed away.
3. **Per-keeper typed policy record** — collapse profile/network/path-gate/env
   hatches into one parsed policy document. Largest blast radius (strict
   decoder makes it a runtime-reset event); last.

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
- isolates client config: `-F none` (ignore `/etc/ssh/ssh_config` and
  `~/.ssh/config`), `ForwardAgent=no`, `ClearAllForwardings=yes`;
- reuses connections: `ControlMaster=auto`, `ControlPersist=120`,
  `ControlPath=<base>/.masc/run/ssh/%C`, `ServerAliveInterval=15`
  `ServerAliveCountMax=2` (a dead master is detected, not hung on);
- pins trust: `BatchMode=yes IdentitiesOnly=yes IdentityFile=<dedicated key>`
  `StrictHostKeyChecking=yes UserKnownHostsFile=<endpoint known_hosts>`
  `ConnectTimeout=<connect_timeout_sec>`;
- reproduces the `dispatch_result` contract: split `on_stdout_chunk`/
  `on_stderr_chunk` streaming from the ssh channel, per-bucket timeouts
  (`Env_config_sandbox.Shell_timeout`);
- budgets wall-clock as `connect_timeout_sec + timeout_sec + drain grace`, so
  a cold ControlMaster connect cannot eat the command's budget; the shim also
  enforces `timeout_sec` server-side and reports `timed_out` in its trailer,
  so local-timeout vs remote-timeout vs transport failure stay three distinct
  named errors;
- cancellation = kill the local ssh client → channel EOF → the shim's watchdog
  reaps the child process group. No pty anywhere (`-T`): a pty merges stderr
  into stdout and would break the split-stream contract;
- logs a first-SSH-dispatch-per-endpoint info line (observability parity with
  the Phase 0 hatch warning).

**Remote shim.** A small **static Linux binary** `masc-exec-shim` installed on
the remote host (pinned: a binary, not a script). The ssh remote command is
the fixed literal `masc-exec-shim` — the request NEVER travels as an argv
token: sshd runs remote commands via the login shell, a single argv string is
capped at 128 KiB (`MAX_ARG_STRLEN`), and argv is visible in the remote
process table. The request is framed on stdin instead:

```
[8-byte big-endian length][request JSON][stdin_len raw bytes]
```

```json
{ "v": 3,
  "argv": ["<base64>", "..."],
  "env": [["<base64 name>", "<base64 value>"]],
  "cwd": "<base64>",
  "remote_root": "<base64>",
  "timeout_sec": 300.0,
  "stdin_len": 0,
  "mode": "effect" }
```

`mode` (v3, RFC-0422) is one of `effect` (unrestricted), `observe` (the shim
denies every filesystem write outside its per-run scratch with Landlock and
every `socket(2)` with seccomp before exec) or `guest_local` (sockets only).
A shim whose kernel cannot build the box answers with
`shim_error = "observe_unsupported: ..."`; it never runs the payload unboxed.
The probe advertises the `observe` capability where it can.

Binary-suspect fields are base64 *inside* the JSON, so hostile bytes
(invalid-UTF-8 filenames, arbitrary stdin) round-trip losslessly; `v` versions
the protocol. The shim:

- re-applies the path jail server-side (defense in depth against a compromised
  keeper);
- synthesizes a documented minimal base env (`PATH`, `HOME`, `USER`, `TMPDIR`)
  and overlays only endpoint-allowlisted request entries, minus a
  reserved-name denylist (`PATH`, `HOME`, `LD_PRELOAD`, `LD_LIBRARY_PATH`,
  `DYLD_*`, `BASH_ENV`, `ENV`) that is never accepted from the wire;
- `setsid()` the child into its own process group and sets
  `PR_SET_PDEATHSIG=SIGKILL` pre-exec (covers the shim dying first);
- while the child runs, selects on the child's stdout/stderr pipes, shim stdin
  (channel EOF/HUP), and the `timeout_sec` timer; on EOF or timeout it sends
  SIGTERM to the process group, waits a grace, then SIGKILLs the group — no
  remote orphans, including for quiet payloads (`sleep 600`);
- reports the result as a framed trailer appended after the child's stderr,
  delimited by `\x1e` (a control byte that cannot appear in valid UTF-8):
  `\x1e{"masc_exec_result":{"v":3,"exit":0,"signal":null,"timed_out":false,"shim_error":null}}\x1e`.
  This is how WEXITED vs WSIGNALED vs shim/transport errors stay distinct —
  ssh alone cannot tell them apart (ssh exits 255 for its own errors);
- answers `masc-exec-shim --probe` with `{name, version, capabilities}`;
  preflight compares major version and fails with `remote_shim_version_skew`;
- in Phase 2 the same shim runs *inside* each microVM unchanged.

**Path mapping.** Today the path gate validates host paths under
`.masc/playground/<keeper>/` (`keeper_sandbox_config.ml:75`,
`playground_paths.ml`). For `Remote_ssh`, keeper-visible logical paths stay
unchanged and ONE translation module owns both directions: host→remote on
dispatch (`remote_root/<keeper>/`), and remote→keeper-logical on streamed
stdout/stderr and error text — tool output contains absolute remote paths
(compiler errors, `rg` hits), and a keeper that sees them will feed them back
into the next call. Workspace read ops route through the shim too: the
host-side `Sys.file_exists` preflight in `keeper_workspace_read_ops.ml` is
wrong for remote targets, so existence checks gain an SSH backend behind the
`Keeper_sandbox_read_runner` seam. Host-FS call sites
(`host_root_abs_of_meta`, ~27 users: telemetry, filesystem-runtime
normalization, dashboard workspace views) are enumerated in the plan and
classified as logical-path, remote-proxied, or explicitly-divergent.

**Provisioning.** A new operator tool (`bin/masc_exec_ssh_bootstrap.ml`):
generates the dedicated keypair under `<base>/.masc/ssh/` (0600, never
committed); `ssh-keyscan`s the host and writes the pinned `known_hosts` only
after an out-of-band fingerprint confirmation (runbook step); installs or
upgrades `masc-exec-shim` and records its version; creates `remote_root`; and
provisions the per-keeper remote GitHub identity (see Secret policy).

`masc_keeper_up` preflight (extends `Env_config_sandbox.Preflight`) gains
remote readiness: ssh reachable, shim present and version-compatible, remote
`git --version`, playground root exists with a disk-free floor, repo checkouts
present (clone/rsync over ssh on first up), per-keeper remote gh identity
present, local ControlPath dir creatable. Unready ⇒ `keeper_up` fails with a
named error — **no fallback to any other lane** (a silent downgrade to
`docker` violates RFC-0001 exactly like a downgrade to local). Boot checks
config validity only; endpoint readiness is checked at keeper_up and
re-checked with a short TTL cache at dispatch — an endpoint that degrades
mid-session fails the tool call with a named error.

**Config surface.** Per-keeper TOML: `sandbox_profile = "remote_ssh"` +
`remote_endpoint = "<name>"`. Endpoint registry in runtime config (new
`[exec.ssh.endpoints.<name>]` tables):

| key | default | meaning |
|---|---|---|
| `host` | — (required) | remote host |
| `user` | — (required) | remote unix user |
| `port` | 22 | ssh port |
| `identity_file` | `<base>/.masc/ssh/<name>.key` | dedicated key — a path *reference*; key material at 0600, `config/identity/` conventions |
| `known_hosts_file` | `<base>/.masc/ssh/known_hosts.d/<name>` | pinned host keys (public; may be committed) |
| `remote_root` | — (required) | remote playground root |
| `connect_timeout_sec` | 10 | → `ConnectTimeout` |
| `max_concurrent_sessions` | 8 | sessions multiplex onto one ControlMaster connection; sshd `MaxSessions` defaults to 10, so the ceiling must be explicit |
| `env_allowlist` | `[]` | request env names allowed to cross the wire |
| `capabilities` | `[]` | reserved: `kvm`, `firecracker` (Phase 2); unknown values warn-and-ignore |

Unknown registry keys and unknown `remote_endpoint` names in keeper TOML are
config-load errors (fail-closed).

**Secret policy.** `Keeper_secret_projection` currently projects host env into
local exec. Over SSH the default inverts: **no host secrets cross the wire**.
GitHub auth is per-keeper remote-side: the bootstrap provisions
`<remote_root>/<keeper>/.config/gh` per keeper (never per-call over the wire),
preflight checks `gh auth status` for it (`remote_github_identity_missing`),
and the bootstrap registers the remote token *value* in the host redaction set
so a leak into output is still scrubbed. The SSH dispatch branch skips the
local identity/env projection (`keeper_tool_execute_runtime.ml:268-330`) but
STILL runs `Keeper_github_identity.validate_local_tool_env` on typed env — or
rejects typed env exactly like the Docker arm — so a model cannot smuggle
`GH_TOKEN`/`LD_PRELOAD` onto the wire past the allowlist.

**Docker-parity hardening table.** `remote_ssh` does not reproduce the Docker
container knobs; the delta is declared, not discovered in review:

| Docker knob (`keeper_sandbox_runtime_setup`) | `remote_ssh` disposition |
|---|---|
| per-command timeout | shim-enforced (server-side) + local budget |
| `network_mode = "none"` | **rejected at config load** (`remote_ssh_no_network_mode`; Phase 2 honors it via per-VM egress policy) |
| memory / pids-limit / read-only rootfs / cap-drop / seccomp | deferred to Phase 2 (microVM); documented as not enforced |
| path jail | enforced host-side (first layer) AND shim-side (defense in depth) |

`network_mode = "inherit"` is the only accepted mode for `remote_ssh` in
Phase 1, and it is the profile's default (matching `Local`).

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
- Host key pinning (`StrictHostKeyChecking=yes`, per-endpoint `known_hosts`
  file — public keys, so the file MAY be committed). The private key is a
  dedicated, non-reused keypair at 0600, never committed; `IdentitiesOnly=yes`
  so the agent never leaks other keys. `-F none` isolates the client from
  `/etc/ssh/ssh_config` and `~/.ssh/config`, so the operator's own ssh config
  cannot silently weaken any of these flags.
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
  hostile bytes — invalid UTF-8, NULs in stdin, 10 MiB payload), **result
  trailer parsing** (exit vs signal vs `shim_error` vs transport failure map to
  four distinct named errors; malformed/absent trailer → transport error, never
  a fake exit 0), path translation in BOTH directions (host→remote on dispatch,
  remote→logical on output), timeout mapping, env allowlist/denylist (wire
  `PATH`/`LD_PRELOAD` rejected; allowlisted entry survives), `network_mode =
  "none"` rejected for `remote_ssh` (`remote_ssh_no_network_mode`), shim
  version skew (`--probe` major mismatch → `remote_shim_version_skew`), and
  cancellation. Integration test against a local Linux sshd fixture (Docker
  container running sshd + shim) exercising Execute end-to-end, including
  mid-command cancel of a QUIET payload (`sleep 600`) asserting **no remote
  process survives** (ssh into the fixture and `pgrep`), and an automated
  host-side invariant: after the run, `ps` on the masc host shows the payload
  argv nowhere (only `ssh` client transports).
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
  `ssh` client transports spawned by the runner (Phase 1+). This is not a
  manual checklist item: §6's integration test asserts it automatically on
  every run.
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

## 10. In-flight work registry (2026-08-28)

Coordinates for anyone (human or keeper) picking up W1/W2 — check these have
landed or been abandoned before touching the dispatch:

| ref | state (2026-08-28) | overlaps |
|---|---|---|
| #31253 | merged | `Micro_vm` profile axis + refuse default |
| `keeper_sandbox_microvm.ml` | merged | Apple `container` argv builder (W1 input) |
| #31298 | open PR | CI boundary-matrix rows for the two microvm modules |
| `fix/keeper-sandbox-routing-contract` | branch, +470 | types sandbox routing evidence (follow-up 1) |
| `fix/keeper-sandbox-effect-wiring` | branch, +996 | wires routing receipts (follow-up 1) — stacked on the contract branch |
| `fix/dashboard-sandbox-routing-projection` | branch | dashboard projection of the same evidence |

The two routing-evidence branches implement follow-up 1 of §4.1a; W1/W2
should rebase on whichever of them lands rather than duplicating the receipt
plumbing.
