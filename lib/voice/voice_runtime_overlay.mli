(** Voice runtime overlay.

    Voice TTS/STT/session endpoint rules are local MASC runtime concerns. They
    intentionally live outside [Provider_adapter], whose remaining boundary is
    LLM provider routing and capability projection. *)

type transport =
  | Openai_compat
  | Elevenlabs_direct
  | Voice_mcp

type auth_mode =
  | No_auth
  | Api_key of string

type adapter =
  { canonical_name : string
  ; transport : transport
  ; auth_mode : auth_mode
  ; aliases : string list
  }

type http_request =
  { url : string
  ; headers : (string * string) list
  ; body_json : Yojson.Safe.t
  }

type stt_request =
  { url : string
  ; headers : (string * string) list
  ; form_fields : (string * string) list
  ; file_field : string * string
  }

val string_of_transport : transport -> string
val adapters : adapter list
val resolve_adapter : string -> adapter option
val adapter_for_endpoint : Voice_config.endpoint -> adapter
val adapter_for_endpoint_kind : Voice_config.endpoint_kind -> adapter
val adapter_labels : adapter -> string list
val endpoint_matches_provider_label : string -> Voice_config.endpoint -> bool
val select_endpoints : ?provider:string -> Voice_config.endpoint list -> Voice_config.endpoint list
val auth_env_name : ?endpoint_api_key_env:string -> adapter -> string option
val endpoint_auth_env_name : Voice_config.endpoint -> string option
val transport_supports_http_tts : adapter -> bool
val endpoint_supports_http_tts : Voice_config.endpoint -> bool
val default_agent_voices : unit -> (string * string) list
val default_session_url : path:string -> string
val session_endpoint_result : Voice_config.t -> (Voice_config.endpoint, string) result
val session_mcp_url_of_endpoint : Voice_config.endpoint -> (string, string) result
val session_health_url_of_endpoint : Voice_config.endpoint -> (string, string) result

val http_request_for_tts
  :  Voice_config.endpoint
  -> api_key:string
  -> message:string
  -> voice:string
  -> model:string
  -> tuning:Voice_config.voice_tuning
  -> (http_request, string) result

val stt_request_for_endpoint
  :  Voice_config.endpoint
  -> api_key:string
  -> audio_file:string
  -> model:string
  -> (stt_request, string) result
