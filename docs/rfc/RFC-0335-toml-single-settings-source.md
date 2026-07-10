# RFC-0335 — TOML as the Single Settings Source

- **Status:** Draft
- **Authors:** Vincent (yousleepwhen)
- **Created:** 2026-07-09
- **Related:** RFC-0274 (workspace base-path SSOT), RFC-0032 (env-knob unification), RFC-0317 (in-process Slack gateway)
- **Supersedes:** dotenv sourcing in `start-masc.sh`; env-as-config reads across `env_config_*` and call sites

## TL;DR

All settings — credentials and configuration alike — live in TOML. `runtime.toml` holds config
(tracked), `credentials.toml` holds secrets (gitignored). The `env_config_*` boundary reads TOML, not
`getenv`. dotenv sourcing is removed. The process environment is no longer a settings source (with two
narrow exceptions). One source of truth, every launch path agrees.

## Why

The 2026-07-09 Slack offline incident exposed a structural fault, not a bug: a token "in the
environment" resolved differently depending on launch path (`start-masc.sh` sourced dotenv; direct
`main_eio.exe` inherited the parent shell; the parent was a stale session). The investigation found 52
SSOT violations and 68 operator traps, all rooted in **two coexisting settings sources — env and
files** — that drift.

The disciplined fix is not to arbitrate between them but to **collapse to one**. TOML is already the
config SSOT (`runtime.toml`: trigger policy, timeouts, model catalog) and the read path already exists
(`config_dir_resolver` + `Otoml`; `resolved_trigger_policy()` reads TOML-first). Extending that to
credentials and the remaining config removes the entire fault class.

## Decision

1. **`credentials.toml`** (in `config_dir`, gitignored) — secrets: `SLACK_APP_TOKEN`,
   `SLACK_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, alert/webhook tokens, API keys. Permissions `0600`.
2. **`runtime.toml`** (tracked) — non-secret config: `MASC_SEARXNG_URL`, tuning knobs (RFC-0032
   catalog), everything currently mis-filed in `.env.local`.
3. **`env_config_*` boundary reads TOML, not `getenv`.** `env_config_slack.app_token_opt` becomes a
   `credentials.toml` read (reusing the TOML-first pattern already in `resolved_trigger_policy`).
   `env_config_discord`, `env_config_core` config fields likewise.
4. **No env fallback.** A value is in TOML or it is unset. This is the point: removing the second
   source removes the drift.
5. **dotenv sourcing removed** from `start-masc.sh` (`load_env_file`, `load_base_path_env_local`,
   preserve/restore loops — all gone; the script becomes base-path resolve + build + `exec`).
6. **Two exceptions stay env-only** (not TOML), because they bootstrap or are OS-level:
   - `MASC_BASE_PATH` — resolves `config_dir`, so it must exist *before* any TOML is read. Stays a
     CLI arg (`--base-path`), per RFC-0274. (Putting it in TOML is circular.)
   - OS environment that is not settings: `PATH`, `HOME`, `OPAM`/`CAML_*`, `OCAMLRUNPARAM`. These are
     process runtime, not MASC config.
7. **Production deployment** injects via mounted `credentials.toml` / `runtime.toml` (compose volume,
   k8s secret/configmap, launchd writes the file). Not via `environment:` for settings — though
   `MASC_BASE_PATH` and OS env remain env-injected per the exceptions.

## Scope and staging

"Full TOML transition" is large (many `getenv` sites), so it lands as staged PRs, each independently
green and revertible. The RFC owns the vision and the stage boundaries; each stage is a PR.

- **W1 — Connector credentials → `credentials.toml`.** `env_config_slack`/`env_config_discord` read
  TOML; `getenv` removed for `SLACK_*`/`DISCORD_*`. Fix the direct-`getenv` leak in
  `lib/keeper/keeper_alerting.ml` (`SLACK_TOKEN`/`SLACK_USER_TOKEN`) by routing through the boundary.
  This stage alone resolves the incident.
- **W2 — Config boundary → `runtime.toml`.** `env_config_core` config fields and path-family
  (`MASC_CONFIG_DIR`, `MASC_PERSONAS_DIR`, `MASC_SIDECAR_ROOT`) move to TOML; `MASC_BASE_PATH` stays
  CLI-arg per exception §6. RFC-0274's path-safety becomes "TOML is the only writer" — no shell defense
  needed.
- **W3 — Residual `getenv` sites absorbed.** Every remaining settings `getenv` outside the boundary
  (found in the investigation) routes through `env_config_*` → TOML. A lint/ci rule forbids `Sys.getenv`
  for settings outside the boundary.
- **W4 — dotenv removal + env-fallback purge.** Delete `start-masc.sh` dotenv sourcing; remove the
  last env fallbacks; update install wizard to emit `credentials.toml`/`runtime.toml` instead of
  `.masc/config/.env.local`; update docs.

Doc fixes ride with W1 (they are small and directly caused the incident):
`connector-setup-guides.ts` location guidance; `connector-status.ts:1142` copy-paste fix; README Slack
in-process update.

## Install safety

- No settings file is ever read from an env file → the file/git-leak surface and the
  caller-vs-file contest both vanish.
- Dev and prod read the same TOML (dev: `config_dir/credentials.toml`; prod: mounted
  `credentials.toml`). One path.
- The wizard stops writing `.masc/config/.env.local`; it writes/edits `credentials.toml` (mode 0600)
  and prints the prod mount snippet.

## Verification

- `env_config_slack.app_token_opt` returns the value from `credentials.toml`; `getenv` is not called
  for it. Direct `main_eio.exe`, `start-masc.sh`, and container entrypoint all resolve the token
  identically.
- `GET /api/v1/gate/connector/status?name=slack` is `connected` when `credentials.toml` has the token,
  `offline` (unset message) when not — regardless of launch path or shell state.
- CI rule (W3): `rg 'Sys\.getenv' lib/` outside `lib/config/env_config_*` + allowlist fails.
- Regression: RFC-0274 — `MASC_BASE_PATH` disagreeing with the resolved root warns/refuses (still
  CLI-arg authoritative).

## Open questions

1. `credentials.toml` location: `$config_dir/credentials.toml` (alongside `runtime.toml`), or a
   separate secret dir? Lean: alongside, 0600, gitignored by the existing `.masc` ignore.
2. Migration helper: a one-shot that reads an existing `.env.local`, classifies lines
   (credential → `credentials.toml`, config → `runtime.toml`), and writes both — credentials file
   chmod 0600. Auto-write is acceptable here because the output file is gitignored and local.
3. Should prod still allow `environment:` override for `MASC_BASE_PATH` only (the bootstrap
   exception), or require CLI arg uniformly? Lean: allow env for the bootstrap var only.
4. Telemetry: at boot, log which credential/config keys are present in TOML (names, masked) so the
   next "why is X unset" is debuggable without re-introducing env inspection.
