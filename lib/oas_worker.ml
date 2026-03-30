(** Oas_worker — Unified entry point for OAS-based MASC tool modules.

    Reusable OAS Agent build/run/checkpoint/events template.  Any MASC module that needs to run an OAS Agent
    uses this instead of duplicating boilerplate.

    Phases:
    1. Build  — construct [Agent.t] via [Agent_sdk.Builder]
    2. Run    — execute [Agent.run ~sw agent goal]
    3. Checkpoint — persist [Agent.checkpoint] + optional MASC context
    4. Events — bridge lifecycle events to [Event_bus]

    @since Phase 1 — MASC→OAS migration *)

module Oas = Agent_sdk

(* ================================================================ *)
(* Inference defaults — single definition point (ADR D2).            *)
(* Callers override via optional params.                             *)
(* Cascade config auto-resolution tracked in jeong-sik/me#915.      *)
(* ================================================================ *)

let default_temperature = 0.7
let default_max_tokens = 4096

(* ================================================================ *)
(* Cascade metrics                                                   *)
(* ================================================================ *)

type cascade_counter = {
  mutable calls : int;
  mutable successes : int;
  mutable failures : int;
  mutable rejected : int;
}

let cascade_counters : (string, cascade_counter) Hashtbl.t = Hashtbl.create 8
let cascade_max_keys = 256

let record_cascade ~cascade_name ~outcome =
  let c = match Hashtbl.find_opt cascade_counters cascade_name with
    | Some c -> c
    | None ->
      if Hashtbl.length cascade_counters >= cascade_max_keys then
        { calls = 0; successes = 0; failures = 0; rejected = 0 }
      else begin
        let c = { calls = 0; successes = 0; failures = 0; rejected = 0 } in
        Hashtbl.replace cascade_counters cascade_name c; c
      end
  in
  c.calls <- c.calls + 1;
  (match outcome with
  | `Success -> c.successes <- c.successes + 1
  | `Failure -> c.failures <- c.failures + 1
  | `Rejected -> c.rejected <- c.rejected + 1)

let cascade_metrics_json () : Yojson.Safe.t =
  let entries = Hashtbl.fold (fun name c acc ->
    let error_rate = if c.calls > 0
      then float_of_int (c.failures + c.rejected) /. float_of_int c.calls
      else 0.0 in
    `Assoc [
      ("cascade_name", `String name);
      ("calls", `Int c.calls);
      ("successes", `Int c.successes);
      ("failures", `Int c.failures);
      ("rejected", `Int c.rejected);
        ("error_rate", `Float error_rate);
      ] :: acc
    ) cascade_counters [] in
    `List (List.sort (fun a b ->
      let get_calls j = Yojson.Safe.Util.(j |> member "calls" |> to_int) in
      Int.compare (get_calls b) (get_calls a)
    ) entries)

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type config = {
  name : string;
  provider : Oas.Provider.config;
  model_id : string;
  system_prompt : string;
  tools : Oas.Tool.t list;
  max_turns : int;
  max_idle_turns : int;
  max_tokens : int;
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
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  working_context : Yojson.Safe.t option;
  priority : Llm_provider.Request_priority.t option;
}

let default_config ~name ~provider ~model_id ~system_prompt ~tools : config =
  { name; provider; model_id; system_prompt; tools;
    max_turns = 20;
    max_idle_turns = 3;
    max_tokens = default_max_tokens;
    temperature = default_temperature;
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
    transport = Masc_grpc_transport.from_env ();
    allowed_paths = [];
    working_context = None;
    priority = None;
  }

(* ================================================================ *)
(* Result type                                                       *)
(* ================================================================ *)

type run_result = {
  response : Oas.Types.api_response;
  checkpoint : Oas.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Oas.Raw_trace.run_ref option;
  proof : Oas.Cdal_proof.t option;
}

(* ================================================================ *)
(* Internal: resolve provider                                        *)
(* ================================================================ *)

(** Resolve a model label string to an OAS Provider.config.
    Uses OAS Cascade_config.parse_model_string (Provider_registry SSOT).
    Falls back to glm when parsing fails.

    Note: the previous middle fallback via [to_oas_provider_of_label]
    was dead code — it calls parse_model_string internally, so if
    line 84 fails, line 88 also fails. Removed in v2.136.0. *)
let resolve_provider_of_label (label : string) : Oas.Provider.config =
  match Llm_provider.Cascade_config.parse_model_string label with
  | Some pc -> Oas.Provider.config_of_provider_config pc
  | None ->
    (* No vendor-specific fallback — use local llama via OAS round-robin *)
    Oas.Provider.config_of_provider_config
      (Llm_provider.Provider_config.make
         ~kind:Llm_provider.Provider_config.OpenAI_compat
         ~model_id:"auto"
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

let build_checkpoint ~session_id ?working_context (agent : Oas.Agent.t) =
  match working_context with
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
  : (Oas.Agent.t, string) result =
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
  let builder = match config.named_cascade with
    | Some nc -> Oas.Builder.with_named_cascade nc builder
    | None -> builder
  in
  let builder =
    if config.initial_messages <> [] then
      Oas.Builder.with_initial_messages config.initial_messages builder
    else builder
  in
  let builder =
    if config.allowed_paths <> [] then
      Oas.Builder.with_allowed_paths config.allowed_paths builder
    else builder
  in
  let builder = match config.priority with
    | Some p -> Oas.Builder.with_priority p builder
    | None -> builder
  in
  Oas.Builder.build_safe builder
  |> Result.map_error Oas.Error.to_string

(* ================================================================ *)
(* Run                                                               *)
(* ================================================================ *)

let run
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ?(on_event : (Oas.Types.sse_event -> unit) option)
    ?(agent_ref : Oas.Agent.t option ref option)
    ?(contract : Oas.Risk_contract.t option)
    (goal : string)
  : (run_result, string) result =
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
  match build ~net ~config with
  | Error e ->
    Option.iter (fun bus ->
      publish_lifecycle bus ~name:config.name ~event:"build_error" ~detail:e
    ) config.event_bus;
    Error (Printf.sprintf "Agent build failed: %s" e)
  | Ok agent ->
  (* Set agent_ref for tools that need post-creation agent access (e.g. extend_turns) *)
  (match agent_ref with Some r -> r := Some agent | None -> ());
  (* Wrap agent execution so Eio/network exceptions become Error results,
     honouring the (run_result, string) result return type promised by .mli.
     Eio.Cancel.Cancelled is re-raised for structured-concurrency safety. *)
  (try
    let result, proof = match contract with
      | Some c ->
        let cr = Oas.Contract_runner.run ~sw ~contract:c agent goal in
        (cr.response, Some cr.proof)
      | None ->
        let r = match on_event with
          | Some cb -> Oas.Agent.run_stream ~sw ~on_event:cb agent goal
          | None -> Oas.Agent.run ~sw agent goal
        in
        (r, None)
    in
    let checkpoint = match config.checkpoint_dir with
      | Some dir ->
        let ckpt = build_checkpoint ~session_id ?working_context:config.working_context agent in
        (try persist_checkpoint ~dir ~session_id ckpt
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Log.Misc.error "oas_worker: Checkpoint save failed: %s"
             (Printexc.to_string exn));
        Some ckpt
      | None ->
        Option.map
          (fun _ ->
            build_checkpoint ~session_id ?working_context:config.working_context agent)
          config.working_context
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
    | Ok response -> Ok { response; checkpoint; session_id; turns; trace_ref; proof }
    | Error err ->
      Error (Printf.sprintf "Agent run failed: %s" (Oas.Error.to_string err)))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    (try Oas.Agent.close agent with close_exn ->
      Log.Misc.warn "agent close failed during cleanup: %s" (Printexc.to_string close_exn));
    Error (Printf.sprintf "Agent execution exception: %s" (Printexc.to_string exn)))

(* ================================================================ *)
(* Convenience: run_with_masc_tools                                  *)
(* ================================================================ *)

let run_with_masc_tools
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?on_event
    (goal : string)
  : (run_result, string) result =
  let oas_tools = List.map (fun (td : Types.tool_schema) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.name
      ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  let config = { config with tools = oas_tools @ config.tools } in
  run ~sw ~net ~config ?on_event goal

(* ================================================================ *)
(* Cascade profile defaults (moved from Cascade module)              *)
(* ================================================================ *)

let default_config_path () : string option =
  Config_dir_resolver.log_warnings ~context:"OasWorker" ();
  Config_dir_resolver.cascade_path_opt ()

(** Hardcoded fallback defaults — used only when cascade.json is missing
    and the cascade name has no "{name}_models" entry.
    All profiles are now in config/cascade.json (hot-reloadable). *)
let default_model_strings ~cascade_name:_ =
  let llama_model = Env_config.Llama.default_model in
  let models =
    if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else []
  in
  if models = [] then
    match Provider_adapter.preferred_execution_model_labels () with
    | [] -> [ "llama:auto" ]
    | labels -> labels
  else models

(* ================================================================ *)
(* Named model execution                                            *)
(* ================================================================ *)

let require_eio ?sw ?net () =
  let sw = match sw with Some s -> Some s | None -> Eio_context.get_switch_opt () in
  let net = match net with Some n -> Some n | None -> Eio_context.get_net_opt () in
  match sw, net with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

(** Resolve cascade provider configs via OAS Cascade_config.
    Returns OAS Provider_config.t list directly, bypassing the old Model_spec facade. *)
let resolve_cascade_providers ~cascade_name : Llm_provider.Provider_config.t list =
  let defaults = default_model_strings ~cascade_name in
  let config_path = default_config_path () in
  let configured =
    Llm_provider.Cascade_config.resolve_model_strings
      ?config_path ~name:cascade_name ~defaults ()
  in
  let specs = Llm_provider.Cascade_config.parse_model_strings configured in
  if specs <> [] then specs
  else if configured = defaults then (
      Log.Misc.warn "cascade %s: no callable models from built-in defaults" cascade_name;
      [])
    else (
      Log.Misc.warn "cascade %s: configured models unavailable — retrying built-in defaults" cascade_name;
      Llm_provider.Cascade_config.parse_model_strings defaults)

let config_for_label
    ~(name : string)
    ~(model_label : string)
    ~(system_prompt : string)
    ~(tools : Oas.Tool.t list)
    ~(max_turns : int)
    ~(max_tokens : int)
    ~(temperature : float)
    ?(max_idle_turns = 3)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ~(description : string option)
    () : config =
  let provider = resolve_provider_of_label model_label in
  let model_id = match Oas_model_resolve.provider_name_of_label model_label with
    | Some _ ->
      (* Extract model_id portion from "provider:model_id" *)
      (match String.index_opt model_label ':' with
       | Some idx -> String.sub model_label (idx + 1) (String.length model_label - idx - 1) |> String.trim
       | None -> model_label)
    | None -> model_label
  in
  {
    (default_config ~name ~provider ~model_id
       ~system_prompt ~tools)
    with
    max_turns;
    max_tokens;
    temperature;
    max_idle_turns;
    guardrails;
    hooks;
    context_reducer;
    memory;
    description;
  }

(** Run a single Agent.run() call with cascade model fallback.

    Tries each model in cascade order. Falls through to the next model
    when:
    - Agent.run() returns an error (model unavailable, network issue)
    - [accept] returns [false] (response validation failure)

    This preserves the cascade fallback behavior of the former [Cascade.complete]
    while routing all MODEL calls through Agent.run().

    @param accept Optional response validator. Default accepts all.
    @since Phase 7 — cascade fallback in Oas_worker *)
let run_named
    ~cascade_name
    ~goal
    ?session_id
    ?(system_prompt = "")
    ?(tools = [])
    ?(initial_messages = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?(temperature = default_temperature)
    ?(max_tokens = default_max_tokens)
    ?(accept = fun (_ : Oas_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?context_reducer
    ?priority
    ?memory
    ?raw_trace
    ?on_event
    ?agent_ref
    ?contract
    ?transport
    ?(allowed_paths = [])
    ?working_context
    ?sw
    ?net
    ()
  : (run_result, string) result =
  match require_eio ?sw ?net () with
  | Error e -> Error e
  | Ok (sw, net) ->
  let defaults = default_model_strings ~cascade_name in
  let config_path = default_config_path () in
  let named_cascade = Oas.Api.named_cascade ?config_path
    ~name:cascade_name ~defaults () in
  let name = Printf.sprintf "oas-%s" cascade_name in
  (* Use first available provider config as primary for Builder.
     OAS named_cascade handles actual fallback — this is just the
     initial provider for Agent construction. *)
  let primary_provider = match resolve_cascade_providers ~cascade_name with
    | cfg :: _ -> cfg
    | [] ->
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.Glm
        ~model_id:"auto"
        ~base_url:"https://open.bigmodel.cn/api/paas/v4"
        ~request_path:"/chat/completions"
        ()
  in
  let provider : Oas.Provider.config =
    Oas.Provider.config_of_provider_config primary_provider
  in
  let transport_resolved = match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  let config =
    { (default_config ~name ~provider ~model_id:primary_provider.model_id
         ~system_prompt ~tools)
      with
      max_turns; max_tokens; temperature; max_idle_turns;
      guardrails; hooks; context_reducer; memory;
      description = Some (Printf.sprintf "cascade:%s" cascade_name);
      transport = transport_resolved;
      allowed_paths;
      working_context;
      session_id;
      priority;
    }
  in
  let config = { config with named_cascade = Some named_cascade; initial_messages; raw_trace } in
  match run ~sw ~net ~config ?on_event ?agent_ref ?contract goal with
  | Ok result when accept result.response ->
    record_cascade ~cascade_name ~outcome:`Success;
    Ok result
  | Ok _ ->
    record_cascade ~cascade_name ~outcome:`Rejected;
    Error (Printf.sprintf "cascade %s: response rejected by accept" cascade_name)
  | Error e ->
    record_cascade ~cascade_name ~outcome:`Failure;
    Error e

(** Run a single Agent.run() using a model label string (e.g. "llama:qwen3.5").
    Validates the label parses before attempting execution. *)
let run_model_by_label
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ?(tools = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?(temperature = default_temperature)
    ?(max_tokens = default_max_tokens)
    ?(accept = fun (_ : Oas_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?on_event
    ?transport
    ?priority
    ?sw
    ?net
    ()
  : (run_result, string) result =
  (* Validate the label parses before proceeding via OAS Cascade_config *)
  (match Llm_provider.Cascade_config.parse_model_string model_label with
  | None ->
    Error (Printf.sprintf "Cannot parse model label: %s" model_label)
  | Some _pc ->
    match require_eio ?sw ?net () with
    | Error e -> Error e
    | Ok (sw, net) ->
        let transport_resolved = match transport with
          | Some t -> t
          | None -> Masc_grpc_transport.from_env ()
        in
        let config =
          config_for_label ~name:"oas-label-model" ~model_label ~system_prompt
            ~tools ~max_turns ~max_tokens ~temperature ~max_idle_turns ?guardrails ?hooks
            ?context_reducer ?memory
            ~description:(Some (Printf.sprintf "model_label:%s" model_label))
            ()
        in
        let config = { config with transport = transport_resolved; priority } in
        (match run ~sw ~net ~config ?on_event goal with
        | Ok result when accept result.response -> Ok result
        | Ok _ ->
            Error
              (Printf.sprintf "response rejected by accept from %s" model_label)
        | Error e -> Error e))

let run_named_with_masc_tools
    ~cascade_name
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?(temperature = default_temperature)
    ?(max_tokens = default_max_tokens)
    ?guardrails
    ?hooks
    ?memory
    ?raw_trace
    ?on_event
    ?contract
    ?transport
    ?priority
    ?sw
    ?net
    ()
  : (run_result, string) result =
  (* Convert MASC tools to OAS tools, then delegate to run_named.
     OAS named_cascade handles model fallback internally. *)
  let oas_tools = List.map (fun (td : Types.tool_schema) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.name ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  run_named ~cascade_name ~goal ~system_prompt ~tools:oas_tools
    ~max_turns ~temperature ~max_tokens ?guardrails ?hooks ?memory
    ?raw_trace ?on_event ?contract ?transport ?priority ?sw ?net ()

let run_model_with_masc_tools
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?(temperature = default_temperature)
    ?(max_tokens = default_max_tokens)
    ?guardrails
    ?hooks
    ?memory
    ?raw_trace
    ?on_event
    ?transport
    ?priority
    ?sw
    ?net
    ()
  : (run_result, string) result =
  match require_eio ?sw ?net () with
  | Error e -> Error e
  | Ok (sw, net) ->
      let transport_resolved = match transport with
        | Some t -> t
        | None -> Masc_grpc_transport.from_env ()
      in
      let config =
        config_for_label ~name:"oas-explicit-model" ~model_label ~system_prompt
          ~tools:[] ~max_turns ~max_tokens ~temperature ?guardrails ?hooks
          ?memory
          ~description:(Some (Printf.sprintf "model_label:%s" model_label))
          ()
      in
      let config = { config with raw_trace; transport = transport_resolved; priority } in
      run_with_masc_tools ~sw ~net ~config ~masc_tools ~dispatch ?on_event
        goal
