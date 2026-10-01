---
status: reference
---

# Configuration

> Part of: [SPEC-INDEX](./SPEC-INDEX.md)

## 1. SSOT and path boundary

Configuration is loaded from the selected `BasePath` and decoded into a typed,
immutable snapshot. There is one canonical key for each setting. Environment
variables do not duplicate ordinary product settings; they are reserved for
process-launch concerns that cannot live in the checked configuration and must
be documented at that boundary.

Unknown keys, invalid variants, unresolved references, and decode errors fail
explicitly. Reload builds and validates a complete new snapshot before an
atomic swap. On failure, the prior snapshot remains active and the error is
observable.

## 2. Boundary ownership

| Configuration | Owner | Rule |
|---|---|---|
| provider/model catalog and call features | agent core | generic; imports no MASC concept |
| runtime id and fallback membership | agent core config, referenced by MASC | MASC stores ids, not vendor branches |
| Keeper instructions/world/runtime | MASC Keeper config | one immutable snapshot per Keeper cycle |
| Tool descriptors and schemas | registered tool modules | no parallel policy table |
| Gate mode and judge runtime | MASC Gate config | generic, no product/tool cases |
| Scheduler conditions | MASC Scheduler | explicit time/event expressions |
| Connector bindings | Connector config | typed external space identity |
| Fusion panel/Judge | Fusion config | explicit members and runtime ids |

Checked-in constants are preferred when a value is an invariant rather than an
operator choice. Configurability is not added speculatively.

## 3. Keeper runtime selection

A Keeper assignment (`[runtime.assignments]`, or a lane id in
`[runtime.lanes]`) names a routing id, not a binding. `resolve_assignment`
takes a declared lane first; an id naming a bare runtime resolves to a lane
holding that runtime alone. A lane walks exactly the candidates it declares,
in declaration order — an explicit ordered membership, not a health tier,
score, or vendor-specific branch. A candidate that failed on timeout, 5xx,
or network is demoted until it answers (#36935). An assignment pointing at a
slot the lane does not list falls back to declaration order (#39037).
Provider outcomes are recorded and returned to the Keeper/LLM; MASC does not
turn them into cooldown or admission policy.

Runtime declarations describe capabilities reported by agent core, including text,
tool use, reasoning/thinking, multi-turn, image/audio/voice, streaming, and
structured output. MASC must not guess these features from model-name strings.

### Context window precedence

`max-context` is an optional positive integer on a binding (`[provider.model]`),
a provider (`[providers.provider]`) or a model (`[models.model]`). The binding
wins, then the provider, then the model default; without a declaration, a known
provider/model capability supplies the window. A genuine catalog hard limit
still clamps an oversized declaration. Model defaults synthesized into custom
capabilities do not limit a more specific declaration.

A provider-level default applies to every binding under that provider and
outranks each model default. Use a binding-level declaration when a model
needs a smaller deployment window.

The same model can therefore serve different windows without duplicating its
model definition:

```toml
[models.sol]
api-name = "gpt-6.1-sol"
max-context = 272000

[providers.codex_standard]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/absolute/path/to/codex-account"

[providers.codex_extended]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/absolute/path/to/codex-account"
max-context = 400000

[providers.codex_large]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/absolute/path/to/codex-account"
max-context = 400000

[codex_standard.sol]
# Inherits the model default: 272000.

[codex_extended.sol]
# Inherits the provider default: 400000.

[codex_large.sol]
# Overrides the provider default: 1000000.
max-context = 1000000
```

These values declare deployment intent; they do not prove an account supports
that window. The resolved MASC window is passed to Codex on start and resume,
independently of the selected account home's config. Runtime context metadata
reports whether the binding, provider, model or capability supplied the value,
including capability clamping. Config edits preserve these declarations in the
runtime TOML; account login does not change their precedence.

### Official-client accounts and Muse Code

Claude Code, Codex, Antigravity and Muse Code own their model/tool loops. MASC
owns Keeper routing, durable session bindings, attached MASC tools and process
lifetime. Select the account used by the server process; a browser login on a
separate machine does not select that account.

| Client | Provider protocol | Account selection |
|---|---|---|
| Claude Code | `claude-code` | `account-home` selects `CLAUDE_CONFIG_DIR` |
| Codex | `codex-app-server` | `account-home` selects `CODEX_HOME` |
| Antigravity | `antigravity-cli` | A file credential selects the OAuth source; MASC seeds a separate managed HOME |
| Muse Code | `muse-serve` | Required `account-home` selects the process HOME and native session/data roots; MASC supplies a managed configuration directory |

`masc setup` and the web model picker offer all four official clients. Declared
`account-home` values survive setup unchanged. A new Claude Code, Codex or Muse
connection first selects an existing account directory; the browser selects
only the account declared on the server or its CLI default and retains an
opaque account reference. It cannot send arbitrary credential paths or commands.
The native wizard can select another absolute account directory and runs vendor
sign-in with that selected `CLAUDE_CONFIG_DIR`, `CODEX_HOME` or `HOME`.

Muse model discovery labels provider, bundled and configured catalog metadata;
it does not prove account access or a successful invocation. Fake, unresolved
and unknown catalog sources cannot admit a new setup connection. A selected Muse
model needs a reported context large enough to hold the host's own overhead
(75% of it above 11,946 tokens, so at least 15,930); MASC derives its
start-prompt ceiling from that context (see the template below), so setup asks
for no byte count.
Saving a connection then requires the separate response and MCP tool challenge.


For Muse, inspect the installation actions with
`masc prerequisite-actions muse-code`, and install with
`masc prerequisite-actions muse-code --execute muse_native_install`. Then sign in to the chosen account HOME using the vendor's sign-in flow. The
selected HOME must contain the file-backed `.config/muse/auth.json` produced by
that flow. MASC imports authentication into a managed generation and preserves
vendor refreshes there; a changed source authentication file creates a new
session generation. This does not establish a separate macOS Keychain identity.
Source hooks, plugins and permission settings are not imported into the managed
configuration.

Sign in before assigning the runtime. The installer and the TUI (`/login muse`)
both start the vendor's sign-in with the environment every Muse child gets
(`Runtime_muse_serve.login_environment`): the account HOME and XDG roots, no
ambient provider credentials or `TBH_*` overrides, and
`TBH_CREDENTIAL_BACKEND=file`, which makes the client write the sign-in into
`auth.json` instead of the macOS Keychain. From a shell, the same sign-in is:

```sh
masc runtime-account-login --client muse --account-home /absolute/path/to/muse-account
```

Running the vendor command by hand needs that environment. The vendor documents
`TBH_CREDENTIAL_BACKEND` only in its SDK example harness (`isolatedHostEnv`);
masc depends on it for every Muse child.

```sh
HOME=/absolute/path/to/muse-account \
XDG_CONFIG_HOME=/absolute/path/to/muse-account/.config \
XDG_DATA_HOME=/absolute/path/to/muse-account/.local/share \
XDG_CACHE_HOME=/absolute/path/to/muse-account/.cache \
XDG_STATE_HOME=/absolute/path/to/muse-account/.local/state \
XDG_RUNTIME_DIR=/absolute/path/to/muse-account/.local/run \
TBH_CREDENTIAL_BACKEND=file \
MUSE_NO_AUTO_UPDATE=1 \
muse login
```

The flow must leave `.config/muse/auth.json` under that HOME; MASC reads that
file on first use (`Runtime_muse_home.prepare`). Owned account and
credential-parent directories must not be group/other writable. Muse turn
admission fails with a provider authentication error when:

- the file is missing or has no Meta credentials: `Muse account has no
  file-backed sign-in; sign in to the selected account home`;
- the Meta slot is marked `storage: "keychain"` (a sign-in made without the
  file backend on macOS): `Muse account keeps its sign-in in the macOS
  Keychain, which masc cannot hand to a selected account; sign in again from
  masc (/login muse in the TUI, or the installer's Muse sign-in)`;
- the slot names any other `storage` value, which is refused the same way.

A slot with no `storage` marker is read as holding its secrets inline; whether
it really holds one is not checked until the client authenticates. There is no
login probe: a completed Muse model turn is the evidence that sign-in worked.

`masc runtime-muse-models --account-home /absolute/path/to/muse-account`
queries the selected client's `model/list` without opening a session or making
a model call. Its JSON preserves the catalog source, nullable context/output
limits and reported reasoning tiers. A listed model is not evidence that this
account can invoke it. `fakeCatalog`, `unresolvedCatalog` and unknown sources
must not serve as setup admission evidence; absent context limits require an
explicit verified value before setup. No token-to-byte conversion is inferred.
The command deadline covers the cancellable metadata exchange; account
preparation can outlast it if the selected account filesystem stalls.

This template belongs in the selected base path's `.masc/config/runtime.toml`.
Replace both uppercase placeholders with the selected vendor model's actual ID
and documented context window before loading it. Leave `max-prompt-bytes` out:
the Muse host rewrites an input larger than its window instead of refusing it,
so MASC bounds the prompt it seeds a new session with at
`4 × (⌊75% of max-context⌋ − 11,946)` bytes, from Muse Code 1.4.0's measured
behaviour (its token estimate is UTF-8 bytes / 4, its own overhead is 11,946
estimated tokens, and it compacts at 75% of the window). A declared
`max-prompt-bytes` can only lower that ceiling; a larger value is not used,
because the host compacts a larger prompt whatever the file says. A Muse model
whose window leaves no room above the host's overhead is refused at load,
declared value or not. No runtime is assigned merely by adding a provider and binding.

```toml
[providers.muse_personal]
protocol = "muse-serve"
command = "muse"
account-home = "/absolute/path/to/muse-account"
is-non-interactive = true

[models.muse_selected]
api-name = "VENDOR_MODEL_ID"
max-context = CONTEXT_WINDOW_TOKENS
tools-support = true
streaming = true

[muse_personal.muse_selected]

# Add this entry to the existing assignments table after validating the account.
# [runtime.assignments]
# my_keeper = "muse_personal.muse_selected"
```

Muse native posture is declared under `[keeper.tools]` in the Keeper TOML:
`native = "read"` uses managed read policy and disables native writes and shell;
`native = "full"` requires the Keeper's `yolo` tool-approval mode and enables
native effects under the managed vendor policy. `native = "none"` is refused:
MSP cannot remove all built-in tools. Native effects do not pass through MASC's
tool approval gate. A native working directory is not a filesystem confinement
boundary; read posture does not establish that files outside it are unreadable.

For a Docker Keeper, native tools use the host directory mounted as its Keeper
workspace. They still run in the official client's host execution environment.
For an endpoint-owned microVM or SSH workspace, Muse uses a separate persistent
host directory and receives an explicit context note; use MASC tools for the
endpoint's actual files. This is not a claim that native execution moved into
the Keeper's guest.

Muse can carry text and declared image inputs, stream replies, call attached MASC
tools and resume a settled Keeper session. MSP has no output-schema channel:
Muse entries in exact-output lanes are rejected, and schema-constrained Fusion
calls are refused before spawn. Login probes remain unsupported. A successful
CLI start or metadata response is not evidence of an authenticated model turn;
actual completion and tool-call evidence must come from a run using the selected
account.

`masc runtime-verify muse_personal.muse_selected` performs that readiness
measurement using a private workspace and an authenticated MCP challenge.
Success requires the selected model to call the tool and return its actual
result; a model list or a fabricated result cannot satisfy the measurement.

## 4. Gate modes

Gate configuration is deliberately small:

```text
mode = Always_allow | Auto_judge | Manual
judge_runtime = <runtime-id>   # required only for Auto_judge
```

- `Always_allow` dispatches after the owning domain's objective invariants.
- `Auto_judge` calls the configured LLM and persists verdict, rationale,
  provenance, and correlation.
- `Manual` persists nonblocking HITL and returns `Deferred`.

Configuration contains no risk hierarchy, risk score, privileged actor,
product-specific credential/repository case, tool-name allowlist, or automatic
Keeper pause/stop. Gate mode is not a second tool catalog.

## 5. Scheduler and Connector

Scheduler entries contain an explicit typed time/event condition, target
Keeper, and stimulus payload. Triggering appends to that Keeper's durable lane.
A busy Keeper keeps the item queued; Scheduler does not skip or pause it based
on an idle score, cooldown, fleet pressure, or recent activity.

Connector entries bind a connector implementation to an explicit external
space and channel identity. Secrets/credentials remain at the connector's
credential boundary. Core MASC configuration does not recognize Discord,
GitHub, or another product in authorization logic.

## 6. Fusion

Fusion configuration declares panel members and a Judge runtime explicitly.
Each member result or failure is durable; the Judge receives the complete
available evidence asynchronously. There is no minimum response quorum,
majority authority, fixed concurrency budget, token budget, or semantic timeout
formula. Completion wakes the originating Keeper lane.

Judge-of-Judges is composition of the same Fusion/Tool boundary, not a new
hierarchy.

## 7. Observability

Every loaded snapshot has a stable revision and source path. Reload success and
failure, runtime resolution, Gate mode, Scheduler trigger, Connector binding,
and Fusion member/Judge selection are recorded with correlation and provenance.
Secrets are redacted at the typed secret boundary, not by substring matching.

## 8. Required invariants

- `INV-CONFIG-001`: one canonical key and one typed owner per setting.
- `INV-CONFIG-002`: all paths derive from `BasePath`.
- `INV-CONFIG-003`: reload is validate-then-atomic-swap.
- `INV-CONFIG-004`: agent core remains free of MASC concepts.
- `INV-CONFIG-005`: Tool descriptors are the tool-surface SSOT.
- `INV-CONFIG-006`: semantic Gate decisions use the configured LLM.
- `INV-CONFIG-007`: no config value automatically pauses/stops a Keeper.
- `INV-CONFIG-008`: Scheduler, Connector, Fusion, and Gate failures are local
  and observable.

### Interactive official-client account login

The authenticated setup surface can sign in to Codex, Claude Code, Antigravity,
and Muse from a TUI or browser connected to the server. Login runs in the
selected account's environment. It never changes the server environment or sends
operator input to a Keeper.

In the TUI, `/login` opens the account panel on the four clients, each with its
number of configured accounts; Enter lists that client's accounts, by email,
under a `+ 새 계정` row. `/login codex`, `/login claude`, `/login antigravity`,
and `/login muse` open a client's accounts directly. Enter on `+ 새 계정` (or
`n`) starts a new account, Enter on an account signs in as that account, `D`
previews removing it, and Esc goes back to the clients. Login codes stay
masked in the panel and terminal keys are sent to that login process. Ctrl-C
cancels; `r` retrieves the recovery receipt. After authentication, choose a model
and press Enter to verify and save.
The current default and its declared fallback order remain ahead of the added
model. In dashboard runtime setup, the equivalent login panel retains the
selected account through model discovery and save.

`POST /api/v1/setup/accounts/login` accepts `integration_id` and an optional
`account_ref`. Omitting the reference adds a private new account; supplying one
explicitly reauthenticates that selection. The server catalog chooses the
executable. Browser paths and shell commands are not accepted.

The response is SSE: `started` identifies the login and its recovery receipt;
`output` carries the CLI's instructions; `input_ready` acknowledges delivered
input; `complete` returns an account reference and an authentication observation;
`error` reports an incomplete operation. These instructions and inputs are
transient and are not copied into logs or transcripts.

- `POST /api/v1/setup/accounts/login/<id>/input` accepts `{kind:"text",text:...}`
  or `{kind:"key",key:"enter"|"up"|"down"|"tab"|"eof"}`. One input is pending
  until acknowledged. A text frame is limited to 64 KiB as a transport resource
  boundary, independently of how long the login takes.
- `POST /api/v1/setup/accounts/login/<id>/cancel` cancels that login.
- `GET /api/v1/setup/accounts/login/<id>` reads the private recovery receipt.
  Controls and receipts require the same authenticated actor and workspace.

Codex and Claude expose an `authenticated` native observation. Muse reports
`login_completed` after the successful official login and native credential
validation. Antigravity reports `credential_captured`; this is not a network
verification. All login receipts retain `invocation_verified:false`. The returned
reference is used for model discovery and the existing response/tool verification
before configuration publication. A save calls the runtimes it adds and the
runtime that becomes the first call in the chain. A runtime already bound in
`runtime.toml` that stays where it was is not called again. When the save leaves
any selected runtime uncalled, the receipt reports `readiness: "partly_checked"`
and lists them under `not_rechecked`; that says nothing about whether they ever
passed a check, and clients must not show the save as verified. `verified` means
every selected runtime answered a real check in that save. A runtime whose provider declines the check
for the account's usage (`quota_exhausted` or `rate_limited`) is still published:
the save receipt lists those runtimes under `unverified` with their code:
`readiness: "usage_limited"` when every selected runtime was called, and
`"partly_checked"` (with `not_rechecked`) when some were not. Any other verification failure refuses the
save and publishes nothing. `masc setup` applies the same rule when it checks
imp's runtime: a usage limit is reported and the step succeeds. Antigravity reauthentication publishes a new
reference, preserving the previous configured reference until an explicit save.

Cancellation and connection loss preserve already-written credentials and the
non-secret recovery receipt. Native account references exist before the CLI
starts. Antigravity captures a reference during normal completion or graceful
interruption; an abrupt server kill before capture can leave an interrupted
receipt without a reference. Such a receipt must not be presented as successful.

### Codex context admission

A scoped `max-context` is a requested nominal window. Before a Codex thread or
turn is dispatched, MASC reads the selected binary's catalog through an isolated
connection and refuses a request above its `max_context_window`. It never silently
calls a clamped request effective. The admitted catalog is passed to the actual
client as `model_catalog_json`, so a different account-local cached catalog cannot
change the ceiling between admission and dispatch. An unavailable or malformed
catalog refuses dispatch; no model prompt or tool call has been submitted.

Successful catalog admission is cached per binary, connection, workspace and
model/window. Binary metadata, account configuration, credentials, original catalog,
inherited configuration, and filtered environment revisions invalidate that cache.
Only digests and public model metadata are retained. There is no age-based cache.
An unchanged connection avoids a catalog subprocess on later turns.

MASC also overrides `model_auto_compact_token_limit` with the requested nominal
window. Codex applies its own model-native compaction headroom; an account-local
smaller threshold no longer silently controls a MASC turn. The catalog's usable
input percentage is recorded separately from the nominal window. This check does
not tokenize the vendor-composed prompt or prove that a 1M declaration is available
on an account whose client advertises a smaller maximum. The vendor remains the
authority for exact token admission and actual compaction.
