# MASC Interactive Install Wizard Design

**Date:** 2026-07-02
**Scope:** `scripts/install.sh`, typed runtime catalog/default writer commands, runtime schema metadata, and install-wizard tests.
**Status:** Implemented in PR #23060; retained as the design record for review.

## Goal

Make `install.sh` interactive when run in a TTY so that a single command can:

1. Download and install the `masc` binary.
2. Seed default config files (`tool_policy.toml`, `runtime.toml`).
3. Let the user pick a default provider.
4. Collect the required API key securely.
5. Write `.masc/config/.env.local`.
6. Optionally verify provider connectivity.
7. Print the exact command to start the server.

After the wizard finishes, the user should only need to run `source .masc/config/.env.local && masc start`.

## Motivation

Current install flow leaves the user at a dead end:

- `install.sh` downloads the binary and seeds configs, but does not ask for a provider key.
- The first `masc start` fails with `refusing to boot` if `.env.local` is missing.
- The user must manually read `runtime.toml`, identify the default provider, find its env key, create `.env.local`, and source it.

A wizard removes this friction and prevents the common "server exits immediately" first-run experience.

## Scope

### In scope

- Modify `scripts/install.sh`.
- Add interactive prompts for provider selection and API key entry.
- Generate `.masc/config/.env.local`.
- Add optional provider connectivity check.
- Add flags for CI/automation: `--no-wizard`, `--wizard`, `--provider`, `--api-key`.
- Update `test/test_install_script.ml` to cover the wizard path.

### Out of scope

- Changes to the `masc` binary or new subcommands.
- Dashboard installation wizard.
- Web onboarding.
- Automatic keeper creation.

## User Flow (TTY)

```text
$ curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh | bash
==> platform: masc-macos-arm64
==> version: v0.19.51
==> installed: ~/.local/bin/masc
==> seeded configs to ./.masc/config

This looks like an interactive terminal. Let's finish first-time setup.

? Choose your default provider:
  1) ollama_cloud (default) — needs OLLAMA_CLOUD_API_KEY
  2) ollama_cloud_native — needs OLLAMA_CLOUD_API_KEY
  3) deepseek — needs DEEPSEEK_API_KEY
  4) glm-coding — needs ZAI_API_KEY_SB
  5) ollama (local) — no key needed
> 1

? Enter OLLAMA_CLOUD_API_KEY: ********
==> wrote ./.masc/config/.env.local

? Test connectivity to provider? [Y/n] y
==> provider ping: ok

Done. To start:
  source ./.masc/config/.env.local
  masc --base-path .
```

## Provider Catalog

The wizard derives provider IDs, display names, required environment keys, concrete default runtime bindings, and connectivity healthcheck paths through the installed `masc runtime-wizard-catalog` command. That command reads the seeded `config/runtime.toml` through the typed runtime parser; `scripts/install.sh` does not parse TOML itself. Each provider's concrete wizard runtime must be marked explicitly with `wizard-default = true` on exactly one provider/model binding.

The default provider selection is the provider named in `[runtime].default` of the seeded `runtime.toml` (`ollama_cloud` as of this design).

## New Flags

| Flag | Purpose |
|---|---|
| `--wizard` | Force interactive wizard even when not a TTY. |
| `--no-wizard` | Skip wizard even on a TTY. |
| `--provider ID` | Pre-select a provider (CI / non-interactive). |
| `--api-key KEY` | Provide the key without prompting (CI / non-interactive). |
| `--dry-run` | Existing flag; prints what would be written, including a masked `.env.local`. |

In non-TTY mode, `--provider` plus `--api-key` or the selected provider's credential env var writes `.env.local` without prompting. `MASC_API_KEY` is only accepted for providers that declare `credentials.key = "MASC_API_KEY"` in `runtime.toml`.

## Security

- API key input uses silent `read -s` so the key is not echoed or logged.
- The key is never printed, even in dry-run mode (only `KEY=***` is shown).
- `.env.local` is created with `0600` permissions if the platform supports it.
- Key precedence is `--api-key`, then the selected provider's `runtime.toml` credential env var (for example `DEEPSEEK_API_KEY`). `MASC_API_KEY` is not a cross-provider fallback; it is just another credential env var when selected by the provider catalog.

## Connectivity Check

After `.env.local` is written, the wizard optionally pings the provider:

- If the provider declares a credential key, send an HTTP request to `endpoint + healthcheck.path` with the `Authorization: Bearer $KEY` header.
- If the provider has no credential key, probe the same `endpoint + healthcheck.path` without authorization.
- Missing healthcheck metadata is treated as an advisory skipped ping, not a guessed URL.

If the ping fails, the user chooses:

- `retry` — re-enter the key.
- `skip` — continue anyway.
- `abort` — exit without starting.

## Non-TTY Behavior

When stdin is not a TTY:

- The wizard is skipped by default.
- The existing install flow runs unchanged.
- A helpful message is printed pointing to `.masc/config/.env.local` and `docs/runtime-tunables.md`.

## Error Handling

- Missing required tool (`curl`, `chmod`, `mkdir`, `mktemp`, etc.): fail fast with a clear message.
- Provider key is empty after prompt: warn and ask again, or allow skip.
- Connectivity test fails: offer retry/skip/abort.
- Checksum file unavailable: existing behavior is preserved; wizard runs after the binary is installed.

## Backwards Compatibility

- Default behavior for non-TTY / CI remains unchanged.
- Existing flags continue to work.
- No changes to the binary or config formats.

## Testing

Update `test/test_install_script.ml` to add wizard-path coverage:

1. Mock TTY detection and feed scripted provider/key input.
2. Assert `.masc/config/.env.local` is created with the correct `export KEY=value` line.
3. Assert `--no-wizard` does not create `.env.local`.
4. Assert `--provider ollama` skips the key prompt.
5. Assert dry-run prints masked key but does not write the file.

## Open Questions

1. Should the wizard also offer to start the server immediately after success?
2. Should it detect an existing `.env.local` and ask to overwrite or keep?
3. Should connectivity checks be on by default, or default to `no` to keep install fast?

## Workspace Neutrality

MASC is a coordination layer for arbitrary repositories, not only for developing the MASC repository itself. The install wizard must not assume it is being run inside the MASC repo.

- The binary is installed to a global location such as `$HOME/.local/bin/masc`.
- All per-project configuration, state, and secrets live under the **current working directory** at `.masc/config/`.
- Running the installer in `/path/to/my-project` produces a MASC workspace for `my-project`.
- The wizard therefore asks for the provider key relative to that workspace, writes `.masc/config/.env.local` there, and prints `masc --base-path .` as the local start command.

This keeps the install step (global tool) separate from the workspace initialization step (project-local config).

## Recommendation

Implement Option A as described. It is the smallest change with the largest first-run UX improvement and requires no binary work.
