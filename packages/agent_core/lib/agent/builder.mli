(** Builder pattern for Agent creation.

    Provides a flat, chainable API as an alternative to nested
    [Agent.create] params. Use [build_safe] for validated construction.

    @stability Stable
    @since 0.93.1 *)

type t

val create : net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t -> model:Types.model -> t

(** {2 Configuration} *)

val with_name : string -> t -> t
val with_system_prompt : string -> t -> t
val with_max_tokens : int -> t -> t
val with_temperature : float -> t -> t
val with_top_p : float -> t -> t
val with_top_k : int -> t -> t
val with_min_p : float -> t -> t
val with_enable_thinking : bool -> t -> t
val with_preserve_thinking : bool -> t -> t
val with_thinking_budget : int -> t -> t
val with_reasoning_effort : Llm_provider.Reasoning_effort.t -> t -> t
val with_tool_choice : Types.tool_choice -> t -> t
val with_response_format : Types.response_format -> t -> t
val with_disable_parallel_tool_use : bool -> t -> t
val with_initial_messages : Types.message list -> t -> t
val with_cache_system_prompt : bool -> t -> t
val with_cache_extended_ttl : bool -> t -> t

(** Enable or disable provider-lease release before tool execution.

    When [true], a run invokes [on_yield] after assistant collection succeeds
    and immediately before the first tool hook or implementation. A continuing
    run invokes [on_resume] before its next provider turn. Only affects
    [on_yield]/[on_resume] callback behavior; it does not change model or tool
    semantics.

    @since 0.99.7 *)
val with_yield_on_tool : bool -> t -> t

(** {2 Tools and MCP} *)

val with_tools : Tool.t list -> t -> t
val with_tool : Tool.t -> t -> t
val with_mcp_clients : Mcp.managed list -> t -> t

(** {2 Runtime options} *)

val with_hooks : Hooks.hooks -> t -> t
val with_guardrails_async : Guardrails_async.t -> t -> t

(** Pin LLM requests to a specific llama-server slot for KV cache reuse.
    @since 0.109.0 *)
val with_slot_id : int -> t -> t

val with_tracer : Tracing.t -> t -> t
val with_trace_link : (string * string) option -> t -> t
val with_raw_trace : Raw_trace.t -> t -> t
val with_context : Context.t -> t -> t
val with_context_injector : Hooks.context_injector -> t -> t

(** Attach a caller-owned event bus, replacing the default per-agent bus. *)
val with_event_bus : Event_bus.t -> t -> t

(** Opt out of observability-as-default by clearing the event bus.

    {!create} installs a fresh per-agent {!Event_bus.t} so Turn / Tool /
    InferenceTelemetry events are emitted without the caller opting in. Use
    this when no events should be produced at all (e.g. a latency-sensitive
    agent with no observer). With no subscriber the default bus only costs a
    mutex acquire per event, so prefer leaving it on unless you have a reason.
    @since 0.207.19 *)
val without_event_bus : t -> t

(** Set the per-line idle deadline applied to streaming HTTP responses
    (Ollama NDJSON, Anthropic / Openai / Gemini / Glm SSE). Resets after
    each successful line, so this caps inter-chunk silence — not total
    stream duration. A stalled endpoint surfaces as
    [TimeoutError { phase = Stream_idle state; _ }], preserving whether
    the stream was waiting for answer/thinking/tool-call progress.
    @since 0.176.0 *)
val with_stream_idle_timeout : float -> t -> t

(** RFC-OAS-037: set the dedicated time-to-first-event (TTFT / prefill)
    deadline, distinct from [with_stream_idle_timeout]. It bounds only the
    wait for the FIRST streaming event; [stream_idle_timeout_s] arms for
    inter-token idle only after the first event arrives. A silent prefill
    on a large context is slow-but-alive, not a hang, so it must not be
    cut by the short inter-token idle value. When unset the first-event wait
    falls back to the body timeout, then to the stream idle timeout, and is
    unarmed only when none of the three is set; inter-token idle still guards
    once the stream produces, and the connect timeout still guards connection
    setup. @since 0.218.0 *)
val with_first_event_timeout : float -> t -> t

(** Set the per-call total deadline for non-streaming HTTP response body
    consumption. This separately bounds a provider-native input-count
    preflight and a non-streaming completion; it is not a combined turn
    deadline. Requires a clock to be provided to the underlying request;
    without one the wrapper is skipped. The streaming completion itself
    ignores this knob and relies on [with_stream_idle_timeout] for inter-line
    liveness; only its optional non-streaming count preflight uses this
    deadline. @since 0.181.0 *)
val with_body_timeout : float -> t -> t

val with_elicitation : Hooks.elicitation_callback -> t -> t

(** Configure the closed typed approval boundary used only by
    [Hooks.ElicitToolApproval] at [PreToolUse]. The callback settles
    synchronously; OAS does not install a timeout or durable pause. *)
val with_tool_approval : Hooks.tool_approval_callback -> t -> t

val with_description : string -> t -> t
val with_periodic_callback : Agent.periodic_callback -> t -> t
val with_periodic_callbacks : Agent.periodic_callback list -> t -> t

(** Select an exact typed provider configuration. The Builder carries provider
    identity, wire kind, endpoint, credential, headers, request path, and
    capability overrides unchanged to dispatch. Generic turn fields seed the
    Builder and may be replaced by later [with_*] calls. *)
val with_provider_config : Llm_provider.Provider_config.t -> t -> t

(** Select Agent-level provider-fit admission without changing standalone
    [Complete] compatibility behavior. *)
val with_context_fit_admission : Agent.context_fit_admission -> t -> t

(** Apply a caller-owned projection once to the complete provider-bound message
    list. Native request measurement and actual dispatch consume that same
    projected request; canonical Agent state and checkpoints remain unchanged.
    [Error detail] fails the turn as a typed hook execution error. *)
val with_model_input_projection : Agent.model_input_projection -> t -> t

(** Observe metadata-only evidence for the exact provider serialization prepared
    before dispatch. This hook does not prove that transport dispatch started. *)
val with_pre_dispatch_serialization_observer
  :  Agent.pre_dispatch_serialization_observer
  -> t
  -> t

(** Inject an {!Llm_provider.Llm_transport.t} for non-HTTP providers.
    Required for CLI provider kinds ([Claude_code], [Codex],
    [Gemini], [Kimi]) which are reached via subprocess rather
    than HTTP.
    For HTTP kinds (Anthropic/Gemini/Glm/Ollama/OpenAI_compat) the
    transport is unused and can be left unset.

    The transport must outlive the agent's [run] call.
    @since 0.156.0 *)
val with_transport : Llm_provider.Llm_transport.t -> t -> t

(** {2 Contract} *)

val with_contract : Contract.t -> t -> t

(** {3 Runtime skill composition}

    Skills added via [with_skill] / [with_skills] are composed into the
    agent's system prompt at build time.  Each skill body is rendered as
    a [\[Skill: <name>\]] section appended to the base system prompt.

    This is the {b runtime path}: it affects what the LLM sees on every
    turn.  For metadata-only registration (Agent Card export, A2A
    discovery, skill inventory) use {!with_skill_registry} instead. *)

val with_skill : Skill.t -> t -> t
val with_skills : Skill.t list -> t -> t

(** {2 Logging} *)

val with_log_level : Log.level -> t -> t
val with_log_sink : Log.sink -> t -> t
(* with_event_targets removed — was a no-op.  See oas#669. *)

(** {3 Discovery / metadata skill registry}

    Attach a {!Skill_registry.t} for discovery and metadata export only.
    Skills in the registry are surfaced via {!Agent.card} (Agent Card)
    for A2A negotiation, capability queries, and skill inventory.

    {b Does NOT affect runtime prompt composition.}  The registry
    contents are never injected into the agent's system prompt.  To make
    a skill influence LLM behavior, use {!with_skill} / {!with_skills}.

    An agent can use both paths simultaneously: registry skills for
    external discovery, and contract skills for prompt composition. *)
val with_skill_registry : Skill_registry.t -> t -> t

(** {2 Run lifecycle} *)

(** Set a callback invoked when a run finishes.  Receives [true] on
    success, [false] on error.  Intended for emitting eval metrics,
    flushing OTel spans, or other end-of-run side effects.
    @since 0.110.0 *)
val with_on_run_complete : (bool -> unit) -> t -> t

(** Attach an event-sourced journal for crash recovery and replay.
    @since 0.133.0 *)
val with_journal : Durable_event.journal -> t -> t

(** Attach a caller-owned turn-boundary checkpoint sink. The sink is stored
    on the built {!Agent.t}, not in {!Agent.options}, so existing callers that
    construct options records remain source-compatible.
    @since 0.193.9 *)
val with_checkpoint_sink : Agent.checkpoint_sink -> t -> t

(** Install an [on_run_complete] callback that persists the journal
    to [path] whenever the agent run finishes (success or failure).
    Equivalent to attaching a journal and then calling
    {!Agent.save_journal} in a callback, but bundled so consumers
    declare the intent in one line.

    If a journal is not explicitly attached, this builder also
    creates a fresh one so the dump is non-empty.
    @since 0.135.0 *)
val with_auto_dump_journal : path:string -> t -> t

(** {2 Build} *)

(** Build with provider-independent validation. Provider-specific wire
    combinations are validated at request construction, after the concrete
    provider/model catalog entry is known. *)
val build_safe : t -> (Agent.t, Error.sdk_error) result
