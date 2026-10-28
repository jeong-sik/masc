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
| `openai-compatible-http` | HTTP | OpenAI Chat Completions, or Responses when the request path is `/responses`/`/v1/responses` (`provider_http_codec.ml`) | catalog row, or `kind` when uncatalogued |
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
| `request-path` | string | request path override, checked before the catalog row's path — also valid for a catalogued provider reached over a different supported surface (e.g. `ollama_cloud` over OpenAI-compatible, where the catalog's native path 404s, #33652) |
| `enabled` | bool | default `true` |
| `max-context` | positive int | provider-level window default (precedence in spec/14 §3) |
| `connect-timeout-s` | positive float | bound on the phase before response headers. **No default**: absent means unbounded. Keeper turns remain bounded by the keeper's first-event budget |
| `exact-body-timeout-s` | positive float | bound on the whole exact-output request (connect, headers, body). See §7 for when it matters |
| `is-non-interactive` | bool, default `false` | **required `true`** for every official-client protocol (`claude-code`, `codex-app-server`, `antigravity-cli`, `muse-serve`); otherwise the runtime does not materialize |
| `timeout-s` (+ `agent`, `effort`, `add-dirs`) | positive float (string; `low`\|`medium`\|`high`; absolute paths) | `antigravity-cli` only — refused on every other protocol. `timeout-s` is **required**; `effort` and `add-dirs` are optional |
| `account-home` | non-empty absolute path | **required** for `muse-serve`; accepted for `claude-code`/`codex-app-server`; refused elsewhere |
| `admission-priority-run-limit` | positive int | bounds consecutive judgment-lane Priority grants while a Standard Keeper request waits, and combined Priority/Standard grants while Background Librarian work waits. Omitted means one FIFO. Refused on official-client providers and when none of the provider's bindings declares `max-concurrent`. See [provider admission fairness](guides/provider-admission-fairness.md) |

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
- Official clients: `claude-code`, `codex-app-server` and `muse-serve` must
  **not** declare credentials (the client owns subscription login);
  `antigravity-cli` requires a `file` credential naming the operator-owned
  OAuth source.

### `[providers.<id>.healthcheck]`, `.headers`, `.usage-read`, `.capabilities`

- `healthcheck.path` (absolute) is provider-owned metadata for install/setup
  probes; runtime startup does not use it for admission.
- `headers` injects fixed non-auth HTTP headers per request (e.g.
  OpenRouter's `HTTP-Referer`). `authorization`, `x-api-key`, `api-key` and
  `x-auth-token` are stripped (case-insensitively) and never reach the
  request — authentication uses the credentials table only.
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
| `cli_slots` | official-client runtime ids, used when every HTTP slot is blocked |
| `max_output_tokens` | positive int output budget |
| `thinking` | bool thinking control |

`slots = []` means `cli_slots` only; both empty is refused at load on an
enabled lane (a disabled lane may keep empty lists).

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
| credentials on `claude-code`/`codex-app-server`/`muse-serve` | the official client owns subscription login |
| missing `is-non-interactive = true` on an official-client protocol | the runtime does not materialize without it |
| missing `timeout-s`, or non-file credential, on `antigravity-cli` | the CLI's deadline and OAuth source are mandatory |
| missing `account-home` on `muse-serve`; `account-home` outside the three account clients | the client cannot be addressed / the key belongs elsewhere |
| `healthcheck.path` not starting with `/` | must be absolute |
| `reasoning-effort` + `reasoning-uncontrolled` together | two contradictory requests |
| `max-concurrent` ≤ 0, `max-tokens` ≤ 0, non-positive `max-context` | meaningless values are rejected, not downgraded |
| negative/non-finite `turn-timeout-s` | only absent (adapter default) or ≥ 0 (0 removes the deadline) |
| `admission-priority-run-limit` on an official-client provider, or with no `max-concurrent` binding | nothing waits in the permit queue it would order |
| exact-output lane with both slot lists empty, while enabled | nothing to run |

Discovery (not load-time): an uncatalogued provider with no credentials
loads with an empty key, but model discovery (`resolve_api_key`) refuses
it — nothing has said a key is unnecessary.

Runtime (not load-time): an exact-output slot whose provider lacks
`exact-body-timeout-s` is refused at plan admission with `Missing_deadline`
(#36979, #38573) — `connect-timeout-s` alone never qualifies — and a
`slots` entry that newly adds such a gap is refused already at save time
(rule 3, #38779); gaps the file already has are grandfathered.
