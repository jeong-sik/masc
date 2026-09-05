(** Runtime_agent_context — Shared config and agent assembly helpers.

    This module owns the shared [config] surface plus the pure/defaulted
    preparation logic used by both [build] and [resume_from_checkpoint].
    [Runtime_agent] remains the public facade for [build_safe] and
    [Agent.resume] calls. *)

type stop_reason =
  | Completed
  | Yielded_to_operation_queued of { turns_used : int }
    (* The autonomous lane's AGENT_CORE run stopped at a turn boundary because a
        durable Dashboard/connector operation is queued behind the Owner child.
       Progress is checkpointed and the keeper resumes on the next cycle — the
       same checkpoint disposition as a turn-limit observation, but a distinct
       reason so receipts do not conflate an on-demand yield with an AGENT_CORE loop
       observation. *)
  | Yielded_to_durable_stimulus of { turns_used : int }
    (* The current autonomous cycle completed at least one AGENT_CORE provider turn,
       then released its lane because another durable stimulus was queued
       behind the stimulus already leased by this cycle. *)
  | Yielded_after_repeated_tool_call of
      { turns_used : int
      ; tool_name : string
      ; repeated_count : int
      }
    (* The current run repeated the same tool input and observed the same
       result enough times to prove that the provider loop was not advancing.
       The exact post-tool checkpoint is retained for a later cycle. *)
  | Yielded_after_repeated_assistant_text of
      { turns_used : int
      ; repeated_count : int
      }
    (* The last [repeated_count] provider turns each emitted the same
       non-blank assistant text, so the model is restating the same plan
       without advancing even though its tool calls kept changing. The exact
       post-tool checkpoint is retained for a later cycle. *)
  | InputRequired of
      { turns_used : int
      ; request : Agent_core.Error.input_required
      }
    (* AGENT_CORE ended the current run with a typed elicitation request. The host
       must surface [request.question] and persist the checkpoint before
       returning control; this is neither a provider failure nor a completed
       model deliverable. *)

type config =
  { name : string
  ; provider_cfg : Llm_provider.Provider_config.t
  ; model_id : string
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
  ; stream_idle_timeout_s : float option
  ; first_event_timeout_s : float option
    (** Bound on the silent wait for the FIRST streaming provider event
        (TTFT/prefill). [stream_idle_timeout_s] arms only after that event;
        when [None], AGENT_CORE's resolver falls back to [body_timeout_s],
        then to [stream_idle_timeout_s] (RFC-AC-037). *)
  ; body_timeout_s : float option
    (** Total HTTP body-consumption ceiling for non-streaming AGENT_CORE completion
        paths. Streaming paths deliberately ignore this knob so active long
        streams are not killed by total duration; streaming liveness is
        owned by [stream_idle_timeout_s] plus attempt observation. Non-HTTP
        transports ignore it. *)
  ; max_tokens : int option
    (** Caller-level output-token override. [None] adds no override, so an
        explicit [provider_cfg.max_tokens] remains authoritative; when both are
        absent no [max_tokens] field is synthesized from a capability ceiling.
        [Some n] is an operator/profile override or a non-keeper caller's
        deliberate request budget. *)
  ; temperature : float option
  ; hooks : Agent_core.Hooks.hooks option
  ; tool_approval : Agent_core.Hooks.tool_approval_callback option
  ; event_bus : Agent_core.Event_bus.t option
  ; session_id : string option
  ; description : string option
    (** Human-facing label only. Logic must not parse it: the executing
        runtime's identity travels in {!field-runtime_id}
        (RFC-0371 B12 — this field used to smuggle
        ["runtime:<id>/runtime"] for a downstream re-parse). *)
  ; runtime_id : string option
    (** The executing runtime's id, typed. [None] for callers that are
        not dispatching on behalf of a configured runtime. *)
  ; initial_messages : Agent_core.Types.message list
  ; model_input_projection : Agent_core.Agent.model_input_projection option
    (** Caller-owned projection applied only to provider-bound messages.
        Agent state and checkpoints retain their canonical persisted form. *)
  ; serialization_executor : Agent_core.Agent.serialization_executor option
    (** Runs each provider request's body serialisation. MASC hands the domain
        pool so the keeper's fiber scheduler is not held for that walk. *)
  ; pre_dispatch_serialization_observer :
      Agent_core.Agent.pre_dispatch_serialization_observer option
    (** Caller-owned observer for the exact serialized request body, invoked by
        AGENT_CORE after every stream-field injection and after the serialized-body
        admission check. This is the only place MASC can read the byte quantity
        the provider actually admits against [max_request_body_bytes]:
        the canonical checkpoint's bytes measure
        [{system_prompt, messages}] and exclude tool schemas, and a failed
        request is the only path that reports a size today. The observation is
        diagnostic and non-authoritative — AGENT_CORE reports a rejection or a raised
        callback as typed failure evidence without rewriting the result. *)
  ; raw_trace : Agent_core.Raw_trace.t option
  ; trace_link : (string * string) option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; transport : Masc_grpc_transport.t
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; max_tool_rounds : int option
    (** Ceiling on tool-continuation rounds in one AGENT_CORE run. [None] leaves
        the loop unbounded, which is what it was: a turn ended by exhausting
        wall clock or context rather than by any declared bound. Measured
        2026-08-24 over 4,416 keeper turns: p50 0 rounds, p90 6, p99 56, max
        279. *)
  ; context_injector : Agent_core.Hooks.context_injector option
  ; context : Agent_core.Context.t option
  ; thinking_budget : int option
    (** Token budget for extended thinking, forwarded to AGENT_CORE
        [Builder.with_thinking_budget]. Only meaningful when
        [enable_thinking = Some true]. *)
  ; top_p : float option
    (** Nucleus sampling probability forwarded to AGENT_CORE [Builder.with_top_p].
        [None] leaves the provider/model default intact. *)
  ; top_k : int option
    (** Top-k sampling limit forwarded to AGENT_CORE [Builder.with_top_k].
        [None] leaves the provider/model default intact. *)
  ; min_p : float option
    (** Minimum probability threshold for nucleus sampling, forwarded
        to AGENT_CORE [Builder.with_min_p]. [None] leaves the provider default;
        [Some 0.0] is a no-op and some providers reject the field. *)
  ; on_run_complete : (bool -> unit) option
    (** Callback invoked when an AGENT_CORE run finishes (success or failure).
        Forwarded to [Builder.with_on_run_complete]. Useful for emitting
        telemetry, flushing OTel spans, or finalizing receipts. *)
  ; checkpoint_sink : Agent_core.Agent.checkpoint_sink option
    (** Caller-owned turn-boundary checkpoint sink, forwarded to
        [Builder.with_checkpoint_sink]. Allows consumers to persist
        checkpoints at AGENT_CORE turn boundaries. *)
  }

let default_config
      ~name
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ~system_prompt
      ~tools
  : config
  =
  { name
  ; provider_cfg
  ; model_id = provider_cfg.model_id
  ; system_prompt
  ; tools
  ; stream_idle_timeout_s = None
  ; first_event_timeout_s = None
  ; body_timeout_s = None
  ; max_tokens = None
  ; temperature = provider_cfg.temperature
  ; hooks = None
  ; tool_approval = None
  ; event_bus = None
  ; session_id = None
  ; description = None
  ; runtime_id = None
  ; initial_messages = []
  ; model_input_projection = None
  ; pre_dispatch_serialization_observer = None
  ; serialization_executor = None
  ; raw_trace = None
  ; trace_link = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; transport = Masc_grpc_transport.from_env ()
  ; checkpoint_sidecar = None
  ; cache_system_prompt = false
  ; yield_on_tool = false
  ; max_tool_rounds = None
  ; context_injector = None
  ; context = None
  ; thinking_budget = None
  ; top_p = provider_cfg.top_p
  ; top_k = provider_cfg.top_k
  ; min_p = provider_cfg.min_p
  ; on_run_complete = None
  ; checkpoint_sink = None
  }
;;

let agent_core_tracer_ref = Atomic.make Agent_core.Tracing.null
let set_agent_core_tracer tracer = Atomic.set agent_core_tracer_ref tracer

let context_fit_admission (provider_config : Llm_provider.Provider_config.t) =
  if Llm_provider.Count_tokens_sync.supports_completion_request_measurement provider_config
  then Agent_core.Agent.Require_exact_fit
  else
    match Llm_provider.Provider_config.capabilities_for_config_model provider_config with
    | Some { Llm_provider.Capabilities.serving_constraint = Some _; _ } ->
      Agent_core.Agent.Require_exact_fit
    | Some _ | None -> Agent_core.Agent.Body_only
;;

let configured_or_inherited configured inherited =
  match configured with
  | Some _ as configured -> configured
  | None -> inherited
;;

(* Fresh Builder construction starts from [provider_cfg] and applies only
   explicit Runtime_agent overrides. Resume must use that same resolution:
   otherwise an absent caller override clears provider-owned request fields
   such as Anthropic's required [max_tokens] and changes admission semantics. *)
let agent_config_for_request (config : config) : Agent_core.Types.agent_config =
  let provider = config.provider_cfg in
  { (Agent_core.Types.default_config ~model:config.model_id) with
    name = config.name
  ; model = config.model_id
  ; system_prompt = Some config.system_prompt
  ; max_tokens = configured_or_inherited config.max_tokens provider.max_tokens
  ; temperature =
      configured_or_inherited config.temperature provider.temperature
  ; top_p = configured_or_inherited config.top_p provider.top_p
  ; top_k = configured_or_inherited config.top_k provider.top_k
  ; min_p = configured_or_inherited config.min_p provider.min_p
  ; enable_thinking =
      configured_or_inherited config.enable_thinking provider.enable_thinking
  ; preserve_thinking =
      configured_or_inherited
        config.preserve_thinking
        provider.preserve_thinking
  ; response_format = provider.response_format
  ; thinking_budget =
      configured_or_inherited config.thinking_budget provider.thinking_budget
  ; reasoning_effort = provider.reasoning_effort
  ; tool_choice = provider.tool_choice
  ; disable_parallel_tool_use = provider.disable_parallel_tool_use
  ; cache_system_prompt =
      config.cache_system_prompt || provider.cache_system_prompt
  ; initial_messages = config.initial_messages
  ; yield_on_tool = config.yield_on_tool
  ; max_tool_rounds = config.max_tool_rounds
  }
;;

let builder
      ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
      ~(config : config)
      ?transport
      ()
  : Agent_core.Builder.t
  =
  let builder =
    Agent_core.Builder.create ~net ~model:config.model_id
    |> Agent_core.Builder.with_provider_config config.provider_cfg
    |> Agent_core.Builder.with_name config.name
    |> Agent_core.Builder.with_system_prompt config.system_prompt
    |> Agent_core.Builder.with_tools config.tools
    |> Agent_core.Builder.with_context_fit_admission
         (context_fit_admission config.provider_cfg)
  in
  let builder =
    match config.temperature with
    | Some temperature -> Agent_core.Builder.with_temperature temperature builder
    | None -> builder
  in
  let builder =
    (* masc#24067 / agent-core boundary: [None] means the request carries no
       [max_tokens] field at all — [Builder.with_max_tokens] is simply not
       called, rather than filling in a synthesized default. *)
    match config.max_tokens with
    | Some max_tokens -> Agent_core.Builder.with_max_tokens max_tokens builder
    | None -> builder
  in
  let builder =
    match config.stream_idle_timeout_s with
    | Some timeout_s -> Agent_core.Builder.with_stream_idle_timeout timeout_s builder
    | None -> builder
  in
  let builder =
    match config.first_event_timeout_s with
    | Some s -> Agent_core.Builder.with_first_event_timeout s builder
    | None -> builder
  in
  let builder =
    match config.body_timeout_s with
    | Some s -> Agent_core.Builder.with_body_timeout s builder
    | None -> builder
  in
  let builder =
    match config.hooks with
    | Some h -> Agent_core.Builder.with_hooks h builder
    | None -> builder
  in
  let builder =
    match config.description with
    | Some d -> Agent_core.Builder.with_description d builder
    | None -> builder
  in
  let builder =
    match config.raw_trace with
    | Some raw_trace -> Agent_core.Builder.with_raw_trace raw_trace builder
    | None -> builder
  in
  let builder =
    match config.enable_thinking with
    | Some enabled -> Agent_core.Builder.with_enable_thinking enabled builder
    | None -> builder
  in
  let builder =
    match config.preserve_thinking with
    | Some preserve -> Agent_core.Builder.with_preserve_thinking preserve builder
    | None -> builder
  in
  let builder =
    if config.cache_system_prompt
    then Agent_core.Builder.with_cache_system_prompt true builder
    else builder
  in
  let builder =
    if config.yield_on_tool
    then Agent_core.Builder.with_yield_on_tool true builder
    else builder
  in
  let builder =
    match config.max_tool_rounds with
    | Some rounds -> Agent_core.Builder.with_max_tool_rounds rounds builder
    | None -> builder
  in
  let builder =
    if config.initial_messages <> []
    then Agent_core.Builder.with_initial_messages config.initial_messages builder
    else builder
  in
  let builder =
    match config.model_input_projection with
    | Some project -> Agent_core.Builder.with_model_input_projection project builder
    | None -> builder
  in
  let builder =
    match config.pre_dispatch_serialization_observer with
    | Some observe ->
      Agent_core.Builder.with_pre_dispatch_serialization_observer observe builder
    | None -> builder
  in
  let builder =
    match config.serialization_executor with
    | Some executor -> Agent_core.Builder.with_serialization_executor executor builder
    | None -> builder
  in
  let builder =
    match config.context_injector with
    | Some injector -> Agent_core.Builder.with_context_injector injector builder
    | None -> builder
  in
  let builder =
    match config.context with
    | Some ctx -> Agent_core.Builder.with_context ctx builder
    | None -> builder
  in
  let builder =
    match config.thinking_budget with
    | Some budget -> Agent_core.Builder.with_thinking_budget budget builder
    | None -> builder
  in
  let builder =
    match config.top_p with
    | Some top_p -> Agent_core.Builder.with_top_p top_p builder
    | None -> builder
  in
  let builder =
    match config.top_k with
    | Some top_k -> Agent_core.Builder.with_top_k top_k builder
    | None -> builder
  in
  let builder =
    match config.min_p with
    | Some min_p -> Agent_core.Builder.with_min_p min_p builder
    | None -> builder
  in
  let builder =
    match config.event_bus with
    | Some bus -> Agent_core.Builder.with_event_bus bus builder
    | None -> builder
  in
  let builder =
    match config.on_run_complete with
    | Some cb -> Agent_core.Builder.with_on_run_complete cb builder
    | None -> builder
  in
  let builder =
    match config.checkpoint_sink with
    | Some sink -> Agent_core.Builder.with_checkpoint_sink sink builder
    | None -> builder
  in
  let builder =
    Agent_core.Builder.with_tracer (Atomic.get agent_core_tracer_ref) builder
  in
  match transport with
  | Some transport -> Agent_core.Builder.with_transport transport builder
  | None -> builder
;;

type prepared_resume =
  { patched_checkpoint : Agent_core.Checkpoint.t
  ; agent_config : Agent_core.Types.agent_config
  ; options : Agent_core.Agent.options
  ; context_fit_admission : Agent_core.Agent.context_fit_admission
  }

let prepare_resume ~(config : config) ~(checkpoint : Agent_core.Checkpoint.t)
  : prepared_resume
  =
  let agent_config = agent_config_for_request config in
  let patched_checkpoint =
    { checkpoint with
      Agent_core.Checkpoint.model = config.model_id
    ; system_prompt = agent_config.system_prompt
    ; tool_choice = agent_config.tool_choice
    ; disable_parallel_tool_use = agent_config.disable_parallel_tool_use
    ; temperature = agent_config.temperature
    ; top_p = agent_config.top_p
    ; top_k = agent_config.top_k
    ; min_p = agent_config.min_p
    ; reasoning_effort = agent_config.reasoning_effort
    ; enable_thinking = agent_config.enable_thinking
    ; preserve_thinking = agent_config.preserve_thinking
    ; thinking_budget = agent_config.thinking_budget
    ; cache_system_prompt = agent_config.cache_system_prompt
    ; response_format = agent_config.response_format
    }
  in
  let options : Agent_core.Agent.options =
    { Agent_core.Agent.default_options with
      hooks = (match config.hooks with Some hooks -> hooks | None -> Agent_core.Hooks.empty)
    ; provider_config = Some config.provider_cfg
    ; stream_idle_timeout_s = config.stream_idle_timeout_s
    ; first_event_timeout_s = config.first_event_timeout_s
    ; body_timeout_s = config.body_timeout_s
    ; context_injector = config.context_injector
    ; tool_approval = config.tool_approval
    ; event_bus = config.event_bus
    ; raw_trace = config.raw_trace
    ; description = config.description
    ; on_run_complete = config.on_run_complete
    }
  in
  { patched_checkpoint
  ; agent_config
  ; options
  ; context_fit_admission = context_fit_admission config.provider_cfg
  }
;;
