type runtime_kind =
  | Local
  | Direct_api
  | Cli_agent

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
  | Cli_cached_login
  | Vertex_adc of {
      project_env : string;
      location_env : string;
    }

type prompt_transport =
  | Prompt_stdin
  | Prompt_arg of string

type output_contract =
  | Human_stdout
  | Json_stdout

type adapter = {
  canonical_name : string;
  runtime_kind : runtime_kind;
  provider_family : provider_family;
  auth_mode : auth_mode;
  aliases : string list;
}

type cli_adapter = {
  meta : adapter;
  command : string;
  prompt_transport : prompt_transport;
  output_contract : output_contract;
  default_allowed_mcp_servers : string list;
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
  | Cli_agent -> "cli_agent"

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
  | Cli_cached_login -> "cli_cached_login"
  | Vertex_adc { project_env; location_env } ->
      "vertex_adc:" ^ project_env ^ ":" ^ location_env

let string_of_prompt_transport = function
  | Prompt_stdin -> "stdin"
  | Prompt_arg flag -> "arg:" ^ flag

let string_of_output_contract = function
  | Human_stdout -> "human_stdout"
  | Json_stdout -> "json_stdout"

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

let cli_adapters =
  [
    {
      meta =
        {
          canonical_name = "claude";
          runtime_kind = Cli_agent;
          provider_family = Claude_family;
          auth_mode = Cli_cached_login;
          aliases = [ "claude"; "claude-code" ];
        };
      command = "claude --output-format json -p";
      prompt_transport = Prompt_stdin;
      output_contract = Json_stdout;
      default_allowed_mcp_servers = [ "masc" ];
    };
    {
      meta =
        {
          canonical_name = "codex";
          runtime_kind = Cli_agent;
          provider_family = OpenAI_family;
          auth_mode = Cli_cached_login;
          aliases = [ "codex"; "codex-cli" ];
        };
      command = "codex exec --json";
      prompt_transport = Prompt_stdin;
      output_contract = Json_stdout;
      default_allowed_mcp_servers = [ "masc" ];
    };
    {
      meta =
        {
          canonical_name = "gemini";
          runtime_kind = Cli_agent;
          provider_family = Gemini_family;
          auth_mode = Cli_cached_login;
          aliases = [ "gemini"; "gemini-cli" ];
        };
      command = "gemini --yolo --output-format json";
      prompt_transport = Prompt_arg "-p";
      output_contract = Json_stdout;
      default_allowed_mcp_servers = [ "masc" ];
    };
  ]

let resolve_adapter adapters label =
  let normalized = normalize_label label in
  List.find_opt
    (fun adapter ->
      List.exists (fun alias -> normalize_label alias = normalized) adapter.aliases)
    adapters

let resolve_direct_adapter label = resolve_adapter direct_adapters label
let resolve_cli_adapter label =
  let normalized = normalize_label label in
  List.find_opt
    (fun adapter ->
      List.exists
        (fun alias -> normalize_label alias = normalized)
        adapter.meta.aliases)
    cli_adapters

let resolve_cli_canonical_name label =
  Option.map (fun adapter -> adapter.meta.canonical_name) (resolve_cli_adapter label)

let default_cli_agent_name () = "claude"

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
  match Sys.getenv_opt "MASC_DEFAULT_CASCADE" with
  | Some raw ->
      let labels = split_csv_nonempty raw in
      if labels = [] then
        Error "MASC_DEFAULT_CASCADE is set but empty"
      else
        Ok (List.hd labels)
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
         if env_present "ZAI_API_KEY" then
           Some (Printf.sprintf "glm:%s" Env_config.Llm.default_model)
         else None;
         if gemini_direct_available () then
           Some (Printf.sprintf "gemini:%s" Env_config.Gemini.default_model)
         else None;
         if env_present "ANTHROPIC_API_KEY" then
           Some (Printf.sprintf "claude:%s" Env_config.Claude.default_model)
         else None;
         if env_present "OPENAI_API_KEY" then
           Some (Printf.sprintf "openai:%s" Env_config.OpenAI.default_model)
         else None;
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
         if env_present "ZAI_API_KEY" then
           Some (Printf.sprintf "glm:%s" Env_config.Llm.default_model)
         else None;
         if gemini_direct_available () then
           Some (Printf.sprintf "gemini:%s" Env_config.Gemini.flash_model)
         else None;
         if env_present "ANTHROPIC_API_KEY" then
           Some (Printf.sprintf "claude:%s" Env_config.Claude.default_model)
         else None;
         if env_present "OPENAI_API_KEY" then
           Some (Printf.sprintf "openai:%s" Env_config.OpenAI.default_model)
         else None;
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
