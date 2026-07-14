(** Runtime_agent_context — Shared config and agent assembly helpers.

    This module owns the shared [config] surface plus the pure/defaulted
    preparation logic used by both [build] and [resume_from_checkpoint].
    [Runtime_agent] remains the public facade for [build_safe] and
    [Agent.resume] calls. *)

type stop_reason =
  | Completed
  | TurnLimitObserved of
      { turns_used : int
      ; limit : int
      }
  | ExecutionTimeoutObserved of
      { elapsed_sec : float
      ; timeout_sec : float
      ; turn_count : int
      ; max_turns : int
      }
  | ExecutionIdleTimeoutObserved of
      { idle_sec : float
      ; idle_timeout_sec : float
      ; turn_count : int
      ; max_turns : int
      }
  | Yielded_to_chat_waiting of { turns_used : int }
    (* The autonomous lane's OAS run stopped at a turn boundary because a
       dashboard/connector chat request was parked on the keeper's turn slot.
       Progress is checkpointed and the keeper resumes on the next cycle — the
       same checkpoint disposition as a turn-limit observation, but a distinct
       reason so receipts do not conflate an on-demand yield with an OAS loop
       observation. *)
  | Yielded_to_durable_stimulus of { turns_used : int }
    (* The current autonomous cycle completed at least one OAS provider turn,
       then released its lane because another durable stimulus was queued
       behind the stimulus already leased by this cycle. *)
  | InputRequired of
      { turns_used : int
      ; request : Agent_sdk.Error.input_required
      }
    (* OAS ended the current run with a typed elicitation request. The host
       must surface [request.question] and persist the checkpoint before
       returning control; this is neither a provider failure nor a completed
       model deliverable. *)

type config =
  { name : string
  ; provider_cfg : Llm_provider.Provider_config.t
  ; model_id : string
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; stream_idle_timeout_s : float option
  ; body_timeout_s : float option
    (** Total HTTP body-consumption ceiling for non-streaming OAS completion
        paths. Streaming paths deliberately ignore this knob so active long
        streams are not killed by total duration; streaming liveness is
        owned by [stream_idle_timeout_s] plus attempt observation. Non-HTTP
        transports ignore it. *)
  ; max_tokens : int option
    (** Request-time output token budget. [None] means no [max_tokens] field
        goes on the request at all — the keeper lane's default (masc#24067 /
        oas#2517): the OAS capability catalog ceiling is a validation bound,
        never a synthesized request value. [Some n] is an explicit
        operator/profile override or a non-keeper caller's deliberate
        request budget. *)
  ; temperature : float option
  ; hooks : Agent_sdk.Hooks.hooks option
  ; event_bus : Agent_sdk.Event_bus.t option
  ; session_id : string option
  ; description : string option
  ; initial_messages : Agent_sdk.Types.message list
  ; model_input_projection :
      (Agent_sdk.Types.message list -> Agent_sdk.Types.message list) option
    (** Caller-owned projection applied only to provider-bound messages.
        Agent state and checkpoints retain their canonical persisted form. *)
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; trace_link : (string * string) option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; transport : Masc_grpc_transport.t
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; thinking_budget : int option
    (** Token budget for extended thinking, forwarded to OAS
        [Builder.with_thinking_budget]. Only meaningful when
        [enable_thinking = Some true]. *)
  ; top_p : float option
    (** Nucleus sampling probability forwarded to OAS [Builder.with_top_p].
        [None] leaves the provider/model default intact. *)
  ; top_k : int option
    (** Top-k sampling limit forwarded to OAS [Builder.with_top_k].
        [None] leaves the provider/model default intact. *)
  ; min_p : float option
    (** Minimum probability threshold for nucleus sampling, forwarded
        to OAS [Builder.with_min_p]. [None] leaves the provider default;
        [Some 0.0] is a no-op and some providers reject the field. *)
  ; on_run_complete : (bool -> unit) option
    (** Callback invoked when an OAS run finishes (success or failure).
        Forwarded to [Builder.with_on_run_complete]. Useful for emitting
        telemetry, flushing OTel spans, or finalizing receipts. *)
  ; checkpoint_sink : Agent_sdk.Agent.checkpoint_sink option
    (** Caller-owned turn-boundary checkpoint sink, forwarded to
        [Builder.with_checkpoint_sink]. Allows consumers to persist
        checkpoints at OAS turn boundaries. *)
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
  ; body_timeout_s = None
  ; max_tokens = None
  ; temperature = provider_cfg.temperature
  ; hooks = None
  ; event_bus = None
  ; session_id = None
  ; description = None
  ; initial_messages = []
  ; model_input_projection = None
  ; raw_trace = None
  ; trace_link = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; transport = Masc_grpc_transport.from_env ()
  ; checkpoint_sidecar = None
  ; cache_system_prompt = false
  ; yield_on_tool = false
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

let oas_tracer_ref = Atomic.make Agent_sdk.Tracing.null
let set_oas_tracer tracer = Atomic.set oas_tracer_ref tracer

let builder
      ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
      ~(config : config)
      ?transport
      ()
  : Agent_sdk.Builder.t
  =
  let builder =
    Agent_sdk.Builder.create ~net ~model:config.model_id
    |> Agent_sdk.Builder.with_provider_config config.provider_cfg
    |> Agent_sdk.Builder.with_name config.name
    |> Agent_sdk.Builder.with_system_prompt config.system_prompt
    |> Agent_sdk.Builder.with_tools config.tools
  in
  let builder =
    match config.temperature with
    | Some temperature -> Agent_sdk.Builder.with_temperature temperature builder
    | None -> builder
  in
  let builder =
    (* masc#24067 / oas#2517: [None] means the request carries no
       [max_tokens] field at all — [Builder.with_max_tokens] is simply not
       called, rather than filling in a synthesized default. *)
    match config.max_tokens with
    | Some max_tokens -> Agent_sdk.Builder.with_max_tokens max_tokens builder
    | None -> builder
  in
  let builder =
    match config.stream_idle_timeout_s with
    | Some timeout_s -> Agent_sdk.Builder.with_stream_idle_timeout timeout_s builder
    | None -> builder
  in
  let builder =
    match config.body_timeout_s with
    | Some s -> Agent_sdk.Builder.with_body_timeout s builder
    | None -> builder
  in
  let builder =
    match config.hooks with
    | Some h -> Agent_sdk.Builder.with_hooks h builder
    | None -> builder
  in
  let builder =
    match config.description with
    | Some d -> Agent_sdk.Builder.with_description d builder
    | None -> builder
  in
  let builder =
    match config.raw_trace with
    | Some raw_trace -> Agent_sdk.Builder.with_raw_trace raw_trace builder
    | None -> builder
  in
  let builder =
    match config.enable_thinking with
    | Some enabled -> Agent_sdk.Builder.with_enable_thinking enabled builder
    | None -> builder
  in
  let builder =
    match config.preserve_thinking with
    | Some preserve -> Agent_sdk.Builder.with_preserve_thinking preserve builder
    | None -> builder
  in
  let builder =
    if config.cache_system_prompt
    then Agent_sdk.Builder.with_cache_system_prompt true builder
    else builder
  in
  let builder =
    if config.yield_on_tool
    then Agent_sdk.Builder.with_yield_on_tool true builder
    else builder
  in
  let builder =
    if config.initial_messages <> []
    then Agent_sdk.Builder.with_initial_messages config.initial_messages builder
    else builder
  in
  let builder =
    match config.context_injector with
    | Some injector -> Agent_sdk.Builder.with_context_injector injector builder
    | None -> builder
  in
  let builder =
    match config.context with
    | Some ctx -> Agent_sdk.Builder.with_context ctx builder
    | None -> builder
  in
  let builder =
    match config.thinking_budget with
    | Some budget -> Agent_sdk.Builder.with_thinking_budget budget builder
    | None -> builder
  in
  let builder =
    match config.top_p with
    | Some top_p -> Agent_sdk.Builder.with_top_p top_p builder
    | None -> builder
  in
  let builder =
    match config.top_k with
    | Some top_k -> Agent_sdk.Builder.with_top_k top_k builder
    | None -> builder
  in
  let builder =
    match config.min_p with
    | Some min_p -> Agent_sdk.Builder.with_min_p min_p builder
    | None -> builder
  in
  let builder =
    match config.event_bus with
    | Some bus -> Agent_sdk.Builder.with_event_bus bus builder
    | None -> builder
  in
  let builder =
    match config.on_run_complete with
    | Some cb -> Agent_sdk.Builder.with_on_run_complete cb builder
    | None -> builder
  in
  let builder =
    match config.checkpoint_sink with
    | Some sink -> Agent_sdk.Builder.with_checkpoint_sink sink builder
    | None -> builder
  in
  let builder =
    Agent_sdk.Builder.with_tracer (Atomic.get oas_tracer_ref) builder
  in
  match transport with
  | Some transport -> Agent_sdk.Builder.with_transport transport builder
  | None -> builder
;;

type prepared_resume =
  { patched_checkpoint : Agent_sdk.Checkpoint.t
  ; agent_config : Agent_sdk.Types.agent_config
  ; options : Agent_sdk.Agent.options
  }

let prepare_resume ~(config : config) ~(checkpoint : Agent_sdk.Checkpoint.t)
  : prepared_resume
  =

  let patched_checkpoint =
    { checkpoint with
      Agent_sdk.Checkpoint.model = config.model_id
    ; system_prompt = Some config.system_prompt
    ; temperature = config.temperature
    ; top_p = config.top_p
    ; top_k = config.top_k
    ; min_p = config.min_p
    ; enable_thinking = config.enable_thinking
    ; preserve_thinking = config.preserve_thinking
    ; thinking_budget = config.thinking_budget
    ; cache_system_prompt = config.cache_system_prompt
    ; response_format = config.provider_cfg.response_format
    }
  in
  let agent_config : Agent_sdk.Types.agent_config =
    { (Agent_sdk.Types.default_config ~model:config.model_id) with
      name = config.name
    ; model = config.model_id
    ; system_prompt = Some config.system_prompt
    ; max_tokens = config.max_tokens
    ; temperature = config.temperature
    ; top_p = config.top_p
    ; top_k = config.top_k
    ; min_p = config.min_p
    ; enable_thinking = config.enable_thinking
    ; preserve_thinking = config.preserve_thinking
    ; thinking_budget = config.thinking_budget
    ; cache_system_prompt = config.cache_system_prompt
    ; yield_on_tool = config.yield_on_tool
    }
  in
  let options : Agent_sdk.Agent.options =
    { Agent_sdk.Agent.default_options with
      hooks = Option.value ~default:Agent_sdk.Hooks.empty config.hooks
    ; stream_idle_timeout_s = config.stream_idle_timeout_s
    ; body_timeout_s = config.body_timeout_s
    ; context_injector = config.context_injector
    ; event_bus = config.event_bus
    ; raw_trace = config.raw_trace
    ; description = config.description
    ; on_run_complete = config.on_run_complete
    }
  in
  { patched_checkpoint; agent_config; options }
;;
