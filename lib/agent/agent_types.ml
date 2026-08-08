open Types

let _log = Log.create ~module_name:"agent_types" ()

type periodic_callback =
  { interval_sec : float
  ; callback : unit -> unit
  }

type checkpoint_stage =
  | After_assistant_collected
  | After_tool_results_appended
  | After_context_injection

let checkpoint_stage_to_string = function
  | After_assistant_collected -> "after_assistant_collected"
  | After_tool_results_appended -> "after_tool_results_appended"
  | After_context_injection -> "after_context_injection"
;;

type checkpoint_snapshot =
  { stage : checkpoint_stage
  ; turn : int
  ; checkpoint : Checkpoint.t
  ; timestamp : float
  }

type checkpoint_sink = checkpoint_snapshot -> (unit, string) result

type context_fit_admission =
  | Disabled
  | Enforce_when_supported

type model_input_projection = message list -> (message list, string) result
type pre_dispatch_serialization_observer = Llm_provider.Request_wire_observer.try_observe

type options =
  { provider_config : Llm_provider.Provider_config.t option
  ; stream_idle_timeout_s : float option
  ; first_event_timeout_s : float option
    (** RFC-OAS-037: separate bound for the time-to-first-event (TTFT /
        prefill) wait, distinct from [stream_idle_timeout_s] which bounds
        inter-token idle only AFTER the first event. When [None] the
        first-event wait is not bounded by the short idle value; when unset it
        falls back to [body_timeout_s], then to [stream_idle_timeout_s], and a
        slow silent prefill is guarded by inter-token idle once the stream
        produces. *)
  ; body_timeout_s : float option
  ; hooks : Hooks.hooks
  ; guardrails_async : Guardrails_async.t
  ; tracer : Tracing.t
  ; trace_link : (string * string) option
    (** Optional (trace_id, span_id) of a parent span to link to.
        Used to connect OAS agent turns to an external trace root. *)
  ; raw_trace : Raw_trace.t option
  ; context_injector : Hooks.context_injector option
  ; mcp_clients : Mcp.managed list
  ; event_bus : Event_bus.t option
  ; skill_registry : Skill_registry.t option
  ; elicitation : Hooks.elicitation_callback option
  ; tool_approval : Hooks.tool_approval_callback option
  ; description : string option
  ; periodic_callbacks : periodic_callback list
  ; slot_id : int option
  ; on_run_complete : (bool -> unit) option
    (** Optional callback invoked when a run finishes.  Receives [true]
        on success, [false] on error.  Runs before lifecycle state is
        updated.  Intended for emitting eval metrics, flushing OTel
        spans, or other end-of-run side effects.  The callback must
        not raise; exceptions are caught and logged. *)
  ; journal : Durable_event.journal option
    (** Optional event-sourced journal for crash recovery and replay.
        When provided, lifecycle events are appended alongside
        [Event_bus] publishes, enabling offline replay via
        {!Durable_event.replay_summary}.
        @since 0.133.0 *)
  ; transport : Llm_provider.Llm_transport.t option
    (** Optional non-HTTP transport override.  Required for CLI provider
        kinds ([Claude_code], [Codex], [Gemini], [Kimi]) which cannot be
        reached over HTTP.  When [Some t], {!Pipeline.stage_route}
        dispatches via {!Llm_provider.Complete.complete} with this
        transport; when [None], the HTTP path is used.
        @since 0.156.0 *)
  }

(* Re-export lifecycle types from Agent_lifecycle.
   Type equations make these structurally identical so existing code
   using Agent.Accepted, Agent.lifecycle_snapshot, etc. still works. *)
type lifecycle_status = Agent_lifecycle.lifecycle_status =
  | Accepted
  | Ready
  | Running
  | Completed
  | Failed
[@@deriving show, yojson]

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
[@@deriving yojson]

let default_options =
  { provider_config = None
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
  ; event_bus = None
  ; skill_registry = None
  ; elicitation = None
  ; tool_approval = None
  ; description = None
  ; periodic_callbacks = []
  ; slot_id = None
  ; on_run_complete = None
  ; journal = None
  ; transport = None
  }
;;

type t =
  { mu : Eio.Mutex.t
  ; mutable state : agent_state
  ; mutable lifecycle : lifecycle_snapshot option
  ; tools : Tool_set.t
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; context : Context.t
  ; options : options
  ; context_fit_admission : context_fit_admission
  ; model_input_projection : model_input_projection option
  ; pre_dispatch_serialization_observer : pre_dispatch_serialization_observer option
  ; checkpoint_sink : checkpoint_sink option
  }

(* Public accessors — .mli exposes Agent.t as abstract *)
let state t = t.state
let lifecycle t = t.lifecycle
let tools t = t.tools
let context t = t.context
let options t = t.options
let provider_config t = t.options.provider_config
let net t = t.net

(** Mutex-protected write to [state].  All mutations of [t.state] should
    go through this function to prevent lost-update races when parallel
    tool-execution fibers or periodic callbacks yield between read and
    write. *)
let set_state t s = Eio.Mutex.use_rw ~protect:true t.mu (fun () -> t.state <- s)

(** Read-modify-write [state] under the mutex.  Callers pass a pure
    function [f : agent_state -> agent_state]; the read + write happen
    inside a single critical section so no concurrent update is lost. *)
let update_state t f =
  Eio.Mutex.use_rw ~protect:true t.mu (fun () -> t.state <- f t.state)
;;

let description t = t.options.description
let sdk_version = Sdk_version.version

let typed_provider_name (cfg : Llm_provider.Provider_config.t) =
  Provider_runtime_binding.provider_id_of_provider_config cfg
;;

let card ~supported_interfaces t =
  let supported_providers =
    match t.options.provider_config with
    | Some config -> [ typed_provider_name config ]
    | None -> []
  in
  let skills =
    match t.options.skill_registry with
    | Some reg ->
      List.map
        (fun (s : Skill.t) -> { Agent_card.name = s.name; description = s.description })
        (Skill_registry.list reg)
    | None -> []
  in
  Agent_card.of_info
    { agent_name = t.state.config.name
    ; agent_description = t.options.description
    ; version = sdk_version
    ; config = t.state.config
    ; tool_schemas =
        List.map (fun (tool : Tool.t) -> tool.schema) (Tool_set.to_list t.tools)
    ; supported_providers
    ; mcp_clients_count = List.length t.options.mcp_clients
    ; has_elicitation =
        Option.is_some t.options.elicitation || Option.is_some t.options.tool_approval
    ; skills
    ; supported_interfaces
    }
;;

(** Mutex-protected lifecycle update.  Multiple parallel tool-execution
    fibers call this concurrently via [on_tool_execution_started] /
    [on_tool_execution_finished] callbacks.  Without the mutex the
    read of [agent.lifecycle] (for [?previous]) and the subsequent
    write could interleave, losing an update.

    Validates the transition against {!Agent_lifecycle.valid_transitions}.
    Invalid transitions are rejected: the state is not updated and a
    structured error record is logged. *)
let set_lifecycle
      agent
      ?current_run_id
      ?worker_id
      ?runtime_actor
      ?last_error
      ?accepted_at
      ?ready_at
      ?first_progress_at
      ?started_at
      ?last_progress_at
      ?finished_at
      status
  =
  Eio.Mutex.use_rw ~protect:true agent.mu (fun () ->
    let allowed =
      match agent.lifecycle with
      | Some prev ->
        (match Agent_lifecycle.transition ~from:prev.status ~to_:status with
         | Error e ->
           Log.error
             _log
             "invalid lifecycle transition"
             [ Log.S ("agent", agent.state.config.name)
             ; Log.S ("error", Agent_lifecycle.transition_error_to_string e)
             ];
           false
         | Ok _ -> true)
      | None -> true
    in
    if allowed
    then
      agent.lifecycle
      <- Some
           (Agent_lifecycle.build_snapshot
              ~agent_name:agent.state.config.name
              ~model:agent.state.config.model
              ?provider_config:agent.options.provider_config
              ?previous:agent.lifecycle
              ?current_run_id
              ?worker_id
              ?runtime_actor
              ?last_error
              ?accepted_at
              ?ready_at
              ?first_progress_at
              ?started_at
              ?last_progress_at
              ?finished_at
              status))
;;

let create
      ~net
      ~config
      ?(tools = [])
      ?context
      ?(options = default_options)
      ?(context_fit_admission = Disabled)
      ?model_input_projection
      ?pre_dispatch_serialization_observer
      ?checkpoint_sink
      ()
  =
  let mcp_tools =
    List.concat_map (fun (m : Mcp.managed) -> m.tools) options.mcp_clients
  in
  let all_tools = Tool_set.merge (Tool_set.of_list tools) (Tool_set.of_list mcp_tools) in
  let state =
    { config; messages = config.initial_messages; turn_count = 0; usage = empty_usage }
  in
  let ctx =
    match context with
    | Some c -> c
    | None -> Context.create ()
  in
  { mu = Eio.Mutex.create ()
  ; state
  ; lifecycle = None
  ; tools = all_tools
  ; net
  ; context = ctx
  ; options
  ; context_fit_admission
  ; model_input_projection
  ; pre_dispatch_serialization_observer
  ; checkpoint_sink
  }
;;

let clone ?(copy_context = false) agent =
  let ctx = if copy_context then Context.copy agent.context else Context.create () in
  let state =
    { config = agent.state.config
    ; messages = agent.state.messages
    ; turn_count = agent.state.turn_count
    ; usage = agent.state.usage
    }
  in
  { mu = Eio.Mutex.create ()
  ; state
  ; lifecycle = agent.lifecycle
  ; tools = agent.tools
  ; net = agent.net
  ; context = ctx
  ; options = agent.options
  ; context_fit_admission = agent.context_fit_admission
  ; model_input_projection = agent.model_input_projection
  ; pre_dispatch_serialization_observer = agent.pre_dispatch_serialization_observer
  ; checkpoint_sink = agent.checkpoint_sink
  }
;;

let last_raw_trace_run agent =
  match agent.options.raw_trace with
  | Some sink -> Raw_trace.last_run sink
  | None -> None
;;

let lifecycle_snapshot agent = agent.lifecycle
let close agent = Mcp.close_all agent.options.mcp_clients
