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

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;

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
let cn_claude = "claude_code"
let cn_codex = "codex_cli"
let cn_gemini = "gemini_cli"
let cn_kimi = "kimi_cli"
let cn_claude_api = "claude"
let cn_codex_api = "openai"
let cn_gemini_api = "gemini"
let cn_kimi_api = "kimi"
let cn_glm = "glm"
let cn_glm_coding_plan = "glm-coding"
let cn_openrouter = "openrouter"

let display_provider_name label =
  match normalize_label label with
  | "glm" | "glm-api" -> cn_glm
  | "glm-coding" | "glm-coding-plan" -> cn_glm_coding_plan
  | "kimi-api" -> cn_kimi_api
  | _ -> String.trim label
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

module Runtime_binding = Agent_sdk.Provider_runtime_binding

let binding_labels (binding : Runtime_binding.t) =
  let id = binding.Runtime_binding.id in
  let dashed_id = String.map (function '_' -> '-' | c -> c) id in
  let local_aliases =
    if String.equal id cn_llama then [ "llama.cpp"; "llamacpp" ] else []
  in
  id :: dashed_id :: binding.Runtime_binding.aliases @ local_aliases
  |> List.filter_map trim_nonempty
  |> List.map normalize_label
  |> Json_util.dedupe_keep_order
;;

let find_runtime_binding_by_candidates candidates =
  let rec loop = function
    | [] -> None
    | candidate :: rest ->
      (match trim_nonempty candidate with
       | None -> loop rest
       | Some label ->
         (match Runtime_binding.find label with
          | Some _ as binding -> binding
          | None -> loop rest))
  in
  loop candidates
;;

let binding_endpoint_url (binding : Runtime_binding.t) =
  trim_nonempty binding.Runtime_binding.base_url
;;

let binding_default_model_id (binding : Runtime_binding.t) =
  match Option.bind binding.Runtime_binding.default_model trim_nonempty with
  | Some _ as value -> value
  | None ->
    (match binding.Runtime_binding.capabilities.supported_models with
     | Some (model :: _) -> trim_nonempty model
     | Some [] | None -> None)
;;

let binding_auth_env_keys (binding : Runtime_binding.t) =
  let auth_env =
    match binding.Runtime_binding.auth with
    | Runtime_binding.Api_key_env env | Runtime_binding.Setup_token_env env -> [ env ]
    | Runtime_binding.No_auth
    | Runtime_binding.Cli_cached_login
    | Runtime_binding.Oauth_cached_login
    | Runtime_binding.File _
    | Runtime_binding.Exec _ -> []
  in
  binding.Runtime_binding.api_key_env :: auth_env
  |> List.filter_map trim_nonempty
  |> Json_util.dedupe_keep_order
;;

let binding_primary_api_key_env binding =
  match binding_auth_env_keys binding with
  | first :: _ -> Some first
  | [] -> None
;;

let binding_base_url_is_loopback binding =
  match binding_endpoint_url binding with
  | None -> false
  | Some base_url -> Uri.of_string base_url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
;;

let binding_auth_is_no_auth (binding : Runtime_binding.t) =
  match binding.Runtime_binding.auth with
  | Runtime_binding.No_auth -> true
  | Runtime_binding.Api_key_env _
  | Runtime_binding.Cli_cached_login
  | Runtime_binding.Oauth_cached_login
  | Runtime_binding.Setup_token_env _
  | Runtime_binding.File _
  | Runtime_binding.Exec _ -> false
;;

let runtime_kind_of_binding (binding : Runtime_binding.t) =
  match binding.Runtime_binding.transport with
  | Runtime_binding.Cli -> Cli_agent
  | Runtime_binding.Http | Runtime_binding.Managed | Runtime_binding.Custom_openai_compat ->
    if binding_auth_is_no_auth binding && binding_base_url_is_loopback binding
    then Local
    else Direct_api
;;

let binding_supports_runtime_mcp_http_headers (binding : Runtime_binding.t) =
  binding.Runtime_binding.capabilities.supports_runtime_mcp_tools
  || binding.Runtime_binding.capabilities.supports_runtime_tool_events
  || (runtime_kind_of_binding binding = Cli_agent
      && binding.Runtime_binding.capabilities.supports_tools)
;;

let binding_uses_prompt_caching (binding : Runtime_binding.t) =
  binding.Runtime_binding.capabilities.supports_prompt_caching
  || binding.Runtime_binding.capabilities.supports_caching
;;

let binding_usage_missing_by_design (binding : Runtime_binding.t) =
  not binding.Runtime_binding.capabilities.emits_usage_tokens
;;

(** Ask OAS to name a provider kind. This is intentionally a best-effort
    kind-only path; callers with a full config should use
    [provider_label_from_registry] so OpenAI-compatible and GLM endpoints can
    be disambiguated by URL. *)
let provider_name_of_kind (kind : Llm_provider.Provider_config.provider_kind) =
  let cfg =
    Llm_provider.Provider_config.make ~kind ~model_id:"auto" ~base_url:"" ()
  in
  Llm_provider.Provider_registry.provider_name_of_config cfg
;;

(** Map OAS [provider_kind] to the adapter canonical name when only the typed
    kind is available. The mapping itself lives in OAS Provider_registry; this
    helper remains only as the legacy MASC API boundary. *)
let adapter_canonical_name_of_provider_kind
  : Llm_provider.Provider_config.provider_kind -> string
  =
  provider_name_of_kind
;;

let binding_env_fragment (binding : Runtime_binding.t) =
  binding.Runtime_binding.id
  |> String.map (function
    | 'a' .. 'z' as c -> Char.uppercase_ascii c
    | 'A' .. 'Z' | '0' .. '9' as c -> c
    | _ -> '_')
;;

let model_family_of_binding (binding : Runtime_binding.t) =
  match binding.Runtime_binding.kind, binding.Runtime_binding.id with
  | Llm_provider.Provider_config.Glm, "glm-coding" -> Glm_coding
  | Llm_provider.Provider_config.Glm, _ -> Glm_general
  | Llm_provider.Provider_config.Kimi, _ -> Kimi_api_family
  | _ -> Generic
;;

let first_catalog_model models =
  models |> List.find_map trim_nonempty
;;

let catalog_default_model_id_of_binding (binding : Runtime_binding.t) =
  match model_family_of_binding binding with
  | Glm_general -> first_catalog_model (Llm_provider.Zai_catalog.glm_auto_models ())
  | Glm_coding -> first_catalog_model (Llm_provider.Zai_catalog.glm_coding_auto_models ())
  | Generic | Kimi_api_family -> None
;;

let default_model_id_of_binding (binding : Runtime_binding.t) =
  match binding_default_model_id binding with
  | Some _ as value -> value
  | None ->
    (match catalog_default_model_id_of_binding binding with
     | Some _ as value -> value
     | None ->
       (match runtime_kind_of_binding binding with
        | Local -> None
        | Cli_agent | Direct_api -> Some "auto"))
;;

let auto_models_of_binding binding default_model_id =
  match runtime_kind_of_binding binding with
  | Cli_agent ->
    Some
      (Env_csv_or_default
         { env_var = "MASC_" ^ binding_env_fragment binding ^ "_AUTO_MODELS"
         ; defaults = [ Option.value default_model_id ~default:"auto" ]
         ; prefer_default_model_env = false
         })
  | Local | Direct_api ->
    (match model_family_of_binding binding with
     | Glm_general -> Some Zai_general_auto_models
     | Glm_coding -> Some Zai_coding_auto_models
     | Generic | Kimi_api_family -> None)
;;

let auth_mode_of_binding (binding : Runtime_binding.t) =
  match binding_primary_api_key_env binding with
  | Some env_name -> Api_key env_name
  | None ->
    (match runtime_kind_of_binding binding with
     | Cli_agent -> Cli_cached_login
     | Local | Direct_api -> No_auth)
;;

let tool_policy_of_binding (binding : Runtime_binding.t) =
  let requires_bridging =
    match binding.Runtime_binding.command with
    | Some "codex" -> true
    | Some _ | None -> false
  in
  { supports_runtime_mcp_http_headers =
      binding_supports_runtime_mcp_http_headers binding && not requires_bridging
  ; requires_per_keeper_bridging_for_bound_actor_tools = requires_bridging
  ; identity_runtime_mcp_header_keys =
      (if requires_bridging
       then [ "authorization"; "x-masc-agent-name"; "x-masc-keeper-name" ]
       else [])
  ; argv_prompt_preflight = requires_bridging
  ; uses_anthropic_caching = binding_uses_prompt_caching binding
  ; max_turns_per_attempt =
      Llm_provider.Provider_config.max_turns_hard_cap binding.Runtime_binding.kind
  ; tolerates_bound_actor_fallback =
      (not requires_bridging)
      && (binding_supports_runtime_mcp_http_headers binding
          || runtime_kind_of_binding binding <> Direct_api)
  }
;;

let telemetry_policy_of_binding (binding : Runtime_binding.t) =
  if runtime_kind_of_binding binding = Cli_agent || binding_usage_missing_by_design binding
  then telemetry_usage_missing
  else telemetry_reported
;;

let spawn_key_of_binding (binding : Runtime_binding.t) =
  match binding.Runtime_binding.command with
  | Some ("claude" | "codex" | "gemini" | "llama" as command) -> Some command
  | Some _ | None -> None
;;

let generic_adapter_of_binding (binding : Runtime_binding.t) =
  let default_model_id = default_model_id_of_binding binding in
  let auto_models = auto_models_of_binding binding default_model_id in
  { canonical_name = binding.Runtime_binding.id
  ; runtime_kind = runtime_kind_of_binding binding
  ; auth_mode = auth_mode_of_binding binding
  ; aliases = binding_labels binding
  ; spawn_key = spawn_key_of_binding binding
  ; cascade_prefix = binding.Runtime_binding.id
  ; endpoint_url = binding_endpoint_url binding
  ; default_model_id
  ; model_policy =
      { default_model_env =
          Some (binding_env_fragment binding ^ "_DEFAULT_MODEL")
      ; default_model_fallback = default_model_id
      ; auto_models = Option.value auto_models ~default:No_auto_models
      ; expand_auto = Option.is_some auto_models
      ; family = model_family_of_binding binding
      }
  ; tool_policy = tool_policy_of_binding binding
  ; telemetry_policy = telemetry_policy_of_binding binding
  }
;;

let direct_adapters =
  Runtime_binding.all () |> List.map generic_adapter_of_binding
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
     | Api_key env_name -> env_present env_name
     | Vertex_adc { project_env; _ } -> env_present project_env)
  | None -> false
;;

(** Derive the auth_kind string for a provider by looking up its
    adapter config, instead of hardcoding vendor env var names. *)
let auth_kind_for_canonical_name name =
  match resolve_direct_adapter name with
  | Some adapter -> string_of_auth_mode adapter.auth_mode
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
    match
      List.find_opt
        (fun (adapter : adapter) ->
           adapter.runtime_kind = Direct_api
           &&
           match adapter.endpoint_url with
           | Some endpoint when endpoint <> "" -> same_base_url endpoint cfg.base_url
           | Some _ | None -> false)
        direct_adapters
    with
    | Some _ as adapter -> adapter
    | None -> None
;;

let provider_label_from_registry (cfg : Llm_provider.Provider_config.t) =
  match openai_compat_adapter_by_endpoint cfg with
  | Some adapter -> adapter.cascade_prefix
  | None -> Llm_provider.Provider_registry.provider_name_of_config cfg
;;

let adapter_of_provider_config (cfg : Llm_provider.Provider_config.t) =
  resolve_adapter_by_cascade_prefix (provider_label_from_registry cfg)
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

let oas_capabilities_of_config (cfg : Llm_provider.Provider_config.t) =
  Agent_sdk.Provider_runtime_binding.capabilities_for_provider_config cfg
;;

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

let auth_env_keys_of_provider_kind (kind : Llm_provider.Provider_config.provider_kind)
  : string list
  =
  (* Gemini keeps its Vertex ADC pair for host inventory; every other kind
     defers to OAS runtime binding/default env metadata. *)
  match kind with
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
    | Api_key env_name -> [ env_name ]
    | Vertex_adc _ -> [])
  |> List.sort_uniq String.compare
;;

(* is_spawnable removed: use is_spawnable_agent directly. *)
