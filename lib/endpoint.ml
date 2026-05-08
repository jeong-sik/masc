(* RFC-0041 — Endpoint as the only provider abstraction. *)

type transport =
  | Http of
      { base_url : string
      ; request_path : string
      }
  | Cli_subprocess of
      { binary : string
      ; spawn_key : string
      }

type auth =
  | None_required
  | Bearer of { env_var : string }
  | X_api_key of
      { env_var : string
      ; version_header : (string * string) option
      }
  | Url_query_key of { env_var : string }
  | Cli_cached_login
  | Vertex_adc of
      { project_env_var : string
      ; location_env_var : string
      }

type body_schema =
  | Anthropic_content_blocks
  | OpenAI_messages
  | OpenAI_messages_with_thinking
  | Ollama_options
  | Gemini_contents_parts
  | Cli_args_text
  | Cli_args_json

type stream_format =
  | Sse_openai_delta
  | Sse_anthropic_blocks
  | Sse_gemini_server_content
  | Ndjson_ollama
  | Cli_stdout_text
  | Cli_stdout_stream_json

type discovery_method =
  | No_discovery
  | Models_endpoint of { path : string }
  | Ps_endpoint of { path : string }

type capabilities =
  { supports_runtime_mcp_http_headers : bool
  ; supports_per_call_mcp_config : bool
  ; emits_usage_telemetry : bool
  }

type t =
  { label_prefix : string
  ; display_name : string
  ; transport : transport
  ; auth : auth
  ; body_schema : body_schema
  ; stream_format : stream_format
  ; capabilities : capabilities
  ; discovery : discovery_method
  }

(* URL resolution helpers — same logic as Provider_adapter.{env_url_or,
   registry_default_base_url}. Inlined here so this module is independent of
   Provider_adapter (which dies in PR-D / PR-E). Drift between the two is
   caught by [test/test_endpoint.ml] alignment guards. *)

let env_url_or ~env ~default =
  match Sys.getenv_opt env with
  | Some url ->
    let trimmed = String.trim url in
    if trimmed <> "" then trimmed else default
  | None -> default
;;

let registry_default_base_url name =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry name with
  | Some entry -> entry.defaults.base_url
  | None -> ""
;;

(* Resolved at module load time, mirroring Provider_adapter.direct_adapters
   evaluation timing. Process-startup env var changes are not picked up
   afterwards — same constraint as today. *)

let llama_base_url = Env_config_runtime.Llama.server_url
let ollama_base_url = Env_config_runtime.Ollama.server_url

let claude_api_base_url =
  env_url_or ~env:"ANTHROPIC_API_URL" ~default:(registry_default_base_url "claude")
;;

let openai_base_url = env_url_or ~env:"OPENAI_API_URL" ~default:"https://api.openai.com"

let gemini_api_base_url =
  env_url_or ~env:"GEMINI_API_URL" ~default:(registry_default_base_url "gemini")
;;

let glm_general_base_url =
  env_url_or ~env:"ZAI_BASE_URL" ~default:Llm_provider.Zai_catalog.general_base_url
;;

let glm_coding_base_url =
  env_url_or ~env:"ZAI_CODING_BASE_URL" ~default:Llm_provider.Zai_catalog.coding_base_url
;;

let kimi_compat_base_url =
  env_url_or ~env:"KIMI_BASE_URL" ~default:"https://api.moonshot.ai/v1"
;;

let kimi_coding_base_url =
  env_url_or ~env:"KIMI_CODING_BASE_URL" ~default:"https://api.kimi.com/coding/v1"
;;

let openrouter_base_url =
  env_url_or ~env:"OPENROUTER_API_URL" ~default:(registry_default_base_url "openrouter")
;;

(* Anthropic API version header — fixed since 2023-06-01. *)
let anthropic_version_header = "anthropic-version", "2023-06-01"

(* The 14-entry registry, 1:1 with Provider_adapter.direct_adapters. *)

let llama : t =
  { label_prefix = "llama"
  ; display_name = "llama-server (local)"
  ; transport = Http { base_url = llama_base_url; request_path = "/v1/chat/completions" }
  ; auth = None_required
  ; body_schema = OpenAI_messages
  ; stream_format = Sse_openai_delta
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = false
      ; emits_usage_telemetry = false
      }
  ; discovery = Models_endpoint { path = "/v1/models" }
  }
;;

let ollama : t =
  { label_prefix = "ollama"
  ; display_name = "Ollama (local)"
  ; transport = Http { base_url = ollama_base_url; request_path = "/api/chat" }
  ; auth = None_required
  ; body_schema = Ollama_options
  ; stream_format = Ndjson_ollama
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = false
      ; emits_usage_telemetry = true (* done:true line carries eval_count *)
      }
  ; discovery = Ps_endpoint { path = "/api/ps" }
  }
;;

let claude_cli : t =
  { label_prefix = "claude_code"
  ; display_name = "Claude Code (CLI)"
  ; transport = Cli_subprocess { binary = "claude"; spawn_key = "claude" }
  ; auth = Cli_cached_login
  ; body_schema = Cli_args_text
  ; stream_format = Cli_stdout_stream_json
  ; capabilities =
      { supports_runtime_mcp_http_headers = true
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = false (* CLI strips usage tokens *)
      }
  ; discovery = No_discovery
  }
;;

let codex_cli : t =
  { label_prefix = "codex_cli"
  ; display_name = "Codex (CLI)"
  ; transport = Cli_subprocess { binary = "codex"; spawn_key = "codex" }
  ; auth = Cli_cached_login
  ; body_schema = Cli_args_text
  ; stream_format = Cli_stdout_text
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = false
      }
  ; discovery = No_discovery
  }
;;

let gemini_cli : t =
  { label_prefix = "gemini_cli"
  ; display_name = "Gemini (CLI)"
  ; transport = Cli_subprocess { binary = "gemini"; spawn_key = "gemini" }
  ; auth = Cli_cached_login
  ; body_schema = Cli_args_json
  ; stream_format = Cli_stdout_text
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = false
      ; (* gemini-cli #4674 unimplemented *)
        emits_usage_telemetry = false
      }
  ; discovery = No_discovery
  }
;;

let kimi_cli : t =
  { label_prefix = "kimi_cli"
  ; display_name = "Kimi (CLI)"
  ; transport = Cli_subprocess { binary = "kimi"; spawn_key = "kimi" }
  ; auth = Cli_cached_login
  ; body_schema = Cli_args_text
  ; stream_format = Cli_stdout_text
  ; capabilities =
      { supports_runtime_mcp_http_headers = true
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = false
      }
  ; discovery = No_discovery
  }
;;

let claude_api : t =
  { label_prefix = "claude"
  ; display_name = "Claude (Anthropic Direct API)"
  ; transport = Http { base_url = claude_api_base_url; request_path = "/v1/messages" }
  ; auth =
      X_api_key
        { env_var = "ANTHROPIC_API_KEY"; version_header = Some anthropic_version_header }
  ; body_schema = Anthropic_content_blocks
  ; stream_format = Sse_anthropic_blocks
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = true
      }
  ; discovery = No_discovery
  }
;;

let codex_api : t =
  { label_prefix = "openai"
  ; display_name = "OpenAI (Direct API)"
  ; transport = Http { base_url = openai_base_url; request_path = "/v1/chat/completions" }
  ; auth = Bearer { env_var = "OPENAI_API_KEY" }
  ; body_schema = OpenAI_messages
  ; stream_format = Sse_openai_delta
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = true
      }
  ; discovery = No_discovery
  }
;;

let gemini_api : t =
  { label_prefix = "gemini"
  ; display_name = "Gemini (Vertex / Google Direct API)"
  ; transport =
      Http
        { base_url = gemini_api_base_url
        ; (* Gemini's full path is model-specific
       (/v1beta/models/{model}:streamGenerateContent); the base path here is
       the registry root, with model substitution handled at request build
       time. *)
          request_path = "/v1beta/models"
        }
  ; auth =
      Vertex_adc
        { project_env_var = "GOOGLE_CLOUD_PROJECT"
        ; location_env_var = "GOOGLE_CLOUD_LOCATION"
        }
  ; body_schema = Gemini_contents_parts
  ; stream_format = Sse_gemini_server_content
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = true
      }
  ; discovery = No_discovery
  }
;;

let kimi_api : t =
  { label_prefix = "kimi"
  ; display_name = "Kimi (Moonshot Direct API — Anthropic-shaped)"
  ; transport =
      Http
        { base_url = kimi_compat_base_url
        ; request_path = "/v1/messages" (* Anthropic-shaped endpoint *)
        }
  ; (* Bearer auth (OpenAI style) but Anthropic body — the §2.1 surprise. *)
    auth = Bearer { env_var = "KIMI_API_KEY_SB" }
  ; body_schema = Anthropic_content_blocks
  ; stream_format = Sse_anthropic_blocks
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = true
      }
  ; discovery = No_discovery
  }
;;

let kimi_coding : t =
  { label_prefix = "kimi_coding"
  ; display_name = "Kimi Coding (Direct API)"
  ; transport = Http { base_url = kimi_coding_base_url; request_path = "/v1/messages" }
  ; auth = Bearer { env_var = "KIMI_CODING_API_KEY" }
  ; body_schema = Anthropic_content_blocks
  ; stream_format = Sse_anthropic_blocks
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = true
      }
  ; discovery = No_discovery
  }
;;

let glm_api : t =
  { label_prefix = "glm"
  ; display_name = "GLM (Z.ai General)"
  ; transport =
      Http
        { base_url = glm_general_base_url
        ; request_path = "/chat/completions" (* no /v1 prefix — §2.1 surprise *)
        }
  ; auth = Bearer { env_var = "ZAI_API_KEY" }
  ; body_schema = OpenAI_messages_with_thinking
  ; stream_format = Sse_openai_delta
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = true
      }
  ; discovery = No_discovery
  }
;;

let glm_coding_plan : t =
  { label_prefix = "glm-coding"
  ; display_name = "GLM Coding (Z.ai Coding Plan)"
  ; transport =
      Http { base_url = glm_coding_base_url; request_path = "/chat/completions" }
  ; auth = Bearer { env_var = "ZAI_API_KEY" }
  ; body_schema = OpenAI_messages_with_thinking
  ; stream_format = Sse_openai_delta
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = true
      }
  ; discovery = No_discovery
  }
;;

let openrouter : t =
  { label_prefix = "openrouter"
  ; display_name = "OpenRouter (multi-provider gateway)"
  ; transport =
      Http { base_url = openrouter_base_url; request_path = "/api/v1/chat/completions" }
  ; auth = Bearer { env_var = "OPENROUTER_API_KEY" }
  ; body_schema = OpenAI_messages
  ; stream_format = Sse_openai_delta
  ; capabilities =
      { supports_runtime_mcp_http_headers = false
      ; supports_per_call_mcp_config = true
      ; emits_usage_telemetry = true
      }
  ; discovery = No_discovery
  }
;;

let direct_endpoints : t list =
  [ llama
  ; ollama
  ; claude_cli
  ; codex_cli
  ; gemini_cli
  ; kimi_cli
  ; claude_api
  ; codex_api
  ; gemini_api
  ; kimi_api
  ; kimi_coding
  ; glm_api
  ; glm_coding_plan
  ; openrouter
  ]
;;

let find_by_label_prefix lp =
  List.find_opt (fun (e : t) -> String.equal e.label_prefix lp) direct_endpoints
;;

let equal (a : t) (b : t) = String.equal a.label_prefix b.label_prefix
