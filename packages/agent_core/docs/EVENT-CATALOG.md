# OAS Event Catalog

Single source of truth for every event surface exposed by OAS. This
document covers *what* events exist, *where* they are emitted, *how* they
relate, and the contracts downstream consumers can rely on.

**Scope**: `agent_sdk` library (`lib/`).
**Status**: Stable catalog; entries marked *Evolving* may change with
deprecation notice.
**Last updated**: v0.216.0.

> **Note (v0.217.x)**: Surfaces 4 and 6 below reference the former
> `Runtime_server_*` protocol cluster and `Runtime_sync.window` replay
> surface. Those modules have been removed from `agent_sdk`; only
> `Runtime_store` (durable event/snapshot store) and `Runtime.event`
> remain as the live runtime surface. The entries are retained as
> historical contract references; rows marked *removed* no longer
> correspond to shipped code.

---

## 1. Six event surfaces at a glance

OAS carries six independent event surfaces. They are listed here in order
of external relevance.

| # | Surface | Module | Transport | Audience |
|---|---------|--------|-----------|---------|
| 1 | **Event_bus** | `Event_bus` | In-process pub/sub | Library consumers (subscribers) |
| 2 | **Hooks** | `Hooks` | Synchronous callback | Library consumers (interception/audit) |
| 3 | **Durable journal** | `Durable_event` | In-memory append-only + JSONL | Crash recovery + event-sourced replay |
| 4 | **Runtime protocol** | `Runtime` + `Runtime_server_*` | stdout JSON-RPC-ish protocol | `oas_runtime` subprocess consumers |
| 5 | **LLM wire stream** | `Types.sse_event` | Provider-specific SSE → normalized | Internal (streaming accumulation) |
| 6 | **Runtime resume replay** | `Runtime_sync.window` | JSON replay window | External resume/A2A adapters |

Surfaces 3 and 4 **bridge into** Surface 1 via `Journal_bridge` and
`Runtime_server_types.emit_event` respectively (see §4.2 and §5.1).

Surface 5 is independent and does not flow to Event_bus. Surface 6 replays
Surface 4 events for cursor-based resume; it does not publish additional
Event_bus payloads.

---

## 2. Surface 1: `Event_bus` (public pub/sub)

**Header**: `lib/event_bus.mli`. Stability: Evolving.

### 2.1 Envelope

Every event carries a common envelope:

```ocaml
type envelope = {
  correlation_id: string;       (* session-level, stable across a run *)
  run_id: string;               (* per-run identifier *)
  ts: float;                    (* Unix epoch seconds *)
  caused_by: string option;     (* optional causation link (#877) *)
}
```

**Contract**: `correlation_id` is constant for all events belonging to the
same logical session. `run_id` is unique per agent run. `caused_by`, when
`Some id`, points at the prior `run_id` (or `correlation_id`) that
causally triggered this event — enabling A→B→C cascade reconstruction
within a session. Root events and legacy producers set `caused_by =
None`. Envelopes are filled by producers, never rewritten by subscribers.

### 2.2 Native payload variants

Pattern-matchable OCaml sum type. **Stable across every provider.**

| Variant | Emit site | Semantic |
|---------|-----------|---------|
| `AgentStarted` | `agent/agent.ml` (`run`, `run_stream` — incl. `run_with_handoffs`) | Run lifecycle start |
| `AgentCompleted` | `agent/agent.ml` (`run`, `run_stream` — incl. `run_with_handoffs`) | Run lifecycle completion (carries the `result`) |
| `AgentFailed` | `agent/agent.ml` (`run`, `run_stream` — incl. `run_with_handoffs`) | Run lifecycle failure (companion to `AgentCompleted` on `Error`) |
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
- **I2 Stable envelope**: envelope field set is identical across providers.
- **I6 Multi-vendor**: a native variant is only added if its semantic exists in ≥2 vendor SDKs.

### 2.3 Custom namespaces (reserved)

`Custom(name, json)` is the open-ended extension point. **The `name`
string must be a dot-separated, lowercase, snake-case namespaced
identifier.** The following prefixes are reserved:

| Prefix | Owner | Purpose |
|--------|-------|---------|
| `runtime.*` | OAS | Events from `Runtime` session protocol (§5) |
| `durable.*` | OAS | Events from `Durable_event` journal (§4) |
| `provider.*` | OAS | Provider-specific escape hatch — e.g. `provider.anthropic.cache_hit`, `provider.openai.reasoning_tokens`, `provider.gemini.safety_rating` |
| `oas.*` | OAS | Reserved for future OAS use |
| `<downstream>.*` | Downstream | Any other prefix; pick one and stick to it |

**Downstream publishers SHOULD NOT use OAS's `Event_bus` as a general-
purpose telemetry channel for their own domain events.** Create your own
typed event surface for downstream product events.

External product/domain events can correlate with OAS via `correlation_id`,
`run_id`, `caused_by`, raw-trace refs, and OTel trace/span IDs without becoming
OAS-native taxonomy.

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

## 4. Surface 3: Durable journal

**Header**: `lib/durable_event.mli`. Stability: Evolving. @since 0.89.0.

Event-sourced record of everything needed to reconstruct agent state on
crash recovery. Events are immutable; append-only.

`Durable_event` remains the only production durable-journal authority. OAS has
no second public execution journal and external consumers must not dual-write
an alternative occurrence history. Any internal execution-topology work is
outside this public catalog until a production single-writer hard cut is
implemented.

This journal is the SSOT for committed effects and replay idempotency, not for
exact model-tool occurrence correlation. Its tool key intentionally remains a
name-and-input projection. Exact occurrence audit belongs to the canonical
`Tool.Invocation.t` carried by typed events and projected into raw trace.

### 4.1 Journal variants

| Variant | Purpose |
|---------|---------|
| `Turn_started` | New agent turn |
| `Llm_request` | LLM call issued (turn, model, input_tokens) |
| `Llm_response` | LLM call returned (output_tokens, stop_reason, duration_ms) |
| `Tool_called` | Tool invoked with idempotency key + input hash |
| `Tool_completed` | Tool finished; output recorded for replay skip |
| `State_transition` | Agent state machine change |
| `Checkpoint_saved` | Persistence milestone |
| `Error_occurred` | Error recorded with domain + detail |

### 4.2 Projection onto Event_bus

When a journal is created with `Journal_bridge.make ~bus ()`, each append
is mirrored to the Event_bus as a `Custom("durable.<kind>", json)` event
— one name per journal variant, dot-separated.

| Journal variant | Custom name |
|-----------------|-------------|
| `Turn_started` | `durable.turn_started` |
| `Llm_request` | `durable.llm_request` |
| `Llm_response` | `durable.llm_response` |
| `Tool_called` | `durable.tool_called` |
| `Tool_completed` | `durable.tool_completed` |
| `State_transition` | `durable.state_transition` |
| `Checkpoint_saved` | `durable.checkpoint_saved` |
| `Error_occurred` | `durable.error_occurred` |

**Correlation**: `Journal_bridge.make` accepts `?correlation_id` and
`?run_id` so durable events can be attached to the same envelope chain
as the surrounding agent run.

**Failure contract**: the bridge does not absorb publication exceptions.
The journal append commits first; an ordinary projection failure is returned
as `Durable_event.append_error`, while reserved runtime exceptions and
cancellation propagate with their original backtrace.

### 4.3 Deduplication advisory

`agent/agent_tools.ml` publishes native `ToolCalled`/`ToolCompleted`
events AND appends to the journal. If you attach `Journal_bridge` to the
journal AND subscribe to Event_bus, **both** native and `durable.*`
versions will arrive for the same tool call. This is intentional — the
native variants are provider-agnostic snapshots, the `durable.*` variants
carry replay metadata (idempotency keys). Downstream code that counts
tool calls from Event_bus should filter on one or the other.

---

## 5. Surface 4: Runtime protocol

**Header**: `lib/runtime.ml`. Stability: Evolving.

Session-level runtime for `oas_runtime` subprocess usage. Runtime emits
on **two channels simultaneously**:

1. **Primary**: JSON-RPC-ish protocol message `Event_message { session_id; event }` written to stdout.
2. **Secondary**: Event_bus publish as `Custom("runtime.<kind>", json)`.

### 5.1 Runtime event variants

| Variant | Custom name |
|---------|-------------|
| `Session_started` | `runtime.session_started` |
| `Session_settings_updated` | `runtime.session_settings_updated` |
| `Turn_recorded` | `runtime.turn_recorded` |
| `Input_required` | `runtime.input_required` |
| `Input_provided` | `runtime.input_provided` |
| `Agent_spawn_requested` | `runtime.agent_spawn_requested` |
| `Agent_became_live` | `runtime.agent_became_live` |
| `Agent_output_delta` | `runtime.agent_output_delta` |
| `Agent_completed` | `runtime.agent_completed` |
| `Agent_failed` | `runtime.agent_failed` |
| `Artifact_attached` | `runtime.artifact_attached` |
| `Checkpoint_saved` | `runtime.checkpoint_saved` |
| `Finalize_requested` | `runtime.finalize_requested` |
| `Session_completed` | `runtime.session_completed` |
| `Session_failed` | `runtime.session_failed` |

**Name collision note**: `Runtime.Agent_completed` (session-level
participant lifecycle) is distinct from the native
`Event_bus.AgentCompleted` payload. They live in different modules with
different payload shapes. Disambiguate by Custom name prefix:
`runtime.agent_completed` vs native `AgentCompleted`.

**Structured completion/failure metadata**:
- All three participant lifecycle payloads nest the shared identity and trace
  fields in one `Runtime.participant_event_common` record under `participant`.
  `participant_live_event` contains only that common record,
  `participant_completed_event` adds optional `stop_reason` and
  `completion_anomaly`, and `participant_failed_event` requires one typed
  `failure_cause`. Completed-with-failure and failed-without-cause states are
  not representable and their old flat JSON shapes are rejected.
- `Runtime.output_delta_event` carries optional `raw_trace_run_id` so streamed
  child-agent text can be joined to the same EventBus `run_id` and telemetry
  row as its final completion event.
- A non-fatal failure in the EventBus projection, participant terminal-event
  persistence, or the outer participant lane is emitted on the runtime
  protocol as an error `System_message`. Such an observation does not invent a
  durable lifecycle event, roll back an event that already committed, or
  cancel another participant lane.
- `Runtime.session.pending_input` carries the resumable `input_request`
  while phase is `Input_required`; `Provide_input` emits
  `Input_provided`, clears the payload, and returns the session to
  `Running`.
- Runtime finalization persists the operator-facing evidence set:
  `report.json`, `proof.json`, `runtime-telemetry-json`,
  `runtime-telemetry`, `runtime-raw-trace-json`, and `runtime-evidence`.
- `runtime-telemetry-json` carries structured event counts and per-step
  fields such as provider/model, raw-trace run id, stop reason, dropped
  output deltas, and persistence-failure phase.
- `runtime-raw-trace-json` publishes the latest raw-trace run refs,
  summaries, and validations so external consumers can correlate live
  runtime events with persisted raw traces without reconstructing the
  proof bundle first.
- `runtime-evidence` records present/missing files for the session,
  events, report, proof, telemetry, and raw-trace manifest artifacts.
- The complete output surface map is maintained in
  `docs/RUNTIME-OUTPUT-SCHEMA-INDEX.md` and
  `docs/schema-surfaces/runtime-output-surfaces.v1.json`.

## 6. Surface 5: LLM wire stream (`Types.sse_event`)

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

### 6.1 Provider mapping

| Provider wire event | `sse_event` |
|---------------------|-------------|
| Anthropic `message_start` | `MessageStart` |
| Anthropic `content_block_delta` | `ContentBlockDelta` |
| OpenAI `response.created` | `MessageStart` |
| OpenAI `response.output_text.delta` | `ContentBlockDelta(TextDelta)` |
| OpenAI `response.output_item.added` | `ContentBlockStart` |
| OpenAI `response.completed` | `MessageStop` |
| Gemini `streamGenerateContent` chunks | Synthesized via `emit_synthetic_events` |

SSE events **do not reach Event_bus**. They are consumed by the stream
accumulator inside the provider API module, and only the final
`api_response` (and whatever Event_bus events the agent layer emits
around that) become observable.

---

## 7. Surface 6: Runtime resume replay

**Header**: `lib/runtime_sync.mli`; event truth:
`lib/runtime.mli`. Stability: Evolving.

Current OAS core does not expose a `lib/protocol/a2a_server.ml` HTTP task
stream. External A2A or resume-capable adapters should bridge protocol
messages onto Runtime commands and consume `Runtime_sync.window` for replay.

| Runtime surface | Adapter purpose |
|-----------------|-----------------|
| `Runtime.Request_input` / `Runtime.Input_required` | Pause a runtime session with a durable `pending_input` payload |
| `Runtime.Provide_input` / `Runtime.Input_provided` | Resume the matching input request and clear `pending_input` |
| `Runtime_sync.window` | Return cursor-based replay rows for events after `after_seq` |

**Contract**:
- The replay stream is keyed by `stream_id`; adapters may use their own
  external task/message identifier as long as cursors remain stream-local.
- Resume fixtures must assert both pause and resume events:
  `Input_required` followed by matching `Input_provided`.
- This surface derives from Runtime events. It does not reintroduce the legacy
  `TaskStateChanged` / `TaskCompleted` task stream.

---

## 8. Multi-vendor compatibility matrix

Every OAS-supported LLM vendor produces the **same native Event_bus
payload variants** when running via OAS. Provider-specific signals go
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

## 9. How to add a new event

1. **Decide the surface**. Is this:
   - A general agent lifecycle signal (≥2 providers)? → `Event_bus` native variant.
   - An audit/interception point? → `Hooks` callback.
   - A replay-relevant record? → `Durable_event` variant.
   - Provider-specific? → `Custom("provider.<name>.<event>", json)`.
   - Downstream domain event? → downstream's own Event_bus, not OAS's.

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

## 10. How to add a new provider

1. **Hosted API**: create `lib/llm_provider/backend_<name>.ml` implementing
   the same normalized streaming interface (`Types.sse_event` output).
   OpenAI-compatible endpoints don't need a new backend module — declare
   the endpoint in `Llm_provider.Provider_registry`/`Provider_catalog`, then
   pass the resulting exact `Provider_config.t` to
   `Agent.options.provider_config`.
2. **SSE normalization**: map the provider's wire events to
   `Types.sse_event` constructors. Document the mapping in §6.1.
3. **Provider-specific extensions**: if the provider exposes unique
   signals (caching, reasoning summaries, safety ratings) that users want
   to observe, publish them as `Custom("provider.<name>.<event>", json)`.
4. **Verification**: add a row to the multi-vendor matrix (§8) and,
   if desired, a live-mode assertion in `test_multivendor_events.ml`.
5. **No Event_bus taxonomy change**. Adding a provider must not add a
   native variant — if it seems to, revisit I6.

---

## 11. Industry comparison

| Concept | OAS | OpenAI Agents SDK | Claude Agent SDK | LangGraph |
|---------|-----|-------------------|------------------|-----------|
| Primary surface | `Event_bus` + `Hooks` | `RawResponsesStreamEvent` / `RunItemStreamEvent` / `AgentUpdatedStreamEvent` | Hooks (18 events) | `astream_events` |
| Event shape | Tagged OCaml sum (pattern match) | Flat `type` string + JSON | Hook callback arguments | Flat `event` string + data/metadata |
| Raw LLM stream | `Types.sse_event` (internal) | `RawResponsesStreamEvent` | hidden | `on_chat_model_stream` |
| Tool events | `ToolCalled`/`ToolCompleted` | `tool_called` / `tool_output` | `PreToolUse` / `PostToolUse` | `on_tool_start` / `on_tool_end` |
| Handoff events | `HandoffRequested` / `HandoffCompleted` | `handoff_requested` / `handoff_occurred` | — | via node transitions |
| Interception | Hooks | on_handoff callbacks | Hook return value | interrupts |

---

## 12. Stability

Entries in this catalog carry the stability tier of their module (see
`docs/api-stability.md`). Breaking changes are tracked in `CHANGELOG.md`
under a dated **Breaking** section.
