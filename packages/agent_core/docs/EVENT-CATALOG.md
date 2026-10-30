# AGENT_CORE Event Catalog

Single source of truth for every event surface exposed by AGENT_CORE. This
document covers *what* events exist, *where* they are emitted, *how* they
relate, and the contracts downstream consumers can rely on.

**Scope**: `agent_core` library (`lib/`).
**Status**: Stable catalog; entries marked *Evolving* may change with
deprecation notice.
**Last updated**: v0.216.0.

> **Note (v0.217.x)**: The former `Runtime_server_*` subprocess protocol
> cluster and `Runtime_sync.window` replay surface have been removed from
> `agent_core`; only `Runtime_store` (durable event/snapshot store) and
> `Runtime.event` remain as the live runtime surface.

---

## 1. Four event surfaces at a glance

AGENT_CORE carries four active event surfaces, listed here in order of external
relevance.

| # | Surface | Module | Transport | Audience |
|---|---------|--------|-----------|---------|
| 1 | **Event_bus** | `Event_bus` | In-process pub/sub | Library consumers (subscribers) |
| 2 | **Hooks** | `Hooks` | Synchronous callback | Library consumers (interception/audit) |
| 3 | **Execution history** | `Agent.Execution_projection` | Cursor reads from the scoped durable execution store | Occurrence audit and recovery |
| 4 | **LLM wire stream** | `Types.sse_event` | Provider-specific SSE → normalized | Internal (streaming accumulation) |

Surface 3 is read through `Agent.open_execution_projection`; subscriptions to Surface 1
do not establish durable occurrence or effect-replay authority.

Surface 4 is independent and does not flow to Event_bus.

---

## 2. Surface 1: `Event_bus` (public pub/sub)

**Header**: `lib/event_bus.mli`. Stability: Evolving.

### 2.1 Envelope

Every event carries a common envelope:

```ocaml
type envelope = Event_envelope.t = {
  event_id: string;              (* producer-owned occurrence identity *)
  correlation_id: string;        (* session-level, stable across a run *)
  run_id: string;                (* per-run identifier *)
  event_time: float;             (* producer event time *)
  observed_at: float;            (* producer observation time *)
  seq: int option;
  parent_event_id: string option;
  caused_by: string option;
  source_clock: source_clock;
  caller_scope: Caller_scope.t option;  (* from the bus handle, never read here *)
}
```

**Contract**: `event_id` is minted once from operating-system entropy by the
producer for one occurrence and is preserved unchanged by durable, replay, and
live-delivery adapters. Entropy failure is explicit; clocks, process IDs,
paths, and event content are not identity fallbacks.
`correlation_id` is constant for all events belonging to the same logical
session. `run_id` is unique per agent run. `caused_by`, when `Some id`, points
at the prior `run_id` (or `correlation_id`) that causally triggered this event
— enabling A→B→C cascade reconstruction within a session. Root events set
`caused_by = None`. Envelopes are filled by producers, never reconstructed or
rewritten by subscribers.
`caller_scope` is the scope of the bus handle the event was published on
(`Event_bus.with_caller_scope`). The code that made the handle decides what
it means; Agent Core only carries it. A handle keeps a scope the event
already names.

### 2.2 Native payload variants

Pattern-matchable OCaml sum type. **Stable across every provider.**

| Variant | Emit site | Semantic |
|---------|-----------|---------|
| `AgentStarted` | `agent/agent.ml` (`run`, `run_stream` — incl. `run_with_handoffs`) | Run lifecycle start |
| `AgentCompleted` | `agent/agent_lifecycle_events.ml` (wrapping `run`, `run_stream` — incl. `run_with_handoffs`) | Successful run lifecycle completion (carries the response) |
| `AgentFailed` | `agent/agent_lifecycle_events.ml` (wrapping `run`, `run_stream` — incl. `run_with_handoffs`) | Failed run lifecycle terminal outcome; mutually exclusive with `AgentCompleted` |
| `TurnStarted` | `pipeline/pipeline_stage_prepare.ml` | Start of a single agent turn |
| `TurnReady` | `pipeline/pipeline_stage_prepare.ml` | Exact caller-supplied tool surface serialized for this turn |
| `TurnCompleted` | `pipeline/pipeline.ml` | End of a single agent turn |
| `ToolCalled` | `agent/agent_tools.ml` | Tool invocation requested by LLM; carries the exact run-scoped `Tool.Invocation.t` |
| `ToolCompleted` | `agent/agent_tools.ml` | Tool invocation result available; carries the same exact typed invocation |
| `HandoffRequested` | `agent/agent.ml` | Agent delegates control to another agent |
| `HandoffCompleted` | `agent/agent.ml` | Handoff target finished |
| `ElicitationCompleted` | `pipeline/pipeline_stage_prepare.ml` | User elicitation round completed |
| `ToolApprovalCompleted` | `agent/agent_tool_pre_execution_gate.ml` | Caller-owned exact tool approval settled before invocation |
| `InferenceTelemetry` | `pipeline/pipeline.ml` | Per-turn provider timing/token telemetry when reported by the backend |
| `Custom (name, json)` | anywhere | Extension point — see §2.3 |

**Invariants**:
- **I1 Provider-agnostic**: every native payload field is meaningful regardless of which provider serves the underlying LLM.
- **I2 Stable envelope**: envelope field set is identical across providers and
  every occurrence has a non-empty, producer-owned `event_id`.
- **I6 Multi-vendor**: a native variant is only added if its semantic exists in ≥2 vendor SDKs.

### 2.3 Custom namespaces (reserved)

`Custom(name, json)` is the open-ended extension point. **The `name`
string must be a dot-separated, lowercase, snake-case namespaced
identifier.** The following prefixes are reserved:

| Prefix | Owner | Purpose |
|--------|-------|---------|
| `runtime.*` | AGENT_CORE | Events from `Runtime` session protocol (§5) |
| `provider.*` | AGENT_CORE | Provider-specific escape hatch — e.g. `provider.anthropic.cache_hit`, `provider.openai.reasoning_tokens`, `provider.gemini.safety_rating` |
| `agent_core.*` | AGENT_CORE | Reserved for future AGENT_CORE use |
| `<downstream>.*` | Downstream | Any other prefix; pick one and stick to it |

**Downstream publishers SHOULD NOT use AGENT_CORE's `Event_bus` as a general-
purpose telemetry channel for their own domain events.** Create your own
typed event surface for downstream product events.

External product/domain events can correlate with AGENT_CORE via `correlation_id`,
`run_id`, `caused_by`, raw-trace refs, and OTel trace/span IDs without becoming
AGENT_CORE-native taxonomy.

### 2.4 Filters, subscriptions, and draining

```ocaml
val subscription_config :
  capacity:int ->
  overflow:overflow ->
  (subscription_config, subscription_config_error) result

val subscribe :
  config:subscription_config ->
  ?filter:filter ->
  ?purpose:string ->
  t ->
  subscription
val drain : subscription -> event list
```

Filters compose: `filter_any`, `filter_all`, `filter_agent`,
`filter_tools_only`, `filter_topic`, `filter_correlation`, `filter_run`.

Each subscription owns an explicitly sized bounded FIFO and chooses
`Drop_oldest` or `Drop_newest`. `publish` never waits for queue capacity to
become available; capacity pressure affects only that subscriber and increments
its `dropped_total`. `stats` exposes the configured capacity and overflow
behavior, subscriber count, queue depth, and published/drained/drop totals.

### 2.5 What is **not** in the native taxonomy (by design)

- **Thinking / reasoning events** — provider semantics diverge (Anthropic
  encrypted `thinking` block; OpenAI `reasoning` summary; DeepSeek-R1
  raw reasoning; Qwen3 soft thinking). Ride in `provider.<name>.thinking`
  until an RFC reconciles semantics.
- **Prompt caching events** — Anthropic `cache_creation_input_tokens`,
  OpenAI `prompt_tokens_details.cached_tokens`. Different billing
  semantics; use `provider.<name>.cache_hit` for now.

---

## 3. Surface 2: `Hooks` (synchronous callback)

**Header**: `lib/base/hooks.mli`. Stability: Evolving.

Hooks are synchronous interception points registered on `Agent` at build
time. Use Hooks when you need to **audit** or **interfere with** a step;
use Event_bus when you only need to **observe**.

Available hooks (post-v0.154.0):

| Hook | Signature | Purpose |
|------|-----------|---------|
| `before_turn` | `hook_event -> hook_decision` | Continue, request caller input, or append a caller nudge |
| `before_turn_params` | `hook_event -> hook_decision` | Continue or provide exact per-turn parameters |
| `after_turn` | `hook_event -> hook_decision` | Observe the completed provider response |
| `pre_tool_use` | `hook_event -> hook_decision` | Continue, explicitly block, or request input for an exact tool invocation at the embedding boundary |
| `post_tool_use` | `hook_event -> hook_decision` | Observe a tool result |
| `post_tool_use_failure` | `hook_event -> hook_decision` | Observe a typed tool failure |
| `on_stop` | `hook_event -> hook_decision` | Observe the terminal stop reason |
| `on_error` | `hook_event -> hook_decision` | Observe an agent error |
| `on_tool_error` | `hook_event -> hook_decision` | Observe a tool-returned error |

See `lib/base/hooks.mli` for the full decision contract.

### 3.1 Hook vs Event decision matrix

| Use Hook when… | Use Event_bus when… |
|----------------|---------------------|
| You need to adjust a turn or return an exact caller-owned tool rejection | You are strictly observing |
| The callback must run synchronously at that lifecycle point | A bounded subscriber queue is appropriate |
| Callback failure must be surfaced to the agent call | Queue loss can be handled from explicit drop statistics |
| Scope is a single agent | Scope may cross agents/sessions |
| Failure should abort the agent | Subscriber failure is isolated |

---

## 4. Surface 3: Scoped execution history

**Header**: `lib/agent/agent.mli` and
`lib/agent/agent_execution_projection_intf.mli`.

`Agent.execution_store` attaches caller-owned durable storage to one finite Agent
execution. The engine's typed execution scope owns run, turn, provider, output,
Tool invocation and exact Tool attempt occurrences. Nested work belongs to the
creating attempt. A provider-supplied tool-use id or a name/input digest is not
an external-effect receipt.

`Agent.open_execution_projection` opens the public read-only projection for a saved
execution locator. Pages retain the journal's event identity and scoped cursor;
`through` freezes a committed prefix while later events are appended. The
writer's Store/WAL/reducer/transaction machinery is private. Public consumers
cannot append a parallel execution history.

Tool settlement commits the attempt before entering its external effect and
commits the result afterward. Recovery replays a settled result; an admitted
attempt without a result is an explicit unknown outcome, not permission to
repeat the effect. Caller-owned checkpoint sinks remain typed conversation
snapshot boundaries; a failed sink does not certify a later mutation stage.

Event_bus and Raw_trace expose observational callbacks as well. They do not
supply replay or external-effect authority. Their complete conversion to
cursor-bound, read-only post-commit projections, and finite-scope retention
acceptance, remain explicit integration requirements in masc#27890; removing a
writer API alone does not prove those requirements. A transient Agent run
without an execution store has no durable history to recover.

---

## 5. Surface 4: LLM wire stream (`Types.sse_event`)

**Header**: `lib/llm_provider/types.ml`. Stability: Internal.

Normalized representation of provider SSE streams. Each provider's
`lib/llm_provider/backend_<name>.ml` parses its wire format and produces
`Types.sse_event` values; `Llm_provider.Complete_stream_acc` accumulates
them into a final `Types.api_response`.

| Variant | Semantic |
|---------|---------|
| `MessageStart` | Stream begun (id, model, initial usage) |
| `ContentBlockStart` | New content block — text, thinking, or tool_use |
| `ContentBlockDelta` | Incremental content (text / thinking / input JSON) |
| `ContentBlockStop` | Content block finished |
| `MessageDelta` | Partial message update (stop_reason, usage) |
| `MessageStop` | Stream finished |
| `Ping` | Keepalive |
| `SSEError` | Stream-level error |

### 5.1 Provider mapping

| Provider wire event | `sse_event` |
|---------------------|-------------|
| Anthropic `message_start` | `MessageStart` |
| Anthropic `content_block_delta` | `ContentBlockDelta` |
| OpenAI `response.created` | `MessageStart` |
| OpenAI `response.output_text.delta` | `ContentBlockDelta(TextDelta)` |
| OpenAI `response.output_item.added` | `ContentBlockStart` |
| OpenAI `response.completed` | `MessageStop` |
| Gemini `streamGenerateContent` chunks | Parsed per chunk by `gemini_chunk_to_events` (`streaming.ml`) into `ContentBlockStart` / `ContentBlockDelta(TextDelta\|ThinkingDelta)` / `MessageDelta` / `MessageStop` |

`emit_synthetic_events` has no production callers (test-only fallback that
synthesizes a pseudo-stream from a final `api_response`); it is not how any
provider's live chunks are mapped.

SSE events **do not reach Event_bus**. They are consumed by the stream
accumulator inside the provider API module, and only the final
`api_response` (and whatever Event_bus events the agent layer emits
around that) become observable.

---

## 6. Multi-vendor compatibility matrix

Every AGENT_CORE-supported LLM vendor produces the **same native Event_bus
payload variants** when running via AGENT_CORE. Provider-specific signals go
through `Custom("provider.<name>.<event>", ...)`.

| Provider | Native: Agent/Turn/Tool | Native: Handoff | Native: Context* | Provider-specific Custom |
|----------|------------------------|-----------------|------------------|--------------------------|
| Anthropic | ✓ | ✓ | ✓ | `provider.anthropic.cache_hit`, `provider.anthropic.thinking` |
| OpenAI (Chat/Responses) | ✓ | ✓ | ✓ | `provider.openai.reasoning_tokens`, `provider.openai.prompt_cache_hit` |
| Gemini | ✓ | ✓ | ✓ | `provider.gemini.safety_rating`, `provider.gemini.thinking` |
| GLM / ZhipuAI | ✓ | ✓ | ✓ | `provider.glm.*` |
| OpenRouter | ✓ | ✓ | ✓ | inherits upstream, namespaced under `provider.openrouter.*` |
| Groq / DeepSeek / Alibaba / SiliconFlow / xAI | ✓ | ✓ | ✓ | `provider.<name>.*` |
| llama.cpp / llama-server (local) | ✓ | ✓ | ✓ | `provider.llama.*` |
| Ollama (local) | ✓ | ✓ | ✓ | `provider.ollama.*` |
| vLLM / LM Studio / TGI / MLX (local) | ✓ | ✓ | ✓ | `provider.<runtime>.*` |
| Caller-supplied typed endpoint | ✓ | ✓ | ✓ | caller-defined |

**Verification**: `test/test_multivendor_events.ml` asserts a golden
Event_bus sequence (`AgentStarted → TurnStarted → ToolCalled →
ToolCompleted → TurnCompleted → AgentCompleted`) across every available
provider. Missing credentials / endpoints skip gracefully.

---

## 7. How to add a new event

1. **Decide the surface**. Is this:
   - A general agent lifecycle signal (≥2 providers)? → `Event_bus` native variant.
   - An audit/interception point? → `Hooks` callback.
   - A replay-relevant record? → the engine-owned typed execution transaction,
     with a read-only `Agent.Execution_projection` representation.
   - Provider-specific? → `Custom("provider.<name>.<event>", json)`.
   - Downstream domain event? → downstream's own Event_bus, not AGENT_CORE's.

2. **Provider-agnostic check** (native variants only, per I6):
   - Confirm the semantic exists in Anthropic + OpenAI + Gemini.
   - Payload fields must make sense regardless of which provider is running.
   - If provider-specific info leaks in, redesign the payload or use `Custom`.

3. **Update artifacts**:
   - Add to `Event_bus.mli` with doc comment + `@since`.
   - Add the exhaustive `payload_kind` and filter branches in `event_bus.ml`.
   - Emit site(s) in the appropriate module.
   - Add this doc row.
   - Update `test/test_multivendor_events.ml` golden transcript if the new event is part of the standard lifecycle.

4. **Exhaustiveness**: confirm `Event_bus.payload_kind` in
   `lib/event_bus.ml` and other `match` sites on `Event_bus.payload`
   cover the new variant (they use explicit arms, not `_`, so the
   compiler will flag omissions under the repo's `warn-error +8` flag
   set). `lib/eval_collector.ml` was removed in PR #2689 and is no
   longer a match site to update.

## 8. How to add a new provider

1. **Hosted API**: create `lib/llm_provider/backend_<name>.ml` implementing
   the same normalized streaming interface (`Types.sse_event` output).
   OpenAI-compatible endpoints don't need a new backend module — declare
   the endpoint in `Llm_provider.Provider_registry`/`Provider_catalog`, then
   pass the resulting exact `Provider_config.t` to
   `Agent.options.provider_config`.
2. **SSE normalization**: map the provider's wire events to
   `Types.sse_event` constructors. Document the mapping in §5.1.
3. **Provider-specific extensions**: if the provider exposes unique
   signals (caching, reasoning summaries, safety ratings) that users want
   to observe, publish them as `Custom("provider.<name>.<event>", json)`.
4. **Verification**: add a row to the multi-vendor matrix (§6) and,
   if desired, a live-mode assertion in `test_multivendor_events.ml`.
5. **No Event_bus taxonomy change**. Adding a provider must not add a
   native variant — if it seems to, revisit I6.

---

## 9. Industry comparison

| Concept | AGENT_CORE | OpenAI Agents SDK | Claude Agent SDK | LangGraph |
|---------|-----|-------------------|------------------|-----------|
| Primary surface | `Event_bus` + `Hooks` | `RawResponsesStreamEvent` / `RunItemStreamEvent` / `AgentUpdatedStreamEvent` | Hooks (18 events) | `astream_events` |
| Event shape | Tagged OCaml sum (pattern match) | Flat `type` string + JSON | Hook callback arguments | Flat `event` string + data/metadata |
| Raw LLM stream | `Types.sse_event` (internal) | `RawResponsesStreamEvent` | hidden | `on_chat_model_stream` |
| Tool events | `ToolCalled`/`ToolCompleted` | `tool_called` / `tool_output` | `PreToolUse` / `PostToolUse` | `on_tool_start` / `on_tool_end` |
| Handoff events | `HandoffRequested` / `HandoffCompleted` | `handoff_requested` / `handoff_occurred` | — | via node transitions |
| Interception | Hooks | on_handoff callbacks | Hook return value | interrupts |

---

## 10. Stability

Entries in this catalog carry the stability tier of their module (see
`docs/api-stability.md`). Breaking changes are tracked in `CHANGELOG.md`
under standard Keep a Changelog release headings (`Added` / `Changed` /
`Removed`).
