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
(* Cascade profile helpers (moved from Cascade)                      *)
(* ================================================================ *)

let int_of_env_default name ~default ~min_v ~max_v =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      let v =
        try int_of_string (String.trim raw)
        with Failure _ -> default
      in
      max min_v (min max_v v)

(** Locate config/cascade.json via CWD or ME_ROOT. *)
let default_config_path () : string option =
  let base dir name = Filename.concat (Filename.concat dir "config") name in
  let cwd = Sys.getcwd () in
  let me_root =
    Sys.getenv_opt "ME_ROOT"
    |> Option.value
         ~default:(Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp")
  in
  let masc_root = Filename.concat me_root "workspace/yousleepwhen/masc-mcp" in
  let candidates =
    [ base cwd "cascade.json";
      base masc_root "cascade.json";
      base cwd "llm_cascade.json";
      base masc_root "llm_cascade.json" ]
  in
  List.find_opt Sys.file_exists candidates

let cascade_label provider model =
  if model = "" then None
  else Some (Printf.sprintf "%s:%s" provider model)

let cascade_labels_of pairs =
  List.filter_map (fun (p, m) -> cascade_label p m) pairs

let default_model_strings ~cascade_name =
  let llama_model = Env_config.Llama.default_model in
  let glm_model = Env_config.Llm.default_model in
  let glm_flash = Env_config.Llm.flash_model in
  let llama_glm =
    (if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else [])
    @ [ "glm:auto" ]
  in
  match cascade_name with
  | "heartbeat_action" | "heartbeat_wake" -> llama_glm
  | "sentinel_board" | "sentinel_task" | "sentinel_keeper" -> llama_glm
  | "lodge_direct" | "lodge_context_rewrite" | "lodge_trait_gen"
  | "lodge_comment" | "lodge_agent_match" -> llama_glm
  | "gardener_spawn" | "gardener_retire" -> llama_glm
  | "classification" | "context_router" | "capability_match" -> llama_glm
  | "tom" -> llama_glm
  | "verifier" | "code_swarm_verify" | "code_swarm" -> llama_glm
  | "keeper_autonomy" | "keeper_proactive" | "keeper_deliberation"
  | "keeper_reply" | "keeper_social" | "keeper_turn" -> llama_glm
  | "routing_judge" | "team_router" -> llama_glm
  | "chain_llm" -> llama_glm
  | "autoresearch" -> llama_glm
  | "trpg_intent" -> llama_glm
  | "briefing" ->
      (if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else [])
      @ cascade_labels_of [ ("glm", glm_flash); ("gemini", Env_config.Gemini.flash_model) ]
      @ [ "glm:auto" ]
  | "governance_judge" | "operator_judge" -> llama_glm
  | "walph" -> llama_glm
  | "auto_responder_claude" ->
      cascade_labels_of [ ("claude", Env_config.Claude.default_model) ]
      @ [ "glm:auto" ]
  | "auto_responder_gemini" ->
      cascade_labels_of [ ("gemini", Env_config.Gemini.flash_model) ]
      @ [ "glm:auto" ]
  | "auto_responder_glm" ->
      cascade_labels_of [ ("glm", glm_model) ]
      @ [ "glm:auto" ]
  | "auto_responder" -> llama_glm
  | "spawn_glm" ->
      cascade_labels_of [ ("glm", glm_model); ("glm", glm_flash) ]
      @ [ "glm:auto" ]
  | "mitosis" -> llama_glm
  | "topic_extraction" -> llama_glm
  | _ -> llama_glm

(** Max concurrent LLM calls — observability only, no throttling. *)
let max_concurrent_llm =
  int_of_env_default "MASC_MAX_CONCURRENT_LLM" ~default:8 ~min_v:1 ~max_v:128

let inflight = Atomic.make 0
let llm_semaphore_available () = max_concurrent_llm - Atomic.get inflight
let llm_permits_in_use () = Atomic.get inflight

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
(* Single-shot cascade call (replaces Cascade.complete)              *)
(* ================================================================ *)

(** Format OAS http_error as cascade error string. *)
let format_cascade_error ~cascade_name = function
  | Llm_provider.Http_client.HttpError { code; body } ->
    Printf.sprintf "[cascade] %s: HTTP %d: %s" cascade_name code
      (if String.length body > 200
       then String.sub body 0 200 ^ "..."
       else body)
  | Llm_provider.Http_client.NetworkError { message } ->
    Printf.sprintf "[cascade] %s: %s" cascade_name message

(** Single-shot LLM call via cascade policy.
    Drop-in replacement for the former [Cascade.complete].
    Policy (model selection, config path) is read from {!Cascade};
    execution goes through [Llm_provider.Cascade_config.complete_named]. *)
let complete_single ~cascade_name ~messages
    ?(config_path = "") ?(temperature = 0.3) ?(timeout_sec = 30)
    ?(max_tokens = 500) ?(accept = fun _ -> true) ?tools () =
  let env = Masc_eio_env.get () in
  let defaults = default_model_strings ~cascade_name in
  let config_path_opt =
    if String.length config_path > 0 then Some config_path
    else default_config_path ()
  in
  match
    Llm_provider.Cascade_config.complete_named
      ~sw:env.sw ~net:env.net ?clock:env.clock
      ?config_path:config_path_opt
      ~name:cascade_name ~defaults ~messages
      ?tools ~temperature ~max_tokens ~accept ~timeout_sec ()
  with
  | Ok resp -> Ok resp
  | Error err -> Error (format_cascade_error ~cascade_name err)

(* ================================================================ *)
(* Named cascade API — callers pass cascade_name, not model_spec    *)
(* ================================================================ *)

let require_eio () =
  match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

(** Resolve cascade model specs from config + defaults. *)
let resolve_cascade_specs ~cascade_name : Model_spec.model_spec list =
  let defaults = default_model_strings ~cascade_name in
  let configured =
    match default_config_path () with
    | Some path ->
      let from_file =
        Llm_provider.Cascade_config.load_profile ~config_path:path ~name:cascade_name
      in
      if from_file <> [] then from_file else defaults
    | None -> defaults
  in
  let specs = Model_spec.available_model_specs_of_strings configured in
  if specs <> [] then specs
  else
    let fallback = default_model_strings ~cascade_name in
    if configured = fallback then (
      Printf.eprintf "[cascade] %s: no callable models from built-in defaults\n%!" cascade_name;
      [])
    else (
      Printf.eprintf "[cascade] %s: configured models unavailable — retrying built-in defaults\n%!" cascade_name;
      Model_spec.available_model_specs_of_strings fallback)

(** Run a single Agent.run() call with cascade model fallback.

    Tries each model in cascade order. Falls through to the next model
    when:
    - Agent.run() returns an error (model unavailable, network issue)
    - [accept] returns [false] (response validation failure)

    This preserves the cascade fallback behavior of [Cascade.complete]
    while routing all LLM calls through Agent.run().

    @param accept Optional response validator. Default accepts all.
    @since Phase 7 — cascade fallback in Oas_worker *)
let run_named
    ~cascade_name
    ~goal
    ?(system_prompt = "")
    ?(tools = [])
    ?(max_turns = 20)
    ?(temperature = 0.7)
    ?(max_tokens = 4096)
    ?(accept = fun (_ : Llm_provider.Types.api_response) -> true)
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
  let specs = resolve_cascade_specs ~cascade_name in
  let rec try_specs last_error = function
    | [] ->
      let err = match last_error with
        | Some e -> e
        | None -> Printf.sprintf "No models available for cascade '%s'" cascade_name
      in
      Error err
    | (spec : Model_spec.model_spec) :: rest ->
      let provider = resolve_provider spec in
      let name = Printf.sprintf "oas-%s" cascade_name in
      let config = { (default_config ~name ~provider ~model_id:spec.model_id
                        ~system_prompt ~tools) with
        max_turns;
        max_tokens;
        temperature;
        guardrails;
        hooks;
        context_reducer;
        memory;
        description = Some (Printf.sprintf "cascade:%s" cascade_name);
      } in
      match run ~sw ~net ~config ?on_event goal with
      | Ok result when accept result.response -> Ok result
      | Ok _ ->
        Log.Misc.info "[oas_worker] cascade %s: model %s response rejected by accept, trying next"
          cascade_name spec.model_id;
        try_specs (Some (Printf.sprintf "accept rejected response from %s" spec.model_id)) rest
      | Error e when rest <> [] ->
        Log.Misc.info "[oas_worker] cascade %s: model %s failed (%s), trying next"
          cascade_name spec.model_id e;
        try_specs (Some e) rest
      | Error e -> Error e
  in
  try_specs None specs

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
  let specs = resolve_cascade_specs ~cascade_name in
  let rec try_specs last_error = function
    | [] ->
      let err = match last_error with
        | Some e -> e
        | None -> Printf.sprintf "No models available for cascade '%s'" cascade_name
      in
      Error err
    | (spec : Model_spec.model_spec) :: rest ->
      let provider = resolve_provider spec in
      let name = Printf.sprintf "oas-%s" cascade_name in
      let config = { (default_config ~name ~provider ~model_id:spec.model_id
                        ~system_prompt ~tools:[]) with
        max_turns;
        max_tokens;
        temperature;
        guardrails;
        hooks;
        memory;
        description = Some (Printf.sprintf "cascade:%s" cascade_name);
      } in
      match run_with_masc_tools ~sw ~net ~config ~masc_tools ~dispatch ?on_event goal with
      | Ok result -> Ok result
      | Error e when rest <> [] ->
        Log.Misc.info "[oas_worker] cascade %s: model %s failed (%s), trying next"
          cascade_name spec.model_id e;
        try_specs (Some e) rest
      | Error e -> Error e
  in
  try_specs None specs
