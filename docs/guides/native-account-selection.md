# Native account selection

Claude Code and Codex bindings select their permitted process environment when
the runtime is materialized. The selected context owns the configuration
directory, how it was selected, and the allowed credential environment. Quota
scope, Keeper execution, continuation fingerprints, Fusion, usage reads,
Dashboard probes and verification use that context. Later changes to the server
process environment do not move an admitted binding to another account home.
Reloading the configuration selects a new context; a changed context invalidates
the previous dispatch observation even when the TOML text is unchanged.

An explicit `account-home` keeps the existing credential isolation policy.
Claude omits inherited provider credentials. Its child also gets
`ANTHROPIC_CONFIG_DIR=<account-home>/anthropic`, so the Anthropic profile it
reads (the `ant` CLI, workload identity federation, a Console sign-in without
an API key) is the one of that account and not the one of the server's OS
user. A declared account that authenticated through a profile in
`~/.config/anthropic` signs in again. Without `account-home` the child reads
the profile directory under the inherited `XDG_CONFIG_HOME` or `HOME`. Codex omits account overrides unless
the selected home's provider configuration explicitly names their environment
variables. Setup, login and account display still select the current environment
at the time of their operation. They do not change an already materialized
binding's context.

Claude's inherited user-HOME mode remains distinct from an explicit or inherited
`CLAUDE_CONFIG_DIR`. Its ordinary account file is `HOME/.claude.json`; directory
modes use `.claude.json` inside that directory. The client's legacy `.config.json`
preference remains in place. A captured relative CLI directory keeps the working
directory against which it was selected.

Codex verification copies connection configuration and file-backed credentials
from the selected source into a private home. Its process environment derives
from the captured context and is filtered again using the private configuration's
declared credential names. The private process store does not replace the
binding's original quota or continuation scope.

MASC does not pass Codex `--profile`. Put the connection intended for a binding
in its selected home's root `config.toml`. Codex 0.134.0 and later use separate
profile files selected by that flag; inline `profile` and `profiles` settings
are retired. MASC rejects those fields rather than interpreting them as an
active connection. See the [official profile documentation](https://learn.chatgpt.com/docs/config-file/config-advanced#profiles).

This selection freezes paths and projected environment values. Credential files,
keychains, external credential helpers and the vendor's actual account subject
can still change. Confirmed vendor identity requires a fresh execution
observation; a selected directory or synthetic test is not that observation.
