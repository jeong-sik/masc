---
rfc: "0394"
title: "Local playground fail-closed; execution relocates off-host (SSH, then microVM)"
status: Draft
created: 2026-08-27
updated: 2026-08-27
author: jeong-sik
supersedes: []
related: ["0213", "0208", "0001"]
---

# RFC-0394 — Local playground fail-closed; off-host execution

> **2026-08-31.** The relocation this RFC describes finished, and the profile
> went with it: `Local` is no longer a `sandbox_profile`, and
> `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND` no longer exists. A keeper declares
> `docker`, `microvm`, or `remote_ssh`, and one that declares nothing is
> refused at config load rather than resolved to a host default. The
> fail-closed gate specified below has no subject left; what remains of this
> RFC is the reasoning that removed it.

- Supersedes RFC-0213 §5's durable recommendation (B1 seatbelt). Rationale:
  seatbelt is a deprecated Apple API and still shares the host kernel; the
  workspace trust boundary we actually want is a machine boundary.
- Activates RFC-0213 §4 option C (off-host microVM), phased:
  - **Phase 0 (this RFC):** `sandbox_profile = "local"` is rejected at config
    load, keeper create/update, and dispatch unless
    `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1` (dev/test escape hatch; dispatch logs
    a per-process warning naming the keeper when the hatch lifts the gate).
  - **Phase 1:** OpenSSH remote exec lane (`sandbox_profile = "remote_ssh"`).
  - **Phase 2:** per-keeper Firecracker microVMs on a remote Linux host; the
    SSH endpoint becomes the VM.
- Fail-closed per RFC-0001: an unreachable remote or a disabled local profile
  is an error, never a silent fallback to host execution.
- Design spec: docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md

## Behavior changes

- Keeper create/update without an explicit `sandbox_profile` is now rejected
  instead of silently defaulting to `local`. The published tool schema
  default is `"docker"`; schema defaults are descriptive only and never
  injected (`lib/tool_surface/tool_definition_toml.ml` treats them as
  comments), so callers must pass the field explicitly.
- Existing keepers whose TOML pins `sandbox_profile = "local"` fail their next
  config load or update unless migrated to `"docker"` (or run under the
  hatch). The last bundled offender (`config/keepers/issue_king.toml`) moved
  to `docker` in this change.
- Dispatch errors name the reason: `local_playground_disabled: ...`.

## Escape hatch

`MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1` lifts all three gates for the process
(dev/test only). Test stanzas that exercise the typed dispatch on a local
profile set it via `(setenv MASC_EXEC_ALLOW_LOCAL_PLAYGROUND true (run %{test}))`
in their dune stanza, with a header comment stating why the hatch is
incidental to what the suite measures.
