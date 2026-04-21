(** Provider_adapter — provider registry, auth resolution, voice bridge,
    and cascade label construction.

    Single source of truth for all LLM and voice provider adapters.
    Adding a new provider = adding one entry to [direct_adapters].

    @since v2.100.0 *)

(** {1 Types} *)

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

type voice_transport =
  | Voice_openai_compat
  | Voice_elevenlabs_direct
  | Voice_mcp

type adapter = {
  canonical_name : string;
  runtime_kind : runtime_kind;
  auth_mode : auth_mode;
  aliases : string list;
  spawn_key : string option;
  cascade_prefix : string;
  default_voice : string option;
  endpoint_url : string option;
  default_model_id : string option;
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
  file_field : string * string;
}

type gemini_direct_auth =
  | Gemini_vertex_adc of {
      project : string;
      location : string;
    }
  | Gemini_api_key
  | Gemini_auth_missing of string

type auth_detail = {
  auth_kind : string;
  status : string;
  available : bool;
  supports_run : bool;
  endpoint_url : string option;
  note : string option;
}

(** {1 Canonical Provider Names} *)

val cn_llama : string
val cn_ollama : string
val cn_claude : string
val cn_codex : string
val cn_gemini : string
val cn_kimi : string
val cn_claude_api : string
val cn_codex_api : string
val cn_gemini_api : string
val cn_kimi_api : string
val cn_glm : string
val cn_glm_coding_plan : string
val cn_openrouter : string
val cn_custom : string

(** {1 String Converters} *)

val string_of_runtime_kind : runtime_kind -> string
val string_of_auth_mode : auth_mode -> string
val string_of_voice_transport : voice_transport -> string

(** {1 Adapter Registry} *)

(** All registered LLM provider/runtime adapters. *)
val direct_adapters : adapter list

(** All registered voice provider adapters. *)
val voice_adapters : voice_adapter list

(** {1 Label and Provider Resolution} *)

(** Normalize a label to lowercase trimmed form. *)
val normalize_label : string -> string

(** User-facing provider label for cascade/dashboard surfaces.
    Keeps wire/config prefixes stable while presenting distinct names for
    ambiguous providers such as [glm] vs [glm-coding]. *)
val display_provider_name : string -> string

(** SSOT cascade prefix for local models. *)
val local_cascade_prefix : string

(** Build a cascade model label for a local model.
    Single entry point; other modules must not concatenate prefix manually. *)
val make_local_label : string -> string

(** SSOT string form of OAS [Provider_config.provider_kind]. *)
val string_of_provider_kind :
  Llm_provider.Provider_config.provider_kind -> string

(** Resolve required auth env keys for a provider kind. *)
val auth_env_keys_of_provider_kind :
  Llm_provider.Provider_config.provider_kind -> string list

(** Resolve Docker worker auth env keys for a provider config. *)
val docker_auth_env_keys_of_provider_config :
  Llm_provider.Provider_config.t -> string list

(** Collect all auth env keys across direct adapters. *)
val all_auth_env_keys : unit -> string list

(** Resolve an adapter by canonical name or alias. *)
val resolve_direct_adapter : string -> adapter option

(** Resolve the canonical name for a provider label. *)
val resolve_direct_canonical_name : string -> string option

(** Resolve spawn_key for an agent label. *)
val resolve_spawn_key : string -> string option

(** Check if a name is a known direct adapter label or alias. *)
val is_known_provider : string -> bool

(** Check if a name is a CLI-spawnable agent (has a spawn_key). *)
val is_spawnable_agent : string -> bool

(** Return canonical names of all spawnable adapters. *)
val spawnable_canonical_names : unit -> string list

(** Returns true if the provider uses runtime discovery (e.g. live /props probe). *)
val requires_discovery : string -> bool

(** Returns true if the provider is self-hosted and always available. *)
val is_local_provider : string -> bool

(** {1 Voice Adapter Resolution} *)

val resolve_voice_adapter : string -> voice_adapter option
val voice_adapter_for_endpoint : Voice_config.endpoint -> voice_adapter
val voice_adapter_for_endpoint_kind : Voice_config.endpoint_kind -> voice_adapter
val voice_adapter_labels : voice_adapter -> string list
val voice_endpoint_matches_provider_label : string -> Voice_config.endpoint -> bool
val select_voice_endpoints :
  ?provider:string -> Voice_config.endpoint list -> Voice_config.endpoint list
(** Resolve auth env var name for a voice adapter, with optional endpoint override. *)
val voice_auth_env_name :
  ?endpoint_api_key_env:string -> voice_adapter -> string option

val voice_endpoint_auth_env_name : Voice_config.endpoint -> string option
val voice_transport_supports_http_tts : voice_adapter -> bool
val voice_endpoint_supports_http_tts : Voice_config.endpoint -> bool

(** All agent voices as [(canonical_name, voice_name)] pairs. *)
val all_agent_voices : unit -> (string * string) list

(** {1 Voice Session URLs} *)

val default_voice_session_url : path:string -> string
val voice_session_endpoint_result :
  Voice_config.t -> (Voice_config.endpoint, string) result
val voice_session_mcp_url_of_endpoint :
  Voice_config.endpoint -> (string, string) result
val voice_session_health_url_of_endpoint :
  Voice_config.endpoint -> (string, string) result

(** {1 Voice HTTP Requests} *)

val voice_http_request_for_tts :
  Voice_config.endpoint ->
  api_key:string ->
  message:string ->
  voice:string ->
  model:string ->
  tuning:Voice_config.voice_tuning ->
  (voice_http_request, string) result

val voice_stt_request_for_endpoint :
  Voice_config.endpoint ->
  api_key:string ->
  audio_file:string ->
  model:string ->
  (voice_stt_request, string) result

(** {1 Model Label Resolution} *)

(** Default fallback label for local runtime when no preferred models exist. *)
val default_local_fallback_label : unit -> string

(** Preferred execution model labels in priority order. *)
val preferred_execution_model_labels : unit -> string list

(** Preferred verifier model labels in priority order. *)
val preferred_verifier_model_labels : unit -> string list

(** Configured default model label (first from MASC_DEFAULT_CASCADE or
    MASC_DEFAULT_PROVIDER/MASC_DEFAULT_MODEL). *)
val configured_default_model_label_result : unit -> (string, string) result

(** Configured verifier model label (MASC_DEFAULT_VERIFIER_MODEL fallback to default). *)
val configured_verifier_model_label_result : unit -> (string, string) result

(** Default model label(s) result. *)
val default_model_labels_result : unit -> (string list, string) result

(** First default model label. *)
val default_model_label_result : unit -> (string, string) result

(** Extract provider prefix from a "provider:model" label. *)
val provider_prefix_of_label_result : string -> (string, string) result

(** Provider prefix of the default model label. *)
val default_model_provider_prefix_result : unit -> (string, string) result

(** Override the model portion of the default model label. *)
val default_model_override_label_result : string -> (string, string) result

(** Default local model label; raises [Invalid_arg] if unconfigured. *)
val default_local_model_label : unit -> string

(** {1 Llama Model Resolution} *)

val explicit_llama_model_id_result : unit -> (string, string) result
val explicit_llama_model_id : unit -> string
val explicit_llama_model_label_result : unit -> (string, string) result
val explicit_llama_model_label : unit -> string

(** {1 Ollama} *)

val bare_ollama_migration_message : unit -> string
val is_bare_ollama_label : string -> bool

(** {1 Auth} *)

(** Check whether a provider has auth credentials configured. *)
val provider_auth_available : string -> bool

(** Derive auth_kind string for a provider canonical name. *)
val auth_kind_for_canonical_name : string -> string

(** Provider-agnostic auth detail for dashboard display. *)
val auth_detail_of_provider : string -> auth_detail

(** Cascade prefix from adapter record. *)
val cascade_prefix_of_adapter : adapter -> string

(** Endpoint URL from adapter record. *)
val endpoint_url_of_adapter : adapter -> string option

(** Best-effort mapping from Provider_registry/OAS [provider_kind] to a
    MASC cascade prefix. *)
val cascade_prefix_of_provider_kind :
  Llm_provider.Provider_config.provider_kind -> string

(** {1 Gemini Auth} *)

val gemini_direct_available : unit -> bool
val resolve_gemini_direct_auth : unit -> gemini_direct_auth

(** Compute the Vertex AI OpenAI-compatible endpoint URL. *)
val gemini_vertex_openai_base_url : project:string -> location:string -> string

(** {1 Misc} *)

val default_cli_agent_name : unit -> string

(** Build "provider:model" label, returns [None] if model is empty. *)
val provider_model_label : string -> string -> string option

(** Extract the env var name from an adapter's [auth_mode], if any. *)
val auth_env_var_of_adapter : adapter -> string option
