(** Builder pattern for Agent creation.
    Provides a flat, chainable API as an alternative to nested Agent.create params. *)

open Types

let _log = Log.create ~module_name:"builder" ()

type t =
  { net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; model : model
  ; name : string
  ; system_prompt : string option
  ; max_tokens : int option
  ; temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; response_format : response_format
  ; thinking_budget : int option
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  ; tool_choice : tool_choice option
  ; disable_parallel_tool_use : bool
  ; cache_system_prompt : bool
  ; cache_extended_ttl : bool
  ; initial_messages : message list
  ; tools : Tool_set.t
  ; context : Context.t option
  ; provider_config : Llm_provider.Provider_config.t option
  ; context_fit_admission : Agent.context_fit_admission
  ; model_input_projection : Agent.model_input_projection option
  ; pre_dispatch_serialization_observer : Agent.pre_dispatch_serialization_observer option
  ; stream_idle_timeout_s : float option
  ; first_event_timeout_s : float option
  ; body_timeout_s : float option
  ; hooks : Hooks.hooks
  ; guardrails_async : Guardrails_async.t
  ; tracer : Tracing.t
  ; trace_link : (string * string) option
  ; raw_trace : Raw_trace.t option
  ; context_injector : Hooks.context_injector option
  ; mcp_clients : Mcp.managed list
  ; event_bus : Event_bus.t option
  ; skill_registry : Skill_registry.t option
  ; elicitation : Hooks.elicitation_callback option
  ; tool_approval : Hooks.tool_approval_callback option
  ; description : string option
  ; periodic_callbacks : Agent.periodic_callback list
  ; contract : Contract.t
  ; yield_on_tool : bool
  ; slot_id : int option
  ; on_run_complete : (bool -> unit) option
  ; journal : Durable_event.journal option
  ; checkpoint_sink : Agent.checkpoint_sink option
  ; transport : Llm_provider.Llm_transport.t option
  }

let create ~net ~model =
  let defaults = default_config ~model in
  { net
  ; model
  ; name = defaults.name
  ; system_prompt = defaults.system_prompt
  ; max_tokens = defaults.max_tokens
  ; temperature = defaults.temperature
  ; top_p = defaults.top_p
  ; top_k = defaults.top_k
  ; min_p = defaults.min_p
  ; enable_thinking = defaults.enable_thinking
  ; preserve_thinking = defaults.preserve_thinking
  ; response_format = defaults.response_format
  ; thinking_budget = defaults.thinking_budget
  ; reasoning_effort = defaults.reasoning_effort
  ; tool_choice = defaults.tool_choice
  ; disable_parallel_tool_use = defaults.disable_parallel_tool_use
  ; cache_system_prompt = defaults.cache_system_prompt
  ; cache_extended_ttl = defaults.cache_extended_ttl
  ; initial_messages = defaults.initial_messages
  ; tools = Tool_set.empty
  ; context = None
  ; provider_config = None
  ; context_fit_admission = Agent.Disabled
  ; model_input_projection = None
  ; pre_dispatch_serialization_observer = None
  ; stream_idle_timeout_s = None
  ; first_event_timeout_s = None
  ; body_timeout_s = None
  ; hooks = Hooks.empty
  ; guardrails_async = Guardrails_async.empty
  ; tracer = Tracing.null
  ; trace_link = None
  ; raw_trace = None
  ; context_injector = None
  ; mcp_clients = []
  ; (* Observability-as-default: every Builder-constructed agent gets a fresh,
       per-agent event bus so Turn/Tool/InferenceTelemetry events are emitted
       without the caller opting in. [create] is a per-call function, so this
       allocates a NEW bus per builder — not a shared global mutable bus (which
       remains forbidden; [Agent_types.default_options.event_bus] stays [None]).
       With no subscriber, [Event_bus.publish] is a no-op (it iterates an empty
       subscriber list), so the default carries only a mutex acquire per event.
       Callers that want zero emission use {!without_event_bus}. *)
    event_bus = Some (Event_bus.create ())
  ; skill_registry = None
  ; elicitation = None
  ; tool_approval = None
  ; description = None
  ; periodic_callbacks = []
  ; contract = Contract.empty
  ; yield_on_tool = false
  ; slot_id = None
  ; on_run_complete = None
  ; journal = None
  ; checkpoint_sink = None
  ; transport = None
  }
;;

let with_journal journal b = { b with journal = Some journal }

let with_checkpoint_sink checkpoint_sink b =
  { b with checkpoint_sink = Some checkpoint_sink }
;;

let with_transport transport b = { b with transport = Some transport }

let with_auto_dump_journal ~path b =
  let journal =
    match b.journal with
    | Some j -> j
    | None -> Durable_event.create ()
  in
  let dump _ok =
    match Durable_event.save_to_file journal path with
    | Ok () -> ()
    | Error err ->
      (* Best-effort diagnostic: consumers that need hard guarantees should
         provide their own [on_run_complete] callback. *)
      Log.warn
        _log
        "auto_dump_journal save failed"
        [ Log.S ("path", path); Log.S ("error", err) ]
  in
  { b with journal = Some journal; on_run_complete = Some dump }
;;

let with_system_prompt prompt b = { b with system_prompt = Some prompt }
let with_name name b = { b with name }
let with_max_tokens n b = { b with max_tokens = Some n }
let with_temperature t b = { b with temperature = Some t }
let with_top_p p b = { b with top_p = Some p }
let with_top_k k b = { b with top_k = Some k }
let with_min_p p b = { b with min_p = Some p }
let with_enable_thinking enabled b = { b with enable_thinking = Some enabled }
let with_preserve_thinking preserve b = { b with preserve_thinking = Some preserve }
let with_tools tools b = { b with tools = Tool_set.of_list tools }
let with_tool tool b = { b with tools = Tool_set.merge b.tools (Tool_set.singleton tool) }
let with_hooks hooks b = { b with hooks }
let with_tracer tracer b = { b with tracer }
let with_trace_link trace_link b = { b with trace_link }
let with_raw_trace raw_trace b = { b with raw_trace = Some raw_trace }
let with_context ctx b = { b with context = Some ctx }

let with_provider_config (pc : Llm_provider.Provider_config.t) b =
  { b with
    model = pc.model_id
  ; system_prompt = pc.system_prompt
  ; max_tokens = pc.max_tokens
  ; temperature = pc.temperature
  ; top_p = pc.top_p
  ; top_k = pc.top_k
  ; min_p = pc.min_p
  ; enable_thinking = pc.enable_thinking
  ; preserve_thinking = pc.preserve_thinking
  ; response_format = pc.response_format
  ; thinking_budget = pc.thinking_budget
  ; reasoning_effort = pc.reasoning_effort
  ; tool_choice = pc.tool_choice
  ; disable_parallel_tool_use = pc.disable_parallel_tool_use
  ; cache_system_prompt = pc.cache_system_prompt
  ; provider_config = Some pc
  }
;;

let with_context_fit_admission context_fit_admission b = { b with context_fit_admission }

let with_model_input_projection model_input_projection b =
  { b with model_input_projection = Some model_input_projection }
;;

let with_pre_dispatch_serialization_observer observer b =
  { b with pre_dispatch_serialization_observer = Some observer }
;;

let with_mcp_clients clients b = { b with mcp_clients = clients }
let with_guardrails_async guardrails_async b = { b with guardrails_async }
let with_slot_id slot_id b = { b with slot_id = Some slot_id }
let with_on_run_complete cb b = { b with on_run_complete = Some cb }
let with_contract contract b = { b with contract = Contract.merge b.contract contract }
let with_skill skill b = with_contract (Contract.with_skill skill Contract.empty) b
let with_skills skills b = with_contract (Contract.with_skills skills Contract.empty) b
let with_tool_choice tc b = { b with tool_choice = Some tc }
let with_response_format response_format b = { b with response_format }
let with_disable_parallel_tool_use v b = { b with disable_parallel_tool_use = v }
let with_thinking_budget n b = { b with thinking_budget = Some n }
let with_reasoning_effort effort b = { b with reasoning_effort = Some effort }
let with_initial_messages msgs b = { b with initial_messages = msgs }
let with_cache_system_prompt v b = { b with cache_system_prompt = v }
let with_cache_extended_ttl v b = { b with cache_extended_ttl = v }
let with_yield_on_tool v b = { b with yield_on_tool = v }
let with_event_bus bus b = { b with event_bus = Some bus }
let without_event_bus b = { b with event_bus = None }
let with_stream_idle_timeout s b = { b with stream_idle_timeout_s = Some s }
let with_first_event_timeout s b = { b with first_event_timeout_s = Some s }
let with_body_timeout s b = { b with body_timeout_s = Some s }
let with_context_injector injector b = { b with context_injector = Some injector }
let with_skill_registry reg b = { b with skill_registry = Some reg }
let with_elicitation cb b = { b with elicitation = Some cb }
let with_tool_approval cb b = { b with tool_approval = Some cb }
let with_description desc b = { b with description = Some desc }

let with_periodic_callback cb b =
  { b with periodic_callbacks = b.periodic_callbacks @ [ cb ] }
;;

let with_periodic_callbacks cbs b =
  { b with periodic_callbacks = b.periodic_callbacks @ cbs }
;;

let with_log_level level _b =
  Log.set_global_level level;
  _b
;;

let with_log_sink sink _b =
  Log.add_sink sink;
  _b
;;

let build b =
  let tools = b.tools in
  let mcp_clients = b.mcp_clients in
  let context = Contract.context_with_contract ?context:b.context b.contract in
  let config =
    { name = b.name
    ; model = b.model
    ; system_prompt = Contract.compose_system_prompt ?base:b.system_prompt b.contract
    ; max_tokens = b.max_tokens
    ; temperature = b.temperature
    ; top_p = b.top_p
    ; top_k = b.top_k
    ; min_p = b.min_p
    ; enable_thinking = b.enable_thinking
    ; preserve_thinking = b.preserve_thinking
    ; response_format = b.response_format
    ; thinking_budget = b.thinking_budget
    ; reasoning_effort = b.reasoning_effort
    ; tool_choice = b.tool_choice
    ; disable_parallel_tool_use = b.disable_parallel_tool_use
    ; cache_system_prompt = b.cache_system_prompt
    ; cache_extended_ttl = b.cache_extended_ttl
    ; initial_messages = b.initial_messages
    ; yield_on_tool = b.yield_on_tool
    }
  in
  let options =
    { Agent_types.provider_config = b.provider_config
    ; stream_idle_timeout_s = b.stream_idle_timeout_s
    ; first_event_timeout_s = b.first_event_timeout_s
    ; body_timeout_s = b.body_timeout_s
    ; hooks = b.hooks
    ; guardrails_async = b.guardrails_async
    ; tracer = b.tracer
    ; trace_link = b.trace_link
    ; raw_trace = b.raw_trace
    ; context_injector = b.context_injector
    ; mcp_clients
    ; event_bus = b.event_bus
    ; skill_registry = b.skill_registry
    ; elicitation = b.elicitation
    ; tool_approval = b.tool_approval
    ; description = b.description
    ; periodic_callbacks = b.periodic_callbacks
    ; slot_id = b.slot_id
    ; on_run_complete = b.on_run_complete
    ; journal = b.journal
    ; transport = b.transport
    }
  in
  Agent.create
    ~net:b.net
    ~config
    ~tools:(Tool_set.to_list tools)
    ?context
    ~options
    ~context_fit_admission:b.context_fit_admission
    ?model_input_projection:b.model_input_projection
    ?pre_dispatch_serialization_observer:b.pre_dispatch_serialization_observer
    ?checkpoint_sink:b.checkpoint_sink
    ()
;;

let build_safe b =
  match b.max_tokens with
  | Some n when n <= 0 ->
    Error
      (Error.Config
         (Error.InvalidConfig
            { field = "max_tokens"; detail = Printf.sprintf "must be > 0, got %d" n }))
  | _ -> Ok (build b)
;;
