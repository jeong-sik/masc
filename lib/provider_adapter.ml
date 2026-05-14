type runtime_kind =
  | Local [@tla.symbol "local"]
  | Cli_agent [@tla.symbol "cli_agent"]
  | Direct_api [@tla.symbol "direct_api"]
[@@deriving tla]

type auth_mode =
  | No_auth
  | Cli_cached_login
  | Api_key of string
  | Vertex_adc of
      { project_env : string
      ; location_env : string
      }

type model_family =
  | Generic
  | Glm_general
  | Glm_coding
  | Kimi_api_family

type auto_models_source =
  | No_auto_models
  | Env_csv_or_default of
      { env_var : string
      ; defaults : string list
      ; prefer_default_model_env : bool
      }
  | Zai_general_auto_models
  | Zai_coding_auto_models

type reporting_policy =
  | Reported
  | Missing_by_design
  | Unknown

type model_policy =
  { default_model_env : string option
  ; default_model_fallback : string option
  ; auto_models : auto_models_source
  ; expand_auto : bool
  ; family : model_family
  }

type tool_policy =
  { supports_runtime_mcp_http_headers : bool
  ; requires_per_keeper_bridging_for_bound_actor_tools : bool
  ; identity_runtime_mcp_header_keys : string list
  ; argv_prompt_preflight : bool
  ; uses_anthropic_caching : bool
  ; max_turns_per_attempt : int option
  ; tolerates_bound_actor_fallback : bool
  }

type telemetry_policy =
  { usage_reporting : reporting_policy
  ; runtime_reporting : reporting_policy
  }

type adapter =
  { canonical_name : string
  ; runtime_kind : runtime_kind
  ; auth_mode : auth_mode
  ; aliases : string list
  ; spawn_key : string option
    (** Key for CLI spawn lookup in Spawn.spawn_config_of_key. None = not spawnable via CLI. *)
  ; cascade_prefix : string
    (** MASC cascade model prefix (e.g. "claude", "openai").
                                       CONTRACT: Must match the prefix used by the local
                                       [Cascade_config] parser and Provider_registry-compatible
                                       model labels. This is the primary naming boundary between
                                       MASC routing and OAS provider configs. *)
  ; endpoint_url : string option (** Base URL for the provider API. *)
  ; default_model_id : string option (** Default model ID for the provider. *)
  ; model_policy : model_policy
  ; tool_policy : tool_policy
  ; telemetry_policy : telemetry_policy
  }

type gemini_direct_auth =
  | Gemini_vertex_adc of
      { project : string
      ; location : string
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
;;

let string_of_auth_mode = function
  | No_auth -> "none"
  | Cli_cached_login -> "cli_cached_login"
  | Api_key env_name -> "api_key:" ^ env_name
  | Vertex_adc { project_env; location_env } ->
    "vertex_adc:" ^ project_env ^ ":" ^ location_env
;;

let normalize_label label = String.trim label |> String.lowercase_ascii

let env_value_opt ?(getenv = Sys.getenv_opt) name =
  match getenv name with
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
  | None -> None
;;

let csv_items raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")
;;

let no_tool_http_headers =
  { supports_runtime_mcp_http_headers = false
  ; requires_per_keeper_bridging_for_bound_actor_tools = false
  ; identity_runtime_mcp_header_keys = []
  ; argv_prompt_preflight = false
  ; uses_anthropic_caching = false
  ; max_turns_per_attempt = None
  ; tolerates_bound_actor_fallback = false
  }
;;

let runtime_mcp_http_headers =
  { supports_runtime_mcp_http_headers = true
  ; requires_per_keeper_bridging_for_bound_actor_tools = false
  ; identity_runtime_mcp_header_keys = []
  ; argv_prompt_preflight = false
  ; uses_anthropic_caching = false
  ; max_turns_per_attempt = None
  ; tolerates_bound_actor_fallback = false
  }
;;

(* Codex CLI quirk: its cached login cannot natively inject per-keeper auth
   headers, so any runtime MCP policy that uses bound-actor tools requires
   per-keeper bridging at the cascade layer. The
   [Cascade_runner.codex_cli_can_auth_keeper_bound_runtime_mcp] predicate is
   what the cascade filter consults to decide whether such bridging is in
   place for a given keeper before admitting codex_cli for runtime MCP.

   The MASC identity headers are non-secret routing labels.
   [identity_runtime_mcp_header_keys] enumerates the keys accepted via this
   carve-out even with [supports_runtime_mcp_http_headers = false]. Bearer
   auth remains stripped by the provider-specific runtime policy normalizer. *)
let codex_cli_tool_policy =
  { supports_runtime_mcp_http_headers = false
  ; requires_per_keeper_bridging_for_bound_actor_tools = true
  ; identity_runtime_mcp_header_keys = [ "x-masc-agent-name"; "x-masc-keeper-name" ]
  ; argv_prompt_preflight = true
  ; uses_anthropic_caching = false
  ; max_turns_per_attempt = None
  ; tolerates_bound_actor_fallback = false
  }
;;

let telemetry_reported = { usage_reporting = Reported; runtime_reporting = Reported }
let telemetry_unknown = { usage_reporting = Unknown; runtime_reporting = Unknown }

let telemetry_usage_missing =
  { usage_reporting = Missing_by_design; runtime_reporting = Unknown }
;;

let telemetry_usage_missing_runtime_reported =
  { usage_reporting = Missing_by_design; runtime_reporting = Reported }
;;

(* ── Canonical adapter names (single definition point) ──────── *)

let cn_llama = "llama"
let cn_ollama = "ollama"
let cn_unknown_provider = "unknown_provider"
let cn_claude = "claude"
let cn_codex = "codex"
let cn_gemini = "gemini"
let cn_kimi = "kimi"
let cn_claude_api = "claude-api"
let cn_codex_api = "codex-api"
let cn_gemini_api = "gemini-api"
let cn_kimi_api = "kimi-api"
let cn_kimi_coding = "kimi-coding"
let cn_glm = "glm-api"
let cn_glm_coding_plan = "glm-coding-plan"
let cn_openrouter = "openrouter"
let auth_header_authorization = "Authorization"
let kimi_api_key_envs = [ "KIMI_API_KEY_SB"; "KIMI_API_KEY" ]
let kimi_coding_key_envs = [ "KIMI_CODING_API_KEY"; "KIMI_API_KEY_SB" ]

let display_provider_name label =
  match normalize_label label with
  | "glm" | "glm-api" -> cn_glm
  | "glm-coding" | "glm-coding-plan" -> cn_glm_coding_plan
  | "kimi-api" -> cn_kimi
  | "kimi-coding" | "kimi_coding" -> cn_kimi_coding
  | _ -> String.trim label
;;

(** Default API base URLs — overridable via env var for proxying/testing.
    Where OAS Provider_registry already defines a default, query it rather
    than duplicating the literal here. *)

let env_url_or ~env ~default =
  match Sys.getenv_opt env with
  | Some url ->
    let trimmed = String.trim url in
    if trimmed <> "" then trimmed else default
  | None -> default
;;

(** Query OAS Provider_registry for a provider's default base_url.
    Returns empty string if the provider is not known to OAS.
    This removes duplicated defaults between MASC and OAS. *)
let registry_default_base_url name =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry name with
  | Some entry -> entry.defaults.base_url
  | None -> ""
;;

let anthropic_api_url () =
  env_url_or ~env:"ANTHROPIC_API_URL" ~default:(registry_default_base_url "claude")
;;

let openai_api_url () = env_url_or ~env:"OPENAI_API_URL" ~default:"https://api.openai.com"

let openrouter_api_url () =
  env_url_or ~env:"OPENROUTER_API_URL" ~default:(registry_default_base_url "openrouter")
;;

let gemini_generative_api_url () =
  env_url_or ~env:"GEMINI_API_URL" ~default:(registry_default_base_url "gemini")
;;

let glm_api_url () =
  env_url_or ~env:"ZAI_BASE_URL" ~default:Llm_provider.Zai_catalog.general_base_url
;;

let glm_coding_api_url () =
  env_url_or ~env:"ZAI_CODING_BASE_URL" ~default:Llm_provider.Zai_catalog.coding_base_url
;;

let moonshot_compat_base_url = "https://api.moonshot.ai/v1"
let kimi_api_url () = env_url_or ~env:"KIMI_BASE_URL" ~default:moonshot_compat_base_url
let kimi_coding_base_url = "https://api.kimi.com/coding/v1"

let kimi_coding_api_url () =
  env_url_or ~env:"KIMI_CODING_BASE_URL" ~default:kimi_coding_base_url
;;

(* SSOT cascade prefix for local llama-server instances.
    All cascade label construction for local models must use this constant.
    Format: [local_cascade_prefix ^ ":" ^ model_id] → e.g. "llama:qwen3.5" *)
let local_cascade_prefix = cn_llama

(** Build a cascade model label for a local model.
    Single entry point — other modules must not concatenate prefix manually. *)
let make_local_label (model_id : string) : string = local_cascade_prefix ^ ":" ^ model_id

(** SSOT string form of OAS [provider_kind].
    This must stay aligned with [Provider_config.string_of_provider_kind]. *)
let string_of_provider_kind : Llm_provider.Provider_config.provider_kind -> string =
  Llm_provider.Provider_config.string_of_provider_kind
;;

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
  | DashScope -> cn_codex_api
  | Ollama -> cn_ollama
  | Gemini -> cn_gemini_api
  | Gemini_cli -> cn_gemini
  | Kimi_cli -> cn_kimi
  | Glm -> cn_glm
  | Claude_code -> cn_claude
  | Codex_cli -> cn_codex
;;

(** MASC-local policy overlay for provider/runtime adapters.
    Simple names ([claude], [codex], [gemini]) are CLI runtimes.
    Direct API adapters use explicit [*-api] canonical names.

    Generic OAS provider bindings are appended below; this list remains only
    for MASC-specific policy that OAS should not own. *)
let legacy_direct_adapters =
  [ { canonical_name = cn_llama
    ; runtime_kind = Local
    ; auth_mode = No_auth
    ; aliases = [ cn_llama; "llama.cpp"; "llamacpp" ]
    ; spawn_key = Some "llama"
    ; cascade_prefix = "llama"
    ; endpoint_url = Some Env_config_runtime.Llama.server_url
    ; default_model_id =
        (let m = Env_config_runtime.Llama.default_model in
         if m = "" || m = "explicit-model-required" then None else Some m)
    ; model_policy =
        { default_model_env = Some "LLAMA_DEFAULT_MODEL"
        ; default_model_fallback = None
        ; auto_models = No_auto_models
        ; expand_auto = false
        ; family = Generic
        }
    ; tool_policy = no_tool_http_headers
    ; telemetry_policy = telemetry_reported
    }
  ; { canonical_name = cn_ollama
    ; runtime_kind = Local
    ; auth_mode = No_auth
    ; aliases = [ cn_ollama; "ollama-local" ]
    ; spawn_key = None
    ; cascade_prefix = "ollama"
    ; endpoint_url = Some Env_config_runtime.Ollama.server_url
    ; default_model_id =
        (let m = Env_config_runtime.Ollama.default_model in
         if m = "" then None else Some m)
    ; model_policy =
        { default_model_env = Some "OLLAMA_DEFAULT_MODEL"
        ; default_model_fallback = None
        ; auto_models = No_auto_models
        ; expand_auto = false
        ; family = Generic
        }
    ; tool_policy = { no_tool_http_headers with tolerates_bound_actor_fallback = true }
    ; telemetry_policy = telemetry_usage_missing_runtime_reported
    }
  ; { canonical_name = cn_claude
    ; runtime_kind = Cli_agent
    ; auth_mode = Cli_cached_login
    ; aliases = [ cn_claude; "claude-code"; "claude_code" ]
    ; spawn_key = Some "claude"
    ; cascade_prefix = "claude_code"
    ; endpoint_url = None
    ; default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = None
        ; default_model_fallback = Some "auto"
        ; auto_models =
            Env_csv_or_default
              { env_var = "MASC_CLAUDE_CODE_AUTO_MODELS"
              ; defaults = [ "auto" ]
              ; prefer_default_model_env = false
              }
        ; expand_auto = true
        ; family = Generic
        }
    ; tool_policy =
        { runtime_mcp_http_headers with
          uses_anthropic_caching = true
        ; max_turns_per_attempt = Some 30
        ; tolerates_bound_actor_fallback = true
        }
    ; telemetry_policy = telemetry_usage_missing_runtime_reported
    }
  ; { canonical_name = cn_codex
    ; runtime_kind = Cli_agent
    ; auth_mode = Cli_cached_login
    ; aliases = [ cn_codex; "codex-cli"; "codex_cli" ]
    ; spawn_key = Some "codex"
    ; cascade_prefix = "codex_cli"
    ; endpoint_url = None
    ; default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = None
        ; default_model_fallback = Some "auto"
        ; auto_models =
            Env_csv_or_default
              { env_var = "MASC_CODEX_CLI_AUTO_MODELS"
              ; defaults = [ "auto" ]
              ; prefer_default_model_env = false
              }
        ; expand_auto = true
        ; family = Generic
        }
    ; tool_policy = codex_cli_tool_policy
    ; telemetry_policy = telemetry_usage_missing_runtime_reported
    }
  ; { canonical_name = cn_gemini
    ; runtime_kind = Cli_agent
    ; auth_mode = Cli_cached_login
    ; aliases = [ cn_gemini; "gemini-cli"; "gemini_cli" ]
    ; spawn_key = Some "gemini"
    ; cascade_prefix = "gemini_cli"
    ; endpoint_url = None
    ; default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = Some "GEMINI_DEFAULT_MODEL"
        ; default_model_fallback = Some "gemini-3-flash-preview"
        ; auto_models =
            Env_csv_or_default
              { env_var = "MASC_GEMINI_CLI_AUTO_MODELS"
              ; defaults =
                  [ "gemini-3-flash-preview"
                  ; "gemini-3.1-flash-lite-preview"
                  ; "gemini-3.1-pro-preview"
                  ]
              ; prefer_default_model_env = true
              }
        ; expand_auto = true
        ; family = Generic
        }
    ; (* gemini-cli reads MCP servers only from ~/.gemini/settings.json or
         project .gemini/settings.json (no --mcp-config flag — see
         google-gemini/gemini-cli#3470 closed via PR #5481 which added
         the [gemini mcp add] subcommand for the global file, and #4674
         duplicate request for runtime override still unimplemented).
         Even though the settings.json mcpServers schema accepts httpUrl
         + headers (https://github.com/google-gemini/gemini-cli/blob/main/docs/tools/mcp-server.md),
         masc-mcp emits per-keeper request-scoped policies that gemini-cli
         cannot consume. OAS reflects this with a hardcoded reject in
         lib/llm_provider/transport_gemini_cli.ml (runtime_mcp_policy = Some
         _ branch). Keep this false until upstream adds per-invocation
         MCP config injection. See masc-mcp#11356 for full analysis. *)
      tool_policy = { no_tool_http_headers with tolerates_bound_actor_fallback = true }
    ; telemetry_policy = telemetry_usage_missing_runtime_reported
    }
  ; { canonical_name = cn_kimi
    ; runtime_kind = Cli_agent
    ; auth_mode = Cli_cached_login
    ; aliases = [ cn_kimi; "kimi-cli"; "kimi_cli" ]
    ; spawn_key = None
    ; cascade_prefix = "kimi_cli"
    ; endpoint_url = None
    ; default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = None
        ; default_model_fallback = Some "kimi-for-coding"
        ; auto_models =
            Env_csv_or_default
              { env_var = "MASC_KIMI_CLI_AUTO_MODELS"
              ; defaults = [ "kimi-for-coding" ]
              ; prefer_default_model_env = false
              }
        ; expand_auto = true
        ; family = Generic
        }
    ; tool_policy =
        { runtime_mcp_http_headers with tolerates_bound_actor_fallback = true }
    ; telemetry_policy = telemetry_usage_missing
    }
  ; { canonical_name = cn_claude_api
    ; runtime_kind = Direct_api
    ; auth_mode = Api_key "ANTHROPIC_API_KEY"
    ; aliases = [ cn_claude_api; "anthropic" ]
    ; spawn_key = None
    ; cascade_prefix = "claude"
    ; endpoint_url = Some (anthropic_api_url ())
    ; default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = Some "ANTHROPIC_DEFAULT_MODEL"
        ; default_model_fallback = Some "claude-sonnet-4-6-20250514"
        ; auto_models = No_auto_models
        ; expand_auto = false
        ; family = Generic
        }
    ; tool_policy = { no_tool_http_headers with uses_anthropic_caching = true }
    ; telemetry_policy = telemetry_reported
    }
  ; { canonical_name = cn_codex_api
    ; runtime_kind = Direct_api
    ; auth_mode = Api_key "OPENAI_API_KEY"
    ; aliases = [ cn_codex_api; "openai" ]
    ; spawn_key = None
    ; cascade_prefix = "openai"
    ; endpoint_url = Some (openai_api_url ())
    ; default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = Some "OPENAI_DEFAULT_MODEL"
        ; default_model_fallback = Some "gpt-4.1"
        ; auto_models = No_auto_models
        ; expand_auto = false
        ; family = Generic
        }
    ; tool_policy = no_tool_http_headers
    ; telemetry_policy = telemetry_reported
    }
  ; { canonical_name = cn_gemini_api
    ; runtime_kind = Direct_api
    ; auth_mode =
        Vertex_adc
          { project_env = google_cloud_project_env
          ; location_env = google_cloud_location_env
          }
    ; aliases = [ cn_gemini_api; "google" ]
    ; spawn_key = None
    ; cascade_prefix = "gemini"
    ; endpoint_url = None
    ; (* Resolved dynamically for Gemini *)
      default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = Some "GEMINI_DEFAULT_MODEL"
        ; default_model_fallback = Some "gemini-3-flash-preview"
        ; auto_models = No_auto_models
        ; expand_auto = false
        ; family = Generic
        }
    ; tool_policy = no_tool_http_headers
    ; telemetry_policy = telemetry_reported
    }
  ; { canonical_name = cn_kimi_api
    ; runtime_kind = Direct_api
    ; auth_mode = Api_key "KIMI_API_KEY_SB"
    ; aliases = [ cn_kimi_api; "moonshot" ]
    ; spawn_key = None
    ; cascade_prefix = "kimi"
    ; endpoint_url = Some (kimi_api_url ())
    ; default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = Some "KIMI_DEFAULT_MODEL"
        ; default_model_fallback = Some "kimi-k2.5"
        ; auto_models = No_auto_models
        ; expand_auto = false
        ; family = Kimi_api_family
        }
    ; tool_policy = no_tool_http_headers
    ; telemetry_policy = telemetry_reported
    }
  ; { canonical_name = cn_kimi_coding
    ; runtime_kind = Direct_api
    ; auth_mode = Api_key "KIMI_CODING_API_KEY"
    ; aliases = [ cn_kimi_coding; "kimi_coding" ]
    ; spawn_key = None
    ; cascade_prefix = "kimi_coding"
    ; endpoint_url = Some (kimi_coding_api_url ())
    ; default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = Some "KIMI_CODING_DEFAULT_MODEL"
        ; default_model_fallback = Some "kimi-coding-auto"
        ; auto_models = No_auto_models
        ; expand_auto = false
        ; family = Kimi_api_family
        }
    ; tool_policy = no_tool_http_headers
    ; telemetry_policy = telemetry_reported
    }
  ; { canonical_name = cn_glm
    ; runtime_kind = Direct_api
    ; auth_mode = Api_key "ZAI_API_KEY"
    ; aliases = [ cn_glm; "glm"; "glm_cloud"; "zai" ]
    ; spawn_key = None
    ; cascade_prefix = "glm"
    ; endpoint_url = Some (glm_api_url ())
    ; default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = Some "ZAI_DEFAULT_MODEL"
        ; default_model_fallback = Some "glm-5.1"
        ; auto_models = Zai_general_auto_models
        ; expand_auto = true
        ; family = Glm_general
        }
    ; tool_policy = no_tool_http_headers
    ; telemetry_policy = telemetry_reported
    }
  ; { canonical_name = cn_glm_coding_plan
    ; runtime_kind = Direct_api
    ; auth_mode = Api_key "ZAI_API_KEY"
    ; aliases = [ cn_glm_coding_plan; "glm-coding" ]
    ; spawn_key = None
    ; cascade_prefix = "glm-coding"
    ; endpoint_url = Some (glm_coding_api_url ())
    ; default_model_id = Some "auto"
    ; model_policy =
        { default_model_env = Some "ZAI_CODING_DEFAULT_MODEL"
        ; default_model_fallback = Some "glm-5.1"
        ; auto_models = Zai_coding_auto_models
        ; expand_auto = true
        ; family = Glm_coding
        }
    ; tool_policy = no_tool_http_headers
    ; telemetry_policy = telemetry_reported
    }
  ; { canonical_name = cn_openrouter
    ; runtime_kind = Direct_api
    ; auth_mode = Api_key "OPENROUTER_API_KEY"
    ; aliases = [ cn_openrouter ]
    ; spawn_key = None
    ; cascade_prefix = "openrouter"
    ; endpoint_url = Some (openrouter_api_url ())
    ; default_model_id = None
    ; model_policy =
        { default_model_env = Some "OPENROUTER_DEFAULT_MODEL"
        ; default_model_fallback = None
        ; auto_models = No_auto_models
        ; expand_auto = false
        ; family = Generic
        }
    ; tool_policy = no_tool_http_headers
    ; telemetry_policy = telemetry_reported
    }
  ]
;;

let adapter_binding_candidates (adapter : adapter) =
  adapter.canonical_name :: adapter.cascade_prefix :: adapter.aliases
  |> List.filter_map (fun label ->
    let trimmed = String.trim label in
    if trimmed = "" then None else Some trimmed)
  |> Json_util.dedupe_keep_order
;;

let adapter_labels (adapter : adapter) =
  adapter_binding_candidates adapter |> List.map normalize_label
;;

let overlay_adapter_from_binding
      (adapter : adapter)
      (binding : Provider_runtime_overlay.binding)
  =
  let binding_default_model = Provider_runtime_overlay.default_model_id binding in
  let binding_endpoint = Provider_runtime_overlay.endpoint_url binding in
  { adapter with
    aliases =
      Json_util.dedupe_keep_order
        (adapter.aliases @ Provider_runtime_overlay.labels binding)
  ; endpoint_url =
      (match adapter.endpoint_url, binding_endpoint with
       | Some _ as value, _ -> value
       | None, value -> value)
  ; default_model_id =
      (match adapter.default_model_id, binding_default_model with
       | Some _ as value, _ -> value
       | None, value -> value)
  }
;;

let runtime_kind_of_binding (binding : Provider_runtime_overlay.binding) =
  match Provider_runtime_overlay.runtime_kind binding with
  | `Local -> Local
  | `Cli_agent -> Cli_agent
  | `Direct_api -> Direct_api
;;

let auth_mode_of_binding (binding : Provider_runtime_overlay.binding) =
  match Provider_runtime_overlay.primary_api_key_env binding with
  | Some env_name -> Api_key env_name
  | None ->
    (match Provider_runtime_overlay.runtime_kind binding with
     | `Cli_agent -> Cli_cached_login
     | `Local | `Direct_api -> No_auth)
;;

let tool_policy_of_binding (binding : Provider_runtime_overlay.binding) =
  { no_tool_http_headers with
    supports_runtime_mcp_http_headers =
      Provider_runtime_overlay.supports_runtime_mcp_http_headers binding
  ; uses_anthropic_caching = Provider_runtime_overlay.uses_prompt_caching binding
  }
;;

let telemetry_policy_of_binding (binding : Provider_runtime_overlay.binding) =
  if Provider_runtime_overlay.usage_missing_by_design binding
  then telemetry_usage_missing
  else telemetry_reported
;;

let spawn_key_of_binding (binding : Provider_runtime_overlay.binding) =
  match Provider_runtime_overlay.command binding with
  | Some ("claude" | "codex" | "gemini" | "llama" as command) -> Some command
  | Some _ | None -> None
;;

let generic_adapter_of_binding (binding : Provider_runtime_overlay.binding) =
  let default_model_id = Provider_runtime_overlay.default_model_id binding in
  { canonical_name = Provider_runtime_overlay.id binding
  ; runtime_kind = runtime_kind_of_binding binding
  ; auth_mode = auth_mode_of_binding binding
  ; aliases = Provider_runtime_overlay.labels binding
  ; spawn_key = spawn_key_of_binding binding
  ; cascade_prefix = Provider_runtime_overlay.id binding
  ; endpoint_url = Provider_runtime_overlay.endpoint_url binding
  ; default_model_id
  ; model_policy =
      { default_model_env = None
      ; default_model_fallback = default_model_id
      ; auto_models = No_auto_models
      ; expand_auto = false
      ; family = Generic
      }
  ; tool_policy = tool_policy_of_binding binding
  ; telemetry_policy = telemetry_policy_of_binding binding
  }
;;

let binding_matches_adapter_labels labels (binding : Provider_runtime_overlay.binding) =
  Provider_runtime_overlay.labels binding
  |> List.exists (fun label -> List.mem (normalize_label label) labels)
;;

let direct_adapters =
  let legacy_with_oas_labels =
    List.map
      (fun adapter ->
         match
           Provider_runtime_overlay.find_by_candidates
             (adapter_binding_candidates adapter)
         with
         | Some binding -> overlay_adapter_from_binding adapter binding
         | None -> adapter)
      legacy_direct_adapters
  in
  let legacy_labels =
    legacy_with_oas_labels |> List.concat_map adapter_labels |> Json_util.dedupe_keep_order
  in
  let oas_extra_adapters =
    Provider_runtime_overlay.all ()
    |> List.filter (fun binding -> not (binding_matches_adapter_labels legacy_labels binding))
    |> List.map generic_adapter_of_binding
  in
  legacy_with_oas_labels @ oas_extra_adapters
;;

let find_direct_adapter_by_alias label =
  let normalized = normalize_label label in
  List.find_opt
    (fun (adapter : adapter) ->
       List.exists (fun alias -> normalize_label alias = normalized) adapter.aliases)
    direct_adapters
;;

let resolve_adapter_by_cascade_prefix label =
  let normalized = normalize_label label in
  List.find_opt
    (fun (adapter : adapter) -> normalize_label adapter.cascade_prefix = normalized)
    direct_adapters
;;

let resolve_model_policy_default ?getenv (policy : model_policy) =
  match policy.default_model_env with
  | Some env_name ->
    (match env_value_opt ?getenv env_name with
     | Some _ as value -> value
     | None -> policy.default_model_fallback)
  | None -> policy.default_model_fallback
;;

let resolve_auto_models ?getenv (policy : model_policy) =
  match policy.auto_models with
  | No_auto_models -> None
  | Zai_general_auto_models -> Some (Llm_provider.Zai_catalog.glm_auto_models ())
  | Zai_coding_auto_models -> Some (Llm_provider.Zai_catalog.glm_coding_auto_models ())
  | Env_csv_or_default { env_var; defaults; prefer_default_model_env } ->
    (match env_value_opt ?getenv env_var with
     | Some raw ->
       (match csv_items raw with
        | [] -> Some defaults
        | items -> Some items)
     | None when prefer_default_model_env ->
       (match policy.default_model_env with
        | Some default_env ->
          (match env_value_opt ?getenv default_env with
           | Some model_id -> Some [ model_id ]
           | None -> Some defaults)
        | None -> Some defaults)
     | None -> Some defaults)
;;

let default_model_id_for_cascade_prefix ?getenv provider_name =
  match resolve_adapter_by_cascade_prefix provider_name with
  | Some adapter -> resolve_model_policy_default ?getenv adapter.model_policy
  | None -> None
;;

let auto_models_for_provider ?getenv provider_name =
  match find_direct_adapter_by_alias provider_name with
  | Some adapter when adapter.model_policy.expand_auto ->
    resolve_auto_models ?getenv adapter.model_policy
  | Some _ -> None
  | None -> None
;;

let auto_models_for_cascade_prefix ?getenv provider_name =
  match resolve_adapter_by_cascade_prefix provider_name with
  | Some adapter when adapter.model_policy.expand_auto ->
    resolve_auto_models ?getenv adapter.model_policy
  | Some _ -> None
  | None -> None
;;

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
;;

(** Returns true if the provider is self-hosted and always considered
    available (no API key validation needed).  Covers both
    [runtime_kind = Local] adapters and the special "custom" prefix. *)
let is_local_provider pname =
  let normalized = normalize_label pname in
  normalized = cn_custom || requires_discovery pname
;;

(** [is_http_probe_capable_kind kind] is [true] when the provider
    serves an HTTP capacity probe endpoint that
    {!Cascade_http_probe} can poll (currently the ollama [/api/ps]
    schema).  Used by caller-side registration paths
    ({!Keeper_turn_driver}) to decide whether to register a cfg's
    [base_url] with the probe registry.

    RFC-0058 Phase 5.6: capability predicate, not a vendor match —
    keeper callers stay provider-agnostic.  Adding vLLM/lmstudio
    requires editing this one boundary site. *)
let is_http_probe_capable_kind (kind : Llm_provider.Provider_config.provider_kind) : bool =
  match kind with
  | Llm_provider.Provider_config.Ollama -> true
  | Anthropic | Claude_code | OpenAI_compat | Glm | DashScope | Codex_cli
  | Gemini | Gemini_cli | Kimi | Kimi_cli -> false
;;

(** Per-provider per-attempt timeout bounds.

    [min_timeout_s] is the floor below which an attempt timeout is
    never set (e.g. ollama needs 300s to load a cold model — anything
    lower means the keeper turn fails before the model finishes
    initialising).

    [max_timeout_s] is the ceiling above which an attempt cannot
    block (e.g. claude_code's 120s subprocess budget — exceeding it
    means the CLI has hung and the supervisor must intervene). *)
type timeout_bounds =
  { min_timeout_s : float option
  ; max_timeout_s : float option
  }

(** [timeout_bounds_of_kind kind] is the per-provider attempt timeout
    policy.  Encapsulates the only [match provider_cfg.kind] site that
    used to live in keeper-layer driver helpers; new providers add an
    arm here, not at the call site.

    RFC-0058 Phase 5.6: vendor-specific operational tunables live
    inside the adapter boundary, not the keeper turn-driver. *)
let timeout_bounds_of_kind (kind : Llm_provider.Provider_config.provider_kind)
  : timeout_bounds
  =
  match kind with
  | Llm_provider.Provider_config.Ollama ->
    { min_timeout_s = Some 300.0; max_timeout_s = None }
  | Claude_code -> { min_timeout_s = None; max_timeout_s = Some 120.0 }
  | Gemini | Gemini_cli -> { min_timeout_s = None; max_timeout_s = Some 180.0 }
  | Kimi_cli -> { min_timeout_s = None; max_timeout_s = Some 60.0 }
  | Anthropic | Kimi | OpenAI_compat | Glm | DashScope | Codex_cli ->
    { min_timeout_s = None; max_timeout_s = None }
;;

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
;;

let resolve_direct_adapter label = find_direct_adapter_by_alias label

let resolve_direct_canonical_name label =
  Option.map
    (fun (adapter : adapter) -> adapter.canonical_name)
    (resolve_direct_adapter label)
;;

(** Resolve spawn_key for an agent label.
    Returns the key to look up in Spawn.spawn_config_of_key. *)
let resolve_spawn_key label =
  match resolve_direct_adapter label with
  | Some adapter -> adapter.spawn_key
  | None -> None
;;

(** Check if a name is a known direct adapter label or alias.
    This includes adapters that do not have a CLI spawn_key (e.g. glm, openrouter). *)
let is_known_provider name = resolve_direct_adapter name <> None

(** Check if a name is a CLI-spawnable agent (has a spawn_key).
    For a broader "known provider" predicate, use {!is_known_provider}. *)
let is_spawnable_agent name = resolve_spawn_key name <> None

let spawnable_canonical_names () =
  direct_adapters
  |> List.filter_map (fun a ->
    if a.spawn_key <> None then Some a.canonical_name else None)
;;

let normalize_base_url value =
  let trimmed = String.trim value in
  if String.length trimmed > 1 && String.ends_with ~suffix:"/" trimmed
  then String.sub trimmed 0 (String.length trimmed - 1)
  else trimmed
;;

let default_cli_agent_name () = Env_config_runtime.Cli.default_agent

let split_csv_nonempty raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")
;;

let nonempty_env name =
  match Sys.getenv_opt name with
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
  | None -> None
;;

let env_present name = Option.is_some (nonempty_env name)

(** Extract the env var name from an adapter's auth_mode, if any. *)
let auth_env_var_of_adapter (adapter : adapter) =
  match adapter.auth_mode with
  | Api_key env_name -> Some env_name
  | _ -> None
;;

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
       || (adapter.canonical_name = cn_kimi_coding
           && List.exists env_present kimi_coding_key_envs)
     | Vertex_adc { project_env; _ } -> env_present project_env)
  | None -> false
;;

(** Derive the auth_kind string for a provider by looking up its
    adapter config, instead of hardcoding vendor env var names. *)
let auth_kind_for_canonical_name name =
  match resolve_direct_adapter name with
  | Some adapter ->
    if adapter.canonical_name = cn_kimi_api
    then "api_key:KIMI_API_KEY_SB|KIMI_API_KEY"
    else if adapter.canonical_name = cn_kimi_coding
    then "api_key:KIMI_CODING_API_KEY|KIMI_API_KEY_SB"
    else string_of_auth_mode adapter.auth_mode
  | None -> "unknown"
;;

let bare_ollama_migration_message () =
  "Bare `ollama` without a model requires OLLAMA_DEFAULT_MODEL env var. Use \
   `ollama:<model>` for explicit selection."
;;

let is_bare_ollama_label label =
  let normalized = normalize_label label in
  String.equal normalized cn_ollama && Env_config_runtime.Ollama.default_model = ""
;;

let explicit_llama_model_id_result () =
  match nonempty_env "LLAMA_DEFAULT_MODEL" with
  | Some model_id -> Ok model_id
  | None ->
    (match nonempty_env "MASC_DEFAULT_PROVIDER", nonempty_env "MASC_DEFAULT_MODEL" with
     | Some provider, Some model_id
       when String.equal (String.lowercase_ascii provider) cn_llama -> Ok model_id
     | _ ->
       Error
         "LLAMA_DEFAULT_MODEL is not set; configure LLAMA_DEFAULT_MODEL or \
          MASC_DEFAULT_PROVIDER=llama with MASC_DEFAULT_MODEL")
;;

let explicit_llama_model_label_result () =
  Result.map make_local_label (explicit_llama_model_id_result ())
;;

let gemini_direct_available () =
  env_present google_cloud_project_env || env_present gemini_api_key_env
;;

let configured_default_model_label_result () =
  match Env_config.Model_defaults.default_cascade_opt () with
  | Some raw ->
    let labels = split_csv_nonempty raw in
    (match labels with
     | first :: _ -> Ok first
     | [] -> Error "MASC_DEFAULT_CASCADE is set but empty")
  | None ->
    (match nonempty_env "MASC_DEFAULT_PROVIDER", nonempty_env "MASC_DEFAULT_MODEL" with
     | Some provider, Some model_id -> Ok (provider ^ ":" ^ model_id)
     | Some _, None ->
       Error "MASC_DEFAULT_MODEL is required when MASC_DEFAULT_PROVIDER is set"
     | None, Some _ ->
       Error "MASC_DEFAULT_PROVIDER is required when MASC_DEFAULT_MODEL is set"
     | None, None -> Error "No explicit default model configured")
;;

let configured_verifier_model_label_result () =
  match nonempty_env "MASC_DEFAULT_VERIFIER_MODEL" with
  | Some label -> Ok label
  | None -> configured_default_model_label_result ()
;;

let provider_model_label provider model =
  if model = "" then None else Some (Printf.sprintf "%s:%s" provider model)
;;

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
  | Cli_agent | Direct_api ->
    (match adapter.default_model_id with
     | Some _ -> Ok (adapter.cascade_prefix ^ ":auto")
     | None ->
       Error
         (Printf.sprintf
            "Provider '%s' requires explicit runtime_model"
            adapter.canonical_name))
;;

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
  if not is_available
  then None
  else (
    match default_model_label_for_adapter adapter with
    | Ok label -> Some label
    | Error msg ->
      Log.Misc.warn "[ProviderAdapter] default_model_label_for_adapter failed: %s" msg;
      None)
;;

(** Cloud adapters that participate in auto-detection (excludes llama
    which requires explicit model config, and openrouter which requires
    explicit runtime_model). *)
let auto_detect_adapters =
  List.filter
    (fun (adapter : adapter) ->
       adapter.runtime_kind = Direct_api && adapter.canonical_name <> cn_openrouter)
    direct_adapters
;;

let preferred_execution_model_labels () =
  let explicit =
    [ (match configured_default_model_label_result () with
       | Ok label -> Some label
       | Error _ -> None)
    ; (match explicit_llama_model_label_result () with
       | Ok label -> Some label
       | Error _ -> None)
      (* No hardcoded provider preference here.  Model order is determined
         by MASC cascade.toml via [Cascade_config], not by this adapter module.
         The auto_detect list below only serves as a last-resort fallback when
         no cascade source is available. *)
    ]
  in
  Json_util.dedupe_keep_order
    (List.filter_map Fun.id explicit
     @ List.filter_map auto_label_for_adapter auto_detect_adapters)
;;

let preferred_verifier_model_labels () =
  let explicit =
    [ (match configured_verifier_model_label_result () with
       | Ok label -> Some label
       | Error _ -> None)
    ; (match explicit_llama_model_label_result () with
       | Ok label -> Some label
       | Error _ -> None)
    ]
  in
  Json_util.dedupe_keep_order
    (List.filter_map Fun.id explicit
     @ List.filter_map auto_label_for_adapter auto_detect_adapters)
;;

let default_model_labels_result () =
  let labels = preferred_execution_model_labels () in
  if labels = []
  then
    Error
      "No default model configured; set LLAMA_DEFAULT_MODEL, MASC_DEFAULT_CASCADE, \
       MASC_DEFAULT_PROVIDER/MASC_DEFAULT_MODEL, or a supported cloud provider \
       credential"
  else Ok labels
;;

let default_model_label_result () =
  match default_model_labels_result () with
  | Ok (first :: _) -> Ok first
  | Ok [] -> Error "No default model configured"
  | Error _ as e -> e
;;

let provider_prefix_of_label_result label =
  let normalized = String.trim label in
  match String.index_opt normalized ':' with
  | Some idx when idx > 0 ->
    Ok (String.sub normalized 0 idx |> String.trim |> String.lowercase_ascii)
  | _ ->
    Error
      (Printf.sprintf "Default model label must be provider:model, got: %s" normalized)
;;

let provider_label_of_provider_kind (kind : Llm_provider.Provider_config.provider_kind)
  : string
  =
  let cn = adapter_canonical_name_of_provider_kind kind in
  match resolve_direct_adapter cn with
  | Some adapter -> adapter.cascade_prefix
  | None -> cn
;;

let provider_label_of_explicit_prefix (prefix : string) : string option =
  let normalized = normalize_label prefix in
  match resolve_adapter_by_cascade_prefix normalized with
  | Some adapter -> Some adapter.cascade_prefix
  | None -> if String.equal normalized cn_custom then Some cn_custom else None
;;

(** Classify a model label to a provider name for telemetry grouping.

    This is intentionally conservative. ["provider:model"] labels use the
    adapter registry as the typed boundary. Bare model ids are classified only
    when OAS supplies a typed [provider_kind]; otherwise they remain
    ["unknown"] so metrics do not pretend a substring guess is ground truth. *)
let provider_of_model_label ?provider_kind (model : string) : string =
  let explicit =
    match provider_prefix_of_label_result model with
    | Ok prefix -> provider_label_of_explicit_prefix prefix
    | Error _ -> None
  in
  match explicit, provider_kind with
  | Some provider, _ -> provider
  | None, Some kind -> provider_label_of_provider_kind kind
  | None, None -> "unknown"
;;

let adapter_of_registry_label label =
  match resolve_adapter_by_cascade_prefix label with
  | Some adapter -> Some adapter
  | None -> resolve_direct_adapter label
;;

let supports_runtime_mcp_http_headers_for_model_label ?provider_kind model =
  let provider_label =
    match provider_prefix_of_label_result model with
    | Ok prefix -> prefix
    | Error _ ->
      (match provider_kind with
       | Some kind -> provider_label_of_provider_kind kind
       | None -> model)
  in
  match adapter_of_registry_label provider_label with
  | Some adapter -> adapter.tool_policy.supports_runtime_mcp_http_headers
  | None -> false
;;

(** Whether a provider emits no usage tokens in its standard response.

    Used by metrics coverage gating: a text-only turn against one of
    these providers cannot produce a usage_reported=true record even on
    success, so we don't count that as a coverage gap. The set matches
    the CLI-class providers where the CLI strips or elides usage before
    returning to the caller. *)
let is_structurally_unmetered_provider (provider : string) : bool =
  let adapter =
    match resolve_adapter_by_cascade_prefix provider with
    | Some adapter -> Some adapter
    | None -> resolve_direct_adapter provider
  in
  match adapter with
  | Some { telemetry_policy = { usage_reporting = Missing_by_design; _ }; _ } -> true
  | Some _ | None -> false
;;

let default_model_provider_prefix_result () =
  match default_model_label_result () with
  | Ok label -> provider_prefix_of_label_result label
  | Error _ as e -> e
;;

let default_model_override_label_result model_id =
  let model_id = String.trim model_id in
  if model_id = ""
  then Error "default:<model> requires a non-empty model id"
  else (
    match default_model_provider_prefix_result () with
    | Ok provider -> Ok (provider ^ ":" ^ model_id)
    | Error _ as e -> e)
;;

let vertex_location () =
  match Sys.getenv_opt google_cloud_location_env with
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then "global" else trimmed
  | None -> "global"
;;

let resolve_gemini_direct_auth () =
  match Sys.getenv_opt google_cloud_project_env with
  | Some raw when String.trim raw <> "" ->
    Gemini_vertex_adc { project = String.trim raw; location = vertex_location () }
  | _ ->
    (match Sys.getenv_opt gemini_api_key_env with
     | Some raw when String.trim raw <> "" -> Gemini_api_key
     | _ ->
       Gemini_auth_missing
         "Gemini auth unavailable; set GOOGLE_CLOUD_PROJECT for Vertex ADC or \
          GEMINI_API_KEY")
;;

let gemini_vertex_openai_base_url ~project ~location =
  Printf.sprintf
    "https://aiplatform.googleapis.com/v1/projects/%s/locations/%s/endpoints/openapi"
    project
    location
;;

let same_base_url left right =
  String.equal (normalize_base_url left) (normalize_base_url right)
;;

let openai_compat_adapter_by_endpoint (cfg : Llm_provider.Provider_config.t) =
  if cfg.kind <> Llm_provider.Provider_config.OpenAI_compat
  then None
  else
    List.find_opt
      (fun (adapter : adapter) ->
         adapter.runtime_kind = Direct_api
         &&
         match adapter.endpoint_url with
         | Some endpoint when endpoint <> "" -> same_base_url endpoint cfg.base_url
         | Some _ | None -> false)
      direct_adapters
;;

let provider_label_from_registry (cfg : Llm_provider.Provider_config.t) =
  match openai_compat_adapter_by_endpoint cfg with
  | Some adapter -> adapter.cascade_prefix
  | None -> Llm_provider.Provider_registry.provider_name_of_config cfg
;;

(** [apply_wire_overlay ~provider_cfg provider] returns [provider] with
    its wire-layer transport rewritten when the SDK's
    {!Agent_sdk.Provider.config_of_provider_config} mapping under-routes
    an [OpenAI_compat] cfg as [Local] (no support for a custom
    [request_path] / auth header).

    Behaviour:
    - When [provider_cfg.kind = OpenAI_compat] AND the SDK produced
      [Local { base_url }] AND [provider_cfg.request_path] is not the
      default OpenAI chat-completions path, the [provider] field is
      rewrapped as [OpenAICompat { base_url; auth_header; path;
      static_token }] so the configured non-default path and optional
      auth token actually reach the wire.
    - All other shapes are returned unchanged.

    Keeper-layer callers ({!Cascade_agent_context.default_config}) used
    to inline this match on [provider_cfg.kind] and
    [provider.provider]. RFC-0058 Phase 5.6 moves that inspection into
    this single boundary helper so adding another OpenAI-compatible
    transport (vLLM, lmstudio, OpenRouter) only requires touching this
    adapter module — keeper code never names a provider variant. *)
let apply_wire_overlay
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (provider : Agent_sdk.Provider.config)
  : Agent_sdk.Provider.config
  =
  match provider_cfg.kind, provider.provider with
  | Llm_provider.Provider_config.OpenAI_compat, Agent_sdk.Provider.Local { base_url }
    when not
           (String.equal
              provider_cfg.request_path
              Masc_network_defaults.openai_chat_completions_path) ->
    let api_key_trimmed = String.trim provider_cfg.api_key in
    let auth_header =
      if String.equal api_key_trimmed "" then None else Some auth_header_authorization
    in
    let static_token =
      if String.equal api_key_trimmed "" then None else Some api_key_trimmed
    in
    { provider with
      provider =
        Agent_sdk.Provider.OpenAICompat
          { base_url; auth_header; path = provider_cfg.request_path; static_token }
    }
  | _ -> provider
;;

let adapter_of_provider_config (cfg : Llm_provider.Provider_config.t) =
  (* RFC-0058 §2.4: dispatch flows through the kind→canonical_name table
     ([adapter_canonical_name_of_provider_kind]) rather than enumerating
     every provider variant inline. [Glm] and [OpenAI_compat] still need
     a registry lookup because multiple distinct providers share the
     same [kind]: [OpenAI_compat] is disambiguated by [base_url] via
     [openai_compat_adapter_by_endpoint], while [Glm] is disambiguated
     by registry label ([glm] vs [glm-coding]) via
     [provider_name_of_config]. [provider_label_from_registry] folds
     both into the same [cascade_prefix] key. *)
  match cfg.kind with
  | Llm_provider.Provider_config.Glm | Llm_provider.Provider_config.OpenAI_compat ->
    resolve_adapter_by_cascade_prefix (provider_label_from_registry cfg)
  | kind -> resolve_direct_adapter (adapter_canonical_name_of_provider_kind kind)
;;

(* RFC-0058 §2.4 boundary: callers with only the typed [provider_kind]
   (no full provider config) resolve to an adapter through the same
   registry lookup as [adapter_of_provider_config]. Returns [None] for
   kinds that need a [cascade_prefix] string to disambiguate (Glm /
   OpenAI_compat) — those callers must use [adapter_of_provider_config]
   or a label-based resolver instead. *)
let adapter_of_provider_kind (kind : Llm_provider.Provider_config.provider_kind) =
  match kind with
  | Glm | OpenAI_compat -> None
  | _ -> resolve_direct_adapter (adapter_canonical_name_of_provider_kind kind)
;;

let provider_label_of_config (cfg : Llm_provider.Provider_config.t) =
  match adapter_of_provider_config cfg with
  | Some adapter -> adapter.cascade_prefix
  | None -> provider_label_from_registry cfg
;;

let provider_health_key_of_config (cfg : Llm_provider.Provider_config.t) =
  match cfg.kind with
  | Llm_provider.Provider_config.OpenAI_compat
    when Llm_provider.Provider_config.is_local cfg ->
    let base_url = String.trim cfg.base_url in
    if base_url = ""
    then provider_label_of_config cfg
    else Printf.sprintf "%s:%s@%s" (provider_label_of_config cfg) cfg.model_id base_url
  | _ -> provider_label_of_config cfg
;;

let provider_model_health_key_of_config cfg =
  Printf.sprintf "%s:%s" (provider_health_key_of_config cfg) cfg.model_id
;;

let display_provider_name_of_config (cfg : Llm_provider.Provider_config.t) =
  display_provider_name (provider_label_of_config cfg)
;;

let model_label_of_config (cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf "%s:%s" (display_provider_name_of_config cfg) cfg.model_id
;;

let supports_runtime_mcp_http_headers_for_config (cfg : Llm_provider.Provider_config.t) =
  match adapter_of_provider_config cfg with
  | Some adapter -> adapter.tool_policy.supports_runtime_mcp_http_headers
  | None -> false
;;

let requires_per_keeper_bridging_for_bound_actor_tools_for_config
      (cfg : Llm_provider.Provider_config.t)
  =
  match adapter_of_provider_config cfg with
  | Some adapter -> adapter.tool_policy.requires_per_keeper_bridging_for_bound_actor_tools
  | None -> false
;;

(** RFC-0058 §2.4 SSOT bridge: build a [tool_policy] record from a
    cascade-decl [cascade_capabilities] (the TOML-parsed shape).

    [None] (no [[providers.<id>.capabilities]] sub-table declared in
    cascade.toml) returns [no_tool_http_headers] — the conservative
    baseline that matches the historical hardcoded defaults.

    [Some c] maps the [tool_policy]-relevant subset of
    [cascade_capabilities] (seven fields:
    [supports_runtime_mcp_http_headers],
    [requires_per_keeper_bridging_for_bound_actor_tools],
    [identity_runtime_mcp_header_keys], [argv_prompt_preflight],
    [uses_anthropic_caching], [max_turns_per_attempt],
    [tolerates_bound_actor_fallback]).  The remaining capability
    fields ([supports_inline_tools], [supports_runtime_mcp_tools],
    [supports_runtime_tool_events]) describe runtime tool / event
    surfaces and are intentionally outside the [tool_policy] shape;
    they are consumed elsewhere (e.g. [Provider_tool_support]).

    Caller cutover plan: a future PR will route
    [adapter_of_provider_config] through this bridge so that
    [config/cascade.toml] becomes the lookup root for [tool_policy] and
    the 13 hardcoded [tool_policy = ...] records collapse into a single
    cascade-toml-driven path. This PR adds the primitive only;
    no caller swaps. *)
let tool_policy_of_cascade_capabilities
      (caps : Cascade_declarative_types.cascade_capabilities option)
  =
  match caps with
  | None -> no_tool_http_headers
  | Some c ->
    { supports_runtime_mcp_http_headers = c.supports_runtime_mcp_http_headers
    ; requires_per_keeper_bridging_for_bound_actor_tools =
        c.requires_per_keeper_bridging_for_bound_actor_tools
    ; identity_runtime_mcp_header_keys = c.identity_runtime_mcp_header_keys
    ; argv_prompt_preflight = c.argv_prompt_preflight
    ; uses_anthropic_caching = c.uses_anthropic_caching
    ; max_turns_per_attempt = c.max_turns_per_attempt
    ; tolerates_bound_actor_fallback = c.tolerates_bound_actor_fallback
    }
;;

let requires_per_keeper_bridging_for_bound_actor_tools_for_kind
      (kind : Llm_provider.Provider_config.provider_kind)
  =
  match adapter_of_provider_kind kind with
  | Some adapter -> adapter.tool_policy.requires_per_keeper_bridging_for_bound_actor_tools
  | None -> false
;;

let tolerates_bound_actor_fallback_for_kind
      (kind : Llm_provider.Provider_config.provider_kind)
  =
  match adapter_of_provider_kind kind with
  | Some adapter -> adapter.tool_policy.tolerates_bound_actor_fallback
  | None -> false
;;

(** Normalize a header key for case-insensitive comparison against
    [tool_policy.identity_runtime_mcp_header_keys]. *)
let normalize_header_key key = String.lowercase_ascii (String.trim key)

let accepts_runtime_mcp_http_header_for_config
      (cfg : Llm_provider.Provider_config.t)
      (key : string)
  =
  match adapter_of_provider_config cfg with
  | None -> false
  | Some adapter ->
    if adapter.tool_policy.supports_runtime_mcp_http_headers
    then true
    else (
      let normalized = normalize_header_key key in
      List.exists
        (fun k -> normalize_header_key k = normalized)
        adapter.tool_policy.identity_runtime_mcp_header_keys)
;;

(** SSOT for the OAS provider_kind → capabilities mapping.  This is the
    one place that pattern-matches on [Llm_provider.Provider_config.provider_kind]
    for capability lookup — RFC-0058 §2.4 forbids the dispatch in consumer
    modules; centralising it here keeps consumers off the closed variant. *)
let oas_capabilities_of_config (cfg : Llm_provider.Provider_config.t) =
  match cfg.kind with
  | Llm_provider.Provider_config.Ollama -> Llm_provider.Capabilities.ollama_capabilities
  | Anthropic -> Llm_provider.Capabilities.anthropic_capabilities
  | Kimi -> Llm_provider.Capabilities.kimi_capabilities
  | Glm -> Llm_provider.Capabilities.glm_capabilities
  | Gemini -> Llm_provider.Capabilities.gemini_capabilities
  | DashScope -> Llm_provider.Capabilities.dashscope_capabilities
  | OpenAI_compat -> Llm_provider.Capabilities.openai_chat_capabilities
  | Claude_code -> Llm_provider.Capabilities.claude_code_capabilities
  | Gemini_cli -> Llm_provider.Capabilities.gemini_cli_capabilities
  | Kimi_cli -> Llm_provider.Capabilities.kimi_cli_capabilities
  | Codex_cli -> Llm_provider.Capabilities.codex_cli_capabilities
;;

(* ── Generic provider auth detail ─────────────────────────────── *)

(** Provider-agnostic auth detail for dashboard display.
    Encapsulates vendor-specific auth logic (e.g. Gemini Vertex/API key)
    so consumers do not branch on vendor names. *)
type auth_detail =
  { auth_kind : string
  ; status : string
  ; available : bool
  ; supports_run : bool
  ; endpoint_url : string option
  ; note : string option
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
let cascade_prefix_of_provider_kind (kind : Llm_provider.Provider_config.provider_kind)
  : string
  =
  let cn = adapter_canonical_name_of_provider_kind kind in
  match resolve_direct_adapter cn with
  | Some a -> a.cascade_prefix
  | None -> cn
;;

let provider_kind_of_declarative_protocol raw =
  match normalize_label raw with
  | "anthropic-cli" -> Some Llm_provider.Provider_config.Claude_code
  | "anthropic-http" -> Some Llm_provider.Provider_config.Anthropic
  | "openai-cli" -> Some Llm_provider.Provider_config.Codex_cli
  | "openai-http" -> Some Llm_provider.Provider_config.OpenAI_compat
  | "google-cli" -> Some Llm_provider.Provider_config.Gemini_cli
  | "kimi-cli" -> Some Llm_provider.Provider_config.Kimi_cli
  | "ollama-http" -> Some Llm_provider.Provider_config.Ollama
  | _ -> None
;;

let cascade_prefix_of_declarative_protocol raw =
  provider_kind_of_declarative_protocol raw
  |> Option.map cascade_prefix_of_provider_kind
;;

(** Resolve auth detail for any provider by canonical name or alias.
    Gemini-specific Vertex ADC vs API Key logic is internal. *)
let auth_detail_of_provider provider =
  match resolve_direct_adapter provider with
  | None ->
    { auth_kind = "unknown"
    ; status = "unsupported"
    ; available = false
    ; supports_run = false
    ; endpoint_url = None
    ; note = Some "Unsupported provider"
    }
  | Some adapter ->
    let auth_kind_base =
      if adapter.canonical_name = cn_kimi_api
      then "api_key:KIMI_API_KEY"
      else string_of_auth_mode adapter.auth_mode
    in
    if adapter.canonical_name = cn_gemini_api
    then (
      match resolve_gemini_direct_auth () with
      | Gemini_api_key ->
        { auth_kind = "api_key:GEMINI_API_KEY"
        ; status = "configured"
        ; available = true
        ; supports_run = true
        ; endpoint_url = Some (gemini_generative_api_url ())
        ; note = None
        }
      | Gemini_vertex_adc { project; location } ->
        { auth_kind = Printf.sprintf "vertex_adc:%s:%s" project location
        ; status = "vertex_adc"
        ; available = true
        ; supports_run = false
        ; endpoint_url = Some (gemini_vertex_openai_base_url ~project ~location)
        ; note =
            Some
              "Dashboard run MVP only supports Gemini via GEMINI_API_KEY. Vertex ADC \
               inventory is visible but run is disabled."
        }
      | Gemini_auth_missing message ->
        { auth_kind = auth_kind_base
        ; status = "missing_auth"
        ; available = false
        ; supports_run = false
        ; endpoint_url = None
        ; note = Some message
        })
    else if adapter.runtime_kind = Cli_agent
    then (
      let available = provider_auth_available provider in
      { auth_kind = auth_kind_base
      ; status = (if available then "configured" else "missing_auth")
      ; available
      ; supports_run = available
      ; endpoint_url = None
      ; note =
          Some "Cached CLI login is assumed; final validation happens at execution time."
      })
    else (
      let available = provider_auth_available provider in
      { auth_kind = auth_kind_base
      ; status = (if available then "configured" else "missing_auth")
      ; available
      ; supports_run = available
      ; endpoint_url = endpoint_url_of_adapter adapter
      ; note = None
      })
;;

let auth_env_keys_of_provider_kind (kind : Llm_provider.Provider_config.provider_kind)
  : string list
  =
  (* RFC-0058 §2.4: Kimi and Gemini have non-adapter overrides
     (multi-key fallback list and Vertex env pair respectively);
     every other kind defers to the adapter's [auth_mode]. The
     wildcard branch covers all current and future provider_kind
     variants without enumerating them. *)
  match kind with
  | Llm_provider.Provider_config.Kimi -> kimi_api_key_envs
  | Llm_provider.Provider_config.Gemini ->
    [ google_cloud_project_env; google_cloud_location_env ]
  | _ ->
    let adapter_name = adapter_canonical_name_of_provider_kind kind in
    (match resolve_direct_adapter adapter_name with
     | Some adapter ->
       (match adapter.auth_mode with
        | Api_key env_name -> [ env_name ]
        | No_auth | Cli_cached_login | Vertex_adc _ ->
          Option.to_list (Llm_provider.Provider_config.default_api_key_env kind))
     | None -> Option.to_list (Llm_provider.Provider_config.default_api_key_env kind))
;;

let docker_auth_env_keys_of_provider_config (cfg : Llm_provider.Provider_config.t)
  : string list
  =
  (* Docker sandboxes invoke OpenAI_compat over loopback against the
     local-runtime pool, which carries no remote credentials; every
     other kind delegates to the keyset its adapter declares. Gemini
     uses the API-key env (not Vertex ADC) inside the sandbox because
     ADC files are not mounted. *)
  match cfg.kind with
  | Llm_provider.Provider_config.OpenAI_compat ->
    let uri = Uri.of_string cfg.base_url in
    if Masc_network_defaults.is_loopback_host_opt (Uri.host uri)
    then []
    else auth_env_keys_of_provider_kind cfg.kind
  | Llm_provider.Provider_config.Gemini -> [ gemini_api_key_env ]
  | _ -> auth_env_keys_of_provider_kind cfg.kind
;;

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
;;

(* is_spawnable removed: use is_spawnable_agent directly. *)
