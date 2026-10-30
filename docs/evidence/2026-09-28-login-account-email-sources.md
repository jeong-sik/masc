# Where each official client keeps the signed-in account email

Checked on 2026-09-28 on the operator's machine, read-only. Only key names and
value types were printed. No token, email address, or decoded subject was
recorded. The files were the operator's own login files and the managed homes
under `<base-path>/.masc/official-clients/`.

| Client | File, relative to the selected account home | Path to the email | Type |
|---|---|---|---|
| Codex | `auth.json` (`CODEX_HOME`) | `tokens.id_token`, OpenID claim `email` | string |
| Claude Code | `.claude.json` (`CLAUDE_CONFIG_DIR`) | `oauthAccount.emailAddress` | string |
| Muse Code | `.config/muse/auth.json` (`HOME`) | `providers.meta.user_email` | string |
| Antigravity | captured OAuth JSON | `id_token`, OpenID claim `email` | string |

Observed shapes (keys and types only):

```text
Codex auth.json
  auth_mode: string, OPENAI_API_KEY: null, tokens: object, last_refresh: string
  tokens: id_token: string, access_token: string, refresh_token: string, account_id: string
  id_token claims include: email: string, email_verified: boolean, sub: string

Claude Code .claude.json
  oauthAccount: object with accountUuid: string, emailAddress: string, ...

Muse Code .config/muse/auth.json
  schema_version: int, providers: object
  providers.meta: mechanism: string, storage: string, obtained_via: string,
    api_base_url: string, user_full_name: string, user_email: string
```

Antigravity's shape is in `2026-09-27-antigravity-account-identity.md`.

`claude auth status --json` (Claude Code 2.1.283) has an `email` key, but it was
`null` for a signed-in `claude.ai` account, so it is not the source.

The email is display text for setup's account list. It is not identity:
Antigravity identity stays the OpenID issuer/subject pair, and Claude Code's
stays its configured home spelling.

## Inherited homes

A provider without `account-home` runs its client on the home it inherits from
the server's environment. Checked on 2026-09-28, read-only:

| Client | Login file | Source |
|---|---|---|
| Codex | `$CODEX_HOME/auth.json`, else `$HOME/.codex/auth.json` | `Runtime_codex_app_server.effective_account_home` |
| Claude Code | `$CLAUDE_CONFIG_DIR/.claude.json`, else `$HOME/.claude.json` | Claude Code 2.1.283 bundle: `join(process.env.CLAUDE_CONFIG_DIR \|\| homedir(), ".claude" + suffix + ".json")` |
| Muse Code | `$XDG_CONFIG_HOME/muse/auth.json`, else `$HOME/.config/muse/auth.json` | `~/.local/bin/muse` launcher v3, lines 19-25 (`MUSE_AUTH_PATH` overrides, but masc does not pass it to the child) |

On the operator's machine `$HOME/.claude.json` has `oauthAccount`, while
`$HOME/.claude/.claude.json` exists without it, so the Claude Code file is not
inside the `$HOME/.claude` config directory.
