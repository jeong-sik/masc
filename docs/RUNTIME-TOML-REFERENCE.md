---
status: reference
---

# Runtime TOML Reference — providers, models, bindings, lanes

Key-by-key reference for the provider-to-lane axis of
`<base-path>/.masc/config/runtime.toml`: `[providers.<id>]`, `[models.<id>]`,
binding tables `[<provider>.<model>]`, `[runtime]` lanes, exact-output lanes,
and `[runtime.assignments]`.

Related documents, so this one does not repeat them:

- Reload semantics per section: [TOML-RELOAD-MATRIX.md](TOML-RELOAD-MATRIX.md)
- Keeper runtime selection and context-window precedence:
  [spec/14-configuration.md](spec/14-configuration.md) §3
- Sharing one model row across provider accounts:
  [SHARED-RUNTIME-MODELS.md](SHARED-RUNTIME-MODELS.md)
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
| Provider dialect (`kind`), request path, default API-key env | catalog `[[providers]]` row with a matching `id` |
| Model context window, output ceiling, effort ladder, pricing, thinking-control policy | catalog `[[models]]` rows, matched by longest `id_prefix` |
| Endpoint URL, credentials, timeouts, concurrency, eviction marks | `runtime.toml` |

A provider whose `id` equals a catalog `[[providers]]` `id` is *catalogued*:
the catalog row answers its dialect, request path, and default credential env,
and — when the row declares `serves_bare_rows = true` — the catalog's bare
model rows also answer capability lookups for it (the native `claude` provider
reads the `claude-*` rows this way; before that declaration it fell to the
Anthropic preset and refused every reasoning effort, #37849).

`kind` is writable **only** for an HTTP endpoint the catalog has no row for
(an install-wizard provider id carries a hash, so no catalog row can match it).
Everywhere else a written `kind` is refused at load — see §9.

Context window precedence (binding `max-context` > model `max-context` >
provider `max-context` > catalog) is documented with examples in
[spec/14-configuration.md](spec/14-configuration.md) §3. A runtime that
resolves a window from **neither** the TOML nor the catalog fails at load
(RFC-0206 §2.1).

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
| `openai-compatible-http` | HTTP | OpenAI Chat Completions | catalog row, or `kind` when uncatalogued |
| `ollama-http` | HTTP | Ollama | fixed by the protocol |
| `gemini-http` | HTTP | Gemini | fixed by the protocol |
| `vertex-gemini` | HTTP | Vertex AI Gemini | fixed by the protocol |
| `claude-code` | CLI | Claude Code client | official client |
| `codex-app-server` | CLI | Codex app server | official client |
| `antigravity-cli` | CLI | Antigravity CLI | official client |
| `muse-serve` | CLI | Muse serve | official client |
| `messages-cli`, `openai-compatible-cli` | CLI | internal | not editable |

Optional:

| Key | Type | Meaning |
| --- | --- | --- |
| `display-name` | string | UI label |
| `kind` | `anthropic`\|`kimi`\|`openai_compat`\|`ollama`\|`gemini`\|`glm` | dialect, **only** for an uncatalogued `messages-http`/`openai-compatible-http` endpoint; refused elsewhere (§9) |
| `request-path` | string | request path override for uncatalogued endpoints; catalogued providers take the catalog row's path |
| `enabled` | bool | default `true` |
| `max-context` | positive int | provider-level window default (precedence in spec/14 §3) |
| `connect-timeout-s` | positive float | bound on the phase before response headers. **No default**: absent means unbounded. Keeper turns remain bounded by the keeper's first-event budget |
| `exact-body-timeout-s` | positive float | bound on the whole exact-output request (connect, headers, body). See §7 for when it matters |
| `is-non-interactive`, `timeout-s` | bool, float | CLI-protocol options |
| `account-home` | string | account metadata for official-client providers |

### `[providers.<id>.credentials]`

| Key | Meaning |
| --- | --- |
| `type = "env"`, `key = <NAME>` | read the environment variable `NAME` |
| `type = "file"`, `path = <abs>` | read a raw key from a file |
| `type = "inline"`, `value = <key>` | the key itself; avoid for real secrets |

Resolution (`lib/runtime/runtime_adapter.ml`):

- Omitted credentials fall back to the catalog row's `api_key_env`; a catalog
  row with an **empty** `api_key_env` declares a provider that takes no key.
  An uncatalogued provider with no credentials is a load error.
- `env`: the first non-empty variable is used. `OLLAMA_CLOUD_API_KEY` also
  falls back to `OLLAMA_API_KEY`.
- `file`: must be absolute, owned by the current user, with no group/other
  permission bits, and contain a raw key — a JSON document is refused.

### `[providers.<id>.healthcheck]`, `.headers`, `.usage-read`, `.capabilities`

- `healthcheck.path` (absolute) is provider-owned metadata for install/setup
  probes; runtime startup does not use it for admission.
- `headers` injects fixed HTTP headers per request (e.g. OpenRouter's
  `HTTP-Referer`).
- `usage-read` reads usage windows without a model call: `shape` is one of
  `openrouter-key`, `zai-quota-limit`, `kimi-coding-usages`, `ollama-balance`;
  plus `url` and `refresh-s`.
- `capabilities` (RFC-0058 §2.4): `supports-inline-tools`,
  `argv-prompt-preflight`, `uses-messages-caching`.

## 3. `[models.<id>]` — what a model is

Unknown keys are load errors. The table id is the local model id used by
bindings and lanes.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `api-name` | string | the table id | model id sent on the wire (`model-name` is an accepted alias) |
| `max-context` | positive int | catalog | operator window override; fail-close at load when no source resolves (RFC-0206 §2.1) |
| `tools-support` | bool | `false` | |
| `thinking-support` | bool | absent | absent = follow the caller's policy |
| `preserve-thinking` | bool | absent | replay policy for prior-turn reasoning |
| `streaming` | bool | `true` | |
| `temperature`, `top-p`, `top-k`, `min-p` | float/int | absent | sampling; `top-k`/`min-p` are validated against the declared capabilities |
| `reasoning-effort` | `low`\|`medium`\|`high`\|`xhigh`\|`max` | absent | |
| `reasoning-uncontrolled` | bool | `false` | send no reasoning control; **cannot** coexist with `reasoning-effort` (load error) |
| `turn-timeout-s` | positive float | absent | per-turn bound |

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
- `max-output-tokens`: positive int (non-positive values are ignored with a
  warning).
- Feature booleans: `supports-tool-choice`, `supports-required-tool-choice`,
  `supports-named-tool-choice`, `supports-parallel-tool-calls`,
  `supports-image-input`, `supports-audio-input`, `supports-video-input`,
  `supports-multimodal-inputs`, `supports-response-format-json`,
  `supports-structured-output`, `supports-system-prompt`,
  `supports-assistant-prefill`, `supports-prompt-caching`, `supports-top-k`,
  `supports-min-p`, `supports-seed`, `emits-usage-tokens`.

## 4. `[<provider>.<model>]` — bindings

A binding is the runtime unit: `<provider>.<model>` is the runtime id used by
`[runtime] default`, lane candidates, exact-output slots, and keeper
assignments. Unknown keys are load errors.

| Key | Type | Meaning |
| --- | --- | --- |
| `max-context` | positive int | per-binding window override |
| `max-concurrent` | positive int | static client-side cap. **Omitted means no cap and no admission at all**: the binding dispatches straight out and stops only when the provider itself refuses (HTTP 429). Whether HTTP bindings should be required to declare it is open (#25401). `0` or negative is a load error |
| `context-high-water-tokens` + `context-low-water-tokens` | positive ints, `low < high` | eviction marks, as a pair — one without the other is a load error. After a response, when the whole request (fixed prefix + history) exceeds high, old bundles are dropped until the total is at or below low (#36828, RFC keeper-context-window-in-tokens) |
| `max-tokens` | positive int | per-request output budget; omitted lets the provider default decide (ollama.com/v1 defaults to 65536) |
| `disable-parallel-tool-use` | bool, default `false` | limit responses to one tool call |
| `price-input`, `price-output` | float | per-million pricing override (catalog otherwise) |
| `keep-alive`, `num-ctx`, `repeat-penalty` (> 0), `repeat-last-n` (≥ −1), `return-progress` | | Ollama-family knobs |
| `enabled`, `is-default`, `wizard-default` | bool | internal flags; not hand-written |

## 5. `[runtime]` — routing roots

| Key | Meaning |
| --- | --- |
| `default` | the runtime binding id used when nothing more specific applies. Must name a runtime, not a lane |
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
| `slots` | HTTP binding ids, tried in order |
| `cli_slots` | official-client runtime ids, used when every HTTP slot is blocked |

`slots = []` means `cli_slots` only; both empty is refused at load.

**Deadline rule**: a `slots` entry naming an HTTP runtime whose provider
declares no `exact-body-timeout-s` is refused at save time (rule 3, #38779).
An older admission layer additionally refuses a target carrying neither
deadline at all (`Missing_deadline`, #36979, #38573). `connect-timeout-s`
alone does not qualify a provider for exact-output slots; a keeper turn is
not affected — it keeps its own first-event budget.

## 8. Worked example — catalogued Anthropic provider

The catalog already has a `[[providers]] id = "claude"` row (dialect
`anthropic`, request path `/v1/messages`, env `ANTHROPIC_API_KEY`,
`serves_bare_rows = true`), so the runtime side declares only what the catalog
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
context-high-water-tokens = 100000
context-low-water-tokens = 70000
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
| no credentials on an uncatalogued provider | nothing says whether a key is needed |
| credential file relative / not owner-private / JSON | file credentials must be a raw, private, owned key |
| `healthcheck.path` not starting with `/` | must be absolute |
| `reasoning-effort` + `reasoning-uncontrolled` together | two contradictory requests |
| half-declared water marks, or `low ≥ high` | eviction marks travel as a pair |
| `max-concurrent` ≤ 0, `max-tokens` ≤ 0, non-positive `max-context` | meaningless values are rejected, not downgraded |
| exact-output lane with both slot lists empty | nothing to run |

Runtime (not load-time): an exact-output slot whose provider has neither
`connect-timeout-s` nor `exact-body-timeout-s` is refused at plan admission
with `Missing_deadline` (#36979, #38573), and a `slots` entry whose provider
lacks `exact-body-timeout-s` specifically is refused already at save time
(rule 3, #38779).
