# RFC-0008: `CredentialProvider` Trait (Minimum Viable)

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-04-24
- **Revised**: 2026-04-30 — root credential fallback added and ambient operator credential fallback removed; §3 binding.env is composed **inside** `Host_config_provider.resolve` from the selected root/keeper bundle paths + `Env_git_noninteractive.env`.
- **Related**: RFC-0007 rev.3 (shares a review cycle), F-1 (#9843), F-2 (#9844), F-4 (#9847)
- **Drives**: convert the "keeper-scoped identity" label into an actual capability boundary; make credential lifecycle explicit so Option B (in-container login) can ship later without rewiring the caller

## 1. Problem (field-verified 2026-04-24)

Three observations from `~/me/memory/procedural-memory/2026-04-24-keeper-docker-github-provider-evidence-record.md`:

- **F-1**: `~/.masc/github-identities/anyang-keepers/gh/hosts.yml` stores the same OAuth token as `gh auth token` on the operator host (SHA-256 prefix `406d098bd41b` matches both sides). Identity separation is cosmetic.
- **F-2**: `gh auth login --with-token` (Option B path) rewrites `hosts.yml:user` to the real token owner. Any downstream code that reads `user:` loses the identity label.
- **F-4**: `scripts/rotate-keeper-gh-token.sh` used to default `GH_CONFIG_DIR` to a retired unscoped path. PAT rotation happened off-path, which is how F-1 drifted in.

All three share one failure mode: credential lifecycle (issuance → installation → consumption → rotation → teardown) is implicit. The runtime reads a fixed filesystem location; the rotation script writes to a different fixed location; there is no single object that says "this identity currently has this credential, with this finalize hook, and tears down this way."

## 2. Design principles

| # | Principle | claude-code analog |
|---|-----------|--------------------|
| P1 | **The credential boundary IS the token.** If two identities share a token, they share capabilities, regardless of labels. Enforce by issuance policy (one fine-grained PAT per identity), not by cosmetic overlays. | `subprocessEnv`'s pass-list contains only job-scoped tokens; long-lived host secrets are scrubbed. |
| P2 | **Provider owns lifecycle.** `resolve → finalize → tear_down` is the complete cycle. Any step that needs to run (e.g. identity relabel after `gh auth login --with-token`) is a method on the provider, not a global hook. | `PermissionPromptToolResultSchema` returns `{behavior, updatedPermissions, decisionClassification}` — decision + side effects in one object. |
| P3 | **Ship Option A first, gate Option B.** Host-mounted bundle works today (G3 PASS in evidence record). In-container login requires per-identity fine-grained PATs (F-1 must be resolved first). Shipping both together couples two unrelated risks. | claude-code ships sandbox-off defaults and hardens per-command later. Same ordering. |
| P4 | **Reuse `keeper_binding`.** It already returns `(path, env, metadata)` via `Result`. Wrap it; do not replace it. | claude-code wraps external `sandbox-runtime` rather than reimplementing isolation. Same discipline. |

## 3. Signature

```ocaml
(* lib/keeper/credential_provider.mli *)

type ro_mount = { host : string; container : string }

type binding = {
  identity  : string;                    (* keeper-scoped identity, e.g. "anyang-keepers" *)
  env       : (string * string) list;    (* composed inside resolve; see note below *)
  ro_mounts : ro_mount list;             (* host paths mounted read-only (Option A); empty for Option B *)
  bootstrap : string list option;        (* argv executed inside container after start; None for Option A *)
  metadata  : (string * string) list;    (* audit: source, issued_at, ttl_seconds, sha256_prefix *)
}

type error =
  | Missing_bundle   of { identity : string; path : string }
  | Invalid_token    of { identity : string; reason : string }
  | Finalize_failed  of { identity : string; reason : string }
  | Tear_down_failed of { identity : string; reason : string }

(** Must be total. Pure up to filesystem read; no network. *)
val resolve : config:Coord.config -> identity:string -> (binding, error) result

(** Called once per keeper session, after the container is up and (for Option B)
    after bootstrap argv has executed. Implementations MUST rewrite [hosts.yml:user]
    to [binding.identity] when that file exists in any writable mount. *)
val finalize : binding -> container_id:string -> (unit, error) result

(** Idempotent; safe to call even if finalize was never called. Caller runs this from
    [Eio.Switch.on_release] or equivalent so crashes still hit it. *)
val tear_down : binding -> container_id:string option -> unit
```

> **Evidence note (rev.2 cross-correction, 2026-04-30)**: The upstream `Keeper_gh_env.keeper_binding` exposes `{github_identity; effective_github_identity; credential_scope; git_identity_mode; bundle_root; gh_config_dir}`. If a keeper has no configured `github_identity`, it binds to `$base_path/.masc/github-identities/root/gh`; if that root bundle is missing, resolution fails closed. The `binding.env` list is therefore **composed inside `Host_config_provider.resolve`** from the selected bundle path — `HOME=<cred_root>`, `GH_CONFIG_DIR=<cred_root>/.config/gh`, `GIT_CONFIG_GLOBAL=<cred_root>/.gitconfig`, the `GIT_CONFIG_*` safe.directory block, `GIT_AUTHOR_*`/`GIT_COMMITTER_*` — plus `Env_git_noninteractive.env`. Ambient operator `GH_TOKEN`, `GITHUB_TOKEN`, `GH_CONFIG_DIR`, `SSH_AUTH_SOCK`, `~/.config/gh`, and keychain probes are not part of the provider contract.

Two concrete modules:

```ocaml
module Host_config_provider : sig
  include module type of Credential_provider
end

module In_container_login_provider : sig
  include module type of Credential_provider
  (** Refuses to resolve if the identity's token SHA-256 matches [gh auth token] on the
      operator host (i.e. F-1 is not yet resolved for this identity). *)
  val provider_gate : identity:string -> (unit, string) result
end
```

`provider_gate` is the fuse enforcing P3. A keeper that requests the in-container provider while its identity's token still matches the operator's will be refused at `resolve` time with `Invalid_token`.

## 4. Two-PR phasing

### PR-1 — module + `Host_config_provider` only (≈150 lines + tests)

- **New files**: `lib/keeper/credential_provider.ml(i)`, `lib/keeper/host_config_provider.ml(i)`, `test/test_credential_provider.ml`.
- **Caller change**: `lib/keeper/keeper_shell_docker.ml` swaps its inline `Keeper_gh_env.keeper_binding` call for `Host_config_provider.resolve` and reads `binding.env @ Env_git_noninteractive.env` for docker env flags (depends on RFC-0007 PR-1).
- **`finalize` in PR-1**: a noop (RO mount does not need user rewrite; the label in the host's `hosts.yml` is whatever the operator wrote). The method exists so PR-2 drops in without interface churn.
- **Why safe**: fail-closed at resolution time; no operator credential fallback remains. All focused provider/docker/scrub tests must stay green.

### PR-2 — fine-grained PAT issuance + rotate script fix (≈100 lines, mostly script)

- **Files**: rewrite `scripts/rotate-keeper-gh-token.sh` (in the `me` repo, branch `feat/rotate-keeper-gh-token`) to:
  - require `IDENTITY=<name>` argument,
  - target `$HOME/me/.masc/github-identities/$IDENTITY/gh` only,
  - verify the new token's SHA-256 **differs** from `gh auth token` (F-1 gate — `provider_gate` equivalent at rotation time).
- **`Host_config_provider` update**: `resolve` adds a metadata line `sha256_prefix=<first 12>` and surfaces it in `binding.metadata` so `provider_gate` in PR-3 can consult it without re-reading the file.
- **Why safe**: script is operator-facing; a mismatched identity × PAT never reaches the runtime.

### PR-3 (gated on PR-2 operational proof) — `In_container_login_provider`

- **Files**: new `lib/keeper/in_container_login_provider.ml`, a `bootstrap` argv that runs `gh auth login --with-token`, a `finalize` that rewrites `hosts.yml:user` inside the container, `provider_gate` that refuses if the token SHA matches the operator's.
- **Merge condition**: PR-2 has been running for ≥2 weeks with zero `provider_gate` violations in telemetry (every active keeper identity has its own fine-grained PAT).

## 5. What we explicitly do not do in this RFC

1. **Vault / 1Password / macOS Keychain integration.** The `binding.metadata.source` field is free-form today; integrations become separate RFCs that add new `source` values.
2. **PAT TTL tracking dashboard.** `ttl_seconds` metadata is recorded for future use; a dashboard belongs in masc-mcp dashboards, not here.
3. **Rewriting `keeper_gh_env.ml`.** We wrap it (`Host_config_provider.resolve` calls `Keeper_gh_env.keeper_binding` internally and maps fields). Deprecating it is a post-PR-3 cleanup.
4. **Changing hard-mode execution mode.** `MASC_KEEPER_SANDBOX_HARD_MODE=true` still requires an effective selected identity bundle; keeper-specific `github_identity` wins, otherwise the root bundle is used, and missing bundles fail closed.

## 6. Risks

1. **`finalize` is a cross-cutting concern.** Implementations may forget to call it. Mitigation: the caller in `keeper_shell_docker.ml` is the one call site; `finalize` is invoked from the same `Eio.Switch.on_release` as `tear_down`.
2. **`provider_gate` false positive.** If the operator rotates *both* the operator token and the keeper token from the same fine-grained ancestor, SHA-256 will differ but intent might still be "shared". Mitigation: the gate returns `error` rather than panic; the operator can set `MASC_KEEPER_ALLOW_SHARED_TOKEN=true` to override with an audit log line.
3. **Option B's container-local `hosts.yml` rewrite needs write permission to a named volume.** The RO mount in Option A does not, so `finalize` in Option A is truly a noop; an asymmetry worth encoding in `test_credential_provider.ml`.

## 7. Telemetry contract

Per resolve:
- `keeper_credential_provider_resolve_total{provider=host|container_login,result=ok|error}`
- `keeper_credential_provider_gate_blocked_total{reason=token_sha_match|missing_bundle|...}`

Per finalize:
- `keeper_credential_provider_finalize_relabel_total{result=ok|error}`

No schema change to the existing Prom registry; these are new keys only.

## 8. Evidence

- PoC trait shim proving symmetry between the two concrete implementations: `~/me/.tmp/keeper-docker-gh/provider-shim.sh`.
- Evidence record: `~/me/memory/procedural-memory/2026-04-24-keeper-docker-github-provider-evidence-record.md`.
- masc-mcp commit audited: `0e408ffc1d5b34badb0cc1b9f3704a9e725fb8c6`.
