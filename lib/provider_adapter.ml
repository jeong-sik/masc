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
  | Ollama_family
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
  | Ollama_family -> "ollama"
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
      canonical_name = "ollama";
      runtime_kind = Local;
      provider_family = Ollama_family;
      auth_mode = No_auth;
      aliases = [ "ollama" ];
    };
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
