type runtime_kind =
  | Local
  | Cli_agent
  | Direct_api

type auth_mode =
  | No_auth
  | Cli_cached_login
  | Api_key of string
  | Vertex_adc of {
      project_env : string;
      location_env : string;
    }

type model_family =
  | Generic
  | Glm_general
  | Glm_coding
  | Kimi_api_family

type auto_models_source =
  | No_auto_models
  | Env_csv_or_default of {
      env_var : string;
      defaults : string list;
      prefer_default_model_env : bool;
    }
  | Zai_general_auto_models
  | Zai_coding_auto_models

type reporting_policy =
  | Reported
  | Missing_by_design
  | Unknown

type model_policy = {
  default_model_env : string option;
  default_model_fallback : string option;
  auto_models : auto_models_source;
  expand_auto : bool;
  family : model_family;
}

type tool_policy = {
  supports_runtime_mcp_http_headers : bool;
}

type telemetry_policy = {
  usage_reporting : reporting_policy;
  runtime_reporting : reporting_policy;
}

type voice_transport =
  | Voice_openai_compat
  | Voice_elevenlabs_direct
  | Voice_mcp

type adapter = {
  canonical_name : string;
  runtime_kind : runtime_kind;
  auth_mode : auth_mode;
  aliases : string list;
  spawn_key : string option;       (** Key for CLI spawn lookup in Spawn.spawn_config_of_key. None = not spawnable via CLI. *)
  cascade_prefix : string;         (** MASC cascade model prefix (e.g. "claude", "openai").
                                       CONTRACT: Must match the prefix used by the local
                                       [Cascade_config] parser and Provider_registry-compatible
                                       model labels. This is the primary naming boundary between
                                       MASC routing and OAS provider configs. *)
  default_voice : string option;   (** Default TTS voice name. None = no voice assignment. *)
  endpoint_url : string option;    (** Base URL for the provider API. *)
  default_model_id : string option; (** Default model ID for the provider. *)
  model_policy : model_policy;
  tool_policy : tool_policy;
  telemetry_policy : telemetry_policy;
}

type voice_adapter = {
  canonical_name : string;
  transport : voice_transport;
  auth_mode : auth_mode;
  aliases : string list;
}

type voice_http_request = {
  url : string;
  headers : (string * string) list;
  body_json : Yojson.Safe.t;
}

type voice_stt_request = {
  url : string;
  headers : (string * string) list;
  form_fields : (string * string) list;
  file_field : string * string;  (** (field_name, file_path) *)
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
let gemini_api_key_env = "GEMINI_API_KEY"

let string_of_runtime_kind = function
  | Local -> "local"
  | Cli_agent -> "cli_agent"
  | Direct_api -> "direct_api"

let string_of_auth_mode = function
  | No_auth -> "none"
  | Cli_cached_login -> "cli_cached_login"
  | Api_key env_name -> "api_key:" ^ env_name
  | Vertex_adc { project_env; location_env } ->
      "vertex_adc:" ^ project_env ^ ":" ^ location_env

let string_of_voice_transport = function
  | Voice_openai_compat -> "openai_compat"
  | Voice_elevenlabs_direct -> "elevenlabs_direct"
  | Voice_mcp -> "voice_mcp"

let normalize_label label = String.trim label |> String.lowercase_ascii

let env_value_opt ?(getenv = Sys.getenv_opt) name =
  match getenv name with
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let csv_items raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let no_tool_http_headers = { supports_runtime_mcp_http_headers = false }
let runtime_mcp_http_headers = { supports_runtime_mcp_http_headers = true }
let telemetry_reported = { usage_reporting = Reported; runtime_reporting = Reported }
let telemetry_unknown = { usage_reporting = Unknown; runtime_reporting = Unknown }
let telemetry_usage_missing =
  { usage_reporting = Missing_by_design; runtime_reporting = Unknown }

(* ── Canonical adapter names (single definition point) ──────── *)

let cn_llama = "llama"
let cn_ollama = "ollama"
let cn_claude = "claude"
let cn_codex = "codex"
let cn_gemini = "gemini"
let cn_kimi = "kimi"
let cn_claude_api = "claude-api"
let cn_codex_api = "codex-api"
let cn_gemini_api = "gemini-api"
let cn_kimi_api = "kimi-api"
let cn_glm = "glm-api"
let cn_glm_coding_plan = "glm-coding-plan"
let cn_openrouter = "openrouter"

let kimi_api_key_envs = [ "KIMI_API_KEY_SB"; "KIMI_API_KEY" ]

let display_provider_name label =
  match normalize_label label with
  | "glm" | "glm-api" -> cn_glm
  | "glm-coding" | "glm-coding-plan" -> cn_glm_coding_plan
  | "kimi-api" -> cn_kimi
  | _ -> String.trim label

(** Default API base URLs — overridable via env var for proxying/testing.
    Where OAS Provider_registry already defines a default, query it rather
    than duplicating the literal here. *)

let env_url_or ~env ~default =
  match Sys.getenv_opt env with
  | Some url when String.trim url <> "" -> String.trim url
  | _ -> default

(** Query OAS Provider_registry for a provider's default base_url.
    Returns empty string if the provider is not known to OAS.
    This removes duplicated defaults between MASC and OAS. *)
let registry_default_base_url name =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry name with
  | Some entry -> entry.defaults.base_url
  | None -> ""

let anthropic_api_url () =
  env_url_or ~env:"ANTHROPIC_API_URL"
    ~default:(registry_default_base_url "claude")

let openai_api_url () =
  env_url_or ~env:"OPENAI_API_URL" ~default:"https://api.openai.com"

let openrouter_api_url () =
  env_url_or ~env:"OPENROUTER_API_URL"
    ~default:(registry_default_base_url "openrouter")

let gemini_generative_api_url () =
  env_url_or ~env:"GEMINI_API_URL"
    ~default:(registry_default_base_url "gemini")

let glm_api_url () =
  env_url_or ~env:"ZAI_BASE_URL" ~default:Llm_provider.Zai_catalog.general_base_url

let glm_coding_api_url () =
  env_url_or ~env:"ZAI_CODING_BASE_URL" ~default:Llm_provider.Zai_catalog.coding_base_url

let kimi_api_url () =
  env_url_or ~env:"KIMI_BASE_URL"
    ~default:(registry_default_base_url "kimi")
(** SSOT cascade prefix for local llama-server instances.
    All cascade label construction for local models must use this constant.
    Format: [local_cascade_prefix ^ ":" ^ model_id] → e.g. "llama:qwen3.5" *)
let local_cascade_prefix = cn_llama

(** Build a cascade model label for a local model.
    Single entry point — other modules must not concatenate prefix manually. *)
let make_local_label (model_id : string) : string =
  local_cascade_prefix ^ ":" ^ model_id

(** SSOT string form of OAS [provider_kind].
    This must stay aligned with [Provider_config.string_of_provider_kind]. *)
let string_of_provider_kind
    : Llm_provider.Provider_config.provider_kind -> string
  = Llm_provider.Provider_config.string_of_provider_kind

(** Map OAS [provider_kind] to the MASC adapter canonical name when adapter
    semantics are required.

    Note: [OpenAI_compat] maps to the direct cloud adapter [codex-api]; local
    llama remains an [OpenAI_compat] kind but is identified by endpoint rather
    than by this helper. *)
let adapter_canonical_name_of_provider_kind
    : Llm_provider.Provider_config.provider_kind -> string
  = function
  | Anthropic -> cn_claude_api
  | Kimi -> cn_kimi_api
  | OpenAI_compat -> cn_codex_api
  | Ollama -> cn_ollama
  | Gemini -> cn_gemini_api
  | Gemini_cli -> cn_gemini
  | Kimi_cli -> cn_kimi
  | Glm -> cn_glm
  | Claude_code -> cn_claude
  | Codex_cli -> cn_codex

(** Single source of truth for all provider/runtime adapters.
    Simple names ([claude], [codex], [gemini]) are CLI runtimes.
    Direct API adapters use explicit [*-api] canonical names. *)
let direct_adapters =
  [
    {
      canonical_name = cn_llama;
      runtime_kind = Local;
      auth_mode = No_auth;
      aliases = [ cn_llama; "llama.cpp"; "llamacpp" ];
      spawn_key = Some "llama";
      cascade_prefix = "llama";
      default_voice = Some "Laura";
      endpoint_url = Some Env_config_runtime.Llama.server_url;
      default_model_id =
        (let m = Env_config_runtime.Llama.default_model in
         if m = "" || m = "explicit-model-required" then None else Some m);
      model_policy =
        {
          default_model_env = Some "LLAMA_DEFAULT_MODEL";
          default_model_fallback = None;
          auto_models = No_auto_models;
          expand_auto = false;
          family = Generic;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_ollama;
      runtime_kind = Local;
      auth_mode = No_auth;
      aliases = [ cn_ollama; "ollama-local" ];
      spawn_key = None;
      cascade_prefix = "ollama";
      default_voice = None;
      endpoint_url = Some Env_config_runtime.Ollama.server_url;
      default_model_id =
        (let m = Env_config_runtime.Ollama.default_model in
         if m = "" then None else Some m);
      model_policy =
        {
          default_model_env = Some "OLLAMA_DEFAULT_MODEL";
          default_model_fallback = None;
          auto_models = No_auto_models;
          expand_auto = false;
          family = Generic;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_claude;
      runtime_kind = Cli_agent;
      auth_mode = Cli_cached_login;
      aliases = [ cn_claude; "claude-code"; "claude_code" ];
      spawn_key = Some "claude";
      cascade_prefix = "claude_code";
      default_voice = Some "Sarah";
      endpoint_url = None;
      default_model_id = Some "auto";
      model_policy =
        {
          default_model_env = None;
          default_model_fallback = Some "auto";
          auto_models =
            Env_csv_or_default
              {
                env_var = "MASC_CLAUDE_CODE_AUTO_MODELS";
                defaults = [ "auto" ];
                prefer_default_model_env = false;
              };
          expand_auto = true;
          family = Generic;
        };
      tool_policy = runtime_mcp_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_codex;
      runtime_kind = Cli_agent;
      auth_mode = Cli_cached_login;
      aliases = [ cn_codex; "codex-cli"; "codex_cli" ];
      spawn_key = Some "codex";
      cascade_prefix = "codex_cli";
      default_voice = Some "George";
      endpoint_url = None;
      default_model_id = Some "auto";
      model_policy =
        {
          default_model_env = None;
          default_model_fallback = Some "auto";
          auto_models =
            Env_csv_or_default
              {
                env_var = "MASC_CODEX_CLI_AUTO_MODELS";
                defaults =
                  [
                    "gpt-5.2";
                    "gpt-5.3-codex-spark";
                    "gpt-5.3-codex";
                    "gpt-5.4-mini";
                    "gpt-5.4";
                  ];
                prefer_default_model_env = false;
              };
          expand_auto = true;
          family = Generic;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_gemini;
      runtime_kind = Cli_agent;
      auth_mode = Cli_cached_login;
      aliases = [ cn_gemini; "gemini-cli"; "gemini_cli" ];
      spawn_key = Some "gemini";
      cascade_prefix = "gemini_cli";
      default_voice = Some "Roger";
      endpoint_url = None;
      default_model_id = Some "auto";
      model_policy =
        {
          default_model_env = Some "GEMINI_DEFAULT_MODEL";
          default_model_fallback = Some "gemini-3-flash-preview";
          auto_models =
            Env_csv_or_default
              {
                env_var = "MASC_GEMINI_CLI_AUTO_MODELS";
                defaults =
                  [
                    "gemini-3-flash-preview";
                    "gemini-3.1-flash-lite-preview";
                    "gemini-2.5-flash";
                    "gemini-2.5-flash-lite";
                    "gemini-3.1-pro-preview";
                    "gemini-2.5-pro";
                  ];
                prefer_default_model_env = true;
              };
          expand_auto = true;
          family = Generic;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_kimi;
      runtime_kind = Cli_agent;
      auth_mode = Cli_cached_login;
      aliases = [ cn_kimi; "kimi-cli"; "kimi_cli" ];
      spawn_key = None;
      cascade_prefix = "kimi_cli";
      default_voice = None;
      endpoint_url = None;
      default_model_id = Some "auto";
      model_policy =
        {
          default_model_env = None;
          default_model_fallback = Some "kimi-for-coding";
          auto_models =
            Env_csv_or_default
              {
                env_var = "MASC_KIMI_CLI_AUTO_MODELS";
                defaults = [ "kimi-for-coding" ];
                prefer_default_model_env = false;
              };
          expand_auto = true;
          family = Generic;
        };
      tool_policy = runtime_mcp_http_headers;
      telemetry_policy = telemetry_usage_missing;
    };
    {
      canonical_name = cn_claude_api;
      runtime_kind = Direct_api;
      auth_mode = Api_key "ANTHROPIC_API_KEY";
      aliases = [ cn_claude_api; "anthropic" ];
      spawn_key = None;
      cascade_prefix = "claude";
      default_voice = Some "Sarah";
      endpoint_url = Some (anthropic_api_url ());
      default_model_id = Some "auto";
      model_policy =
        {
          default_model_env = Some "ANTHROPIC_DEFAULT_MODEL";
          default_model_fallback = Some "claude-sonnet-4-6-20250514";
          auto_models = No_auto_models;
          expand_auto = false;
          family = Generic;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_codex_api;
      runtime_kind = Direct_api;
      auth_mode = Api_key "OPENAI_API_KEY";
      aliases = [ cn_codex_api; "openai" ];
      spawn_key = None;
      cascade_prefix = "openai";
      default_voice = Some "George";
      endpoint_url = Some (openai_api_url ());
      default_model_id = Some "auto";
      model_policy =
        {
          default_model_env = Some "OPENAI_DEFAULT_MODEL";
          default_model_fallback = Some "gpt-4.1";
          auto_models = No_auto_models;
          expand_auto = false;
          family = Generic;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_gemini_api;
      runtime_kind = Direct_api;
      auth_mode =
        Vertex_adc
          {
            project_env = google_cloud_project_env;
            location_env = google_cloud_location_env;
          };
      aliases = [ cn_gemini_api; "google" ];
      spawn_key = None;
      cascade_prefix = "gemini";
      default_voice = Some "Roger";
      endpoint_url = None; (** Resolved dynamically for Gemini *)
      default_model_id = Some "auto";
      model_policy =
        {
          default_model_env = Some "GEMINI_DEFAULT_MODEL";
          default_model_fallback = Some "gemini-3-flash-preview";
          auto_models = No_auto_models;
          expand_auto = false;
          family = Generic;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_kimi_api;
      runtime_kind = Direct_api;
      auth_mode = Api_key "KIMI_API_KEY_SB";
      aliases = [ cn_kimi_api; "moonshot" ];
      spawn_key = None;
      cascade_prefix = "kimi";
      default_voice = None;
      endpoint_url = Some (kimi_api_url ());
      default_model_id = Some "auto";
      model_policy =
        {
          default_model_env = Some "KIMI_DEFAULT_MODEL";
          default_model_fallback = Some "kimi-k2.5";
          auto_models = No_auto_models;
          expand_auto = false;
          family = Kimi_api_family;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_glm;
      runtime_kind = Direct_api;
      auth_mode = Api_key "ZAI_API_KEY";
      aliases = [ cn_glm; "glm"; "glm_cloud"; "zai" ];
      spawn_key = None;
      cascade_prefix = "glm";
      default_voice = None;
      endpoint_url = Some (glm_api_url ());
      default_model_id = Some "auto";
      model_policy =
        {
          default_model_env = Some "ZAI_DEFAULT_MODEL";
          default_model_fallback = Some "glm-5.1";
          auto_models = Zai_general_auto_models;
          expand_auto = true;
          family = Glm_general;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_glm_coding_plan;
      runtime_kind = Direct_api;
      auth_mode = Api_key "ZAI_API_KEY";
      aliases = [ cn_glm_coding_plan; "glm-coding" ];
      spawn_key = None;
      cascade_prefix = "glm-coding";
      default_voice = None;
      endpoint_url = Some (glm_coding_api_url ());
      default_model_id = Some "auto";
      model_policy =
        {
          default_model_env = Some "ZAI_CODING_DEFAULT_MODEL";
          default_model_fallback = Some "glm-5.1";
          auto_models = Zai_coding_auto_models;
          expand_auto = true;
          family = Glm_coding;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
    {
      canonical_name = cn_openrouter;
      runtime_kind = Direct_api;
      auth_mode = Api_key "OPENROUTER_API_KEY";
      aliases = [ cn_openrouter ];
      spawn_key = None;
      cascade_prefix = "openrouter";
      default_voice = None;
      endpoint_url = Some (openrouter_api_url ());
      default_model_id = None;
      model_policy =
        {
          default_model_env = Some "OPENROUTER_DEFAULT_MODEL";
          default_model_fallback = None;
          auto_models = No_auto_models;
          expand_auto = false;
          family = Generic;
        };
      tool_policy = no_tool_http_headers;
      telemetry_policy = telemetry_reported;
    };
  ]

let find_direct_adapter_by_alias label =
  let normalized = normalize_label label in
  List.find_opt
    (fun (adapter : adapter) ->
      List.exists (fun alias -> normalize_label alias = normalized) adapter.aliases)
    direct_adapters

let resolve_adapter_by_cascade_prefix label =
  let normalized = normalize_label label in
  List.find_opt
    (fun (adapter : adapter) ->
      normalize_label adapter.cascade_prefix = normalized)
    direct_adapters

let resolve_model_policy_default ?getenv (policy : model_policy) =
  match policy.default_model_env with
  | Some env_name -> (
      match env_value_opt ?getenv env_name with
      | Some _ as value -> value
      | None -> policy.default_model_fallback)
  | None -> policy.default_model_fallback

let resolve_auto_models ?getenv (policy : model_policy) =
  match policy.auto_models with
  | No_auto_models -> None
  | Zai_general_auto_models -> Some (Llm_provider.Zai_catalog.glm_auto_models ())
  | Zai_coding_auto_models -> Some (Llm_provider.Zai_catalog.glm_coding_auto_models ())
  | Env_csv_or_default { env_var; defaults; prefer_default_model_env } -> (
      match env_value_opt ?getenv env_var with
      | Some raw -> (
          match csv_items raw with
          | [] -> Some defaults
          | items -> Some items)
      | None when prefer_default_model_env -> (
          match policy.default_model_env with
          | Some default_env -> (
              match env_value_opt ?getenv default_env with
              | Some model_id -> Some [ model_id ]
              | None -> Some defaults)
          | None -> Some defaults)
      | None -> Some defaults)

let default_model_id_for_cascade_prefix ?getenv provider_name =
  match resolve_adapter_by_cascade_prefix provider_name with
  | Some adapter -> resolve_model_policy_default ?getenv adapter.model_policy
  | None -> None

let auto_models_for_provider ?getenv provider_name =
  match find_direct_adapter_by_alias provider_name with
  | Some adapter when adapter.model_policy.expand_auto ->
      resolve_auto_models ?getenv adapter.model_policy
  | Some _ -> None
  | None -> None

let auto_models_for_cascade_prefix ?getenv provider_name =
  match resolve_adapter_by_cascade_prefix provider_name with
  | Some adapter when adapter.model_policy.expand_auto ->
      resolve_auto_models ?getenv adapter.model_policy
  | Some _ -> None
  | None -> None

let voice_openai_compat_adapter =
  {
    canonical_name = "voice-openai-compat";
    transport = Voice_openai_compat;
    auth_mode = No_auth;
    aliases =
      [ "voice-openai-compat"; "openai_compat"; "openai"; "railway-elevenlabs-proxy" ];
  }

let voice_elevenlabs_direct_adapter =
  {
    canonical_name = "elevenlabs-direct";
    transport = Voice_elevenlabs_direct;
    auth_mode = Api_key "ELEVENLABS_API_KEY";
    aliases = [ "elevenlabs-direct"; "elevenlabs"; "tts-elevenlabs" ];
  }

let voice_mcp_adapter =
  {
    canonical_name = "voice-mcp";
    transport = Voice_mcp;
    auth_mode = No_auth;
    aliases = [ "voice-mcp"; "voice_mcp"; "mcp"; "local-voice-mcp" ];
  }

let voice_adapters =
  [
    voice_openai_compat_adapter;
    voice_elevenlabs_direct_adapter;
    voice_mcp_adapter;
  ]

(** The "custom" provider prefix represents user-provided self-hosted
    endpoints (e.g. "custom:model@url").  It is not in [direct_adapters]
    because it has no fixed config; it is always considered available and
    requires no API key. *)
let cn_custom = "custom"

(** Returns true if the provider name represents a local runtime that
    uses runtime discovery (e.g. the live /props probe for per-slot
    context).  Any provider with [runtime_kind = Local] qualifies.
    Adding a new local provider (ollama, vllm, ...) only requires
    adding an entry with [runtime_kind = Local] in [direct_adapters]. *)
let requires_discovery pname =
  let normalized = normalize_label pname in
  List.exists
    (fun (adapter : adapter) ->
      adapter.runtime_kind = Local
      && List.exists (fun alias -> normalize_label alias = normalized) adapter.aliases)
    direct_adapters

(** Returns true if the provider is self-hosted and always considered
    available (no API key validation needed).  Covers both
    [runtime_kind = Local] adapters and the special "custom" prefix. *)
let is_local_provider pname =
  let normalized = normalize_label pname in
  normalized = cn_custom || requires_discovery pname

(** Default fallback label for local runtime when no other preferred
    model labels are configured.  Uses "provider:auto" for the first
    [Local] adapter found. *)
let default_local_fallback_label () =
  match
    List.find_opt
      (fun (adapter : adapter) -> adapter.runtime_kind = Local)
      direct_adapters
  with
  | Some adapter -> adapter.canonical_name ^ ":auto"
  | None -> "auto"

let resolve_direct_adapter label =
  find_direct_adapter_by_alias label

let resolve_direct_canonical_name label =
  Option.map (fun (adapter : adapter) -> adapter.canonical_name) (resolve_direct_adapter label)

(** Resolve spawn_key for an agent label.
    Returns the key to look up in Spawn.default_configs. *)
let resolve_spawn_key label =
  match resolve_direct_adapter label with
  | Some adapter -> adapter.spawn_key
  | None -> None

(** Check if a name is a known direct adapter label or alias.
    This includes adapters that do not have a CLI spawn_key (e.g. glm, openrouter). *)
let is_known_provider name =
  resolve_direct_adapter name <> None

(** Check if a name is a CLI-spawnable agent (has a spawn_key).
    For a broader "known provider" predicate, use {!is_known_provider}. *)
let is_spawnable_agent name =
  resolve_spawn_key name <> None

let spawnable_canonical_names () =
  direct_adapters
  |> List.filter_map (fun a -> if a.spawn_key <> None then Some a.canonical_name else None)

(** All agent voices as (canonical_name, voice_name) pairs.
    For backward compatibility with voice_bridge_core. *)
let all_agent_voices () =
  direct_adapters
  |> List.filter_map (fun a ->
    match a.default_voice with
    | Some v -> Some (a.canonical_name, v)
    | None -> None)

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

let trim_opt = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let normalize_base_url value =
  let trimmed = String.trim value in
  if String.length trimmed > 1 && trimmed.[String.length trimmed - 1] = '/' then
    String.sub trimmed 0 (String.length trimmed - 1)
  else
    trimmed

let legacy_voice_env_warning_emitted = Atomic.make false

let warn_legacy_voice_env_once () =
  if not (Atomic.get legacy_voice_env_warning_emitted) then (
    Atomic.set legacy_voice_env_warning_emitted true;
    Log.Misc.warn
      "VOICE_MCP_HOST/PORT fallback is deprecated; prefer .masc/voice_config.json \
       session.endpoints or MASC_HTTP_* listener settings.")

let legacy_voice_base_url_opt () =
  let host_opt = Sys.getenv_opt "VOICE_MCP_HOST" |> trim_opt in
  let port_opt = Sys.getenv_opt "VOICE_MCP_PORT" |> trim_opt in
  match host_opt, port_opt with
  | None, None -> None
  | _ ->
      warn_legacy_voice_env_once ();
      let host = Option.value host_opt ~default:(Env_config.Voice.default_host) in
      let port = Option.value port_opt ~default:(string_of_int Env_config.Voice.default_port) in
      Some (Printf.sprintf "http://%s:%s" host port)

let http_listener_env_explicit () =
  Option.is_some (Sys.getenv_opt Env_config_core.http_base_url_env_key |> trim_opt)
  || Option.is_some (Sys.getenv_opt Env_config_core.host_env_key |> trim_opt)
  || Option.is_some (Sys.getenv_opt Env_config_core.http_port_env_key |> trim_opt)

let default_voice_session_base_url () =
  match Sys.getenv_opt Env_config_core.http_base_url_env_key |> trim_opt with
  | Some base_url -> normalize_base_url base_url
  | None ->
      if http_listener_env_explicit () then
        Printf.sprintf "http://%s:%s"
          (Env_config_core.masc_host ()) (Env_config_core.masc_http_port ())
      else (
        match legacy_voice_base_url_opt () with
        | Some legacy_base_url -> normalize_base_url legacy_base_url
        | None ->
            Printf.sprintf "http://%s:%s"
              (Env_config_core.masc_host ()) (Env_config_core.masc_http_port ()))

let compose_voice_endpoint_url ~base_url ~path =
  let base_uri = Uri.of_string base_url in
  let base_path = Uri.path base_uri in
  let base_path =
    if base_path = "" then "/"
    else if String.ends_with ~suffix:"/" base_path && String.length base_path > 1 then
      String.sub base_path 0 (String.length base_path - 1)
    else base_path
  in
  let final_path =
    if path = "/mcp" then
      if String.ends_with ~suffix:"/mcp" base_path then base_path
      else if base_path = "/" then "/mcp"
      else base_path ^ "/mcp"
    else if path = "/health" then
      if String.ends_with ~suffix:"/health" base_path then base_path
      else if String.ends_with ~suffix:"/mcp" base_path then
        String.sub base_path 0 (String.length base_path - 4) ^ "/health"
      else if base_path = "/" then "/health"
      else base_path ^ "/health"
    else if base_path = "/" then path
    else base_path ^ path
  in
  Uri.with_path base_uri final_path |> Uri.to_string

let default_voice_session_url ~path =
  compose_voice_endpoint_url ~base_url:(default_voice_session_base_url ()) ~path

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
        | None -> Ok (default_voice_session_url ~path:"/mcp"))

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
        | None -> Ok (default_voice_session_url ~path:"/health"))

let voice_transport_supports_http_tts (adapter : voice_adapter) =
  match adapter.transport with
  | Voice_openai_compat | Voice_elevenlabs_direct -> true
  | Voice_mcp -> false

let voice_endpoint_supports_http_tts (endpoint : Voice_config.endpoint) =
  voice_adapter_for_endpoint endpoint
  |> voice_transport_supports_http_tts

(** ElevenLabs base URL — SSOT is [Voice_config.default_elevenlabs_base_url]. *)
let default_elevenlabs_base_url = Voice_config.default_elevenlabs_base_url

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

let voice_stt_request_for_endpoint (endpoint : Voice_config.endpoint) ~api_key
    ~audio_file ~model =
  let adapter = voice_adapter_for_endpoint endpoint in
  match voice_endpoint_base_url endpoint, adapter.transport with
  | None, _ ->
      Error
        (Printf.sprintf "voice config endpoint %s missing base_url" endpoint.id)
  | Some _, Voice_mcp ->
      Error
        (Printf.sprintf
           "voice config endpoint %s uses voice_mcp and cannot build HTTP STT request"
           endpoint.id)
  | Some base_url, Voice_openai_compat ->
      let headers =
        if api_key = "" then []
        else [ ("Authorization", "Bearer " ^ api_key) ]
      in
      Ok
        {
          url = base_url ^ "/audio/transcriptions";
          headers;
          form_fields = [ ("model", model) ];
          file_field = ("file", audio_file);
        }
  | Some base_url, Voice_elevenlabs_direct ->
      let headers = [ ("xi-api-key", api_key) ] in
      Ok
        {
          url = base_url ^ "/speech-to-text";
          headers;
          form_fields = [ ("model_id", model) ];
          file_field = ("file", audio_file);
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

(** Extract the env var name from an adapter's auth_mode, if any. *)
let auth_env_var_of_adapter (adapter : adapter) =
  match adapter.auth_mode with
  | Api_key env_name -> Some env_name
  | _ -> None

(** Check whether a provider (by canonical name or alias) has its
    auth credential configured.  Returns [true] for [No_auth] providers
    (e.g. llama). *)
let provider_auth_available label =
  match resolve_direct_adapter label with
  | Some adapter ->
      (match adapter.auth_mode with
       | No_auth -> true
       | Cli_cached_login ->
            (match adapter.spawn_key with
            | Some cmd -> Llm_provider.Provider_registry.command_in_path cmd
            | None -> false)
       | Api_key env_name ->
           env_present env_name
           || (adapter.canonical_name = cn_kimi_api
               && List.exists env_present kimi_api_key_envs)
       | Vertex_adc { project_env; _ } -> env_present project_env)
  | None -> false

(** Derive the auth_kind string for a provider by looking up its
    adapter config, instead of hardcoding vendor env var names. *)
let auth_kind_for_canonical_name name =
  match resolve_direct_adapter name with
  | Some adapter ->
      if adapter.canonical_name = cn_kimi_api then
        "api_key:KIMI_API_KEY_SB|KIMI_API_KEY"
      else
        string_of_auth_mode adapter.auth_mode
  | None -> "unknown"

let bare_ollama_migration_message () =
  "Bare `ollama` without a model requires OLLAMA_DEFAULT_MODEL env var. Use `ollama:<model>` for explicit selection."

let is_bare_ollama_label label =
  let normalized = normalize_label label in
  String.equal normalized "ollama"
  && Env_config_runtime.Ollama.default_model = ""

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

let explicit_llama_model_label_result () =
  Result.map make_local_label (explicit_llama_model_id_result ())

let gemini_direct_available () =
  env_present google_cloud_project_env || env_present gemini_api_key_env

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

(** Derives the default model label for an adapter from its [runtime_kind]
    and [cascade_prefix].  Local adapters require an explicit model ID
    (resolved via env); Cli_agent/Direct_api adapters use
    "[cascade_prefix]:auto" when
    a default model is configured. *)
let default_model_label_for_adapter (adapter : adapter) =
  match adapter.runtime_kind with
  | Local ->
    Result.map
      (fun model_id -> adapter.cascade_prefix ^ ":" ^ model_id)
      (explicit_llama_model_id_result ())
  | Cli_agent
  | Direct_api ->
    match adapter.default_model_id with
    | Some _ -> Ok (adapter.cascade_prefix ^ ":auto")
    | None -> Error (Printf.sprintf "Provider '%s' requires explicit runtime_model" adapter.canonical_name)

(** Build the "provider:auto" label for each adapter that has auth
    credentials present.  Used by preferred_*_model_labels to avoid
    hardcoding vendor env var names. *)
let auto_label_for_adapter (adapter : adapter) =
  let is_available =
    match adapter.auth_mode with
    | No_auth -> true
    | Cli_cached_login ->
        (match adapter.spawn_key with
         | Some cmd -> Llm_provider.Provider_registry.command_in_path cmd
         | None -> false)
    | Api_key env_name -> env_present env_name
    | Vertex_adc { project_env; _ } -> env_present project_env
  in
  if not is_available then None
  else
    match default_model_label_for_adapter adapter with
    | Ok label -> Some label
    | Error msg ->
        Eio.traceln "[ProviderAdapter] default_model_label_for_adapter failed: %s" msg;
        None

(** Cloud adapters that participate in auto-detection (excludes llama
    which requires explicit model config, and openrouter which requires
    explicit runtime_model). *)
let auto_detect_adapters =
  List.filter
    (fun (adapter : adapter) ->
      adapter.runtime_kind = Direct_api
      && adapter.canonical_name <> cn_openrouter)
    direct_adapters

let preferred_execution_model_labels () =
  let explicit = [
    (match configured_default_model_label_result () with
    | Ok label -> Some label
    | Error _ -> None);
    (match explicit_llama_model_label_result () with
    | Ok label -> Some label
    | Error _ -> None);
    (* No hardcoded provider preference here.  Model order is determined
       by MASC cascade.json via [Cascade_config], not by this adapter module. The auto_detect
       list below only serves as a last-resort fallback when cascade.json
       is missing entirely. *)
  ] in
  Json_util.dedupe_keep_order
    (List.filter_map Fun.id explicit
     @ List.filter_map auto_label_for_adapter auto_detect_adapters)

let preferred_verifier_model_labels () =
  let explicit = [
    (match configured_verifier_model_label_result () with
    | Ok label -> Some label
    | Error _ -> None);
    (match explicit_llama_model_label_result () with
    | Ok label -> Some label
    | Error _ -> None);
  ] in
  Json_util.dedupe_keep_order
    (List.filter_map Fun.id explicit
     @ List.filter_map auto_label_for_adapter auto_detect_adapters)

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
      match Sys.getenv_opt gemini_api_key_env with
      | Some raw when String.trim raw <> "" -> Gemini_api_key
      | _ ->
          Gemini_auth_missing
            "Gemini auth unavailable; set GOOGLE_CLOUD_PROJECT for Vertex ADC or GEMINI_API_KEY")

let gemini_vertex_openai_base_url ~project ~location =
  Printf.sprintf
    "https://aiplatform.googleapis.com/v1/projects/%s/locations/%s/endpoints/openapi"
    project location

let starts_with ~prefix s = Base.String.is_prefix s ~prefix

let is_kimi_model_id model_id =
  let normalized = String.trim model_id |> String.lowercase_ascii in
  starts_with ~prefix:"kimi-" normalized
  || starts_with ~prefix:"moonshot-" normalized

let is_moonshot_base_url base_url =
  match Uri.host (Uri.of_string base_url) with
  | Some host -> String.equal (String.lowercase_ascii host) "api.moonshot.ai"
  | None -> false

let provider_label_from_registry (cfg : Llm_provider.Provider_config.t) =
  if cfg.kind = Llm_provider.Provider_config.OpenAI_compat
     && (is_kimi_model_id cfg.model_id || is_moonshot_base_url cfg.base_url)
  then
    "kimi"
  else
    Llm_provider.Provider_registry.provider_name_of_config cfg

let adapter_of_provider_config (cfg : Llm_provider.Provider_config.t) =
  match cfg.kind with
  | Llm_provider.Provider_config.Claude_code ->
      resolve_direct_adapter cn_claude
  | Codex_cli ->
      resolve_direct_adapter cn_codex
  | Gemini_cli ->
      resolve_direct_adapter cn_gemini
  | Kimi_cli ->
      resolve_direct_adapter cn_kimi
  | Anthropic ->
      resolve_direct_adapter cn_claude_api
  | Gemini ->
      resolve_direct_adapter cn_gemini_api
  | Kimi ->
      resolve_direct_adapter cn_kimi_api
  | Ollama ->
      resolve_direct_adapter cn_ollama
  | Glm
  | OpenAI_compat ->
      resolve_adapter_by_cascade_prefix (provider_label_from_registry cfg)

let provider_label_of_config (cfg : Llm_provider.Provider_config.t) =
  match adapter_of_provider_config cfg with
  | Some adapter -> adapter.cascade_prefix
  | None -> provider_label_from_registry cfg

let display_provider_name_of_config (cfg : Llm_provider.Provider_config.t) =
  display_provider_name (provider_label_of_config cfg)

let model_label_of_config (cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf "%s:%s" (display_provider_name_of_config cfg) cfg.model_id

let supports_runtime_mcp_http_headers_for_config
    (cfg : Llm_provider.Provider_config.t) =
  match adapter_of_provider_config cfg with
  | Some adapter -> adapter.tool_policy.supports_runtime_mcp_http_headers
  | None -> false

(* ── Generic provider auth detail ─────────────────────────────── *)

(** Provider-agnostic auth detail for dashboard display.
    Encapsulates vendor-specific auth logic (e.g. Gemini Vertex/API key)
    so consumers do not branch on vendor names. *)
type auth_detail = {
  auth_kind : string;
  status : string;
  available : bool;
  supports_run : bool;
  endpoint_url : string option;
  note : string option;
}

(** Cascade config prefix from adapter record. No match needed. *)
let cascade_prefix_of_adapter (adapter : adapter) = adapter.cascade_prefix

let endpoint_url_of_adapter (adapter : adapter) = adapter.endpoint_url

(** Best-effort mapping from Provider_registry/OAS [provider_kind] to a cascade prefix via the
    adapter registry.

    Warning: this mapping is inherently ambiguous for provider_kind values that
    cover multiple adapters/endpoints (for example OpenAI_compat may represent
    different provider labels such as codex/openrouter/llama). The returned
    string is a cascade prefix only; callers must not assume it can round-trip
    or reconstruct the original provider label.

    When the exact provider identity matters, the only unambiguous approach is
    to parse the prefix directly from the original provider:model label. This
    helper should be used only when a best-effort cascade prefix is sufficient. *)
let cascade_prefix_of_provider_kind (kind : Llm_provider.Provider_config.provider_kind) : string =
  let cn = adapter_canonical_name_of_provider_kind kind in
  match resolve_direct_adapter cn with
  | Some a -> a.cascade_prefix
  | None -> cn

(** Resolve auth detail for any provider by canonical name or alias.
    Gemini-specific Vertex ADC vs API Key logic is internal. *)
let auth_detail_of_provider provider =
  match resolve_direct_adapter provider with
  | None ->
    { auth_kind = "unknown"; status = "unsupported"; available = false;
      supports_run = false; endpoint_url = None;
      note = Some "Unsupported provider" }
  | Some adapter ->
    let auth_kind_base =
      if adapter.canonical_name = cn_kimi_api then
        "api_key:KIMI_API_KEY"
      else
        string_of_auth_mode adapter.auth_mode
    in
    if adapter.canonical_name = cn_gemini_api then
      match resolve_gemini_direct_auth () with
      | Gemini_api_key ->
        { auth_kind = "api_key:GEMINI_API_KEY"; status = "configured";
          available = true; supports_run = true;
          endpoint_url = Some (gemini_generative_api_url ());
          note = None }
      | Gemini_vertex_adc { project; location } ->
        { auth_kind = Printf.sprintf "vertex_adc:%s:%s" project location;
          status = "vertex_adc"; available = true; supports_run = false;
          endpoint_url = Some (gemini_vertex_openai_base_url ~project ~location);
          note = Some "Dashboard run MVP only supports Gemini via GEMINI_API_KEY. \
                       Vertex ADC inventory is visible but run is disabled." }
      | Gemini_auth_missing message ->
        { auth_kind = auth_kind_base; status = "missing_auth";
          available = false; supports_run = false;
          endpoint_url = None; note = Some message }
    else if adapter.runtime_kind = Cli_agent then
      let available = provider_auth_available provider in
      { auth_kind = auth_kind_base;
        status = (if available then "configured" else "missing_auth");
        available; supports_run = available;
        endpoint_url = None;
        note = Some "Cached CLI login is assumed; final validation happens at execution time." }
    else
      let available = provider_auth_available provider in
      { auth_kind = auth_kind_base;
        status = (if available then "configured" else "missing_auth");
        available; supports_run = available;
        endpoint_url = endpoint_url_of_adapter adapter;
        note = None }

let auth_env_keys_of_provider_kind (kind : Llm_provider.Provider_config.provider_kind) : string list =
  match kind with
  | Llm_provider.Provider_config.Kimi -> kimi_api_key_envs
  | Llm_provider.Provider_config.Gemini -> [ google_cloud_project_env; google_cloud_location_env ]
  | _ ->
      let adapter_name = adapter_canonical_name_of_provider_kind kind in
      match resolve_direct_adapter adapter_name with
      | Some adapter -> (
          match adapter.auth_mode with
          | Api_key env_name -> [ env_name ]
          | No_auth | Cli_cached_login | Vertex_adc _ ->
              Option.to_list (Llm_provider.Provider_config.default_api_key_env kind))
      | None -> Option.to_list (Llm_provider.Provider_config.default_api_key_env kind)

let docker_auth_env_keys_of_provider_config (cfg : Llm_provider.Provider_config.t) : string list =
  match cfg.kind with
  | Llm_provider.Provider_config.OpenAI_compat ->
    let uri = Uri.of_string cfg.base_url in
    if Masc_network_defaults.is_loopback_host_opt (Uri.host uri) then []
    else auth_env_keys_of_provider_kind cfg.kind
  | Llm_provider.Provider_config.Gemini -> [ gemini_api_key_env ]
  | Llm_provider.Provider_config.Anthropic
  | Llm_provider.Provider_config.Kimi
  | Llm_provider.Provider_config.Ollama
  | Llm_provider.Provider_config.Gemini_cli
  | Llm_provider.Provider_config.Kimi_cli
  | Llm_provider.Provider_config.Glm
  | Llm_provider.Provider_config.Claude_code
  | Llm_provider.Provider_config.Codex_cli ->
      auth_env_keys_of_provider_kind cfg.kind

let all_auth_env_keys () : string list =
  direct_adapters
  |> List.concat_map (fun (adapter : adapter) ->
    match adapter.auth_mode with
    | No_auth -> []
    | Cli_cached_login -> []
    | Api_key _ when adapter.canonical_name = cn_kimi_api -> kimi_api_key_envs
    | Api_key env_name -> [ env_name ]
    | Vertex_adc _ -> [])
  |> List.sort_uniq String.compare

(* is_spawnable removed: use is_spawnable_agent directly. *)
