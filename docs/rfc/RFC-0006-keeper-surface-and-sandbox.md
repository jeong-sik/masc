# RFC-0006: Keeper Tool Surface Realignment & Symmetric Sandbox

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-04-20
- **Related**: #8773, #8778, #8471
- **Drives**: 18% turn-loss recovery + closes host FS leak for `docker_hardened` keepers

## 1. Problem

Two failures observed on 2026-04-20 are symptoms of the same architectural decision:

| # | Symptom | Mechanism |
|---|---------|-----------|
| A | Tool metrics underreport: 525/2906 (≈18%) keeper turns nuked with `unexpected tool names` | LLM emits Claude Code built-in names (`Bash`/`Read`/`Edit`/`Skill`/`Agent`/`Grep`/`Write`/`WebSearch`). `keeper_agent_run.ml:1893` returns `Error (Internal …)` when no valid call mixes in. |
| B | `minjae` (sandbox_profile=docker_hardened) reads host paths under `/Users/dancer/...` | `keeper_bash` is gated to docker, but `keeper_fs_read` and `keeper_shell` (op=rg/ls/find/cat) execute as the host process. Containment is asymmetric. |

Root cause:

1. **Surface mismatch with the model's training distribution.** We expose `keeper_*` prefixed tools while every Claude/GLM/Codex variant has been heavily trained on the unprefixed Anthropic-Code names. The prefix is for *our* introspection, not the model.
2. **Sandbox boundary follows tool name, not keeper identity.** `effective_sandbox_profile` is read once for `keeper_bash`. Other tools never consult it.

Fix A (alias router) addresses #8778 narrowly but leaves #B and the prefix design intact. We treat both symptoms as one redesign.

## 2. Goals / Non-Goals

**Goals**
- G1. Zero `unexpected tool names` nukes for the eight Claude Code built-ins listed in #8778.
- G2. For `sandbox_profile=docker_hardened` keepers, **all** tool execution (read + write + shell) happens inside the same container.
- G3. Backward compatible with current personas, prompts, and metrics consumers (no decisions.jsonl shape break).
- G4. No regression on prompt cache hit rate (Anthropic input cache).

**Non-Goals**
- Replace OAS Agent.run loop.
- Touch worker (non-keeper) surfaces.
- Rework `work_discovery_sources` (#8773 — separate track).

## 3. Design

### 3.1 Surface realignment (LLM-facing rename, internal alias map)

Public tool names exposed to OAS / LLM become the Anthropic Code built-in set:

| Current (internal key) | New (LLM-facing) |
|------------------------|------------------|
| `keeper_bash`          | `Bash`           |
| `keeper_fs_read`       | `Read`           |
| `keeper_fs_edit`       | `Edit` (with `Write` fan-in for create) |
| `keeper_shell` (op=rg) | `Grep`           |
| `keeper_shell` (op=ls/find/cat/...) | retained as `keeper_shell` *(no built-in cognate)* |
| `keeper_*` (board/task/etc.) | unchanged (no cognate; prefix retained) |

Internal:
- `lib/tool_shard.ml` keeps the canonical specs but emits public-name + internal-alias.
- New module `lib/keeper/keeper_tool_alias.ml` provides:
  ```ocaml
  val to_internal : string -> string option   (* "Bash" -> Some "keeper_bash" *)
  val to_public   : string -> string          (* "keeper_bash" -> "Bash" *)
  ```
- Dispatch in `keeper_agent_run.ml` resolves via `to_internal` before the surface check; metrics, decisions.jsonl, audit logs continue to use the **internal** name as the SSOT (preserves dashboards).
- `Skill` / `Agent` / `WebSearch` have **no** cognate. Surface check now emits a *teaching* error (`feedback_tool-error-messages-teach-llm.md`) rather than nuking; if the LLM only ever calls those, the turn produces a structured tool_result that says "Use Bash/Read/...".

Acceptance: `unexpected_tool_names` distinct list shrinks to ≤ 0 occurrences of `Bash|Read|Edit|Grep|Write` over a 24h replay.

### 3.2 Symmetric sandbox (Phase B)

For any keeper with `sandbox_profile = Docker_hardened`:

- A **per-turn container** owns the keeper's working set: `/work/playground` (rw, mounted from `~/.masc/playground/<keeper>/`), `/work/repos/<repo>` (rw if cloned), `/work/cache` (rw, ephemeral).
- The **host filesystem is not mounted**. `/Users`, `/Volumes`, `/`, `/etc`, etc. are invisible inside the container.
- All four tools dispatch into the container:
  - `Bash` → `docker exec <cid> sh -c …` (existing path)
  - `Read` → `docker exec <cid> cat …` (NEW — replaces `Eio_unix.openfile` path for hardened keepers)
  - `Edit` / `Write` → `docker exec <cid> sh -c 'cat > … <<EOF'` (NEW)
  - `Grep` / `keeper_shell` → `docker exec <cid> rg/ls/find …` (NEW)
- The container is reused across calls within the same turn (cheap exec) and torn down on turn end. Cold-start ≈ 200ms per turn (acceptable; turn budget is seconds).
- Non-hardened keepers (`Legacy_local`) keep host execution. The asymmetry disappears *for the keepers we declared hardened*.

Acceptance: `docker exec` is the only syscall path observed for `minjae`/`analyst`/`janitor`/`poe` over a 24h replay.

### 3.3 Containment matrix (post-redesign)

| Keeper sandbox | Bash | Read | Edit/Write | Grep / keeper_shell |
|----------------|------|------|------------|----------------------|
| `Legacy_local` (default) | host (validated) | host | host | host |
| `Docker_hardened`        | container | container | container | container |

Exactly one rule: **whichever profile decides one tool, decides every tool.**

## 4. Migration

| Phase | Deliverable | Risk |
|-------|-------------|------|
| **A** | Alias router + public rename + teaching errors for non-cognate names | Low. Pure dispatch change. Test fixture covers 8 hallucinated names. |
| **B-1** | `Read`/`Grep`/`keeper_shell` docker-exec path; **PoC: minjae only** behind env flag `MASC_KEEPER_SYMMETRIC_SANDBOX=true` | Medium. Mount semantics, perf, missing tools in image. |
| **B-2** | Roll out to remaining hardened keepers (analyst, janitor, poe) | Medium. Image must include git/gh/opam/dune/rg/jq for each persona's needs. |
| **C** | Decommission host fallback for hardened keepers; remove env flag | Low (after B-2 stabilizes). |

Each phase is independently mergeable and revertable.

## 5. Validation

- `test/test_keeper_tool_alias.ml` — alias map round-trip + unknown name → teaching error.
- `test/test_keeper_symmetric_sandbox.ml` — assert that for `Docker_hardened` keepers, `keeper_fs_read` resolves through `docker exec`, not `Eio_unix.openfile`.
- 24h replay metric:
  - `unexpected_tool_names` distinct count over 24h: target **0** for the Anthropic 5 (`Bash|Read|Edit|Grep|Write`).
  - `Read` calls outside `/work/...` for hardened keepers: target **0**.
- Prompt cache: compare `cache_read_input_tokens` ratio before/after on `claude-opus-4-7` keepers (target ≥ baseline).

## 6. Open Questions

1. **`keeper_shell` op=git_clone** — needs network. Container `network_mode=inherit` already allowed; image needs `git` + GH token mount path agreed. Decide in B-1.
2. **`Skill` / `Agent` cognates** — keep as teaching error, or invent a `keeper_skill` surface? RFC defaults to teaching error; revisit after Phase A metrics.
3. **Dashboard column** — telemetry currently displays the internal name. Add a `(displayed-as)` column or keep internal as SSOT? Preference: keep internal, add tooltip.
4. **Non-hardened keepers** — should we eventually default everyone to hardened? Out of scope for this RFC; create follow-up after Phase C.

## 7. Rollback

Each phase guarded by an env flag (`MASC_KEEPER_TOOL_ALIAS=true`, `MASC_KEEPER_SYMMETRIC_SANDBOX=true`). Disable to revert immediately. Decisions.jsonl shape unchanged → dashboards unaffected by rollback.

## 8. Addendum — 2026-04-21 profile rename

After deploying, the three-variant external surface (`Legacy_local | Docker_hardened | Docker_with_git`) proved to mix two concerns: (a) execution location (host vs container) and (b) per-command credential mounting for git/gh. Only (a) is a stable profile attribute; (b) is a runtime dispatch decision.

The external surface is now collapsed to two variants:

| Old external variant | New external variant | Notes |
|----------------------|----------------------|-------|
| `Legacy_local`       | `Local`              | Same semantics. Fs scoped to `~/.masc/playground/<keeper>/`. |
| `Docker_hardened`    | `Docker`             | Same base semantics (hardened container with network=none). |
| `Docker_with_git`    | `Docker` + per-command dispatch | No longer a profile. When `sandbox_profile=Docker` and the `keeper_bash` cmd's leading token is `git`/`gh`, the container is launched with network=inherit + gh/git credential mounts *for that one command*. Surfaced in response JSON as `git_creds_enabled: true`. |

The 3→2 containment matrix (section 3.3) now reads:

| Keeper sandbox | Bash | Read | Edit/Write | Grep / keeper_shell |
|----------------|------|------|------------|----------------------|
| `Local` (default) | host (validated) | host | host | host |
| `Docker`          | container | container | container | container |

Compat: `sandbox_profile_of_string` accepts the three old strings and warns via `sandbox_profile_of_string_with_warning`. The compat arm is removable once all state JSON/TOML files are rewritten. No other RFC-0006 semantics change.
