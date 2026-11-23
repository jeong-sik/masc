---
status: reference
---

# Configuration

> Part of: [SPEC-INDEX](./SPEC-INDEX.md)

For Dashboard editing, draft retention, revision conflicts and workspace changes,
see [runtime.toml drafts](../guides/runtime-toml-drafts.md).
For the key-by-key reference of the provider/model/binding/lane tables
(`[providers.<id>]`, `[models.<id>]`, `[<provider>.<model>]`, lanes,
exact-output lanes, assignments), see
[Runtime TOML reference](../RUNTIME-TOML-REFERENCE.md).
For configuration-preserving Exact Lane activity and its Required/Optional
boundary, see [Exact Lane activity](../guides/exact-lane-activity.md).

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

`.masc/config/runtime.toml` uses a five-table schema:

1. `[providers.<id>]` — transport protocol (`openai`, `anthropic`, `gemini`, `codex-app-server`, `claude-code`, `antigravity-cli`, `acp`, etc.), endpoint/command, and account or credential reference;
2. `[models.<id>]` — `api-name`, `max-context`, and model capability declarations;
3. `[<provider>.<model>]` — concrete runtime binding combining a provider and model (with optional binding-level overrides such as `max-context`);
4. `[runtime.lanes]` and `[runtime.exact_output_lanes]` — ordered candidate lists of `<provider>.<model>` bindings for general turns and structured exact-output system tasks;
5. `[runtime.assignments]` — maps a Keeper name (or `default`) to a declared lane id or single `<provider>.<model>` binding.

The configurable builtin exact-output routes are `librarian_exact`,
`hitl_auto_judge`, `board_attention_exact`, `verifier_exact`,
`candle_appraiser`, `librarian_memory` and `workspace_memory_curator`. Board Attention and HITL are
Required; the other builtin routes are Optional according to `Standalone_lane.obligation`.

`librarian_memory` is the lane the Librarian asks through for one Keeper's
Memory changes. It is a separate table from `librarian_exact`: the two ask
different questions with different output sizes. First-run setup does not fill
it; the operator declares its slots. Like `verifier_exact`, every `slots` id
must name a configured runtime, and an enabled table must declare
`max_output_tokens`, or runtime.toml refuses to load. Each slot's
window comes from its binding's `max-context` (then provider, then model, then
the capability catalog), and a slot whose window cannot be resolved leaves the
lane without a value. Its asks keep no per-ask run record.

`workspace_memory_curator` is the lane the in-process World Memory curator
asks through, for classification and for the briefing. First-run setup does
not fill it; the operator declares its slots. Without this table the curator
asks no model, and declaring `librarian_memory` does not start it. Its asks
keep no run record: what the curator committed is in the World Memory log and
ledger. The curator does not read the Addon tables.

A Keeper assignment (`[runtime.assignments]`, or a lane id in
`[runtime.lanes]`) names a routing id, not a binding. `resolve_assignment`
takes a declared lane first; an id naming a bare runtime resolves to a lane
holding that runtime alone. A lane walks exactly the candidates it declares,
in declaration order — an explicit ordered membership, not a health tier,
score, or vendor-specific branch. A candidate that failed on timeout, 5xx or
network is deprioritized behind remaining healthy candidates until it answers
(`#36935`, `#43375`). One refused for a rate limit or quota stays behind them
until the time the provider stated, or the fallback floor (429) or cap (quota)
when it stated none (RFC-provider-path-rest §3.3); an answer ends a rate limit
or an unstated quota sooner. Keyed HTTP providers must
declare `[providers.<id>.credentials]` explicitly (`#42927`, `#42933`). An
assignment pointing at a slot the lane does not list falls back to declaration
order (`#39037`). Provider outcomes are recorded and returned to the
Keeper/LLM; MASC does not turn them into cooldown or admission policy.

Per-Keeper deployment files live at `<base-path>/.masc/config/keepers/<name>.toml`
and declare `[keeper]` (`instructions`, `mention_targets`, `board_interests`,
`activation_mode`, `sandbox_profile`, `sandbox_image`), `[sandbox]`
(`microvm_dns` `#43254`, resource/mount settings), and `[keeper.tools]` (such as
official-client `native = "read" | "full"` posture). Additional workspace capability setup
is provided by `masc web-search-setup` and `masc browser-lane-setup`.

Runtime declarations describe capabilities reported by agent core, including text,
tool use, reasoning/thinking, multi-turn, image/audio/voice, streaming, and
structured output. MASC must not guess these features from model-name strings.

### Context window precedence

HTTP providers may declare `request-path` as an endpoint-relative absolute
path, for example `/responses` or `/v1/responses`. It cannot contain an origin,
query, fragment or whitespace. An absent declaration uses the provider catalog
or protocol default. Setup preserves the catalog's request surface on generated
account providers; an OpenAI-compatible Responses surface selects the Responses
request and response codec. The path is part of connection identity, so chat and
Responses endpoints cannot accidentally reuse each other's provider.

Setup reuses an enabled configured provider only when its transport, credential
reference, account home and HTTP surface match. It does not enable disabled
providers. The terminal renderer's `--base-path` prepares model identities against
that workspace before selection, and the batch writer repeats the match while
checking the source revision. Operator-owned provider IDs and settings survive a
new model or context variant; ambiguous matching accounts are refused.

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

### Official-client accounts

Claude Code, Codex, Antigravity and ACP official clients own their model/tool
loops. MASC owns Keeper routing, durable session bindings, attached MASC tools
and process lifetime. Select the account used by the server process; a browser
login on a separate machine does not select that account.

| Client | Provider protocol | Account selection |
|---|---|---|
| Claude Code | `claude-code` | `account-home` selects `CLAUDE_CONFIG_DIR` |
| Codex | `codex-app-server` | `account-home` selects `CODEX_HOME` |
| Antigravity | `antigravity-cli` | A file credential selects the OAuth source; MASC seeds a separate managed HOME for persistent sessions and uses a disposable per-call HOME for one-shot exact/panel calls (`#43401`, `#43404`) |
| ACP (`agy`, `kimi`, `vibe-acp`) | `acp` | Driver-native login (e.g. host keyring / CLI config) or optional file credential (`oauth_source` for Antigravity) |

`masc setup` and the web model picker offer the official clients. Declared
`account-home` values survive setup unchanged. A new Claude Code or Codex
connection first selects an existing account directory; the browser selects
only the account declared on the server or its CLI default and retains an
opaque account reference. It cannot send arbitrary credential paths or commands.
The native wizard can select another absolute account directory and runs vendor
sign-in with that selected `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
Saving a connection then requires the separate response and MCP tool challenge.

## 4. Gate modes

Gate configuration (`.masc/gate/`) is deliberately small:

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

The authenticated setup surface can sign in to Codex, Claude Code, and
Antigravity from a TUI or browser connected to the server. Login runs in the
selected account's environment. It never changes the server environment or sends
operator input to a Keeper.

In dashboard runtime setup, the login panel retains the selected account
through model discovery and save.

`POST /api/v1/setup/accounts/login` accepts `integration_id` and an optional
`account_ref`. Omitting the reference adds a private new account; supplying one
explicitly reauthenticates that selection. The server catalog chooses the
executable. Browser paths and shell commands are not accepted.

The response is SSE: `started` identifies the login and its recovery receipt;
`output` carries what a CLI writes to its pipes, chunk by chunk; `screen`
carries the 80 x 24 screen of a CLI that runs in a terminal, its rows down to
the last that shows text with SGR styles and OSC 8 hyperlinks, and replaces
the screen before it; `input_ready` acknowledges delivered
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

Codex and Claude expose an `authenticated` native observation. Antigravity reports
`credential_captured`; this is not a network
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
