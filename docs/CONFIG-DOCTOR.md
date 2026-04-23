---
status: runbook
last_verified: 2026-04-23
code_refs:
  - bin/main_eio.ml
  - lib/config/
---

# Config Doctor

`main_eio.exe doctor` is the canonical operator path for answering:

- Is this base path initialized?
- Which config root is actually active?
- Am I accidentally looking at the repo seed config instead of the live config?

This document is the operating SSOT for config diagnosis. It intentionally
describes the supported launcher contract, not every low-level fallback path in
the raw resolver.

## Quick Start

Built binary:

```bash
./_build/default/bin/main_eio.exe doctor --base-path "$PWD"
```

JSON output for automation:

```bash
./_build/default/bin/main_eio.exe doctor --base-path "$PWD" --json
```

`doctor` 는 내부적으로 subcommand group 이다. 위 예제처럼 서브 없이 호출하면
기본 `config` subcommand 가 실행된다. 명시적으로 쓰려면:

```bash
./_build/default/bin/main_eio.exe doctor config --base-path "$PWD"
./_build/default/bin/main_eio.exe doctor auth --base-path "$PWD"
./_build/default/bin/main_eio.exe doctor sidecar <discord|slack|telegram|imessage|cli>
```

Sidecar dispatch 는 `docs/DOCTOR-ARCHITECTURE.md` 의 "Dispatch" 섹션 참조.
`codex cannot CanAdmin` 같은 auth/bearer mismatch 는 이 문서 범위가 아니며,
`doctor auth` + `docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md` 를 사용한다.

Typical results:

- `status=ok`, `init_state=initialized`
  - Active config is ready. Edit `active_config_root`.
- `status=warn`, `init_state=shadowed`
  - `MASC_CONFIG_DIR` is active, but `<base-path>/.masc/config` also exists.
- `status=error`, `init_state=missing_init`
  - The supported active config root for this base path is not initialized yet.
- `status=error`, `init_state=invalid_env`
  - `MASC_CONFIG_DIR` or `MASC_PERSONAS_DIR` points at an invalid directory.

Exit codes:

- `0`: healthy diagnosis (`status=ok`)
- `1`: operator action required (`status=warn` or `status=error`)

## Active Root Rules

`doctor` uses the supported operator contract:

1. If `MASC_CONFIG_DIR` is set, that directory is the active config root.
2. Otherwise, the active config root is `<base-path>/.masc/config`.
3. `MASC_PERSONAS_DIR`, when set, overrides only the active personas root.
4. `repo/config` is never treated as the active config root by `doctor`.

`repo/config` is a bootstrap seed only. Supported launchers copy or materialize
that seed into the active root under `.masc/config`.

## What `doctor` Reports

Core fields:

- `base_path`: effective workspace root being diagnosed
- `runtime_data_root`: `<base-path>/.masc`
- `active_config_root`: the config root that operators should edit
- `active_personas_root`: the personas root actually in effect
- `config_root_source`: `env` or `local_masc`
- `local_base_config_root`: the base-path local config candidate
- `local_base_config_initialized`: whether the local base root already has a
  usable config signature
- `repo_config_seed_path`: checked-in seed config, when discoverable
- `keeper_runtime_toml_present`: whether active runtime tuning exists at
  `<active_config_root>/keeper_runtime.toml`
- `sandbox_preflight`: Docker keeper sandbox readiness (`docker` daemon,
  local image presence, required commands, hardening checks)

Important interpretation:

- If `repo_config_seed_path` differs from `active_config_root`, the repo config
  is not live. Edit the active root instead.
- `shadowed` means both roots exist, but the explicit env root wins.
- `missing_init` means the supported active root is not ready even if other
  fallback locations exist elsewhere on disk.
- `sandbox_preflight` is independent of config init state. Even when no live
  config root exists yet, `doctor` still reports whether the default Docker
  keeper sandbox image can actually run.

## Secondary Proof Surfaces

`doctor` is the first proof surface. Running server endpoints are secondary
cross-checks:

- `GET /health`
  - confirms startup phase and runtime path diagnostics
- `GET /health/ready`
  - confirms the server finished blocking startup
- `GET /api/v1/dashboard/shell`
  - shows `config_resolution` and `runtime_resolution`
- `GET /api/v1/dashboard/runtime-probe`
  - runtime-only probe, useful after the server is already up

Use these when you need to compare offline diagnosis with the currently running
server. Do not use them as a substitute for `doctor` when deciding which config
root to edit.

## Appendix

### Supported launcher model

- `scripts/run-local.sh`
  - treats `<target>/.masc/config` as the local active root
- `start-masc-mcp.sh`
  - resolves `MASC_BASE_PATH`, then defaults `MASC_CONFIG_DIR` to
    `<base-path>/.masc/config` when unset
- `main_eio.exe --base-path ...`
  - bootstraps `<base-path>/.masc/config` before runtime initialization

### Low-level fallback note

`Config_dir_resolver` still has optional repo fallback behavior behind
`MASC_ALLOW_REPO_CONFIG_FALLBACK=true`, plus home-level compatibility paths.
Those are implementation details, not the normal operator contract.

If you need to answer “what should I edit right now?”, use `doctor`, not the raw
fallback chain.
