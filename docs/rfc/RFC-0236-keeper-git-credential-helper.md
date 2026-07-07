---
rfc: "0236"
title: "Keeper git credential helper: make the ambient GH_TOKEN usable by git-over-HTTPS"
status: Draft
created: 2026-06-14
updated: 2026-07-07
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
- Non-goal (refined by §10): token **rotation/validation policy** (explicit expiry checks, scope auditing) remains a separate ops concern. Token **source diversification** — replacing the shared PAT with per-keeper short-lived installation tokens — moves in scope under §10.
- Non-goal: SSH auth (the `Identity file id_ed not accessible` cases are a separate, smaller class).

## 9. Open questions

- Does any keeper run git in a cwd outside the playground where `GIT_CONFIG_GLOBAL` would not apply? (Audit keeper git cwd before implementation.)
- Should the helper be restricted to `github.com` only (yes — scope to the host to avoid sending the token to other remotes).

## 10. Token source extension — GitHub App installation token (per keeper)

### 10.1 Problem (this amendment)

Section 8 deferred "rotating/validating the provisioned tokens" as a non-goal. The operational state that motivated this amendment (audited 2026-07-07): **every keeper shares the same classic Personal Access Token** materialised at `secrets/<keeper>/env/GH_TOKEN`. The blast radius of a single leak is the full fleet's GitHub authority; the token is long-lived with no expiry pressure; there is no per-keeper separation. This is the "expired/wrong-scope" class §8 pointed at, now concrete.

### 10.2 Proposal

Replace the shared PAT source with a **per-keeper GitHub App installation access token**, without changing RFC-0236's credential-helper contract. The helper `!gh auth git-credential` continues to read `GH_TOKEN` from the ambient env; only the *source* of that env value changes — from a static file to a short-lived, installation-scoped token minted at projection time.

GitHub App installation tokens (per [GitHub docs](https://docs.github.com/enterprise-cloud@latest/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)):
- minted by `POST /app/installations/{installation_id}/access_tokens`, authenticated with a RS256-signed JWT bearing the App's credentials;
- expire after **1 hour**;
- scoped to the installation's repositories and the App's permissions.

### 10.3 Architecture

New modules under `lib/keeper/`:

- `keeper_github_app_jwt.ml`: signs a GitHub App JWT (RS256) from the App ID + PEM-encoded RSA private key. Header `{"alg":"RS256","typ":"JWT"}`, payload `iss=<app_id>; iat=now; exp=now+9min` (GitHub rejects exp beyond 10min). RSA signing via `mirage-crypto-pk` (already in opam at 1.2.0; add to `dune-project` + `lib/keeper/dune`), base64url via the existing `base64` dependency.
- `keeper_github_app_installation_token.ml`: requests the installation token via `Masc_http_client.post_sync`, parses `expires_at`, caches per-keeper in a `Mutex`-protected `Hashtbl`. A cached entry is reused until `expires_at - 5min`; a later call re-mints. Mint errors surface as `Result.Error` (fail-closed — projection falls back to the existing static `GH_TOKEN` so a transient GitHub API outage does not brick the keeper).

Projection insertion (`keeper_secret_projection.ml`):
- In `local_env_for_keeper` / `docker_args_for_keeper`, immediately after `merge_env_entries roots`, if the keeper has GitHub App config loaded, mint (or reuse cached) the installation token and overlay `("GH_TOKEN", token)` ahead of the existing entries. This overlay flips `has_github_token` true, so the §3 git-config helper activates on the installation token exactly as it does on a PAT — no change to the credential-helper path.

Per-keeper config storage:
- PEM private key: `secrets/<keeper>/files/github-app/private-key.pem` (PEM is multiline, rejected by `validate_env_value`'s single-line env rule; the `files/` path is the existing file-projection channel, mounted read-only into the sandbox).
- `MASC_GITHUB_APP_ID` and `MASC_GITHUB_APP_INSTALLATION_ID`: numeric, single-line, valid as env at `secrets/<keeper>/env/`.

Redaction (`keeper_secret_redaction.ml`): add PEM begin/end markers (`-----BEGIN PRIVATE KEY-----`, `-----BEGIN RSA PRIVATE KEY-----`) to the deny-list so a leaked key never reaches logs/argv.

### 10.4 Security analysis

- An installation-token leak exposes at most 1 hour of installation-scoped authority, not the years-long PAT.
- Per-keeper App config means one keeper's PEM is not another's — isolation the shared PAT cannot provide.
- The PEM lives on disk under `files/` (read-only mount); it is never inlined into env or argv. Redaction denies it from logs.
- The token still flows through the §3 credential helper — git resolves it from env at call time, nothing secret is written to git config (RFC-0236 §5 preserved).
- Fail-closed on mint failure: projection keeps the static PAT fallback rather than silently dropping git auth. Operators see the failure in the projection result and can rotate.

### 10.5 Alternatives considered

| Approach | Rejected because |
|---|---|
| Keep the shared classic PAT | Blast radius = full fleet; long-lived; no per-keeper separation (the problem this section exists to solve). |
| Per-keeper fine-grained PATs | Still long-lived (no 1h expiry); rotation stays manual; finer repo scoping but the expiry posture is unchanged. |
| OAuth user token per keeper | User-scoped, not installation-scoped; conflates keeper identity with a human account; harder to provision per keeper. |
| Mint the token inside the keeper container | Requires the PEM and signing logic inside the sandbox — larger trust surface; the projection layer already handles secrets and is the right boundary. |

### 10.6 Verification plan (additions to §7)

- JWT RS256 unit test cross-checked with `openssl dgst -sha256 -sign` against the same PEM.
- Installation-token mint + cache: mock GitHub API returns a token with `expires_at`; assert reuse within the window and re-mint after expiry.
- Redaction regression: a PEM literal in a scrubbed env is masked (`test_env_keeper_scrub` extended).
- Integration: a keeper whose `files/github-app/private-key.pem` is populated pushes over HTTPS using the minted installation token (the §3 helper consumes it).
- Census: `git_gh_auth_error` continues to drop; a new metric `keeper_github_app_mint_error` is watched over 168h.

### 10.7 Scope / non-goals (this amendment)

- In scope: JWT + installation-token modules, projection overlay, PEM redaction, per-keeper config storage contract, BE verification.
- Non-goal: dashboard UI for keeper App config (separate follow-up PR — operators provision via `secrets/<keeper>/` files until then).
- Non-goal: per-keeper installation scoping (a single installation covers the repos the App can see; finer per-keeper scoping needs multiple installations or Apps).
- Non-goal: token rotation/validation policy (the 1h expiry is the rotation; explicit validation remains a separate ops concern).
