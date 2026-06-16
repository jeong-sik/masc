---
rfc: "0236"
title: "Keeper git credential helper: make the ambient GH_TOKEN usable by git-over-HTTPS"
status: Draft
created: 2026-06-14
updated: 2026-06-14
author: vincent
supersedes: []
related: ["RFC-0074", "RFC-0007"]
---

# RFC-0236 — Keeper git credential helper

## 1. Problem (evidence-grounded)

Keeper Execute failure census (`<base-path>/.masc/tool_calls/2026-06/{08..14}.jsonl`, 22,902 calls):

- `git_gh_auth_error` = **146** failures (3.55%). Top signature: `fatal: could not read Username for 'https://github.com'` (72), `You are not logged into any GitHub hosts` (23).
- The auth-failing keepers are `taskmaster` (55), `sangsu` (30), `issue_king` (10) — and they **have provisioned tokens**: `secrets/<keeper>/env/GH_TOKEN` and `GITHUB_TOKEN` exist for them.
- A second, distinct symptom shares the same root: keepers try to pass `GITHUB_TOKEN` / `GH_TOKEN` / `GIT_PASSWORD` / `GIT_ASKPASS` through the typed `Execute {env}` field. These hit the "typed Shell IR Docker dispatch does not support env yet" guard, and even if env were supported they would be (correctly) dropped by `Env_keeper_scrub`. This is keepers manually working around missing git auth.

**Root cause** (verified by code read): `GH_TOKEN` reaches the keeper environment on both profiles — Docker via `Keeper_secret_projection.docker_args_for_keeper` (`--env-file`), Local via `local_env_for_keeper` (`overlay_env_entries`). `gh` is present in the sandbox image (`Dockerfile.keeper-sandbox:24`). **But `git` over HTTPS does not consume `GH_TOKEN`** — only `gh` does. There is **no git credential helper, no `gh auth setup-git`, no `url.insteadOf` rewrite, and no `GIT_ASKPASS`** configured anywhere in `lib/keeper/` (verified: `rg "credential.helper|gh auth setup-git|insteadOf|GIT_ASKPASS" lib/keeper/` → empty). So a raw `git push origin <branch>` over `https://github.com/...` prompts for a username and fails non-interactively.

This blocks keepers from pushing branches / creating PRs over git — the core deliverable path of the autonomous fleet.

## 2. Relationship to RFC-0074 (Retired)

RFC-0074 (Sandbox Credential Auto-provision) was **Retired** with the contract: *"Git authentication is ambient to the process environment and is not materialized by MASC."*

That decision is sound for *not writing tokens to disk*, but it left a gap: an ambient `GH_TOKEN` env var is **not** automatically used by `git` over HTTPS. The retirement assumed ambient env is sufficient; the 146 failures prove it is not for git-native operations.

This RFC does **not** re-introduce token materialization. It proposes configuring git to **read the already-ambient token via gh's credential helper** — a config pointer, not a stored secret. The token stays in env; nothing secret is written to disk.

## 3. Proposal

Configure git, once per keeper sandbox, to use gh as its credential helper for `github.com`:

```
git config credential."https://github.com".helper "!gh auth git-credential"
```

(equivalently `gh auth setup-git`, which writes exactly this helper). `gh auth git-credential` reads `GH_TOKEN`/`GITHUB_TOKEN` from the ambient env — so no token is stored; the helper is a pointer that resolves the ambient token at git-time.

### 3.1 Docker profile

Run the `git config` once at container initialisation, after the env-file is in place, scoped to the container's git config (the container is single-tenant per keeper, so `--global` inside the container is safe and isolated). Insertion point: the keeper sandbox container setup path (`lib/keeper/keeper_sandbox_runtime_setup.ml`).

### 3.2 Local profile (the tricky case)

Local keepers (14/16 of the fleet) run git on the **host**, sharing the host user's `~/.gitconfig`. A `--global` write would mutate the operator's host gitconfig — invasive and a cross-keeper leak (one keeper's helper visible to all + to the human). Therefore the Local path must scope the config per keeper:

- Set `GIT_CONFIG_GLOBAL=<per-keeper gitconfig path>` in the keeper's projected env (so each keeper has an isolated global gitconfig under its playground), and write the credential helper into that file; **or**
- Inject `-c credential."https://github.com".helper="!gh auth git-credential"` on each keeper git invocation via the typed Shell IR git path.

The per-keeper `GIT_CONFIG_GLOBAL` approach is preferred: it is set once, isolates each keeper, never touches the host `~/.gitconfig`, and is removed with the keeper playground (still "not materialized" in any durable, shared sense).

## 4. Boundary

MASC keeper sandbox only (`lib/keeper/keeper_sandbox_runtime_setup.ml`, `lib/keeper/keeper_secret_projection.ml`). **OAS untouched** — git auth is a keeper-runtime concern, not an agent-SDK concern.

## 5. Security analysis (RFC-0007 alignment)

- The token is **not** stored: the helper is `!gh auth git-credential`, which resolves `GH_TOKEN` from env at call time. No token in argv, no token in a config file, no token in `url.insteadOf` (which would put it in process listings and git config).
- `Env_keeper_scrub` continues to block the **operator's ambient** `GH_TOKEN`/`*_TOKEN` (deny-suffix). The token git uses is the **per-keeper provisioned** token from `secrets/<keeper>/env/GH_TOKEN`, projected via the existing path. This RFC does not change what token is provisioned, only that git can use it.
- Local `GIT_CONFIG_GLOBAL` scoping prevents one keeper's git config (and thus its credential-helper pointer) from leaking to other keepers or the host user.

## 6. Alternatives considered

| Approach | Rejected because |
|---|---|
| `url."https://x-access-token:$GH_TOKEN@github.com/".insteadOf` | Materialises the token into git config / process listings — a leak, and violates RFC-0074 "not materialized". |
| `GIT_ASKPASS` script echoing the token | More moving parts (a script on disk), and the script would need the token — closer to materialisation. |
| Steer keepers to use `gh` instead of `git push` | Does not cover git-native ops (clone/fetch/push in worktrees) that keepers legitimately need; `gh` already works for API calls. |
| Support `Execute {env}` so keepers self-pass `GH_TOKEN` | The dominant env attempts ARE credential injection; `Env_keeper_scrub` correctly blocks them. Supporting it would either still block (deny model) or open a leak. Wrong layer. |

## 7. Verification plan

- A keeper git push over HTTPS with its provisioned token succeeds (integration, fake-remote or a scoped test repo).
- Census `git_gh_auth_error` ("could not read Username") drops on the next 168h sample after deploy.
- Security regression: `test_env_keeper_scrub` stays green (operator ambient `GH_TOKEN`/`*_TOKEN` still denied). Add a test that the Local path sets `GIT_CONFIG_GLOBAL` to a per-keeper path (never the host `~/.gitconfig`).
- Idempotence: re-running the `git config` is safe (overwrites the same helper).

## 8. Scope / non-goals

- In scope: Docker container git-config setup; Local per-keeper `GIT_CONFIG_GLOBAL` + credential helper; verification.
- Non-goal: rotating/validating the provisioned tokens (separate ops concern — some 146 failures may also include expired/wrong-scope tokens; this RFC fixes the *config* gap, not token lifecycle).
- Non-goal: SSH auth (the `Identity file id_ed not accessible` cases are a separate, smaller class).

## 9. Open questions

- Does any keeper run git in a cwd outside the playground where `GIT_CONFIG_GLOBAL` would not apply? (Audit keeper git cwd before implementation.)
- Should the helper be restricted to `github.com` only (yes — scope to the host to avoid sending the token to other remotes).
