(** Oas_worker_exec — Config, build, and run for OAS agent execution.

    Contains the [config] type, [build], [run], and [run_with_masc_tools]
    functions. All model-selection and cascade logic lives in
    {!Oas_worker_cascade} and {!Oas_worker_named}.

    @since God file decomposition — extracted from oas_worker.ml *)

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type stop_reason =
  | Completed
  | TurnBudgetExhausted of { turns_used : int; limit : int }
  | MutationBoundaryReached of { turns_used : int; tool_name : string option }

type config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  provider : Oas.Provider.config;
  model_id : string;
  priority : Llm_provider.Request_priority.t option;
  system_prompt : string;
  tools : Oas.Tool.t list;
  runtime_mcp_policy :
    Llm_provider.Llm_transport.runtime_mcp_policy option;
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
  exit_condition_result : (int -> stop_reason * string option) option;
  summarizer : (Oas.Types.message list -> string) option;
      (** Custom summarizer for OAS [Budget_strategy.reduce_for_budget]
          Emergency-phase compaction. Defaults to OAS's extractive
          default. Keeper workers inject [Keeper_summarizer.keeper_summarizer]
          to scrub [STATE] blocks before the 100-char truncation. *)
}

let default_config
    ~name
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~system_prompt
    ~tools : config =
  let provider = Oas.Provider.config_of_provider_config provider_cfg in
  { name; provider_cfg; provider; model_id = provider_cfg.model_id;
    priority = None; system_prompt; tools;
    runtime_mcp_policy = None;
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
    exit_condition_result = None;
    summarizer = None;
  }

type run_result = {
  response : Oas.Types.api_response;
  checkpoint : Oas.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Oas.Raw_trace.run_ref option;
  run_validation : Oas.Raw_trace.run_validation option;
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
    Uses MASC [Cascade_config.parse_model_string] (with Provider_registry as SSOT).
    Explicit model-label execution must never silently substitute a
    discovery-only model. Callers are expected to validate labels
    before reaching this helper. *)
type label_resolution_error =
  | Invalid_model_label of string

let label_resolution_error_to_string = function
  | Invalid_model_label label ->
    Printf.sprintf "invalid model label %S" label

let label_resolution_error_to_sdk_error err =
  Oas.Error.Config
    (Oas.Error.InvalidConfig
       {
         field = "model_label";
         detail = label_resolution_error_to_string err;
       })

let resolve_provider_config_of_label (label : string) :
    (Llm_provider.Provider_config.t, label_resolution_error) result =
  match Cascade_config.parse_model_string label with
  | Some pc -> Ok pc
  | None ->
      Log.error ~ctx:"oas_worker_exec"
        "refusing unresolved explicit model label=%S; execution never falls back to discovery-only models"
        label;
      Error (Invalid_model_label label)

let invalid_runtime_config field detail =
  Oas.Error.Config
    (Oas.Error.InvalidConfig { field; detail })

let cli_model_override model_id =
  match String.lowercase_ascii (String.trim model_id) with
  | "" | "auto" -> None
  | _ -> Some (String.trim model_id)

let provider_caps_of_config (provider_cfg : Llm_provider.Provider_config.t) =
  let base_caps =
    match provider_cfg.kind with
    | Llm_provider.Provider_config.Ollama ->
        Llm_provider.Capabilities.ollama_capabilities
    | Anthropic -> Llm_provider.Capabilities.anthropic_capabilities
    | Kimi -> Llm_provider.Capabilities.kimi_capabilities
    | Glm -> Llm_provider.Capabilities.glm_capabilities
    | Gemini -> Llm_provider.Capabilities.gemini_capabilities
    | OpenAI_compat -> Llm_provider.Capabilities.openai_chat_capabilities
    | Claude_code -> Llm_provider.Capabilities.claude_code_capabilities
    | Gemini_cli -> Llm_provider.Capabilities.gemini_cli_capabilities
    | Kimi_cli -> Llm_provider.Capabilities.kimi_cli_capabilities
    | Codex_cli -> Llm_provider.Capabilities.codex_cli_capabilities
  in
  let caps =
    match provider_cfg.kind with
    | Llm_provider.Provider_config.Claude_code
    | Gemini_cli
    | Kimi_cli
    | Codex_cli -> base_caps
    | _ ->
        (match Llm_provider.Capabilities.for_model_id provider_cfg.model_id with
         | Some caps -> caps
         | None -> base_caps)
  in
  match provider_cfg.supports_tool_choice_override with
  | Some supports_tool_choice -> { caps with supports_tool_choice }
  | None -> caps

let provider_supports_inline_tools (provider_cfg : Llm_provider.Provider_config.t) =
  (provider_caps_of_config provider_cfg).supports_tools

let provider_supports_runtime_mcp_lane
    (provider_cfg : Llm_provider.Provider_config.t) =
  let caps = provider_caps_of_config provider_cfg in
  caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events

let dedupe_preserve_order (items : string list) =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item then
        false
      else (
        Hashtbl.add seen item ();
        true))
    items

let public_mcp_tool_names_of_oas_tools (tools : Oas.Tool.t list) =
  List.map (fun (tool : Oas.Tool.t) -> tool.schema.name) tools

let tool_names_are_public_mcp (tool_names : string list) =
  tool_names <> [] && List.for_all Tool_catalog.is_public_mcp tool_names

let public_mcp_runtime_policy_of_tool_names (tool_names : string list) :
    Llm_provider.Llm_transport.runtime_mcp_policy option =
  let tool_names = dedupe_preserve_order tool_names in
  if not (tool_names_are_public_mcp tool_names) then
    None
  else
    Some
      {
        Llm_provider.Llm_transport.empty_runtime_mcp_policy with
        servers =
          [
            Llm_provider.Llm_transport.Http_server
              {
                name = "masc";
                url = Env_config_runtime.Local_runtime.mcp_url ();
                headers = [];
              };
          ];
        allowed_server_names = [ "masc" ];
        allowed_tool_names = tool_names;
        strict = true;
        disable_builtin_tools = true;
      }

let provider_label (provider_cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf "%s:%s"
    (Llm_provider.Provider_config.string_of_provider_kind provider_cfg.kind)
    provider_cfg.model_id

let resolve_tool_lane_for_oas_tools
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~(tools : Oas.Tool.t list)
  : (Oas.Tool.t list
     * Llm_provider.Llm_transport.runtime_mcp_policy option,
     Oas.Error.sdk_error)
    result =
  let tool_names = public_mcp_tool_names_of_oas_tools tools in
  match public_mcp_runtime_policy_of_tool_names tool_names with
  | Some runtime_mcp_policy
    when provider_supports_runtime_mcp_lane provider_cfg ->
      Ok ([], Some runtime_mcp_policy)
  | _ when tools = [] ->
      Ok (tools, None)
  | _ when provider_supports_inline_tools provider_cfg ->
      Ok (tools, None)
  | _ ->
      let detail =
        if tool_names_are_public_mcp tool_names then
          Printf.sprintf
            "%s does not support inline tools or request-scoped runtime MCP tools"
            (provider_label provider_cfg)
        else
          Printf.sprintf "%s does not support inline tools"
            (provider_label provider_cfg)
      in
      Error (invalid_runtime_config "tool_support" detail)

(** Wrap CLI transports in a per-call sub-switch.

    agent_sdk's CLI subprocess helper binds stdout/stderr pipes to the
    switch passed at transport construction time. Reusing a long-lived
    keeper/server switch across many calls can therefore retain those pipe
    resources until the outer switch exits. By instantiating the real CLI
    transport inside a fresh sub-switch for each completion call, any
    leftover pipe resources are deterministically released at the end of the
    call even when the outer keeper lifetime is long-lived. *)
let make_per_call_switch_transport
    (factory : sw:Eio.Switch.t -> Llm_provider.Llm_transport.t)
    : Llm_provider.Llm_transport.t =
  let with_call_switch f =
    Eio.Switch.run (fun sw -> f (factory ~sw))
  in
  {
    complete_sync =
      (fun req ->
        with_call_switch (fun transport -> transport.complete_sync req));
    complete_stream =
      (fun ~on_event req ->
        with_call_switch (fun transport ->
            transport.complete_stream ~on_event req));
  }

let non_http_transport_of_provider
    ~(sw : Eio.Switch.t)
    ~(provider_cfg : Llm_provider.Provider_config.t)
  : (Llm_provider.Llm_transport.t option, Oas.Error.sdk_error) result =
  let _ = sw in
  let proc_mgr_result () =
    match Process_eio.get_proc_mgr () with
    | Ok mgr -> Ok mgr
    | Error detail -> Error (invalid_runtime_config "proc_mgr" detail)
  in
  match provider_cfg.kind with
  | Llm_provider.Provider_config.Claude_code ->
      (match proc_mgr_result () with
       | Error _ as e -> e
       | Ok mgr ->
           let config =
             {
               Llm_provider.Transport_claude_code.default_config with
               model = cli_model_override provider_cfg.model_id;
             }
           in
           Ok
             (Some
                (make_per_call_switch_transport (fun ~sw ->
                     Llm_provider.Transport_claude_code.create ~sw ~mgr
                       ~config))))
  | Llm_provider.Provider_config.Gemini_cli ->
      (match proc_mgr_result () with
       | Error _ as e -> e
       | Ok mgr ->
           let config =
             {
               Llm_provider.Transport_gemini_cli.default_config with
               model = cli_model_override provider_cfg.model_id;
             }
           in
           Ok
             (Some
                (make_per_call_switch_transport (fun ~sw ->
                     Llm_provider.Transport_gemini_cli.create ~sw ~mgr
                       ~config))))
  | Llm_provider.Provider_config.Kimi_cli ->
      (match proc_mgr_result () with
       | Error _ as e -> e
       | Ok mgr ->
           let config =
             {
               Llm_provider.Transport_kimi_cli.default_config with
               model = cli_model_override provider_cfg.model_id;
             }
           in
           Ok
             (Some
                (make_per_call_switch_transport (fun ~sw ->
                     Llm_provider.Transport_kimi_cli.create ~sw ~mgr
                       ~config))))
  | Llm_provider.Provider_config.Codex_cli ->
      (match proc_mgr_result () with
       | Error _ as e -> e
       | Ok mgr ->
           Ok
             (Some
                (make_per_call_switch_transport (fun ~sw ->
                     Llm_provider.Transport_codex_cli.create ~sw ~mgr
                       ~config:
                         Llm_provider.Transport_codex_cli.default_config))))
  | Anthropic | Kimi | OpenAI_compat | Ollama | Gemini | Glm ->
      Ok None

(* ================================================================ *)
(* Internal: event publishing                                        *)
(* ================================================================ *)

let publish_lifecycle _bus ~name ~event ~detail =
  match Masc_event_bus.get () with
  | None -> ()
  | Some mb ->
    Oas_bus_instrument.publish mb
      (Oas.Event_bus.mk_event
        (Custom
          (Printf.sprintf "masc.oas_worker.%s" event,
           `Assoc [
             ("agent", `String name);
             ("detail", `String detail);
             ("timestamp", `Float (Time_compat.now ()));
           ])))

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

let partial_response_of_stop
    ~(session_id : string)
    ~(model_id : string)
    ~(text : string)
  : Oas.Types.api_response =
  {
    id = session_id;
    model = model_id;
    stop_reason = Oas.Types.EndTurn;
    content = [ Oas.Types.Text text ];
    usage = None;
    telemetry = None;
  }

(* ================================================================ *)
(* Build                                                             *)
(* ================================================================ *)

let build
    ~(sw : Eio.Switch.t)
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
    match config.runtime_mcp_policy with
    | Some policy -> Oas.Builder.with_runtime_mcp_policy policy builder
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
  let builder = match config.summarizer with
    | Some s -> Oas.Builder.with_summarizer s builder
    | None -> builder
  in
  let builder =
    match non_http_transport_of_provider ~sw ~provider_cfg:config.provider_cfg with
    | Ok (Some transport) -> Ok (Oas.Builder.with_transport transport builder)
    | Ok None -> Ok builder
    | Error _ as e -> e
  in
  match builder with
  | Error _ as e -> e
  | Ok builder ->
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
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(checkpoint : Oas.Checkpoint.t)
  : (Oas.Agent.t, Oas.Error.sdk_error) result =
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
    max_tokens = Some config.max_tokens;
    max_turns = effective_max_turns;
    temperature = Some config.temperature;
    enable_thinking = config.enable_thinking;
    cache_system_prompt = config.cache_system_prompt;
    max_input_tokens = config.max_input_tokens;
    max_cost_usd = effective_max_cost_usd;
    yield_on_tool = config.yield_on_tool;
    context_compact_ratio = config.compact_ratio;
    priority = config.priority;
    exit_condition = config.exit_condition;
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
  (* Parity with [build]: every Agent.options field that [build] threads
     from [config] via the Builder must also be threaded here. Missing
     fields cause silent behavioral drift on resume — e.g. dropping
     [approval] makes OAS log "ApprovalRequired but no approval callback
     — executing" on the first ApprovalRequired tool, dropping
     [summarizer] leaks raw STATE blocks into compaction, dropping
     [slot_id] desyncs admission queue accounting. *)
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
    approval = config.approval;
    slot_id = config.slot_id;
    runtime_mcp_policy = config.runtime_mcp_policy;
    summarizer = config.summarizer;
    priority = config.priority;
  } in
  match non_http_transport_of_provider ~sw ~provider_cfg:config.provider_cfg with
  | Error _ as e -> e
  | Ok transport ->
      let options = { options with transport } in
      Ok
        (Oas.Agent.resume ~net ~checkpoint:patched_checkpoint
           ~tools:config.tools ?context:config.context
           ~options ~config:agent_config ())

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
      (try resume_from_checkpoint ~sw ~net ~config ~checkpoint
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn "oas_worker %s: resume_from_checkpoint failed (%s), falling back to build"
           config.name (Printexc.to_string exn);
         build ~sw ~net ~config)
    | None -> build ~sw ~net ~config
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
    let run_validation =
      match trace_ref with
      | Some ref_ ->
        (match Oas.Raw_trace_query.validate_run ref_ with
         | Ok v -> Some v
         | Error err ->
           Log.Misc.warn "oas_worker: run_validation failed: %s"
             (Oas.Error.to_string err);
           None)
      | None -> None
    in
    (match result with
    | Ok response ->
      Ok
        {
          response;
          checkpoint;
          session_id;
          turns;
          trace_ref;
          run_validation;
          proof;
          cascade_observation = None;
          stop_reason = Completed;
        }
    | Error (Oas.Error.Agent (Oas.Error.MaxTurnsExceeded r)) ->
      let partial_response =
        partial_response_of_stop
          ~session_id
          ~model_id:config.model_id
          ~text:(Printf.sprintf
            "[turn budget exhausted: %d/%d turns used]" r.turns r.limit)
      in
      Ok
        {
          response = partial_response;
          checkpoint;
          session_id;
          turns;
          trace_ref;
          run_validation;
          proof;
          cascade_observation = None;
          stop_reason = TurnBudgetExhausted { turns_used = r.turns; limit = r.limit };
        }
    | Error (Oas.Error.Agent (Oas.Error.ExitConditionMet r)) -> (
      match config.exit_condition_result with
      | Some render ->
        let stop_reason, response_text_opt = render r.turn in
        let response_text =
          match response_text_opt with
          | Some text when String.trim text <> "" -> text
          | _ -> Printf.sprintf "[exit condition met at turn %d]" r.turn
        in
        let partial_response =
          partial_response_of_stop
            ~session_id
            ~model_id:config.model_id
            ~text:response_text
        in
        Ok
          {
            response = partial_response;
            checkpoint;
            session_id;
            turns;
            trace_ref;
            run_validation;
            proof;
            cascade_observation = None;
            stop_reason;
          }
      | None ->
        Error (Oas.Error.Agent (Oas.Error.ExitConditionMet r)))
    | Error err ->
      let detail = Oas.Error.to_string err in
      let detail =
        enrich_idle_detail detail (Oas.Agent.state agent).messages
      in
      (* Demoted from WARN to DEBUG (task-239): this fires once per tier,
         but a cascade caller (Oas_worker_named.run_named) retries on the
         next provider.  Emitting WARN/ERROR here creates noise on
         recovered cascades.  The cascade layer logs [cascade-fallback] at
         INFO when it retries and emits ERROR only on full exhaustion. *)
      (match proof with
       | Some p ->
         Log.Misc.debug "oas_worker: agent errored with CDAL proof: run_id=%s status=%s error=%s"
           p.run_id
           (proof_result_status_to_string p.result_status)
           detail
       | None ->
         Log.Misc.debug "oas_worker: agent errored (no proof): %s" detail);
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
  match
    public_mcp_runtime_policy_of_tool_names
      (List.map (fun (td : Types.tool_schema) -> td.name) masc_tools)
  with
  | Some runtime_mcp_policy
    when provider_supports_runtime_mcp_lane config.provider_cfg ->
      let config = { config with runtime_mcp_policy = Some runtime_mcp_policy } in
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume ?contract goal
  | _ when masc_tools = [] ->
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume ?contract goal
  | _ when provider_supports_inline_tools config.provider_cfg ->
      let oas_tools =
        List.map
          (fun (td : Types.tool_schema) ->
            Tool_bridge.oas_tool_of_masc
              ~name:td.name
              ~description:td.description
              ~input_schema:td.input_schema
              (fun input -> dispatch ~name:td.name ~args:input))
          masc_tools
      in
      let config = { config with tools = oas_tools @ config.tools } in
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume ?contract goal
  | _ ->
      Error
        (invalid_runtime_config "tool_support"
           (Printf.sprintf
              "%s does not support inline tools or request-scoped runtime MCP tools"
              (provider_label config.provider_cfg)))
