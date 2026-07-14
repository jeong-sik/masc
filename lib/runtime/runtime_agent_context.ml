(** Runtime_agent_context — shared MASC-owned assembly for OAS agents. *)

type stop_reason =
  | Completed
  | Yielded_to_chat_waiting of { turns_used : int }
  | Yielded_to_durable_stimulus of { turns_used : int }
  | InputRequired of
      { turns_used : int
      ; request : Agent_sdk.Error.input_required
      }

type config =
  { name : string
  ; provider_cfg : Llm_provider.Provider_config.t
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; stream_idle_timeout_s : float option
  ; body_timeout_s : float option
  ; hooks : Agent_sdk.Hooks.hooks option
  ; event_bus : Agent_sdk.Event_bus.t option
  ; session_id : string option
  ; description : string option
  ; initial_messages : Agent_sdk.Types.message list
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; trace_link : (string * string) option
  ; transport : Masc_grpc_transport.t
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; yield_on_tool : bool
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; on_run_complete : (bool -> unit) option
  ; checkpoint_sink : Agent_sdk.Agent.checkpoint_sink option
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
  ; system_prompt
  ; tools
  ; stream_idle_timeout_s = None
  ; body_timeout_s = None
  ; hooks = None
  ; event_bus = None
  ; session_id = None
  ; description = None
  ; initial_messages = []
  ; raw_trace = None
  ; trace_link = None
  ; transport = Masc_grpc_transport.from_env ()
  ; checkpoint_sidecar = None
  ; yield_on_tool = false
  ; context_injector = None
  ; context = None
  ; on_run_complete = None
  ; checkpoint_sink = None
  }
;;

let oas_tracer_ref = Atomic.make Agent_sdk.Tracing.null
let set_oas_tracer tracer = Atomic.set oas_tracer_ref tracer

let apply_optional value apply builder =
  match value with
  | Some value -> apply value builder
  | None -> builder
;;

let builder
      ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
      ~(config : config)
      ?transport
      ()
  : Agent_sdk.Builder.t
  =
  let builder =
    Agent_sdk.Builder.create ~net ~model:config.provider_cfg.model_id
    |> Agent_sdk.Builder.with_provider_config config.provider_cfg
    |> Agent_sdk.Builder.with_name config.name
    |> Agent_sdk.Builder.with_system_prompt config.system_prompt
    |> Agent_sdk.Builder.with_tools config.tools
  in
  let builder =
    apply_optional
      config.stream_idle_timeout_s
      Agent_sdk.Builder.with_stream_idle_timeout
      builder
  in
  let builder = apply_optional config.body_timeout_s Agent_sdk.Builder.with_body_timeout builder in
  let builder = apply_optional config.hooks Agent_sdk.Builder.with_hooks builder in
  let builder = apply_optional config.description Agent_sdk.Builder.with_description builder in
  let builder = apply_optional config.raw_trace Agent_sdk.Builder.with_raw_trace builder in
  let builder = apply_optional config.trace_link Agent_sdk.Builder.with_trace_link builder in
  let builder =
    if config.yield_on_tool
    then Agent_sdk.Builder.with_yield_on_tool true builder
    else builder
  in
  let builder =
    if config.initial_messages = []
    then builder
    else Agent_sdk.Builder.with_initial_messages config.initial_messages builder
  in
  let builder =
    apply_optional config.context_injector Agent_sdk.Builder.with_context_injector builder
  in
  let builder = apply_optional config.context Agent_sdk.Builder.with_context builder in
  let builder = apply_optional config.event_bus Agent_sdk.Builder.with_event_bus builder in
  let builder =
    apply_optional
      config.on_run_complete
      Agent_sdk.Builder.with_on_run_complete
      builder
  in
  let builder =
    apply_optional config.checkpoint_sink Agent_sdk.Builder.with_checkpoint_sink builder
  in
  let builder = Agent_sdk.Builder.with_tracer (Atomic.get oas_tracer_ref) builder in
  match transport with
  | Some transport -> Agent_sdk.Builder.with_transport transport builder
  | None -> builder
;;

type prepared_resume =
  { options : Agent_sdk.Agent.options }

let prepare_resume ~(config : config) ~(checkpoint : Agent_sdk.Checkpoint.t)
  : (prepared_resume, Agent_sdk.Error.sdk_error) result
  =
  if not (String.equal checkpoint.model config.provider_cfg.model_id)
  then
    Error
      (Agent_sdk.Error.Config
         (Agent_sdk.Error.InvalidConfig
            { field = "checkpoint.model"
            ; detail =
                Printf.sprintf
                  "checkpoint model %S does not match selected provider model %S"
                  checkpoint.model
                  config.provider_cfg.model_id
            }))
  else
    let options : Agent_sdk.Agent.options =
      { Agent_sdk.Agent.default_options with
        stream_idle_timeout_s = config.stream_idle_timeout_s
      ; body_timeout_s = config.body_timeout_s
      ; hooks = Option.value ~default:Agent_sdk.Hooks.empty config.hooks
      ; tracer = Atomic.get oas_tracer_ref
      ; trace_link = config.trace_link
      ; raw_trace = config.raw_trace
      ; context_injector = config.context_injector
      ; event_bus = config.event_bus
      ; description = config.description
      ; on_run_complete = config.on_run_complete
      }
    in
    Ok { options }
;;
