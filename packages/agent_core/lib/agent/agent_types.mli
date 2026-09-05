(** Core types for the Agent module.

    [Agent_types.t] exposes record fields for library-internal code.
    External consumers should use the abstract [Agent.t] and its
    accessor functions instead.

    @stability Internal
    @since 0.93.1 *)

(** {1 Configuration} *)

type periodic_callback =
  { interval_sec : float
  ; callback : unit -> unit
  }

type checkpoint_stage =
  | After_assistant_collected
  | After_tool_results_appended
  | After_context_injection
  | After_rejected_response_dropped
  (** Written by the caller, not the pipeline: the checkpoint that stood after
      the assistant's response was collected, with that response removed
      because accept refused it. Same turn count as the one it replaces. *)

val checkpoint_stage_to_string : checkpoint_stage -> string

type checkpoint_snapshot =
  { stage : checkpoint_stage
  ; turn : int
  ; checkpoint : Checkpoint.t
  ; timestamp : float
  }

type checkpoint_sink = checkpoint_snapshot -> (unit, string) result

type context_fit_admission =
  | Body_only
  | Require_exact_fit

(** Caller-owned provider-message projection. [Error e] aborts the turn before
    request measurement or dispatch; canonical Agent state is unchanged. The
    error is the caller's own typed fact, not a rendered string: a projection
    that refuses because this candidate's declared ceiling cannot carry the
    turn says so with [Error.Api (ContextOverflow _)], which the lane loop
    already rotates on. *)
type model_input_projection = Types.message list -> (Types.message list, Error.t) result

type pre_dispatch_serialization_observer = Llm_provider.Request_wire_observer.try_observe

(** Runs the serialisation of an admitted provider body, the walk over every
    message in the request. The closure reads immutable request values and
    returns a value. A caller whose scheduler must stay responsive supplies
    one that runs it on another domain; [None] runs it inline. *)
type serialization_executor = { run : 'a. (unit -> 'a) -> 'a }

type options =
  { provider_config : Llm_provider.Provider_config.t option
  ; stream_idle_timeout_s : float option
    (** Inter-line idle deadline applied to streaming HTTP responses.
        Threaded through {!Pipeline.stage_route} into
        {!Llm_provider.Complete.complete_stream}, which forwards it to
        {!Llm_provider.Http_client.read_ndjson} (Ollama native NDJSON)
        and {!Llm_provider.Http_client.read_sse} (Anthropic / Openai-
        compatible / Gemini / Glm). The deadline resets after each
        successful line, so this caps inter-chunk silence — not total
        stream duration. A stalled endpoint surfaces as
        [TimeoutError { phase = Stream_idle state; _ }], preserving
        whether the stream was waiting for answer/thinking/tool-call
        progress. CLI transports honour the parallel
        [stdout_idle_timeout_s] knob via the transport's own config.
        @since 0.176.0 *)
  ; first_event_timeout_s : float option
    (** Agent Core contract: dedicated bound for the time-to-first-event
        (TTFT / prefill) wait, distinct from [stream_idle_timeout_s].
        While the stream is still awaiting its first event this bounds
        the wait; [stream_idle_timeout_s] arms only AFTER the first event
        (inter-token idle). A silent prefill on a large context is a
        slow-but-alive stream, not a hang, so it must not be cut by the
        short inter-token idle value. When [None] the first-event wait falls
        back to [body_timeout_s], then to [stream_idle_timeout_s], and stays
        unarmed only when none of the three is set; inter-token idle still
        guards once the stream produces, and [connect_timeout_s] still guards
        connection setup. @since 0.218.0 *)
  ; body_timeout_s : float option
    (** Per-call total deadline applied to non-streaming HTTP response body
        consumption. Threaded through {!Pipeline.stage_route} into both the
        provider-native input-count preflight, when enabled, and
        {!Llm_provider.Complete.complete}. Each round-trip owns a separate
        deadline; the value is not a combined turn deadline.
        Requires [clock] to be supplied; without a clock the wrapper is
        skipped. A timeout surfaces as
        [TimeoutError] and is returned unchanged after that provider attempt.
        On the streaming path this field is the fallback bound for the
        first-event (TTFT/prefill) wait when [first_event_timeout_s] is
        [None] — inter-token liveness after the first event is still governed
        by [stream_idle_timeout_s], and only the optional non-streaming count
        preflight uses this deadline directly.
        @since 0.181.0 *)
  ; hooks : Hooks.hooks
  ; guardrails_async : Guardrails_async.t
  ; tracer : Tracing.t
  ; trace_link : (string * string) option
  ; raw_trace : Raw_trace.t option
  ; context_injector : Hooks.context_injector option
  ; mcp_clients : Mcp.managed list
  ; event_bus : Event_bus.t option
  ; skill_registry : Skill_registry.t option
    (** Discovery/metadata path only.  Surfaced via {!Agent.card} for
          A2A negotiation.  Does not affect runtime prompt composition. *)
  ; elicitation : Hooks.elicitation_callback option
  ; tool_approval : Hooks.tool_approval_callback option
    (** Closed synchronous exact-tool approval callback. *)
  ; description : string option
  ; periodic_callbacks : periodic_callback list
  ; slot_id : int option
    (** Pin LLM requests to a specific llama-server slot for KV cache reuse.
        When [Some n], adds ["id_slot": n] to OpenAI-compat request body.
        @since 0.109.0 *)
  ; on_run_complete : (bool -> unit) option
    (** Optional callback invoked when a run finishes.  Receives [true]
        on success, [false] on error.  Runs before lifecycle state is
        updated.  Intended for emitting eval metrics, flushing OTel
        spans, or other end-of-run side effects.
        @since 0.110.0 *)
  ; journal : Durable_event.journal option
    (** Optional event-sourced journal for crash recovery and replay.
        When provided, lifecycle events are appended alongside
        [Event_bus] publishes, enabling offline replay via
        {!Durable_event.replay_summary}.
        @since 0.133.0 *)
  ; transport : Llm_provider.Llm_transport.t option
    (** Optional non-HTTP transport override.  Required for CLI provider
        kinds ([Claude_code], [Codex], [Gemini], [Kimi])
        which cannot be reached over HTTP.  When [Some t], {!Pipeline.stage_route}
        dispatches via {!Llm_provider.Complete.complete} with this
        transport; when [None], the HTTP path is used.
        @since 0.156.0 *)
  }

(** {1 Lifecycle re-exports} *)

type lifecycle_status = Agent_lifecycle.lifecycle_status =
  | Accepted
  | Ready
  | Running
  | Completed
  | Failed
[@@deriving show]

type lifecycle_snapshot = Agent_lifecycle.lifecycle_snapshot =
  { current_run_id : string option
  ; agent_name : string
  ; worker_id : string option
  ; runtime_actor : string option
  ; status : lifecycle_status
  ; requested_provider : string option
  ; requested_model : string option
  ; resolved_provider : string option
  ; resolved_model : string option
  ; last_error : string option
  ; accepted_at : float option
  ; ready_at : float option
  ; first_progress_at : float option
  ; started_at : float option
  ; last_progress_at : float option
  ; finished_at : float option
  }

(** {1 Agent state} *)

(** Mutable agent record — library-internal only.
    External code must use [Agent.t] (abstract) and its accessors.

    All mutable fields are protected by [mu].  Use [set_state],
    [update_state], [set_lifecycle], etc. rather than direct assignment
    to prevent lost-update races from parallel tool-execution fibers or
    periodic callbacks. *)
type t =
  { mu : Eio.Mutex.t
  ; mutable state : Types.agent_state
  ; mutable lifecycle : lifecycle_snapshot option
  ; mutable tools : Tool_set.t
      (** Widened during a turn by {!extend_tools} and never narrowed. *)
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; context : Context.t
  ; options : options
  ; context_fit_admission : context_fit_admission
  ; model_input_projection : model_input_projection option
  ; pre_dispatch_serialization_observer : pre_dispatch_serialization_observer option
  ; serialization_executor : serialization_executor option
  ; checkpoint_sink : checkpoint_sink option
  }

(** {1 Defaults} *)

val default_options : options

(** {1 Accessors} *)

val state : t -> Types.agent_state
val lifecycle : t -> lifecycle_snapshot option
val tools : t -> Tool_set.t

val extend_tools : t -> Tool.t list -> unit
(** Widen the callable tool set mid-turn, under the same mutex as [state].
    Widening only, and a name already held is ignored — see [Agent.extend_tools]
    for why neither is a restriction that can be relaxed. *)
val context : t -> Context.t
val options : t -> options
val provider_config : t -> Llm_provider.Provider_config.t option
val net : t -> [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
val set_state : t -> Types.agent_state -> unit
val update_state : t -> (Types.agent_state -> Types.agent_state) -> unit
val description : t -> string option

(** {1 Agent-core version} *)

val agent_core_version : string

(** {1 Construction} *)

val create
  :  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> config:Types.agent_config
  -> ?tools:Tool.t list
  -> ?context:Context.t
  -> ?options:options
  -> ?context_fit_admission:context_fit_admission
  -> ?model_input_projection:model_input_projection
  -> ?pre_dispatch_serialization_observer:pre_dispatch_serialization_observer
  -> ?serialization_executor:serialization_executor
  -> ?checkpoint_sink:checkpoint_sink
  -> unit
  -> t

val clone : ?copy_context:bool -> t -> t

(** {1 Agent card} *)

val card
  :  supported_interfaces:Agent_card.supported_interfaces
  -> t
  -> Agent_card.agent_card

(** {1 Lifecycle management} *)

val set_lifecycle
  :  t
  -> ?current_run_id:string
  -> ?worker_id:string
  -> ?runtime_actor:string
  -> ?last_error:string
  -> ?accepted_at:float
  -> ?ready_at:float
  -> ?first_progress_at:float
  -> ?started_at:float
  -> ?last_progress_at:float
  -> ?finished_at:float
  -> Agent_lifecycle.lifecycle_status
  -> unit

(** {1 Trace / Checkpoint} *)

val last_raw_trace_run : t -> Raw_trace.run_ref option
val lifecycle_snapshot : t -> lifecycle_snapshot option
val close : t -> unit
