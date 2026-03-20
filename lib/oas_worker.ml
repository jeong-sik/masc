(** Oas_worker — Unified entry point for OAS-based MASC tool modules.

    Generalizes the build/run/checkpoint/events pattern from [perpetual_oas.ml]
    into a reusable template.  Any MASC module that needs to run an OAS Agent
    uses this instead of duplicating boilerplate.

    Phases:
    1. Build  — construct [Agent.t] via [Agent_sdk.Builder]
    2. Run    — execute [Agent.run ~sw agent goal]
    3. Checkpoint — persist [Agent.checkpoint] + optional MASC context
    4. Events — bridge lifecycle events to [Event_bus]

    @since Phase 1 — MASC→OAS migration *)

module Oas = Agent_sdk

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
}

let default_config ~name ~provider ~model_id ~system_prompt ~tools : config =
  { name; provider; model_id; system_prompt; tools;
    max_turns = 20;
    max_tokens = 4096;
    temperature = 0.7;
    hooks = None;
    context_reducer = None;
    guardrails = None;
    event_bus = None;
    checkpoint_dir = None;
    session_id = None;
    description = None;
    memory = None;
  }

(* ================================================================ *)
(* Result type                                                       *)
(* ================================================================ *)

type run_result = {
  response : Oas.Types.api_response;
  checkpoint : Oas.Checkpoint.t option;
  session_id : string;
  turns : int;
}

(* ================================================================ *)
(* Internal: resolve provider                                        *)
(* ================================================================ *)

let resolve_provider (spec : Model_spec.model_spec) : Oas.Provider.config =
  match Oas_type_adapters.to_oas_provider spec with
  | Some cfg -> cfg
  | None ->
    { Oas.Provider.provider =
        Oas.Provider.OpenAICompat {
          base_url = spec.api_url;
          auth_header = None;
          path = "/v1/chat/completions";
          static_token = None;
        };
      model_id = spec.model_id;
      api_key_env = Option.value ~default:"" spec.api_key_env;
    }

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
  (* Wrap agent execution so Eio/network exceptions become Error results,
     honouring the (run_result, string) result return type promised by .mli.
     Eio.Cancel.Cancelled is re-raised for structured-concurrency safety. *)
  (try
    let result = match on_event with
      | Some cb -> Oas.Agent.run_stream ~sw ~on_event:cb agent goal
      | None -> Oas.Agent.run ~sw agent goal
    in
    let checkpoint = match config.checkpoint_dir with
      | Some dir ->
        let ckpt = Oas.Agent.checkpoint ~session_id agent in
        (try persist_checkpoint ~dir ~session_id ckpt
         with exn ->
           Printf.eprintf "[oas_worker] Checkpoint save failed: %s\n%!"
             (Printexc.to_string exn));
        Some ckpt
      | None -> None
    in
    Option.iter (fun bus ->
      let status = match result with Ok _ -> "completed" | Error _ -> "failed" in
      publish_lifecycle bus ~name:config.name ~event:status
        ~detail:(Printf.sprintf "session=%s" session_id)
    ) config.event_bus;
    let turns = (Oas.Agent.state agent).turn_count in
    Oas.Agent.close agent;
    (match result with
    | Ok response -> Ok { response; checkpoint; session_id; turns }
    | Error err ->
      Error (Printf.sprintf "Agent run failed: %s" (Oas.Error.to_string err)))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    (try Oas.Agent.close agent with _ -> ());
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
(* Named cascade API — callers pass cascade_name, not model_spec    *)
(* ================================================================ *)

let require_eio () =
  match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

let resolve_cascade ~cascade_name =
  let defaults = Cascade.default_model_strings ~cascade_name in
  let configured =
    match Cascade.default_config_path () with
    | Some path ->
      let from_file =
        Llm_provider.Cascade_config.load_profile ~config_path:path ~name:cascade_name
      in
      if from_file <> [] then from_file else defaults
    | None -> defaults
  in
  let specs = Model_spec.available_model_specs_of_strings configured in
  let specs =
    if specs <> [] then specs
    else
      let fallback = Cascade.default_model_strings ~cascade_name in
      if configured = fallback then (
        Printf.eprintf "[cascade] %s: no callable models from built-in defaults\n%!" cascade_name;
        [])
      else (
        Printf.eprintf "[cascade] %s: configured models unavailable — retrying built-in defaults\n%!" cascade_name;
        Model_spec.available_model_specs_of_strings fallback)
  in
  match specs with
  | [] ->
    Error (Printf.sprintf "No models available for cascade '%s'" cascade_name)
  | spec :: _ ->
    let provider = resolve_provider spec in
    Ok (provider, spec.model_id)

let run_named
    ~cascade_name
    ~goal
    ?(system_prompt = "")
    ?(tools = [])
    ?(max_turns = 20)
    ?(temperature = 0.7)
    ?(max_tokens = 4096)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?on_event
    ()
  : (run_result, string) result =
  match require_eio () with
  | Error e -> Error e
  | Ok (sw, net) ->
  match resolve_cascade ~cascade_name with
  | Error e -> Error e
  | Ok (provider, model_id) ->
  let name = Printf.sprintf "oas-%s" cascade_name in
  let config = { (default_config ~name ~provider ~model_id ~system_prompt ~tools) with
    max_turns;
    max_tokens;
    temperature;
    guardrails;
    hooks;
    context_reducer;
    memory;
    description = Some (Printf.sprintf "cascade:%s" cascade_name);
  } in
  run ~sw ~net ~config ?on_event goal

let run_named_with_masc_tools
    ~cascade_name
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?(temperature = 0.7)
    ?(max_tokens = 4096)
    ?guardrails
    ?hooks
    ?memory
    ?on_event
    ()
  : (run_result, string) result =
  match require_eio () with
  | Error e -> Error e
  | Ok (sw, net) ->
  match resolve_cascade ~cascade_name with
  | Error e -> Error e
  | Ok (provider, model_id) ->
  let name = Printf.sprintf "oas-%s" cascade_name in
  let config = { (default_config ~name ~provider ~model_id ~system_prompt ~tools:[]) with
    max_turns;
    max_tokens;
    temperature;
    guardrails;
    hooks;
    memory;
    description = Some (Printf.sprintf "cascade:%s" cascade_name);
  } in
  run_with_masc_tools ~sw ~net ~config ~masc_tools ~dispatch ?on_event goal
