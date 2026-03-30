type runtime_kind =
  | Local
  | Direct_api

type provider_family =
  | Claude_family
  | OpenAI_family
  | Gemini_family
  | Glm_family
  | Llama_family
  | OpenRouter_family
  | Custom_family of string

type auth_mode =
  | No_auth
  | Api_key of string
  | Vertex_adc of {
      project_env : string;
      location_env : string;
    }

type voice_transport =
  | Voice_openai_compat
  | Voice_elevenlabs_direct
  | Voice_mcp

type adapter = {
  canonical_name : string;
  runtime_kind : runtime_kind;
  provider_family : provider_family;
  auth_mode : auth_mode;
  aliases : string list;
}

type voice_adapter = {
  canonical_name : string;
  transport : voice_transport;
  provider_family : provider_family;
  auth_mode : auth_mode;
  aliases : string list;
}

type voice_http_request = {
  url : string;
  headers : (string * string) list;
  body_json : Yojson.Safe.t;
}

type gemini_direct_auth =
  | Gemini_vertex_adc of {
      project : string;
      location : string;
    }
  | Gemini_api_key
  | Gemini_auth_missing of string

let google_cloud_project_env = "GOOGLE_CLOUD_PROJECT"
let google_cloud_location_env = "GOOGLE_CLOUD_LOCATION"

let string_of_runtime_kind = function
  | Local -> "local"
  | Direct_api -> "direct_api"

let string_of_provider_family = function
  | Claude_family -> "claude"
  | OpenAI_family -> "openai"
  | Gemini_family -> "gemini"
  | Glm_family -> "glm"
  | Llama_family -> "llama"
  | OpenRouter_family -> "openrouter"
  | Custom_family name -> "custom:" ^ name

let string_of_auth_mode = function
  | No_auth -> "none"
  | Api_key env_name -> "api_key:" ^ env_name
  | Vertex_adc { project_env; location_env } ->
      "vertex_adc:" ^ project_env ^ ":" ^ location_env

let string_of_voice_transport = function
  | Voice_openai_compat -> "openai_compat"
  | Voice_elevenlabs_direct -> "elevenlabs_direct"
  | Voice_mcp -> "voice_mcp"

let normalize_label label = String.trim label |> String.lowercase_ascii

let direct_adapters =
  [
    {
      canonical_name = "llama";
      runtime_kind = Local;
      provider_family = Llama_family;
      auth_mode = No_auth;
      aliases = [ "llama"; "llama.cpp"; "llamacpp" ];
    };
    {
      canonical_name = "claude-api";
      runtime_kind = Direct_api;
      provider_family = Claude_family;
      auth_mode = Api_key "ANTHROPIC_API_KEY";
      aliases = [ "claude-api"; "claude"; "anthropic" ];
    };
    {
      canonical_name = "codex-api";
      runtime_kind = Direct_api;
      provider_family = OpenAI_family;
      auth_mode = Api_key "OPENAI_API_KEY";
      aliases = [ "codex-api"; "openai" ];
    };
    {
      canonical_name = "gemini-api";
      runtime_kind = Direct_api;
      provider_family = Gemini_family;
      auth_mode =
        Vertex_adc
          {
            project_env = google_cloud_project_env;
            location_env = google_cloud_location_env;
          };
      aliases = [ "gemini-api"; "gemini"; "google" ];
    };
    {
      canonical_name = "glm";
      runtime_kind = Direct_api;
      provider_family = Glm_family;
      auth_mode = Api_key "ZAI_API_KEY";
      aliases = [ "glm"; "glm_cloud"; "zai" ];
    };
    {
      canonical_name = "openrouter";
      runtime_kind = Direct_api;
      provider_family = OpenRouter_family;
      auth_mode = Api_key "OPENROUTER_API_KEY";
      aliases = [ "openrouter" ];
    };
  ]

let voice_openai_compat_adapter =
  {
    canonical_name = "voice-openai-compat";
    transport = Voice_openai_compat;
    provider_family = OpenAI_family;
    auth_mode = No_auth;
    aliases =
      [ "voice-openai-compat"; "openai_compat"; "openai"; "railway-elevenlabs-proxy" ];
  }

let voice_elevenlabs_direct_adapter =
  {
    canonical_name = "elevenlabs-direct";
    transport = Voice_elevenlabs_direct;
    provider_family = Custom_family "elevenlabs";
    auth_mode = Api_key "ELEVENLABS_API_KEY";
    aliases = [ "elevenlabs-direct"; "elevenlabs"; "tts-elevenlabs" ];
  }

let voice_mcp_adapter =
  {
    canonical_name = "voice-mcp";
    transport = Voice_mcp;
    provider_family = Custom_family "voice_mcp";
    auth_mode = No_auth;
    aliases = [ "voice-mcp"; "voice_mcp"; "mcp"; "local-voice-mcp" ];
  }

let voice_adapters =
  [
    voice_openai_compat_adapter;
    voice_elevenlabs_direct_adapter;
    voice_mcp_adapter;
  ]

let resolve_direct_adapter label =
  let normalized = normalize_label label in
  List.find_opt
    (fun (adapter : adapter) ->
      List.exists (fun alias -> normalize_label alias = normalized) adapter.aliases)
    direct_adapters

let resolve_direct_canonical_name label =
  Option.map (fun (adapter : adapter) -> adapter.canonical_name) (resolve_direct_adapter label)

let resolve_voice_adapter label =
  let normalized = normalize_label label in
  List.find_opt
    (fun (adapter : voice_adapter) ->
      List.exists (fun alias -> normalize_label alias = normalized) adapter.aliases)
    voice_adapters

let voice_adapter_labels (adapter : voice_adapter) =
  adapter.canonical_name
  :: string_of_voice_transport adapter.transport
  :: adapter.aliases

let voice_adapter_for_endpoint_kind = function
  | Voice_config.Openai_compat -> voice_openai_compat_adapter
  | Voice_config.Elevenlabs_direct -> voice_elevenlabs_direct_adapter
  | Voice_config.Voice_mcp -> voice_mcp_adapter

let voice_adapter_for_endpoint (endpoint : Voice_config.endpoint) =
  match resolve_voice_adapter endpoint.id with
  | Some adapter -> adapter
  | None -> voice_adapter_for_endpoint_kind endpoint.kind

let voice_endpoint_matches_provider_label label (endpoint : Voice_config.endpoint) =
  let normalized = normalize_label label in
  let adapter = voice_adapter_for_endpoint endpoint in
  let candidates =
    endpoint.id
    :: Voice_config.string_of_endpoint_kind endpoint.kind
    :: voice_adapter_labels adapter
  in
  List.exists (fun candidate -> String.equal (normalize_label candidate) normalized) candidates

let select_voice_endpoints ?provider (endpoints : Voice_config.endpoint list) =
  let endpoints =
    List.filter (fun (endpoint : Voice_config.endpoint) -> endpoint.enabled) endpoints
  in
  match provider with
  | Some label when String.trim label <> "" ->
      List.filter (voice_endpoint_matches_provider_label label) endpoints
  | _ -> endpoints

let voice_auth_env_name ?endpoint_api_key_env (adapter : voice_adapter) =
  match endpoint_api_key_env with
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed <> "" then Some trimmed
      else (
        match adapter.auth_mode with
        | Api_key env_name -> Some env_name
        | _ -> None)
  | None -> (
      match adapter.auth_mode with
      | Api_key env_name -> Some env_name
      | _ -> None)

let voice_endpoint_auth_env_name (endpoint : Voice_config.endpoint) =
  let adapter = voice_adapter_for_endpoint endpoint in
  voice_auth_env_name ?endpoint_api_key_env:endpoint.api_key_env adapter

let ends_with ~suffix s =
  let slen = String.length s in
  let plen = String.length suffix in
  slen >= plen && String.sub s (slen - plen) plen = suffix

let compose_voice_endpoint_url ~base_url ~path =
  let base_uri = Uri.of_string base_url in
  let base_path = Uri.path base_uri in
  let base_path =
    if base_path = "" then "/"
    else if ends_with ~suffix:"/" base_path && String.length base_path > 1 then
      String.sub base_path 0 (String.length base_path - 1)
    else base_path
  in
  let final_path =
    if path = "/mcp" then
      if ends_with ~suffix:"/mcp" base_path then base_path
      else if base_path = "/" then "/mcp"
      else base_path ^ "/mcp"
    else if path = "/health" then
      if ends_with ~suffix:"/health" base_path then base_path
      else if ends_with ~suffix:"/mcp" base_path then
        String.sub base_path 0 (String.length base_path - 4) ^ "/health"
      else if base_path = "/" then "/health"
      else base_path ^ "/health"
    else if base_path = "/" then path
    else base_path ^ path
  in
  Uri.with_path base_uri final_path |> Uri.to_string

let voice_session_endpoint_result (config : Voice_config.t) =
  match Voice_config.select_endpoint config.session.endpoints with
  | Some endpoint ->
      let adapter = voice_adapter_for_endpoint endpoint in
      if adapter.transport = Voice_mcp then Ok endpoint
      else
        Error
          (Printf.sprintf "session endpoint %s must use kind=voice_mcp" endpoint.id)
  | None -> Error "no configured session endpoint"

let voice_session_mcp_url_of_endpoint (endpoint : Voice_config.endpoint) =
  let adapter = voice_adapter_for_endpoint endpoint in
  if adapter.transport <> Voice_mcp then
    Error (Printf.sprintf "session endpoint %s must use voice_mcp transport" endpoint.id)
  else
    match endpoint.mcp_url with
    | Some url -> Ok url
    | None -> (
        match endpoint.base_url with
        | Some base_url -> Ok (compose_voice_endpoint_url ~base_url ~path:"/mcp")
        | None -> Ok "http://127.0.0.1:8936/mcp")

let voice_session_health_url_of_endpoint (endpoint : Voice_config.endpoint) =
  let adapter = voice_adapter_for_endpoint endpoint in
  if adapter.transport <> Voice_mcp then
    Error (Printf.sprintf "session endpoint %s must use voice_mcp transport" endpoint.id)
  else
    match endpoint.health_url with
    | Some url -> Ok url
    | None -> (
        match endpoint.base_url with
        | Some base_url -> Ok (compose_voice_endpoint_url ~base_url ~path:"/health")
        | None -> Ok "http://127.0.0.1:8936/health")

let voice_transport_supports_http_tts (adapter : voice_adapter) =
  match adapter.transport with
  | Voice_openai_compat | Voice_elevenlabs_direct -> true
  | Voice_mcp -> false

let voice_endpoint_supports_http_tts (endpoint : Voice_config.endpoint) =
  voice_adapter_for_endpoint endpoint
  |> voice_transport_supports_http_tts

let default_elevenlabs_base_url = "https://api.elevenlabs.io/v1"

let normalize_base_url value =
  let trimmed = String.trim value in
  if String.length trimmed > 1 && trimmed.[String.length trimmed - 1] = '/' then
    String.sub trimmed 0 (String.length trimmed - 1)
  else
    trimmed

let voice_endpoint_base_url (endpoint : Voice_config.endpoint) =
  match voice_adapter_for_endpoint endpoint with
  | { transport = Voice_elevenlabs_direct; _ } -> (
      match endpoint.base_url with
      | Some value -> Some (normalize_base_url value)
      | None -> Some default_elevenlabs_base_url)
  | _ -> Option.map normalize_base_url endpoint.base_url

let elevenlabs_voice_id voice =
  match String.trim voice with
  | "Sarah" -> "EXAVITQu4vr4xnSDxMaL"
  | "Roger" -> "CwhRBWXzGAHq8TQ4Fs17"
  | "George" -> "JBFqnCBsd6RMkjVDRZzb"
  | "Laura" -> "FGY2WhTYpPnrIDTdsKH5"
  | "" -> "21m00Tcm4TlvDq8ikWAM"
  | value -> value

let voice_http_request_for_tts (endpoint : Voice_config.endpoint) ~api_key
    ~message ~voice ~model ~(tuning : Voice_config.voice_tuning) =
  let adapter = voice_adapter_for_endpoint endpoint in
  match voice_endpoint_base_url endpoint, adapter.transport with
  | None, _ ->
      Error
        (Printf.sprintf "voice config endpoint %s missing base_url" endpoint.id)
  | Some _, Voice_mcp ->
      Error
        (Printf.sprintf
           "voice config endpoint %s uses voice_mcp and cannot build HTTP TTS request"
           endpoint.id)
  | Some base_url, Voice_openai_compat ->
      let headers =
        [ ("Content-Type", "application/json"); ("Accept", "audio/mpeg") ]
        @
        if api_key = "" then [] else [ ("Authorization", "Bearer " ^ api_key) ]
      in
      let body_json =
        `Assoc
          [
            ("input", `String message);
            ("voice", `String voice);
            ("model", `String model);
            ("response_format", `String "mp3");
            ( "voice_settings",
              `Assoc
                [
                  ("stability", `Float tuning.stability);
                  ("similarity_boost", `Float tuning.similarity_boost);
                  ("style", `Float tuning.style);
                ] );
          ]
      in
      Ok { url = base_url ^ "/audio/speech"; headers; body_json }
  | Some base_url, Voice_elevenlabs_direct ->
      let headers =
        [
          ("xi-api-key", api_key);
          ("Content-Type", "application/json");
          ("Accept", "audio/mpeg");
        ]
      in
      let body_json =
        `Assoc
          [
            ("text", `String message);
            ("model_id", `String model);
            ( "voice_settings",
              `Assoc
                [
                  ("stability", `Float tuning.stability);
                  ("similarity_boost", `Float tuning.similarity_boost);
                  ("style", `Float tuning.style);
                ] );
          ]
      in
      Ok
        {
          url =
            Printf.sprintf "%s/text-to-speech/%s" base_url
              (elevenlabs_voice_id voice);
          headers;
          body_json;
        }

let default_cli_agent_name () = Env_config_runtime.Cli.default_agent

let split_csv_nonempty raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let nonempty_env name =
  match Sys.getenv_opt name with
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let env_present name = Option.is_some (nonempty_env name)

let dedupe_keep_order items =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item then
        false
      else (
        Hashtbl.add seen item ();
        true))
    items

let bare_ollama_migration_message () =
  "Bare `ollama` is no longer supported. Use `default` for normal selection, or `llama:<model>` / another explicit provider:model label as an override."

let is_bare_ollama_label label =
  String.equal (normalize_label label) "ollama"

let explicit_llama_model_id_result () =
  match nonempty_env "LLAMA_DEFAULT_MODEL" with
  | Some model_id -> Ok model_id
  | None -> (
      match
        ( nonempty_env "MASC_DEFAULT_PROVIDER",
          nonempty_env "MASC_DEFAULT_MODEL" )
      with
      | Some provider, Some model_id
        when String.equal (String.lowercase_ascii provider) "llama" ->
          Ok model_id
      | _ ->
          Error
            "LLAMA_DEFAULT_MODEL is not set; configure LLAMA_DEFAULT_MODEL or MASC_DEFAULT_PROVIDER=llama with MASC_DEFAULT_MODEL")

let explicit_llama_model_id () =
  match explicit_llama_model_id_result () with
  | Ok model_id -> model_id
  | Error msg -> invalid_arg msg

let explicit_llama_model_label_result () =
  Result.map (fun model_id -> "llama:" ^ model_id) (explicit_llama_model_id_result ())

let explicit_llama_model_label () =
  match explicit_llama_model_label_result () with
  | Ok label -> label
  | Error msg -> invalid_arg msg

let gemini_direct_available () =
  env_present google_cloud_project_env || env_present "GEMINI_API_KEY"

let configured_default_model_label_result () =
  match Env_config.Model_defaults.default_cascade_opt () with
  | Some raw ->
      let labels = split_csv_nonempty raw in
      (match labels with
       | first :: _ -> Ok first
       | [] -> Error "MASC_DEFAULT_CASCADE is set but empty")
  | None -> (
      match
        ( nonempty_env "MASC_DEFAULT_PROVIDER",
          nonempty_env "MASC_DEFAULT_MODEL" )
      with
      | Some provider, Some model_id -> Ok (provider ^ ":" ^ model_id)
      | Some _, None ->
          Error
            "MASC_DEFAULT_MODEL is required when MASC_DEFAULT_PROVIDER is set"
      | None, Some _ ->
          Error
            "MASC_DEFAULT_PROVIDER is required when MASC_DEFAULT_MODEL is set"
      | None, None -> Error "No explicit default model configured")

let configured_verifier_model_label_result () =
  match nonempty_env "MASC_DEFAULT_VERIFIER_MODEL" with
  | Some label -> Ok label
  | None -> configured_default_model_label_result ()

let provider_model_label provider model =
  if model = "" then None
  else Some (Printf.sprintf "%s:%s" provider model)

(** Centralized family → model label mapping.
    Vendor-specific env var resolution happens here only. *)
let default_model_label_for_family = function
  | Claude_family ->
      let m = Env_config.Claude.default_model in
      if m = "" then Error "No Claude model configured (MASC_CLAUDE_DEFAULT_MODEL)"
      else Ok ("claude:" ^ m)
  | Gemini_family ->
      let m = Env_config.Gemini.default_model in
      if m = "" then Error "No Gemini model configured (MASC_GEMINI_DEFAULT_MODEL)"
      else Ok ("gemini:" ^ m)
  | OpenAI_family ->
      let m = Env_config.OpenAI.default_model in
      if m = "" then Error "No OpenAI model configured (MASC_OPENAI_DEFAULT_MODEL)"
      else Ok ("openai:" ^ m)
  | Glm_family ->
      Ok "glm:auto"
  | Llama_family ->
      explicit_llama_model_label_result ()
  | OpenRouter_family ->
      Error "OpenRouter requires explicit runtime_model"
  | Custom_family _ ->
      Error "Custom provider requires explicit runtime_model"

let preferred_execution_model_labels () =
  dedupe_keep_order
    (List.filter_map
       Fun.id
       [
         (match configured_default_model_label_result () with
         | Ok label -> Some label
         | Error _ -> None);
         (match explicit_llama_model_label_result () with
         | Ok label -> Some label
         | Error _ -> None);
         (* GLM: even with empty model config, include as "glm:" —
            the GLM provider selects the model at runtime. *)
         (if env_present "ZAI_API_KEY" then
           Some "glm:auto"
         else None);
         (* Non-GLM providers: only include when model is explicitly configured.
            APIs require a model field, so empty model = skip. *)
         (if gemini_direct_available () then
           provider_model_label "gemini" Env_config.Gemini.default_model
         else None);
         (if env_present "ANTHROPIC_API_KEY" then
           provider_model_label "claude" Env_config.Claude.default_model
         else None);
         (if env_present "OPENAI_API_KEY" then
           provider_model_label "openai" Env_config.OpenAI.default_model
         else None);
       ])

let preferred_verifier_model_labels () =
  dedupe_keep_order
    (List.filter_map
       Fun.id
       [
         (match configured_verifier_model_label_result () with
         | Ok label -> Some label
         | Error _ -> None);
         (match explicit_llama_model_label_result () with
         | Ok label -> Some label
         | Error _ -> None);
         (if env_present "ZAI_API_KEY" then
           Some "glm:auto"
         else None);
         (if gemini_direct_available () then
           provider_model_label "gemini" Env_config.Gemini.flash_model
         else None);
         (if env_present "ANTHROPIC_API_KEY" then
           provider_model_label "claude" Env_config.Claude.default_model
         else None);
         (if env_present "OPENAI_API_KEY" then
           provider_model_label "openai" Env_config.OpenAI.default_model
         else None);
       ])

let default_model_labels_result () =
  let labels = preferred_execution_model_labels () in
  if labels = [] then
    Error
      "No default model configured; set LLAMA_DEFAULT_MODEL, MASC_DEFAULT_CASCADE, MASC_DEFAULT_PROVIDER/MASC_DEFAULT_MODEL, or a supported cloud provider credential"
  else Ok labels

let default_model_label_result () =
  match default_model_labels_result () with
  | Ok (first :: _) -> Ok first
  | Ok [] -> Error "No default model configured"
  | Error _ as e -> e

let provider_prefix_of_label_result label =
  let normalized = String.trim label in
  match String.index_opt normalized ':' with
  | Some idx when idx > 0 ->
      Ok
        (String.sub normalized 0 idx |> String.trim |> String.lowercase_ascii)
  | _ ->
      Error
        (Printf.sprintf
           "Default model label must be provider:model, got: %s"
           normalized)

let default_model_provider_prefix_result () =
  match default_model_label_result () with
  | Ok label -> provider_prefix_of_label_result label
  | Error _ as e -> e

let default_model_override_label_result model_id =
  let model_id = String.trim model_id in
  if model_id = "" then
    Error "default:<model> requires a non-empty model id"
  else
    match default_model_provider_prefix_result () with
    | Ok provider -> Ok (provider ^ ":" ^ model_id)
    | Error _ as e -> e

let default_local_model_label () =
  match default_model_label_result () with
  | Ok label -> label
  | Error msg -> invalid_arg msg

let vertex_location () =
  match Sys.getenv_opt google_cloud_location_env with
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then "global" else trimmed
  | None -> "global"

let resolve_gemini_direct_auth () =
  match Sys.getenv_opt google_cloud_project_env with
  | Some raw when String.trim raw <> "" ->
      Gemini_vertex_adc
        {
          project = String.trim raw;
          location = vertex_location ();
        }
  | _ -> (
      match Sys.getenv_opt "GEMINI_API_KEY" with
      | Some raw when String.trim raw <> "" -> Gemini_api_key
      | _ ->
          Gemini_auth_missing
            "Gemini auth unavailable; set GOOGLE_CLOUD_PROJECT for Vertex ADC or GEMINI_API_KEY")

let gemini_vertex_openai_base_url ~project ~location =
  Printf.sprintf
    "https://aiplatform.googleapis.com/v1/projects/%s/locations/%s/endpoints/openapi"
    project location
