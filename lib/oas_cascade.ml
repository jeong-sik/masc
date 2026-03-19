(** Oas_cascade — public single-shot access to OAS named cascades.

    MASC owns cascade policy (cascade name -> default provider/model labels).
    OAS owns execution: config loading, health checks, retries/failover,
    timeout handling, validation, and final response parsing.

    New or migrated single-shot LLM call sites should depend on this module
    instead of reaching for [Llm_cascade] directly. *)

type text_result = {
  response : string;
  llm_used : string;
  duration_ms : int;
}

type json_result = {
  json : Yojson.Safe.t;
  response : Llm_types.api_response;
}

(* ================================================================ *)
(* Concurrency diagnostics (observability only, no throttling)       *)
(* ================================================================ *)

let max_concurrent_llm =
  Llm_types.int_of_env_default "MASC_MAX_CONCURRENT_LLM" ~default:8 ~min_v:1
    ~max_v:128

let inflight = Atomic.make 0

let llm_semaphore_available () = max 0 (max_concurrent_llm - Atomic.get inflight)
let llm_permits_in_use () = Atomic.get inflight

let with_inflight f =
  ignore (Atomic.fetch_and_add inflight 1);
  Fun.protect ~finally:(fun () ->
      ignore (Atomic.fetch_and_add inflight (-1)))
    f

(* ================================================================ *)
(* Cascade policy                                                    *)
(* ================================================================ *)

let default_config_path () : string option =
  let candidates =
    let cwd_candidate = Filename.concat (Sys.getcwd ()) "config/llm_cascade.json" in
    let me_root_candidate =
      let me =
        Sys.getenv_opt "ME_ROOT"
        |> Option.value
             ~default:(Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp")
      in
      Filename.concat
        (Filename.concat me "workspace/yousleepwhen/masc-mcp")
        "config/llm_cascade.json"
    in
    [ cwd_candidate; me_root_candidate ]
  in
  List.find_opt Sys.file_exists candidates

let label provider model =
  if model = "" then None else Some (Printf.sprintf "%s:%s" provider model)

let labels_of pairs = List.filter_map (fun (p, m) -> label p m) pairs

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
  | "lodge_comment" | "lodge_agent_match" ->
      llama_glm
  | "gardener_spawn" | "gardener_retire" -> llama_glm
  | "classification" | "context_router" | "capability_match" -> llama_glm
  | "tom" -> llama_glm
  | "verifier" | "code_swarm_verify" | "code_swarm" -> llama_glm
  | "keeper_autonomy" | "keeper_proactive" | "keeper_deliberation"
  | "keeper_reply" | "keeper_social" | "keeper_turn" ->
      llama_glm
  | "routing_judge" | "team_router" -> llama_glm
  | "chain_llm" -> llama_glm
  | "autoresearch" -> llama_glm
  | "trpg_intent" -> llama_glm
  | "briefing" ->
      (if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else [])
      @ labels_of
          [ ("glm", glm_flash); ("gemini", Env_config.Gemini.flash_model) ]
      @ [ "glm:auto" ]
  | "governance_judge" | "operator_judge" -> llama_glm
  | "walph" -> llama_glm
  | "auto_responder_claude" ->
      labels_of [ ("claude", Env_config.Claude.default_model) ] @ [ "glm:auto" ]
  | "auto_responder_gemini" ->
      labels_of [ ("gemini", Env_config.Gemini.flash_model) ] @ [ "glm:auto" ]
  | "auto_responder_glm" ->
      labels_of [ ("glm", glm_model) ] @ [ "glm:auto" ]
  | "auto_responder" -> llama_glm
  | "spawn_glm" ->
      labels_of [ ("glm", glm_model); ("glm", glm_flash) ] @ [ "glm:auto" ]
  | "mitosis" -> llama_glm
  | "topic_extraction" -> llama_glm
  | _ -> llama_glm

let get_cascade ?(config_path = "") ~cascade_name () : Llm_types.model_spec list =
  let defaults = default_model_strings ~cascade_name in
  let configured =
    if String.length config_path > 0 then
      let from_file =
        Llm_provider.Cascade_config.load_profile ~config_path ~name:cascade_name
      in
      if from_file <> [] then from_file else defaults
    else
      match default_config_path () with
      | Some path ->
          let from_file =
            Llm_provider.Cascade_config.load_profile ~config_path:path
              ~name:cascade_name
          in
          if from_file <> [] then from_file else defaults
      | None -> defaults
  in
  let specs = Llm_types.available_model_specs_of_strings configured in
  if specs <> [] then specs
  else
    let fallback = default_model_strings ~cascade_name in
    if configured = fallback then (
      Log.Llm.warn "cascade %s has no callable models from defaults" cascade_name;
      [])
    else (
      Log.Llm.warn
        "cascade %s configured models unavailable; retrying built-in defaults"
        cascade_name;
      Llm_types.available_model_specs_of_strings fallback)

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let call_state ~cascade_name ~temperature ~max_tokens :
    Agent_sdk.Types.agent_state =
  {
    Agent_sdk.Types.config =
      {
        Agent_sdk.Types.default_config with
        name = "masc-named-cascade";
        model = "named-cascade:" ^ cascade_name;
        system_prompt = None;
        max_tokens;
        max_turns = 1;
        temperature = Some temperature;
      };
    messages = [];
    turn_count = 0;
    usage = Agent_sdk.Types.empty_usage;
  }

let effective_config_path ~config_path =
  if String.length config_path > 0 then Some config_path else default_config_path ()

let named_cascade ~cascade_name ~config_path =
  Agent_sdk.Api.named_cascade ?config_path:(effective_config_path ~config_path)
    ~name:cascade_name ~defaults:(default_model_strings ~cascade_name) ()

let response_model (response : Llm_types.api_response) =
  response.Llm_provider.Types.model

let response_text (response : Llm_types.api_response) =
  Llm_types.text_of_response response

let accept_with_logging ~cascade_name ~accept (response : Llm_types.api_response) =
  if accept response then true
  else (
    Log.Llm.warn "named cascade %s rejected response from model=%s" cascade_name
      (response_model response);
    false)

let extract_json_from_response (raw : string) : (Yojson.Safe.t, string) result =
  let trimmed = String.trim raw in
  match Yojson.Safe.from_string trimmed with
  | json -> Ok json
  | exception Yojson.Json_error _ ->
      let re_fenced = Str.regexp {|```\(json\)?\n?\(.*\)\n?```|} in
      if Str.string_match re_fenced trimmed 0 then
        let inner = Str.matched_group 2 trimmed in
        match Yojson.Safe.from_string (String.trim inner) with
        | json -> Ok json
        | exception Yojson.Json_error _ ->
            Error "JSON parse failed after fence extraction"
      else
        let len = String.length trimmed in
        let rec find_brace i =
          if i >= len then Error "no JSON object found in response"
          else if trimmed.[i] = '{' then
            let depth = ref 0 in
            let in_string = ref false in
            let escape = ref false in
            let j = ref i in
            let found = ref false in
            while !j < len && not !found do
              let c = trimmed.[!j] in
              if !escape then escape := false
              else if c = '\\' && !in_string then escape := true
              else if c = '"' then in_string := not !in_string
              else if not !in_string then (
                if c = '{' then incr depth
                else if c = '}' then (
                  decr depth;
                  if !depth = 0 then found := true));
              if not !found then incr j
            done;
            if !found then
              let substr = String.sub trimmed i (!j - i + 1) in
              match Yojson.Safe.from_string substr with
              | json -> Ok json
              | exception Yojson.Json_error msg ->
                  Error (Printf.sprintf "extracted JSON parse failed: %s" msg)
            else Error "unmatched braces in response"
          else find_brace (i + 1)
        in
        find_brace 0

let json_response_is_valid (response : Llm_types.api_response) =
  match extract_json_from_response (response_text response) with
  | Ok _ -> true
  | Error _ -> false

(* ================================================================ *)
(* Core                                                              *)
(* ================================================================ *)

let complete_cascade ~cascade_name ~messages ?(config_path = "")
    ?(temperature = 0.3) ?(timeout_sec = 30) ?(max_tokens = 500)
    ?(accept = fun _ -> true) ?tools () =
  let env = Masc_eio_env.get () in
  let state = call_state ~cascade_name ~temperature ~max_tokens in
  let named = named_cascade ~cascade_name ~config_path in
  let defaults = default_model_strings ~cascade_name in
  let tool_count =
    match tools with Some ts -> List.length ts | None -> 0
  in
  Log.Llm.debug
    "named cascade call cascade=%s timeout_sec=%d max_tokens=%d tools=%d defaults=%s"
    cascade_name timeout_sec max_tokens tool_count
    (String.concat "," defaults);
  with_inflight (fun () ->
      match
        Agent_sdk.Api.create_message_named ~sw:env.sw ~net:env.net
          ?clock:env.clock ~named_cascade:named ~config:state ~messages ?tools
          ~accept:(accept_with_logging ~cascade_name ~accept) ~timeout_sec ()
      with
      | Ok response ->
          Log.Llm.debug "named cascade success cascade=%s model=%s tools=%d"
            cascade_name (response_model response) tool_count;
          Ok response
      | Error err ->
          let message = Agent_sdk.Error.to_string err in
          Log.Llm.warn "named cascade failure cascade=%s tools=%d: %s"
            cascade_name tool_count message;
          Error (Printf.sprintf "[cascade] %s: %s" cascade_name message))

let call ~cascade_name ~prompt ?(config_path = "") ?(temperature = 0.3)
    ?(timeout_sec = 30) ?(max_tokens = 500) ?(accept = fun _ -> true)
    ?system () =
  let messages : Llm_provider.Types.message list =
    (match system with
    | Some s -> [ Llm_provider.Types.system_msg s ]
    | None -> [])
    @ [ Llm_provider.Types.user_msg prompt ]
  in
  let t0 = Time_compat.now () in
  match
    complete_cascade ~cascade_name ~messages ~config_path ~temperature
      ~timeout_sec ~max_tokens ~accept ()
  with
  | Ok response ->
      let duration_ms = int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
      Ok
        {
          response = response_text response;
          llm_used = response_model response;
          duration_ms;
        }
  | Error _ as err -> err

let call_raw ~cascade_name ~prompt ?(config_path = "") ?(temperature = 0.3)
    ?(timeout_sec = 30) ?(max_tokens = 500) ?(accept = fun _ -> true)
    ?system () =
  let messages : Llm_provider.Types.message list =
    (match system with
    | Some s -> [ Llm_provider.Types.system_msg s ]
    | None -> [])
    @ [ Llm_provider.Types.user_msg prompt ]
  in
  complete_cascade ~cascade_name ~messages ~config_path ~temperature
    ~timeout_sec ~max_tokens ~accept ()

let call_json ~cascade_name ~prompt ?(config_path = "") ?(temperature = 0.3)
    ?(timeout_sec = 30) ?(max_tokens = 500) ?system () =
  match
    call_raw ~cascade_name ~prompt ~config_path ~temperature ~timeout_sec
      ~max_tokens ~accept:json_response_is_valid ?system ()
  with
  | Error _ as err -> err
  | Ok response -> (
      match extract_json_from_response (response_text response) with
      | Ok json -> Ok { json; response }
      | Error parse_error ->
          Log.Llm.warn
            "named cascade %s produced unparseable JSON after acceptance: %s"
            cascade_name parse_error;
          Error (Printf.sprintf "[cascade] %s: %s" cascade_name parse_error))

let call_with_tools ~cascade_name ~messages ?(config_path = "")
    ?(temperature = 0.3) ?(timeout_sec = 30) ?(max_tokens = 500)
    ?(accept = fun _ -> true) ?tools () =
  complete_cascade ~cascade_name ~messages ~config_path ~temperature
    ~timeout_sec ~max_tokens ~accept ?tools ()
