(** Oas_worker_exec — Config, build, and run for OAS agent execution.

    Contains the [config] type, [build], [run], and [run_with_masc_tools]
    functions. All model-selection and cascade logic lives in
    {!Oas_worker_cascade} and {!Oas_worker_named}.

    @since God file decomposition — extracted from oas_worker.ml *)

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type config = {
  name : string;
  provider : Oas.Provider.config;
  model_id : string;
  priority : Llm_provider.Request_priority.t option;
  system_prompt : string;
  tools : Oas.Tool.t list;
  max_turns : int;
  max_idle_turns : int;
  max_tokens : int;
  max_input_tokens : int option;
  max_cost_usd : float option;
  temperature : float;
  hooks : Oas.Hooks.hooks option;
  context_reducer : Oas.Context_reducer.t option;
  guardrails : Oas.Guardrails.t option;
  event_bus : Oas.Event_bus.t option;
  checkpoint_dir : string option;
  session_id : string option;
  description : string option;
  memory : Oas.Memory.t option;
  named_cascade : Oas.Api.named_cascade option;
  initial_messages : Oas.Types.message list;
  raw_trace : Oas.Raw_trace.t option;
  tool_retry_policy : Oas.Tool_retry_policy.t option;
  contract : Oas.Risk_contract.t option;
  enable_thinking : bool option;
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  compact_ratio : float option;
  context_injector : Oas.Hooks.context_injector option;
  context : Oas.Context.t option;
  slot_id : int option;
  approval : Oas.Hooks.approval_callback option;
  exit_condition : (int -> bool) option;
}

let default_config ~name ~provider ~model_id ~system_prompt ~tools : config =
  { name; provider; model_id; priority = None; system_prompt; tools;
    max_turns = 20;
    max_idle_turns = 3;
    max_tokens = Oas_worker_cascade.default_max_tokens;
    max_input_tokens = None;
    max_cost_usd = None;
    temperature = Oas_worker_cascade.default_temperature;
    hooks = None;
    context_reducer = None;
    guardrails = None;
    event_bus = None;
    checkpoint_dir = None;
    session_id = None;
    description = None;
    memory = None;
    named_cascade = None;
    initial_messages = [];
    raw_trace = None;
    tool_retry_policy = None;
    contract = None;
    enable_thinking = None;
    transport = Masc_grpc_transport.from_env ();
    allowed_paths = [];
    checkpoint_sidecar = None;
    cache_system_prompt = false;
    yield_on_tool = false;
    compact_ratio = None;
    context_injector = None;
    context = None;
    slot_id = None;
    approval = None;
    exit_condition = None;
  }

(* ================================================================ *)
(* Result type                                                       *)
(* ================================================================ *)

type stop_reason =
  | Completed
  | TurnBudgetExhausted of { turns_used : int; limit : int }

type run_result = {
  response : Oas.Types.api_response;
  checkpoint : Oas.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Oas.Raw_trace.run_ref option;
  proof : Oas.Cdal_proof.t option;
  cascade_observation : Oas_worker_cascade.cascade_observation option;
  stop_reason : stop_reason;
}

let lowercase_enum_case_name raw =
  let raw =
    match String.rindex_opt raw '.' with
    | Some idx when idx + 1 < String.length raw ->
        String.sub raw (idx + 1) (String.length raw - idx - 1)
    | _ -> raw
  in
  String.lowercase_ascii raw

let proof_result_status_to_string status =
  Oas.Cdal_proof.show_result_status status |> lowercase_enum_case_name

(* ================================================================ *)
(* Internal: resolve provider                                        *)
(* ================================================================ *)

(** Resolve a model label string to an OAS Provider.config.
    Uses OAS Cascade_config.parse_model_string (Provider_registry SSOT).
    Falls back to default local provider when parsing fails. *)
let resolve_provider_of_label (label : string) : Oas.Provider.config =
  match Llm_provider.Cascade_config.parse_model_string label with
  | Some pc -> Oas.Provider.config_of_provider_config pc
  | None ->
    let fallback = Provider_adapter.default_local_fallback_label () in
    match Llm_provider.Cascade_config.parse_model_string fallback with
    | Some pc -> Oas.Provider.config_of_provider_config pc
    | None ->
      (* Failsafe: direct Provider_config construction — cascade bypass.
         This is the last-resort path when BOTH the requested label AND the
         default fallback label fail Cascade_config parsing.  That happens
         only when no cascade TOML/env is configured at all, which is a
         valid startup state for fresh installs.  Raw infrastructure values
         (endpoint, request_path) are passed to OAS, which owns them.
         Ollama rejects literal "auto" — must resolve to a concrete ID. *)
      let model_id =
        match Llm_provider.Discovery.first_discovered_model_id () with
        | Some id -> id
        | None ->
          Sys.getenv_opt "OLLAMA_DEFAULT_MODEL"
          |> Option.value ~default:"auto"
      in
      Oas.Provider.config_of_provider_config
        (Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~model_id
           ~base_url:(Llm_provider.Provider_registry.next_llama_endpoint ())
           ~request_path:"/v1/chat/completions" ())

(* ================================================================ *)
(* Internal: event publishing                                        *)
(* ================================================================ *)

let publish_lifecycle bus ~name ~event ~detail =
  Oas.Event_bus.publish bus
    (Oas.Event_bus.Custom
      (Printf.sprintf "masc:oas_worker:%s" event,
       `Assoc [
         ("agent", `String name);
         ("detail", `String detail);
         ("timestamp", `Float (Time_compat.now ()));
       ]))

(* ================================================================ *)
(* Internal: checkpoint persistence                                  *)
(* ================================================================ *)

let persist_checkpoint ~dir ~session_id (ckpt : Oas.Checkpoint.t) =
  let path = Filename.concat dir (session_id ^ ".json") in
  Fs_compat.mkdir_p dir;
  Fs_compat.save_file path (Oas.Checkpoint.to_string ckpt)

let build_checkpoint ~session_id ?checkpoint_sidecar (agent : Oas.Agent.t) =
  match checkpoint_sidecar with
  | None -> Oas.Agent.checkpoint ~session_id agent
  | Some json ->
      Oas.Agent_checkpoint.build_checkpoint
        ~session_id ~working_context:json
        ~state:(Oas.Agent.state agent)
        ~tools:(Oas.Agent.tools agent)
        ~context:(Oas.Agent.context agent)
        ~mcp_clients:(Oas.Agent.options agent).mcp_clients
        ()

(* ================================================================ *)
(* Build                                                             *)
(* ================================================================ *)

let build
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
  : (Oas.Agent.t, Oas.Error.sdk_error) result =
  let tool_names =
    List.map (fun (t : Oas.Tool.t) -> t.schema.name) config.tools in
  let guardrails = match config.guardrails with
    | Some g -> g
    | None ->
      { Oas.Guardrails.default with
        tool_filter =
          if tool_names <> [] then Oas.Guardrails.AllowList tool_names
          else Oas.Guardrails.AllowAll }
  in
  let builder =
    Oas.Builder.create ~net ~model:config.model_id
    |> Oas.Builder.with_name config.name
    |> Oas.Builder.with_system_prompt config.system_prompt
    |> Oas.Builder.with_max_tokens config.max_tokens
    |> Oas.Builder.with_max_turns config.max_turns
    |> Oas.Builder.with_max_idle_turns config.max_idle_turns
    |> Oas.Builder.with_temperature config.temperature
    |> Oas.Builder.with_provider config.provider
    |> Oas.Builder.with_tools config.tools
    |> Oas.Builder.with_guardrails guardrails
  in
  let builder =
    if config.tools <> [] then
      Oas.Builder.with_tool_choice Oas.Types.Auto builder
    else builder
  in
  let builder = match config.hooks with
    | Some h -> Oas.Builder.with_hooks h builder
    | None -> builder
  in
  let builder = match config.context_reducer with
    | Some r -> Oas.Builder.with_context_reducer r builder
    | None -> builder
  in
  let builder = match config.description with
    | Some d -> Oas.Builder.with_description d builder
    | None -> builder
  in
  let builder = match config.memory with
    | Some m -> Oas.Builder.with_memory m builder
    | None -> builder
  in
  let builder = match config.raw_trace with
    | Some raw_trace -> Oas.Builder.with_raw_trace raw_trace builder
    | None -> builder
  in
  let builder = match config.tool_retry_policy with
    | Some policy -> Oas.Builder.with_tool_retry_policy policy builder
    | None -> builder
  in
  let builder = match config.named_cascade with
    | Some nc -> Oas.Builder.with_named_cascade nc builder
    | None -> builder
  in
  let builder = match config.enable_thinking with
    | Some enabled -> Oas.Builder.with_enable_thinking enabled builder
    | None -> builder
  in
  let builder =
    match config.priority with
    | Some priority -> Oas.Builder.with_priority priority builder
    | None -> builder
  in
  let builder =
    match config.max_cost_usd with
    | Some usd -> Oas.Builder.with_max_cost_usd usd builder
    | None -> builder
  in
  let builder =
    match config.max_input_tokens with
    | Some tokens -> Oas.Builder.with_max_input_tokens tokens builder
    | None -> builder
  in
  let builder =
    if config.cache_system_prompt then
      Oas.Builder.with_cache_system_prompt true builder
    else builder
  in
  let builder =
    if config.yield_on_tool then
      Oas.Builder.with_yield_on_tool true builder
    else builder
  in
  let builder =
    if config.allowed_paths <> [] then
      Oas.Builder.with_allowed_paths config.allowed_paths builder
    else builder
  in
  let builder =
    if config.initial_messages <> [] then
      Oas.Builder.with_initial_messages config.initial_messages builder
    else builder
  in
  let builder =
    match config.compact_ratio with
    | Some ratio ->
      Oas.Builder.with_context_thresholds ~compact_ratio:ratio builder
    | None -> builder
  in
  let builder = match config.context_injector with
    | Some injector -> Oas.Builder.with_context_injector injector builder
    | None -> builder
  in
  let builder = match config.context with
    | Some ctx -> Oas.Builder.with_context ctx builder
    | None -> builder
  in
  let builder = match config.slot_id with
    | Some id -> Oas.Builder.with_slot_id id builder
    | None -> builder
  in
  let builder = match config.approval with
    | Some cb -> Oas.Builder.with_approval cb builder
    | None -> builder
  in
  let builder = match config.exit_condition with
    | Some cond -> Oas.Builder.with_exit_condition cond builder
    | None -> builder
  in
  Oas.Builder.build_safe builder

(* ================================================================ *)
(* Idle-detail enrichment                                           *)
(* ================================================================ *)

(** Enrich an [Oas.Error.to_string] detail with the name of the most
    recently called tool when the error is an "Idle detected" failure.
    For all other error strings the input is returned unchanged.

    Exposed at module level so it can be unit-tested independently of
    the network-bound [run] function. *)
let enrich_idle_detail (detail : string) (messages : Oas.Types.message list) : string =
  if String.starts_with ~prefix:"Idle detected" detail then
    let last_tool =
      let rec find = function
        | [] -> None
        | (m : Oas.Types.message) :: rest ->
          let later = find rest in
          if Option.is_some later then later
          else if m.role = Oas.Types.Assistant then
            List.find_map (function
              | Oas.Types.ToolUse { name; _ } -> Some name
              | _ -> None
            ) m.content
          else None
      in
      find messages
    in
    (match last_tool with
     | Some name -> Printf.sprintf "%s (tool: %s)" detail name
     | None -> detail)
  else detail

(* ================================================================ *)
(* Resume from checkpoint                                            *)
(* ================================================================ *)

(** Build an Agent.t from a checkpoint via [Agent.resume], overriding
    per-turn config values from the MASC config.

    The checkpoint provides: messages, turn_count, usage_stats.
    The MASC config provides: provider, model_id, system_prompt,
    max_turns, temperature, tools, hooks, guardrails, etc.

    [max_turns] and [max_cost_usd] are adjusted to account for
    cumulative values in the checkpoint — the keeper's per-call budget
    is added on top of the checkpoint's accumulated state.

    @boundary-contract
    - MASC owns: per-turn config selection (model, temperature, tools,
      system_prompt), per-turn budget allocation, checkpoint field patching
      to align MASC intent with OAS resume semantics.
    - OAS owns: cumulative token/cost accounting, turn_count tracking,
      Agent.resume state restoration, loop guard enforcement.
    - Neither may: MASC must not set [max_total_tokens] (OAS SSOT for
      cumulative budgets); OAS must not override MASC model/temperature
      selection after resume. *)
let resume_from_checkpoint
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(checkpoint : Oas.Checkpoint.t)
  : Oas.Agent.t =
  (* Adjust budgets: max_turns and max_cost_usd are per-call, but
     Agent.resume restores turn_count/usage from checkpoint. Without
     adjustment the loop guard fires immediately on resumed agents. *)
  let effective_max_turns = checkpoint.turn_count + config.max_turns in
  let effective_max_cost_usd = match config.max_cost_usd with
    | Some budget ->
      Some (checkpoint.usage.estimated_cost_usd +. budget)
    | None -> None
  in
  (* Patch checkpoint fields that MASC controls per-turn.
     OAS build_resume copies checkpoint.model/system_prompt/temperature
     over the base config, so we align the checkpoint with MASC intent. *)
  let patched_checkpoint = { checkpoint with
    Oas.Checkpoint.model = config.model_id;
    system_prompt = Some config.system_prompt;
    temperature = Some config.temperature;
    enable_thinking = config.enable_thinking;
    cache_system_prompt = config.cache_system_prompt;
    max_input_tokens = config.max_input_tokens;
    max_total_tokens = None;  (* MASC does not manage cumulative token budgets — OAS SSOT *)
  } in
  let agent_config : Oas.Types.agent_config = {
    Oas.Types.default_config with
    name = config.name;
    model = config.model_id;
    system_prompt = Some config.system_prompt;
    max_tokens = config.max_tokens;
    max_turns = effective_max_turns;
    temperature = Some config.temperature;
    enable_thinking = config.enable_thinking;
    cache_system_prompt = config.cache_system_prompt;
    max_input_tokens = config.max_input_tokens;
    max_cost_usd = effective_max_cost_usd;
    yield_on_tool = config.yield_on_tool;
    context_compact_ratio = config.compact_ratio;
    priority = config.priority;
  } in
  let tool_names =
    List.map (fun (t : Oas.Tool.t) -> t.schema.name) config.tools in
  let guardrails = match config.guardrails with
    | Some g -> g
    | None ->
      { Oas.Guardrails.default with
        tool_filter =
          if tool_names <> [] then Oas.Guardrails.AllowList tool_names
          else Oas.Guardrails.AllowAll }
  in
  let options : Oas.Agent.options = {
    Oas.Agent.default_options with
    provider = Some config.provider;
    hooks = Option.value ~default:Oas.Hooks.empty config.hooks;
    max_idle_turns = config.max_idle_turns;
    guardrails;
    context_reducer = config.context_reducer;
    context_injector = config.context_injector;
    event_bus = config.event_bus;
    memory = config.memory;
    raw_trace = config.raw_trace;
    tool_retry_policy = config.tool_retry_policy;
    allowed_paths = config.allowed_paths;
    description = config.description;
  } in
  Oas.Agent.resume ~net ~checkpoint:patched_checkpoint ~tools:config.tools
    ?context:config.context ?named_cascade:config.named_cascade
    ~options ~config:agent_config ()

(* ================================================================ *)
(* Run                                                               *)
(* ================================================================ *)

let run
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ?oas_checkpoint
    ?(on_event : (Oas.Types.sse_event -> unit) option)
    ?(on_yield : (unit -> unit) option)
    ?(on_resume : (unit -> unit) option)
    ?(agent_ref : Oas.Agent.t option ref option)
    ?(proof_ref : Oas.Cdal_proof.t option ref option)
    ?(contract : Oas.Risk_contract.t option)
    (goal : string)
  : (run_result, Oas.Error.sdk_error) result =
  let session_id = match config.session_id with
    | Some id -> id
    | None ->
      Printf.sprintf "%s-%d-%06x"
        config.name
        (int_of_float (Time_compat.now () *. 1000.0))
        (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF)
  in
  (match config.transport with
  | Masc_grpc_transport.Local -> ()
  | t ->
    Log.Misc.info "oas_worker %s: transport=%s"
      config.name (Masc_grpc_transport.to_string t));
  Option.iter (fun bus ->
    publish_lifecycle bus ~name:config.name ~event:"build" ~detail:goal
  ) config.event_bus;
  let agent_result = match oas_checkpoint with
    | Some checkpoint ->
      (try Ok (resume_from_checkpoint ~net ~config ~checkpoint)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn "oas_worker %s: resume_from_checkpoint failed (%s), falling back to build"
           config.name (Printexc.to_string exn);
         build ~net ~config)
    | None -> build ~net ~config
  in
  match agent_result with
  | Error e ->
    Option.iter (fun bus ->
      publish_lifecycle bus ~name:config.name ~event:"build_error"
        ~detail:(Oas.Error.to_string e)
    ) config.event_bus;
    Error e
  | Ok agent ->
  (match agent_ref with Some r -> r := Some agent | None -> ());
  let effective_contract = match contract with Some c -> Some c | None -> config.contract in
  (try
    let result, proof = match effective_contract with
      | Some c ->
        let cr = Oas.Contract_runner.run ~sw ~contract:c agent goal in
        (cr.response, Some cr.proof)
      | None ->
        let r = match on_event with
          | Some cb -> Oas.Agent.run_stream ~sw ?on_yield ?on_resume ~on_event:cb agent goal
          | None -> Oas.Agent.run ~sw ?on_yield ?on_resume agent goal
        in
        (r, None)
    in
    (match proof_ref with Some ref_ -> ref_ := proof | None -> ());
    let checkpoint =
      let ckpt =
        build_checkpoint ~session_id
          ?checkpoint_sidecar:config.checkpoint_sidecar agent
      in
      (match config.checkpoint_dir with
       | Some dir ->
         (try persist_checkpoint ~dir ~session_id ckpt
          with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            Log.Misc.error "oas_worker: Checkpoint save failed: %s"
              (Printexc.to_string exn))
       | None -> ());
      Some ckpt
    in
    Option.iter (fun bus ->
      let status = match result with Ok _ -> "completed" | Error _ -> "failed" in
      publish_lifecycle bus ~name:config.name ~event:status
        ~detail:(Printf.sprintf "session=%s" session_id)
    ) config.event_bus;
    let turns = (Oas.Agent.state agent).turn_count in
    let trace_ref = Oas.Agent.last_raw_trace_run agent in
    Oas.Agent.close agent;
    (match result with
    | Ok response ->
      Ok
        {
          response;
          checkpoint;
          session_id;
          turns;
          trace_ref;
          proof;
          cascade_observation = None;
          stop_reason = Completed;
        }
    | Error (Oas.Error.Agent (Oas.Error.MaxTurnsExceeded r)) ->
      let partial_response : Oas.Types.api_response = {
        id = session_id; model = config.model_id;
        stop_reason = Oas.Types.EndTurn;
        content = [Oas.Types.Text (Printf.sprintf
          "[turn budget exhausted: %d/%d turns used]" r.turns r.limit)];
        usage = None;
        telemetry = None;
      } in
      Ok
        {
          response = partial_response;
          checkpoint;
          session_id;
          turns;
          trace_ref;
          proof;
          cascade_observation = None;
          stop_reason = TurnBudgetExhausted { turns_used = r.turns; limit = r.limit };
        }
    | Error err ->
      let detail = Oas.Error.to_string err in
      let detail =
        enrich_idle_detail detail (Oas.Agent.state agent).messages
      in
      (match proof with
       | Some p ->
         Log.Misc.warn "oas_worker: agent errored with CDAL proof: run_id=%s status=%s error=%s"
           p.run_id
           (proof_result_status_to_string p.result_status)
           detail
       | None ->
         Log.Misc.warn "oas_worker: agent errored (no proof): %s" detail);
      Error err)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let bt = Printexc.get_backtrace () in
    (try Oas.Agent.close agent with close_exn ->
      Log.Misc.warn "agent close failed during cleanup: %s" (Printexc.to_string close_exn));
    Log.Misc.error "oas_worker %s: execution exception: %s\nBacktrace: %s"
      config.name (Printexc.to_string exn) bt;
    Error (Oas.Error.Internal (Printf.sprintf "execution exception: %s" (Printexc.to_string exn))))

(* ================================================================ *)
(* Convenience: run_with_masc_tools                                  *)
(* ================================================================ *)

let run_with_masc_tools
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?contract
    ?on_event
    ?on_yield
    ?on_resume
    (goal : string)
  : (run_result, Oas.Error.sdk_error) result =
  let oas_tools = List.map (fun (td : Types.tool_schema) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.name
      ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  let config = { config with tools = oas_tools @ config.tools } in
  run ~sw ~net ~config ?on_event ?on_yield ?on_resume ?contract goal
