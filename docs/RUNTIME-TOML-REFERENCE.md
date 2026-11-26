---
status: reference
---

# Runtime TOML Reference — providers, models, bindings, lanes, media readers

Key-by-key reference for the provider-to-lane axis of
`<base-path>/.masc/config/runtime.toml`: `[providers.<id>]`, `[models.<id>]`,
binding tables `[<provider>.<model>]`, `[runtime]` lanes, exact-output lanes,
`[runtime.assignments]`, and `[[media_readers]]` declarations.

Related documents, so this one does not repeat them:

- Reload semantics per section: [TOML-RELOAD-MATRIX.md](TOML-RELOAD-MATRIX.md)
- Keeper runtime selection and context-window precedence:
  [spec/14-configuration.md](spec/14-configuration.md) §3
- Native MiniMax Responses candidate setup and limits:
  [guides/minimax-responses.md](guides/minimax-responses.md)
- Environment variables the server reads at boot: [ENV-CONTRACT.md](ENV-CONTRACT.md)

Every rule below cites the source that enforces it. Parser:
`lib/runtime/runtime_toml.ml`; adapter: `lib/runtime/runtime_adapter.ml`;
catalog: `packages/agent_core/models.toml` with
`packages/agent_core/lib/llm_provider/{model_catalog,model_provider_catalog,capabilities}.ml`.

## 1. Division of labor with the AGENT_CORE catalog

The catalog (`packages/agent_core/models.toml`) and `runtime.toml` answer
different questions. Knowing which side owns a fact decides what you write.

| Fact | Owner |
| --- | --- |
| Provider dialect (`kind`), request path, default API-key env | catalog `[[providers]]` row with a matching `id` (`request-path` may still override the row's path, §2) |
| Model context window, output ceiling, effort ladder, pricing, thinking-control policy | catalog `[[models]]` rows, matched by longest `id_prefix` |
| Endpoint URL, credentials, timeouts, concurrency | `runtime.toml` |

A provider whose `id` equals a catalog `[[providers]]` `id` is *catalogued*:
the catalog row answers its dialect, request path, and default credential env,
and — when the row declares served bare families such as
`serves_bare_rows = ["claude-"]` — matching bare model rows also answer lookups
for it. The original row's `id_prefix` must belong to a declared family; a
requested model name alone does not grant authority (the native `claude` provider
reads the `claude-*` rows this way; before that declaration it fell to the
Anthropic preset and refused every reasoning effort, #37849).

`kind` is writable **only** for an HTTP endpoint the catalog has no row for
(an install-wizard provider id carries a hash, so no catalog row can match it).
Everywhere else a written `kind` is refused at load — see §9.

Context window precedence (binding `max-context` > provider `max-context` >
model `max-context` > catalog, `lib/runtime/runtime_instance.ml`) is
documented with examples in
[spec/14-configuration.md](spec/14-configuration.md) §3. A runtime that
resolves a window from **neither** the TOML nor the catalog fails at load.

## 2. `[providers.<id>]` — how to connect

Only declared fields are accepted; unknown keys are load errors. Provider ids
that name a reserved top-level namespace (`runtime`, `models`, `exec`, …) are
refused (#39539).

### Required

| Key | Values | Notes |
| --- | --- | --- |
| `protocol` | see table below | names the request shape |
| `endpoint` | URL | for HTTP protocols |
| `command` | path | for CLI protocols, instead of `endpoint` |

Protocol inventory (`lib/runtime/runtime_protocol.ml`):

| `protocol` | Transport | Wire format | Dialect source |
| --- | --- | --- | --- |
| `messages-http` | HTTP | Anthropic Messages API | catalog row, or `kind` (`anthropic`/`kimi`) when uncatalogued |
| `openai-compatible-http` | HTTP | OpenAI Chat Completions, or Responses when the request path is `/responses`/`/v1/responses` (`provider_http_codec.ml`) | catalog row, or `kind` when uncatalogued |
| `ollama-http` | HTTP | Ollama | fixed by the protocol |
| `gemini-http` | HTTP | Gemini | fixed by the protocol |
| `vertex-gemini` | HTTP | Vertex AI Gemini | fixed by the protocol |
| `claude-code` | CLI | Claude Code client | official client |
| `codex-app-server` | CLI | Codex app server | official client |
| `antigravity-cli` | CLI | Antigravity CLI | official client |
| `acp` | CLI | Persistent ACP v1 JSON-RPC 2.0 over stdio (`agy acp`, `kimi acp`, `vibe-acp`, `muse acp`) | official client |
| `messages-cli`, `openai-compatible-cli` | CLI | internal | not editable |

Optional:

| Key | Type | Meaning |
| --- | --- | --- |
| `display-name` | string | UI label |
| `kind` | `anthropic`\|`kimi`\|`openai_compat`\|`ollama`\|`gemini`\|`glm` | dialect, **only** for an uncatalogued `messages-http`/`openai-compatible-http` endpoint; refused elsewhere (§9) |
| `catalog-provider` | string | HTTP protocols only: the AGENT_CORE catalog provider row this account speaks as when its own provider id names no row, e.g. a second Anthropic account `[providers.claude_a]` with `catalog-provider = "claude"`. Catalog lookups (dialect, capabilities, request policy) read that row; the credential, quota scope, runtime ids and admission stay per account, so two accounts of one row are separate exact-output slots. Write the row id as the catalog spells it. Refused at load (`Catalog_provider_refused`, reported under `Undeclared_bindings`) when it names no catalog row (`Names_no_row`), when the provider's own id is already a catalog row (`Beside_own_row`), when it spells an alias of a row (`Names_alias`; the message gives the id to write), or when `kind` is stated beside it (`Beside_kind`); the check runs only for an enabled provider that an enabled binding names (a disabled provider or binding is skipped first). An official-client protocol may not declare it. See [provider admission fairness](guides/provider-admission-fairness.md#several-accounts-of-one-catalog-provider) |
| `request-path` | string | request path override, checked before the catalog row's path — also valid for a catalogued provider reached over a different supported surface (e.g. `ollama_cloud` over OpenAI-compatible, where the catalog's native path 404s, #33652) |
| `enabled` | bool | default `true` |
| `max-context` | positive int | provider-level window default (precedence in spec/14 §3) |
| `connect-timeout-s` | positive float | bound on the phase before response headers. **No default**: absent means unbounded. Keeper turns remain bounded by the keeper's first-event budget |
| `exact-body-timeout-s` | positive float | bound on the whole exact-output request (connect, headers, body). See §7 for when it matters |
| `is-non-interactive` | bool, default `false` | **required `true`** for every official-client protocol (`claude-code`, `codex-app-server`, `antigravity-cli`, `acp`); otherwise the runtime does not materialize |
| `timeout-s` (+ `agent`, `effort`, `add-dirs`) | positive float (string; `low`\|`medium`\|`high`; absolute paths) | `antigravity-cli` options (`agent` and `add-dirs` are `antigravity-cli` only; `timeout-s` is **required** on `antigravity-cli` and optional on `acp`; `effort` is optional on both) |
| `driver` (+ `args`, `strip-env`, `skills-dirs`, `mode`, `contributor-mode`, `admission-timeout-s`) | `antigravity`\|`kimi_code`\|`mistral_vibe`\|`muse_code` (string arrays; string; `on`\|`off`; positive float) | `acp` only — refused on every other protocol. `driver` is **required**; `args`, `strip-env`, `skills-dirs` (absolute paths), `mode`, `contributor-mode`, and `admission-timeout-s` (seconds, default `30.0`; the wait for `initialize`, `session/new`, `session/load` (seconds without activity), `session/resume`, `session/set_mode`, `session/set_model` and `session/set_config_option`, and the default wait of `session/close`) are optional. `contributor-mode` is accepted for `muse_code` only and is `off` when absent |
| `account-home` | non-empty absolute path | accepted for `claude-code`/`codex-app-server`; refused elsewhere |
| `admission-priority-run-limit` | positive int | bounds consecutive `Priority` grants while a `Standard` request waits, and combined `Priority`/`Standard` grants while `Background` work (`Librarian`, `Librarian_memory`, `Workspace_memory_curator`) waits. Omitted means strict `Priority` → `Standard` → `Background` ordering (FIFO within each class; `Background` runs only when `Priority` and `Standard` queues are empty). Set only to bound `Background`/`Standard` starvation on an intentionally shared account, not to protect Keepers. Refused on official-client providers and when none of the provider's bindings declares `max-concurrent`. See [provider admission fairness](guides/provider-admission-fairness.md) |

Claude Code and Codex capture their selected home and permitted credential
environment when the binding is materialized. Execution, probes and verification
retain that selection until reload; changing the process environment does not
retarget an existing binding. See [Native account selection](guides/native-account-selection.md)
for inherited versus explicit homes and Codex configuration requirements.

`acp` runs a persistent ACP v1 (Agent Client Protocol) JSON-RPC 2.0 child over
stdio for official subscription CLIs, selected by `driver`: `antigravity`
(`command = "agy"`, `args = ["acp"]`), `kimi_code` (`command = "kimi"`,
`args = ["acp"]`), `mistral_vibe` (`command = "vibe-acp"`), and `muse_code`
(`command = "muse"`, `args = ["acp"]`). Each Keeper owns
an isolated child process and loopback HTTP MCP bridge. At native posture
`none` the host runs in an empty temporary folder. At `read` and `full` it
runs where a Codex Keeper does, never in the base path: the Keeper's sandbox
host tree when its sandbox mounts one, otherwise
`<base-path>/.masc/official-clients/acp-workspaces/<SHA-256 of the Keeper
name>`, a `0700` folder every ACP driver of that Keeper shares. `driver` and
`is-non-interactive = true` are required; `account-home` is refused. Use
`strip-env` when a host API-key variable must be removed so the client uses its
subscription login (for example, `strip-env = ["MISTRAL_API_KEY"]` on `vibe-acp`
so it uses the host OS keyring). `credentials` may be omitted or a `file`
credential naming an absolute path (`oauth_source` for Antigravity); `env` and
`inline` credentials are refused.

`muse_code` differs from the other drivers in four ways (muse 1.4.25):

- The client signs in with `muse login`. On macOS the secret is in the Keychain
  and `~/.config/muse/auth.json` holds metadata; other platforms are not
  verified. MASC adds these after `args`: `--trust-workspace` (the host
  connects the session's MCP server only with it), one
  `-c runtime_capabilities.<id>.enabled=false` per bundled reminder observer,
  and a `-c run.toolset=[...]` that follows the Keeper's native tool posture
  (next bullet), and `--contributor-mode` with the runtime's `contributor-mode`
  (below). It also sets `MUSE_NO_AUTO_UPDATE=1`. The host refuses to start when
  `args` repeats one of those `-c` keys or sets `--contributor-mode` (exit
  status 2, "cannot be used multiple times"). With the observers on, all
  5 measured turns (one tool call each) ended with one more model run, a
  prompt of 5.8 to 5.9k tokens by the host's estimate and 1.2 to 2.9 s to its
  tool call. With the observers off the run was absent in 12 of 12 turns (9
  set them with `-c`, 3 in `settings.json`, which the host reads the same
  way).
  Switching one observer at a time with the echo provider, only the goal
  reminder switch changed whether the run's tool surface appeared; the other
  five are kept without a measurement that shows they are needed.
- The host decides tool approvals, not MASC, and runs some native tools
  without asking. Its default permission profile has a model run approve MCP
  tool calls (5 measured sessions, one call to a no-argument tool each: a prompt
  of 11.6 to 13.7k tokens by the host's estimate and 1.4 to 4.8 s to its tool
  call; what it does with a call it rejects was not observed) and sends MASC no
  permission request. Workspace writes and sandboxed shell commands run without
  a request, and so does the read tool. Refusing permission requests therefore
  cannot keep native tools off, so MASC names the tools the main conversation
  may use with `-c run.toolset`:

  | Keeper `keeper.tools.native` | `run.toolset` | Tools the host offers |
  | --- | --- | --- |
  | `none` | `["mcp__<bridge>__*"]`, or `[]` when the bridge lists no tool | MASC's tools only |
  | `read` | `["read_file","search","mcp__<bridge>__*"]`, without the last entry when the bridge lists no tool | file read, file search, MASC's tools |
  | `full` | not set | the host's default tools, among them shell, file writes, memory, cron, sub-agents, web fetch and web search |

  `read_file` is not limited to the workspace: a live session read
  `/etc/hosts`. `full` takes effect only when the Keeper's tool approval mode
  is `yolo`; in any other mode MASC runs the Keeper at `read`. The host
  refuses an unknown plain tool name when a session starts, and fails the first
  turn with `invalid run configuration: unknown tool` when a name in the list
  matches no tool. A server that lists no tool, one that `session/new` did not
  carry and one the host could not connect to all end that way, so MASC lists
  `mcp__<bridge>__*` only when the bridge lists a tool. `<bridge>` is `masc_`
  and the first eight hex digits of the SHA-256 of the Keeper's name (for the
  Keeper `keeper-a`, `masc_8d902e5f`). The host refuses a session server that
  has the name of one in the operator's muse settings, in a plugin (one
  installed at user scope counted, approved or not) or in a `.mcp.json` it
  loads for the workspace (the workspace's own, or that of the repository it
  is in; `session/new` fails with `session MCP server name conflicts with a
  host or plugin server`, -32030). An entry for MASC's own server can be named
  `masc`, as it is in the settings and `.mcp.json` this was measured against,
  and an operator can write any other fixed name. The host compares names as
  written but registers a server name with `-` and `.` replaced by `_` (other
  characters were not tried): a settings server named `masc-keeper` was
  accepted next to a bridge with the fixed name `masc_keeper`, both registered
  under `mcp__masc_keeper__`, and for a tool name they shared the host gave the
  plain name to the settings server and a hash suffix to the bridge's tool,
  which the Keeper reads as a tool name its list does not have. No entry has
  the bridge's name by accident. The digits come from the Keeper's name, which
  is not secret, so an entry written to match them still conflicts or shares
  the prefix; keeping such entries out of the host is a matter of its
  configuration (the settings, plugins and `.mcp.json` it loads), not of this
  name. The same Keeper gets the same name every time its host starts, so
  the history of a session the Keeper resumes names the tools the new bridge
  serves. A session made under one name also loaded under another (echo
  provider, 2026-11-25).
  MASC gives the host no settings of its own, so those entries stay loaded:
  under `none` and `read` the list leaves their tools out, under `full` the
  host offers them. `args` must not contain `run.toolset`,
  because the host refuses to start on a repeated key. Fusion and runtime
  verification run Muse Code at `none`. MASC's own permission policy applies only to
  requests the host forwards. With the operator's muse settings on the
  `:ask-me` profile in `$XDG_CONFIG_HOME/muse/settings.json` (default
  `~/.config/muse/settings.json`) and the client in the `promptUnmatched` mode,
  the host forwarded MCP tool calls in 2 of 2 measured sessions. MASC starts
  every session in `onRequest`, and `:ask-me` with `onRequest` was not tried.
  The setting applies to every muse session of that user:

  ```json
  { "schema_version": 1,
    "permissions": { "schema_version": 1, "default_profile": ":ask-me" } }
  ```

- `contributor-mode = "on"` or `"off"` is the mode the host runs in; a runtime
  that omits it runs the host with `off`. Without the flag the host reads
  `contributor_mode_enabled` from the operator's `settings.json`, and with it
  on the host sends the model as `<model>-contributor`. Measured 2026-11-25
  (`MUSE_TRANSPORT_TRACE=1`, muse 1.4.25, no `--model`, model from the
  settings): `muse-ember-1.0` went out as `muse-ember-1.0-contributor`, which
  does not exist, and the turn failed with `modelError`, `retryable: false`, in
  3 of 3 sessions; the same argv with `--contributor-mode off` sent
  `muse-ember-1.0` and ended with `end_turn`. The Model API docs list
  contributor variants for Spark only (`muse-spark-1.3-contributor`,
  `muse-spark-1.2-contributor`) and call Ember Standard mode only
  ([choose a model](https://dev.meta.ai/docs/choose-a-model),
  [Muse Ember](https://dev.meta.ai/docs/muse-ember)). In contributor mode the
  plan grants more usage in exchange for Meta training on the content of the
  session, so the default `off` gives up that extra usage; the docs advise
  setting the mode with the flag on every headless run
  ([subscriptions](https://dev.meta.ai/docs/muse-code/subscriptions)). `on`
  with a model that has no contributor variant, Ember for example, fails as
  measured above. The key is refused on the other drivers.
- Muse bindings reject provider and binding `effort`, model `reasoning-effort`, and
  effort variants at load. Per-turn effort overrides are also refused. Put
  `-c reasoning_effort="<level>"` in `args`, for example
  `args = ["acp", "-c", "reasoning_effort=\"low\""]`.
- Sessions live under `$XDG_DATA_HOME/muse` (default `~/.local/share/muse`), the
  same store as the operator's own `muse` sessions, and the host loads skills
  from `~/.claude/skills`, `~/.agents/skills` and `$CODEX_HOME/skills` into every
  session. The host reports no per-turn token counts over ACP, only the
  context window use. It writes the counts of every model request and every
  approval review to
  `<data root>/muse/sessions/YYYY/MM/DD/<session id>/session.jsonl`, and MASC
  reads what that file gains during each prompt. A plugin of the host can start
  observers, child sessions that call the model on their own. Their counts are
  in `subagent/<child id>/session.jsonl` under the session's directory, and MASC
  adds those of the observers that had finished when the prompt returned, each
  journal once. An observer that is still running, or that the host linked
  without a journal, adds nothing, and the log line counts them; the next turn
  does not add a running one either. The turn's cost-ledger row holds the
  requests, the reviews and the observers added up, cache writes included, the
  way the ledger holds a turn of the other ACP drivers, and the Keeper log line
  `Muse turn usage` shows the three apart. When the host reports no occupancy,
  the input of the turn's last request stands in for it. The file's format is
  the host's own and unpublished: MASC reads the record versions it was
  checked against (muse 1.4.25) and, for any other, logs
  `Muse turn usage unreadable` with the reason and leaves the turn without
  counts instead of writing zeros. The same holds when an observer's journal is
  missing, cannot be read or links observers of its own: the whole turn is
  unreadable, and the reason names that journal.

`mistral_vibe` takes the Keeper's native tool posture as its own tool
allowlist (vibe-acp 3.1.0 and 3.1.5, measured offline 2026-11-26). The host
runs some calls without asking the client. With no allowlist, an `echo` the
host allows ran with no permission request while MASC refused every request.
MASC therefore starts the host with `VIBE_ENABLED_TOOLS`, Vibe's documented
override of its `enabled_tools` setting:

| Keeper `keeper.tools.native` | `VIBE_ENABLED_TOOLS` | Tools the host offers |
| --- | --- | --- |
| `none` | `["<bridge>_*","todo"]` | MASC's tools and the session plan |
| `read` | `["<bridge>_*","todo","read_file"]` | the above and file read |
| `full` | not set | the tools the operator's Vibe settings enable |

- `<bridge>` is `masc`, the name of the Keeper's MCP bridge. A start without
  a bridge leaves that entry out.
- A builtin left off the list stays in the model's tool list. A call to it
  ends inside the host with `tool_denied` ("Tool execution denied by approval
  policy") and sends no permission request. The same holds for a call from
  `run_typescript`.
- A tool the host provides itself leaves the model's tool list: `cron`,
  `unified_harness_scratchpad`, and in 3.1.5 `create_goal`, `get_goal` and
  `update_goal`. The 3.1.5 source filters the connector tools (web search,
  news, finance, weather, `open_url`) by the same list; that was read, not
  run. Search files with MASC's `Grep` and the web with `WebSearch` and
  `WebFetch`.
- The variable beats an `enabled_tools` line in the settings file. MASC
  removes an inherited `VIBE_ENABLED_TOOLS` at every posture, so under `full`
  the settings file alone decides.
- `full` takes effect only when the Keeper's tool approval mode is `yolo`; in
  any other mode MASC runs the Keeper at `read`. Fusion and runtime
  verification run Vibe at `none`.

### `[providers.<id>.credentials]`

| Key | Meaning |
| --- | --- |
| `type = "env"`, `key = <NAME>` | read the environment variable `NAME` |
| `type = "file"`, `path = <abs>` | read a raw key from a file |
| `type = "inline"`, `value = <key>` | the key itself; avoid for real secrets |

Resolution (`lib/runtime/runtime_adapter.ml` and `lib/runtime/runtime_toml.ml`):

- Keyed providers (whose catalog row declares a non-empty `api_key_env`) **must** declare an explicit `[providers.<id>.credentials]` block (`type = "env", key = "..."`, `file`, or `inline`); omitting `[providers.<id>.credentials]` on a keyed provider fails at load (#42927, #42933). A catalog row with an **empty** `api_key_env` declares a provider that takes no key.
  An uncatalogued provider with no credentials still loads — with an empty
  key, which is what a keyless local endpoint needs. The refusal for a
  credential-less uncatalogued provider happens at model discovery
  (`resolve_api_key`), not at load.
- `env`: the first non-empty variable is used. `OLLAMA_CLOUD_API_KEY` also
  falls back to `OLLAMA_API_KEY`.
- `file`: must be absolute, owned by the current user, with no group/other
  permission bits, and contain a raw key — a JSON document is refused.
- Official clients: `claude-code` and `codex-app-server` must **not** declare
  credentials (the client owns subscription login); `antigravity-cli` requires a
  `file` credential naming the operator-owned OAuth source; `acp` accepts no
  credentials or a `file` credential (`env` and `inline` are refused).

### `[providers.<id>.healthcheck]`, `.headers`, `.usage-read`, `.capabilities`

- `healthcheck.path` (absolute) is provider-owned metadata for install/setup
  probes; runtime startup does not use it for admission.
- `headers` injects fixed non-auth HTTP headers per request (e.g.
  OpenRouter's `HTTP-Referer`), on Keeper turns and exact-output slots alike;
  an exact request writes its own `Content-Type` and `Content-Length`. `authorization`, `x-api-key`, `api-key` and
  `x-auth-token` are stripped (case-insensitively) and never reach the
  request — authentication uses the credentials table only.
- `usage-read` reads usage windows without a model call: `shape` is one of
  `openrouter-key`, `zai-quota-limit`, `kimi-coding-usages`, `ollama-balance`;
  plus `url` and `refresh-s`. With `shape = "openrouter-key"`, an optional
  `[providers.<id>.usage-read.credit]` table adds `url` for the account Credit
  endpoint. It uses the same credential and refresh period; its URL follows
  the same HTTPS and provider-host checks as the primary `url`.
- `capabilities`: `supports-inline-tools`,
  `argv-prompt-preflight`, `uses-messages-caching`.

## 3. `[models.<id>]` — what a model is

Unknown keys are load errors. The table id is the local model id used by
bindings and lanes.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `api-name` | string | the table id | model id sent on the wire (`model-name` is an accepted alias) |
| `max-context` | positive int | catalog | operator window override; fail-close at load when no source resolves |
| `tools-support` | bool | `false` | whether a turn may carry tools. An official-client row is answered by this key. An Agent Core row is answered by its AGENT_CORE catalog row when the catalog has one for this provider and model; the key is read only for a model the catalog has no row for, together with `[models.<id>.capabilities]` |
| `thinking-support` | bool | absent | absent = follow the caller's policy; on a `reasoning-uncontrolled` row it only says the model thinks and sends no request. When set on an Agent Core row, every turn sends it, so the configuration is refused at load (`Thinking_requests_inadmissible`, naming each runtime) when request admission refuses the request it builds, for example `true` on a `reasoning-effort` wire with no effort to send |
| `preserve-thinking` | bool | absent | replay policy for prior-turn reasoning |
| `streaming` | bool | `true` | |
| `temperature`, `top-p`, `top-k`, `min-p` | float/int | absent | sampling; `top-k`/`min-p` are validated against the declared capabilities |
| `reasoning-effort` | `low`\|`medium`\|`high`\|`xhigh`\|`max` | absent | |
| `reasoning-uncontrolled` | bool | `false` | send no reasoning control, including the enable or disable `thinking-support` would ask for; **cannot** coexist with `reasoning-effort` (load error) |
| `turn-timeout-s` | non-negative float | absent | per-turn bound; `0` removes the deadline (the spawned client owns it), absent keeps the adapter default. Negative/non-finite is a load error |

### `[models.<id>.capabilities]`

All keys optional; absent means "the operator wrote nothing here" and each
consumer resolves it against the layer it owns — a written `false` is
different from an unwritten key (#37435).

- `thinking-control-format`: `none`, `thinking-object`,
  `thinking-object-adaptive`, `thinking-object-only`,
  `chat-template-kwargs`, `chat-template-token`, `ollama-think`,
  `reasoning-effort`. `thinking-control-token` (the token string) requires
  `chat-template-token`.
- `reasoning-streaming-format`: `none`, `default`, `template_parser`,
  `delta:<field>`, `delta_details:<field>`.
- `anthropic-thinking-control`: `adaptive_default`,
  `adaptive_disabled_through_high`, `adaptive_between_tools`,
  `always_adaptive` (hyphen-joined spellings accepted too). Only for an
  Anthropic-wire binding the model catalog answers no policy for
  (operator-own pattern: no readable row, or a row that carries no policy);
  the loader refuses it where the catalog already declares a policy for the
  binding's model and where the wire is not Anthropic.
- `max-output-tokens`: positive int (non-positive values are ignored with a
  warning).
- Feature booleans: `supports-tool-choice`, `supports-required-tool-choice`,
  `supports-named-tool-choice`, `supports-parallel-tool-calls`,
  `supports-image-input`, `supports-document-input`, `supports-audio-input`, `supports-video-input`,
  `supports-multimodal-inputs`, `supports-response-format-json`,
  `supports-structured-output`, `supports-system-prompt`,
  `supports-assistant-prefill`, `supports-prompt-caching`, `supports-top-k`,
  `supports-min-p`, `supports-seed`, `emits-usage-tokens`.

Media keys are opt-in: an absent key does not grant that modality.
`supports-document-input` declares native document input independently of
`supports-multimodal-inputs`, which declares combined media input. A PDF alone
needs document support; a PDF plus an image needs both individual flags and
the combined-input flag. The materialized API configuration carries the same
document decision used by admission and request serialization. Native Ollama
and the official-client transports cannot acquire document support from TOML.

When the candidate cannot carry a document or mixed request, Keeper uses its
[media reading projection](KEEPER-MEDIA-FALLBACK-H5.md), retaining the canonical
attachment. Declaring support does not prove that an endpoint accepts the file;
verify the configured model and wire before enabling it.

## 4. `[<provider>.<model>]` — bindings

A binding is the runtime unit: `<provider>.<model>` is the runtime id used by
`[runtime] default`, lane candidates, exact-output slots, and keeper
assignments. Unknown keys are load errors.

| Key | Type | Meaning |
| --- | --- | --- |
| `max-context` | positive int | per-binding window override |
| `max-concurrent` | positive int | static client-side cap. **Omitted means no cap and no admission at all**: the binding dispatches straight out and stops only when the provider itself refuses (HTTP 429). Whether HTTP bindings should be required to declare it is open (#25401); the exception is a runtime an enabled exact-output lane lists in `cli_slots`, whose binding **must** declare it (the seats: client processes the lane may run at once) — omitting it refuses the load with `Exact_lane_cli_slot_unservable`, reason `Seats_undeclared` (§7). `0` or negative is a load error |
| `max-tokens` | positive int | per-request output budget; omitted lets the provider default decide (ollama.com/v1 defaults to 65536) |
| `disable-parallel-tool-use` | bool, default `false` | limit responses to one tool call |
| `price-input`, `price-output` | float | per-million pricing override (catalog otherwise) |
| `keep-alive`, `num-ctx`, `repeat-penalty` (> 0), `repeat-last-n` (≥ −1), `return-progress` | | Ollama-family knobs |
| `enabled`, `is-default`, `wizard-default` | bool | internal flags; not hand-written |

## 5. `[runtime]` — routing roots

| Key | Meaning |
| --- | --- |
| `default` | the runtime binding id used when nothing more specific applies. May name a lane or a runtime — lanes resolve first, and a lane name enters on the lane's head (`lib/runtime/runtime.ml`) |
| `media_failover` | ordered binding ids for media work |

## 6. `[runtime.lanes.<name>]` — keeper lanes

| Key | Meaning |
| --- | --- |
| `candidates` | ordered binding ids; later entries are failover targets |

Lane behavior to plan around: after a turn breaks on repeated output, the lane
skips candidates whose `api-name` equals the one that repeated; the lane's turn
budget is bounded by the **smallest** window among its candidates, so one
narrow candidate shrinks the whole lane.

Keeper assignments (`[runtime.assignments]`, keeper name → binding id) may
name a lane instead of a single runtime.

## 7. `[runtime.exact_output_lanes.<name>]` — exact-output slots

| Key | Meaning |
| --- | --- |
| `enabled` | bool, default `true` (a required lane cannot be disabled) |
| `slots` | HTTP binding ids, tried in order |
| `cli_slots` | official-client runtime ids, used when every HTTP slot is blocked. Each entry's binding must declare `max-concurrent` (§4): every call starts a client process on this machine and nothing stops an overflow, so the lane runs a CLI slot only within its declared seats |
| `max_output_tokens` | positive int output budget |
| `thinking` | bool thinking control |

`slots = []` means `cli_slots` only; both empty is refused at load on an
enabled lane (a disabled lane may keep empty lists).

**Seats rule** (#53025): an enabled lane whose `cli_slots` entry resolves to an
official client with an output-schema channel but whose binding declares no
`max-concurrent` is refused at load, built-in and add-on lanes alike
(`exact_lane_cli_slot_gaps` and `validate_exact_lane_cli_slots` in
`lib/runtime/runtime.ml`). The refusal is
`Exact_lane_cli_slot_unservable` with reason `Seats_undeclared`
(`lib/runtime/runtime_config_error.ml`); it names the lane table, the slot and
the provider, and tells you to add `max-concurrent = <seats>` to the binding
table of that runtime. A raw-config save is refused the same way. The same
runtime listed in `slots` is not held to the rule (only a `cli_slots` entry is
counted), and a lane with `enabled = false` is not checked. See
[lane add-on TOML](guides/lane-addon-toml.md) and
[provider admission fairness](guides/provider-admission-fairness.md).

**Deadline rule**: a `slots` entry that newly adds an HTTP runtime whose
provider declares no `exact-body-timeout-s` is refused at save time
(rule 3, #38779); gaps the file already has are grandfathered — unrelated
saves stay allowed and boot keeps them degraded. Plan admission requires
the body deadline specifically (`Missing_deadline`, #36979, #38573):
`connect-timeout-s` alone never qualifies a provider for exact-output
slots. A keeper turn is not affected — it keeps its own first-event
budget.

## 8. Worked example — catalogued Anthropic provider

The catalog already has a `[[providers]] id = "claude"` row (dialect
`anthropic`, request path `/v1/messages`, env `ANTHROPIC_API_KEY`,
`serves_bare_rows = ["claude-"]`), so the runtime side declares only what the catalog
cannot:

```toml
[providers.claude]
display-name = "Claude API"
protocol = "messages-http"
endpoint = "https://api.anthropic.com"
connect-timeout-s = 180.0

[providers.claude.credentials]
type = "env"
key = "ANTHROPIC_API_KEY_MASC"

[models.claude-sonnet-5-5]
api-name = "claude-sonnet-5-5"
tools-support = true
thinking-support = true
streaming = true

[claude.claude-sonnet-5-5]
max-concurrent = 4
```

Notes on what is deliberately absent:

- No `kind` — the catalog row owns the dialect; writing one is a load error.
- No `request-path` — the catalog row's `/v1/messages` is used.
- No `max-context` — the catalog's `claude-*` row answers (1M).
- No `exact-body-timeout-s` — this provider serves no exact-output slot; a
  `slots` entry naming it is refused at save until the key is added
  (rule 3, #38779).

An uncatalogued Anthropic-dialect endpoint instead states `kind =
"anthropic"` and `request-path = "/v1/messages"` itself.

## 9. Load-time refusal summary

| Written | Refused because |
| --- | --- |
| `kind` on a catalogued provider | the catalog row owns that fact |
| `kind` on `ollama-http`/`gemini-http`/`vertex-gemini` | the protocol already fixes the dialect |
| `kind` on a CLI protocol | an official client speaks no HTTP dialect |
| provider id naming a reserved namespace | reserved top-level namespace (#39539) |
| unknown key in provider/model/binding tables | only declared fields are accepted |
| missing `[providers.<id>.credentials]` on a keyed catalogued provider | keyed providers must declare their credential source explicitly (#42927, #42933) |
| credential file relative / not owner-private / JSON | file credentials must be a raw, private, owned key |
| credentials on `claude-code`/`codex-app-server`; `env`/`inline` credentials on `acp` | the official client owns subscription login (`acp` accepts only a `file` credential or none) |
| missing or unknown `driver` on `acp`; ACP-exclusive keys (`driver`, `args`, `strip-env`, `skills-dirs`, `mode`) on another protocol | ACP options belong exclusively to `protocol = "acp"` |
| missing `is-non-interactive = true` on an official-client protocol | the runtime does not materialize without it |
| missing `timeout-s`, or non-file credential, on `antigravity-cli` | the CLI's deadline and OAuth source are mandatory |
| `account-home` outside `claude-code`/`codex-app-server` | the key belongs only to Claude Code and Codex official clients |
| `healthcheck.path` not starting with `/` | must be absolute |
| `reasoning-effort` + `reasoning-uncontrolled` together | two contradictory requests |
| `max-concurrent` ≤ 0, `max-tokens` ≤ 0, non-positive `max-context` | meaningless values are rejected, not downgraded |
| negative/non-finite `turn-timeout-s` | only absent (adapter default) or ≥ 0 (0 removes the deadline) |
| `admission-priority-run-limit` on an official-client provider, or with no `max-concurrent` binding | nothing waits in the permit queue it would order |
| exact-output lane with both slot lists empty, while enabled | nothing to run |
| `cli_slots` entry of an enabled exact-output lane whose official-client binding declares no `max-concurrent` | `Exact_lane_cli_slot_unservable`, reason `Seats_undeclared`: the lane cannot bound the client processes it starts (§7); not checked for a disabled lane or for the same runtime listed in `slots` |
| `catalog-provider` naming no catalog row, beside the provider's own catalog row id, spelling a row alias, or beside `kind` | `Catalog_provider_refused` (`Names_no_row`, `Beside_own_row`, `Names_alias`, `Beside_kind`): the row must be named unambiguously (§2); checked only for an enabled provider named by an enabled binding |

Discovery (not load-time): an uncatalogued provider with no credentials
loads with an empty key, but model discovery (`resolve_api_key`) refuses
it — nothing has said a key is unnecessary.

Runtime (not load-time): an exact-output slot whose provider lacks
`exact-body-timeout-s` is refused at plan admission with `Missing_deadline`
(#36979, #38573) — `connect-timeout-s` alone never qualifies — and a
`slots` entry that newly adds such a gap is refused already at save time
(rule 3, #38779); gaps the file already has are grandfathered.

## 10. `[[media_readers]]` — external reader declarations

These rows declare audio/document readers in the same immutable Runtime
configuration snapshot. Loading or saving a row does not start its command,
probe a service, choose a reader, or read a document. External execution and
its original-request/Gate lifecycle are separate integration work.

```toml
[[media_readers]]
id = "office-reader"
revision = "office-reader-v1"
kind = "document"
media_types = ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"]
adapter = "markitdown_mcp"
command = "python3"
args = ["-m", "markitdown_mcp"]
```

The service must be installed in the eventual Keeper execution environment.
This example does not install it or establish a working DOCX route.

| Required field | Meaning |
| --- | --- |
| `id` | Nonblank declaration identity, unique across the list. A different revision does not make a duplicate ID valid. |
| `revision` | Nonblank declaration revision. It does not authenticate installed code, dependencies, or an account. |
| `kind` | Exactly `audio` or `document`, the current media-reading kinds. |
| `media_types` | Exact nonblank strings, preserved without normalization or a built-in format whitelist. An empty list declares no supported media types. |
| `adapter` | Exactly `markitdown_mcp`, the currently declared adapter. |
| `command` | Nonblank, NUL-free executable string for the eventual Keeper environment. The loader does not expand `~`, split a shell command, or check host existence. |
| `args` | String array. Order, whitespace and empty arguments are preserved; NUL is refused. |

Omitting the section or writing `media_readers = []` declares no readers. An
array of inline tables is equivalent to the array-of-tables form. A singleton
table such as `[media_readers.docx]`, unknown keys/kinds/adapters, wrong field
types and duplicate IDs are refused. `media_readers` is a reserved provider ID.

Different IDs may declare the same kind and MIME. Every row remains present;
list order confers no priority. A later request owner must pin an explicit
declaration or report ambiguity before any effect. Changing command/arguments
while retaining an ID and revision cannot establish cache equivalence.

`Runtime.media_reader_declarations ()` returns `None` before publication and
`Some []` for a valid published empty list. A captured list keeps its original
rows after another configuration is published. Failed validation does not
publish a partial list. Successful configuration saves and restore operations
use the same atomic loaded state as the rest of Runtime.

Sources: `lib/types/media_reading_kind.mli`,
`lib/runtime/runtime_schema.mli`, `lib/runtime/runtime_toml_media_readers.ml`,
`lib/runtime/runtime.ml`, and
`lib/runtime_toml_namespace/runtime_toml_namespace.ml`.
