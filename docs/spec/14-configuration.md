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

For Muse, inspect the installation actions with
`masc prerequisite-actions muse-code`, and install with
`masc prerequisite-actions muse-code --execute muse_native_install`. Then sign in to the chosen account HOME using the vendor's sign-in flow. The
selected HOME must contain the file-backed `.config/muse/auth.json` produced by
that flow. MASC imports authentication into a managed generation and preserves
vendor refreshes there; a changed source authentication file creates a new
session generation. This does not establish a separate macOS Keychain identity.
Source hooks, plugins and permission settings are not imported into the managed
configuration.

`masc runtime-muse-models --account-home /absolute/path/to/muse-account`
queries the selected client's `model/list` without opening a session or making
a model call. Its JSON preserves the catalog source, nullable context/output
limits and reported reasoning tiers. A listed model is not evidence that this
account can invoke it. `fakeCatalog`, `unresolvedCatalog` and unknown sources
must not serve as setup admission evidence; absent context limits require an
explicit verified value before setup. No token-to-byte conversion is inferred.

This template belongs in the selected base path's `.masc/config/runtime.toml`.
Replace both uppercase placeholders with the selected vendor model's actual ID
and documented context window before loading it. `max-prompt-bytes` is an
operator input budget, not a measured model token limit. No runtime is assigned
merely by adding a provider and binding.

```toml
[providers.muse_personal]
protocol = "muse-serve"
command = "muse"
account-home = "/absolute/path/to/muse-account"
is-non-interactive = true

[models.muse_selected]
api-name = "VENDOR_MODEL_ID"
max-context = CONTEXT_WINDOW_TOKENS
max-prompt-bytes = 1048576
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
