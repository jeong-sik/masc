---
rfc: "0209"
title: "Local Sandbox Credential Boundary — nothing-leaks-by-default for the host exec path"
status: Draft
created: 2026-05-30
updated: 2026-06-02
author: yousleepwhen
supersedes: []
superseded_by: null
related: ["0008", "0019", "0037", "0070", "0126", "0145"]
implementation_prs: []
issue: "#19770"
note: >
  Originally drafted as RFC-0207 (2026-05-30) but never pushed; the 0207
  number was reassigned to per-keeper-runtime-routing in the interim, so this
  is re-homed unchanged as RFC-0209. Code drift since the 2026-05-30
  diagnosis: the `Repo_cli_credentials` module was renamed to
  `Credential_bundle` (#19765, so `compose_base_with_repo_cli_config` →
  `compose_base_with_credential_bundle`), and the dead host-identity
  generator path (`keeper_identity.git_env_for_keeper`) was purged (#19768).
  Module names in §1.1 / §4 reflect the diagnosis-time code; the leak chain,
  root cause, and D1 decision are unchanged.
---

## 1. Problem (field-verified 2026-05-30, CERTAIN)

When a keeper with `sandbox_profile = "local"` executes a network-capable
command (`git push`, `git fetch`, `git clone`, `gh pr create`, `gh api`, …),
the spawned subprocess inherits the **operator's unscrubbed environment**,
including the operator's real `HOME`. The subprocess then resolves the
operator's `~/.gitconfig` credential helper
(`credential.helper = !/opt/homebrew/bin/gh auth git-credential`, verified
present on the primary deployment via `git config --show-origin`) and the
operator's `~/.config/gh/hosts.yml` PAT, and **authenticates to GitHub as the
operator (jeong-sik)**. Keeper audit logs record the command but not the
authenticating identity, so operator credential use is masked as automated
tool execution.

### 1.1 Exact mechanism (CERTAIN — read end-to-end)

| Step | Location | Fact |
|------|----------|------|
| Local dispatch builds no env | `lib/keeper/agent_tool_execute_runtime.ml:~120` | `Local -> Ok (Masc_exec.Sandbox_target.host (), [])` — no credential scope, no scrub |
| Empty env → None | `lib/exec/exec_dispatch.ml:122-133` | `resolve_host_env [] -> None`; non-empty merges the *full* `Unix.environment ()` |
| None → inherit parent | `lib/process/process_eio.ml:116-118, 485-495` | `default_env None = Unix.environment ()`; `Eio.Process.spawn ?env:None` inherits parent |
| In-process keeper turn | `lib/keeper/*` | no `Domain.spawn` / `Unix.fork` for keeper turns → child inherits the MASC server process env |
| Scrub builder is dead on this path | `lib/keeper/repo_cli_credentials.ml:259-266` | `process_env` / `keeper_process_env` (which call `compose_base_with_repo_cli_config`, which applies `Env_keeper_scrub`) have **zero non-test callers** |
| `git`/`gh` are allowlisted | `lib/keeper/dev_exec_allowlist.ml:16-17` (`dev_programs`) | both pass `shell_command_gate.bin_allowed`; the `exec_policy.ml:60-62` gh-rejection is a *hint string*, not an enforcement gate |

### 1.2 Asymmetry with the Docker path (the smell)

The **Docker path is safe**: credentials are resolved via
`Keeper_host_config_provider.resolve` → scrubbed bundle → injected as
explicit `docker run -e` args
(`lib/keeper/keeper_sandbox_docker.ml:311-327, 384-385`). The 8 raw
`~env:(Unix.environment ())` sites are all host-side `docker` CLI plumbing,
never the keeper command.

The boundary is enforced for Docker and **silently absent for Local**. This
violates the invariant the codebase already declares for itself:

> `lib/env_keeper_scrub.mli:1` — "Long-lived host credentials … MUST NOT
> cross the keeper subprocess boundary."

### 1.3 Operational weight

14 of 16 live keepers (`~/.masc/config/keepers/`) run `sandbox_profile=local`
(only `analyst` is docker; `base` is docker but `autoboot_enabled=false`).
The leaking path is the **dominant** runtime case, not an edge case.

### 1.4 Severity

CRITICAL. An allowlisted Local keeper command authenticates as the operator
on the default single-user deployment. Severity degrades to LATENT only where
the server env carries no token AND `HOME` has no credential helper — not the
primary deployment.

## 2. Root cause (typed)

`resolve_host_env`'s `[] -> None` branch maps **"no explicit env"** to
**"inherit the full ambient environment."** This is the same *Unknown →
Permissive Default* anti-pattern captured in the in-repo diagnosis appendix:
an `option` that should mean "fail / fall to a safe default" is read as
"convenient pass-through." Every comparable OSS agent treats this as the
canonical thing to forbid:

- **Hermes Agent** (`security.md`): child processes strip env vars whose name
  contains `KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL/PASSWD/AUTH`; credentials are
  **explicit opt-in only** ("nothing leaks by default"); credential files are
  RO bind-mounted, host `HOME` is not inherited.
- **OpenClaw / OpenShell**: gateway (tokens) and sandbox (untrusted exec) on
  separate hosts; credentials injected from a provider store, never on the
  sandbox filesystem.
- **OpenHands**: provider token store injects only declared tokens; recent fix
  "stops bleeding LLM credentials through `os.environ`."
- **Per-agent identity** (dev.to/agent_paaru, GitHub gh-aw): PAT → short-lived
  **GitHub App installation tokens (1h)**, injected per-repo via
  `git remote set-url origin https://x-access-token:${TOKEN}@…` + per-repo
  `git config user.name '<agent>[bot]'`; operator PAT/SSH key deleted from the
  server; **global git identity set to a fail-safe invalid value** so it breaks
  rather than leaks.

Evidence record: `RFC-0209-EVIDENCE.md`.

`Repo_cli_credentials` is masc-mcp's implementation of the universal layer-2
pattern (per-keeper bundle). It is **standard, not redundant** — the defect is
that it is wired only into Docker, never into Local.

## 3. Design

The fix is two layers, matching the industry-standard split. Layer 1 is
**fully specified and approved for implementation now**. Layer 2 names a
deliberately **deferred operational-model decision** (D1) and must not be
guessed at implementation time.

### 3.1 Layer 1 — Local must not inherit ambient env (DECIDED)

**Invariant (I1):** A keeper command on the Local/Host path must never run
with the operator's ambient environment. "No declared env" must resolve to a
**scrubbed** environment with an overridden `HOME`, never to
`Unix.environment ()`.

Two enforcement points, both required (no single-call-site patch):

1. **Exec layer (root):** change `Exec_dispatch.resolve_host_env` so the `[]`
   case does **not** return `None`-meaning-inherit. The `lib/exec` layer
   cannot depend on `lib/keeper`'s `Env_keeper_scrub` (layering); therefore the
   scrub function is **injected** as data (a `string array -> string array`
   passed via the dispatch path / `Sandbox_target`), or the Host case is
   required to carry an explicit env. The ambient-inherit state is removed at
   the type level: a Host command with no resolved scrubbed env is not
   dispatchable.
2. **Keeper layer:** the Local branch at `agent_tool_execute_runtime.ml:~120`
   supplies the scrubbed env (`Env_keeper_scrub.filter_environment` +
   `HOME` override to the keeper's sandbox root) for **all** Local commands,
   network or not. Non-network local commands (`git status/log/diff`,
   `rg`, `cat`, build tools) keep working under the scrubbed env.

**`HOME` override (I1a):** Local subprocess `HOME` is set to the keeper's
sandbox/bundle root, not the operator home, so `~/.gitconfig` credential
helpers and `~/.config/gh` are unreachable regardless of env scrubbing
(defense in depth — matches Hermes RO-mount + agent_paaru "delete operator
creds from server").

### 3.2 Layer 2 — network git/gh on Local: read-allow / write-fail-closed (DECIDED, D1)

**D1 decision (2026-05-30, owner: yousleepwhen):** split Local network commands
by read vs write. This is driven by observed fleet behavior, not theory.

**Field data (CERTAIN, fleet logs `~/.masc/logs/`):**
- Keepers DO use **read-network** git: `git clone`/`fetch`/`pull` = 21 refs on
  2026-05-27 (keepers pull repos into their sandbox and read them).
- Keepers do **not** push: `git push` = **0** refs across the 7-day window;
  `gh pr` refs are query/read, not authenticated writes.
- All 16 live keepers carry placeholder `repo_cli_identity = "repo_cli_identity"`
  and **no `repo-cli-identities/<id>/gh` bundle exists on disk** (dir empty).
- Historical `anyang-keepers <anyang.keepers@gmail.com>` commits exist (8 in
  14d) plus a telltale `jeong-sik <tech_glutton@masc.keeper>` author — keeper
  work has bled into the operator identity.

**Rule (R1):**
- **Read-network** (`git clone`/`fetch`/`pull`, and non-network local git
  `status`/`log`/`diff`): **allowed** under the Layer-1 scrubbed env + sandbox
  `HOME`. Public-repo clone needs no credential, so a scrubbed env is
  sufficient and there is nothing to leak (operator is never authenticated).
- **Write-network** (`git push`, `gh pr create`/`gh api`/any authenticated
  `gh` write): **fail-closed** with a typed
  `Keeper_sandbox_shell_ir_target.target_error` ("write-network git/gh not
  available on the Local sandbox profile; no keeper credential bound").
  No bundle exists, so this blocks 0 working flows today (push = 0/7d) while
  permanently closing the operator-identity leak.

**Classifier:** `risk_classifier.ml` already separates network prefixes
(`git clone`/`fetch`/`pull` at :111) from write prefixes (`git push` at :98).
The Local fail-closed predicate keys on the **write-network** subset
(`git push` + authenticated `gh` writes), NOT all `git`/`gh` — so read flows
are untouched. Minimum block for maximum safety: credential need and leak risk
coincide exactly on write-network, so blocking only that is both necessary and
sufficient.

**Future work (DEFERRED, separate RFC — "추후 개선"):** restore keeper
*write* capability under the keeper's *own* identity, not fail-closed:
- **Option C — bundle injection (Docker-symmetric):** wire `Repo_cli_credentials`
  bundle env into the Local write path once a bundle-provisioning model exists.
- **Option G — GitHub App tokens (industry trend):** short-lived per-keeper App
  installation tokens (1h) instead of static bundles.
These require a keeper-GitHub-identity provisioning model (bundles are empty
today) and are out of scope for the leak fix. Until then, write-network on
Local stays fail-closed; keepers needing authenticated writes use the Docker
profile (which already injects scoped credentials).

### 3.3 Out of scope

- exec_policy.ml gh-rejection hint vs `bin_allowed` reconciliation (1.1) —
  tracked, fix in the Layer-1 PR or a follow-up; it is a confusing message, not
  the leak.
- Scrub-list drift: `env_keeper_scrub.ml` should gain an in-repo parity test
  against a checked-in scrub-list fixture; the external TS reference used
  during diagnosis is intentionally not cited here because it is not part of
  this repository.

## 4. Purge (dead code removed with Layer 1)

These `Repo_cli_credentials` symbols have **zero live callers** and exist only
as an unwired Local builder; leaving them implies a "wired safety" that does
not exist (false precedent for future AI codegen). Delete with Layer 1:
`process_env`, `keeper_process_env`, `keeper_config_dir`, `with_env`,
`config_dir`, and their transitive-private helpers, **unless** the Layer-1
implementation reuses `compose_base_with_repo_cli_config` to build the
scrubbed Local env (in which case keep exactly that chain). **Keep set**
(Docker-live via `Keeper_host_config_provider`): `keeper_binding` (type),
`credential_scope`/`credential_scope_to_string`, `git_config_env_pairs`,
`git_config_env_entries`, and the bundle-path helpers it transitively needs.
Build safety is verified by `dune build @check` — the OCaml compiler enumerates
every break.

## 5. Validation

| Check | Method | Pass criterion |
|-------|--------|----------------|
| C1 | unit/integration | a Local keeper `git push https://…` / `gh pr create` **fails closed** with a typed error; never presents operator credentials |
| C2 | unit/integration | a Local keeper `git clone`/`fetch`/`pull` (read-network) and `git status`/`log`/`diff` (local) still run, under a scrubbed env + sandbox `HOME` (no operator `GH_TOKEN`/`~/.gitconfig`/`~/.config/gh` reachable) |
| C3 | regression | Docker path credential injection unchanged (`test_keeper_sandbox_docker_route`) |
| C4 | type | `Exec_dispatch` cannot dispatch a Host command without a resolved scrubbed env (illegal state unrepresentable) |
| C5 | build | `dune build @check` green after dead-symbol purge |
| C6 | source-boundary | `lib/exec` still does not depend on `lib/keeper` (scrub injected as data) |

## 6. Decision

Layer 1 (§3.1, scrub + `HOME` override, ambient-inherit removed) **and**
Layer 2 D1 (§3.2, read-network allowed / write-network fail-closed) are both
DECIDED (2026-05-30) and approved for the implementation PR. The implementation
ships them together because they share the same Local-dispatch edit.

Restoring keeper *write* capability under the keeper's own identity (Future
work: Option C bundle injection, Option G GitHub App tokens — §3.2) is
explicitly DEFERRED to a separate RFC; it needs a keeper-identity provisioning
model that does not exist today (all bundles empty). Write-network on Local
stays fail-closed until then.

## 7. Citations

- Leak chain: `lib/exec/exec_dispatch.ml:122-133`,
  `lib/process/process_eio.ml:116-118,485-495`,
  `lib/keeper/agent_tool_execute_runtime.ml:~120`,
  `lib/keeper/repo_cli_credentials.ml:259-266`,
  `lib/keeper/dev_exec_allowlist.ml:16-17`
- Declared invariant: `lib/env_keeper_scrub.mli:1`
- Docker-safe path: `lib/keeper/keeper_sandbox_docker.ml:311-327,384-385`
- Operator config verified: `git config --show-origin` →
  `~/.gitconfig credential.helper`, `~/.config/gh/hosts.yml`
- Current-state diagnosis trace: `RFC-0209-EVIDENCE.md` (this directory)
