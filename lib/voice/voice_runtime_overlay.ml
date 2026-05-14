(** Voice runtime overlay.

    This module owns voice-only runtime resolution so the LLM
    [Provider_adapter] boundary no longer needs to export TTS/STT/session
    helpers. *)

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

let normalize_label label = String.trim label |> String.lowercase_ascii

let string_of_transport = function
  | Openai_compat -> "openai_compat"
  | Elevenlabs_direct -> "elevenlabs_direct"
  | Voice_mcp -> "voice_mcp"
;;

let openai_compat_adapter =
  { canonical_name = "voice-openai-compat"
  ; transport = Openai_compat
  ; auth_mode = No_auth
  ; aliases =
      [ "voice-openai-compat"; "openai_compat"; "openai"; "railway-elevenlabs-proxy" ]
  }
;;

let elevenlabs_direct_adapter =
  { canonical_name = "elevenlabs-direct"
  ; transport = Elevenlabs_direct
  ; auth_mode = Api_key "ELEVENLABS_API_KEY"
  ; aliases = [ "elevenlabs-direct"; "elevenlabs"; "tts-elevenlabs" ]
  }
;;

let voice_mcp_adapter =
  { canonical_name = "voice-mcp"
  ; transport = Voice_mcp
  ; auth_mode = No_auth
  ; aliases = [ "voice-mcp"; "voice_mcp"; "mcp"; "local-voice-mcp" ]
  }
;;

let adapters = [ openai_compat_adapter; elevenlabs_direct_adapter; voice_mcp_adapter ]

let resolve_adapter label =
  let normalized = normalize_label label in
  List.find_opt
    (fun (adapter : adapter) ->
       List.exists (fun alias -> normalize_label alias = normalized) adapter.aliases)
    adapters
;;

let adapter_labels (adapter : adapter) =
  adapter.canonical_name :: string_of_transport adapter.transport :: adapter.aliases
;;

let adapter_for_endpoint_kind = function
  | Voice_config.Openai_compat -> openai_compat_adapter
  | Voice_config.Elevenlabs_direct -> elevenlabs_direct_adapter
  | Voice_config.Voice_mcp -> voice_mcp_adapter
;;

let adapter_for_endpoint (endpoint : Voice_config.endpoint) =
  match resolve_adapter endpoint.id with
  | Some adapter -> adapter
  | None -> adapter_for_endpoint_kind endpoint.kind
;;

let endpoint_matches_provider_label label (endpoint : Voice_config.endpoint) =
  let normalized = normalize_label label in
  let adapter = adapter_for_endpoint endpoint in
  let candidates =
    endpoint.id
    :: Voice_config.string_of_endpoint_kind endpoint.kind
    :: adapter_labels adapter
  in
  List.exists
    (fun candidate -> String.equal (normalize_label candidate) normalized)
    candidates
;;

let select_endpoints ?provider (endpoints : Voice_config.endpoint list) =
  let endpoints =
    List.filter (fun (endpoint : Voice_config.endpoint) -> endpoint.enabled) endpoints
  in
  match provider with
  | Some label when String.trim label <> "" ->
    List.filter (endpoint_matches_provider_label label) endpoints
  | _ -> endpoints
;;

let auth_env_name ?endpoint_api_key_env (adapter : adapter) =
  match endpoint_api_key_env with
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed <> ""
    then Some trimmed
    else (
      match adapter.auth_mode with
      | Api_key env_name -> Some env_name
      | No_auth -> None)
  | None ->
    (match adapter.auth_mode with
     | Api_key env_name -> Some env_name
     | No_auth -> None)
;;

let endpoint_auth_env_name (endpoint : Voice_config.endpoint) =
  let adapter = adapter_for_endpoint endpoint in
  auth_env_name ?endpoint_api_key_env:endpoint.api_key_env adapter
;;

let transport_supports_http_tts (adapter : adapter) =
  match adapter.transport with
  | Openai_compat | Elevenlabs_direct -> true
  | Voice_mcp -> false
;;

let endpoint_supports_http_tts endpoint =
  adapter_for_endpoint endpoint |> transport_supports_http_tts
;;

let default_agent_voices () = []

let trim_opt = function
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
  | None -> None
;;

let normalize_base_url value =
  let trimmed = String.trim value in
  if String.length trimmed > 1 && String.ends_with ~suffix:"/" trimmed
  then String.sub trimmed 0 (String.length trimmed - 1)
  else trimmed
;;

let legacy_voice_env_warning_emitted = Atomic.make false

let warn_legacy_voice_env_once () =
  if not (Atomic.get legacy_voice_env_warning_emitted)
  then (
    Atomic.set legacy_voice_env_warning_emitted true;
    Log.Misc.warn
      "VOICE_MCP_HOST/PORT fallback is deprecated; prefer .masc/voice_config.json \
       session.endpoints or MASC_HTTP_* listener settings.")
;;

let legacy_voice_base_url_opt () =
  let host_opt = Sys.getenv_opt "VOICE_MCP_HOST" |> trim_opt in
  let port_opt = Sys.getenv_opt "VOICE_MCP_PORT" |> trim_opt in
  match host_opt, port_opt with
  | None, None -> None
  | _ ->
    warn_legacy_voice_env_once ();
    let host = Option.value host_opt ~default:Env_config.Voice.default_host in
    let port =
      Option.value port_opt ~default:(string_of_int Env_config.Voice.default_port)
    in
    Some (Printf.sprintf "http://%s:%s" host port)
;;

let http_listener_env_explicit () =
  Option.is_some (Sys.getenv_opt Env_config_core.http_base_url_env_key |> trim_opt)
  || Option.is_some (Sys.getenv_opt Env_config_core.host_env_key |> trim_opt)
  || Option.is_some (Sys.getenv_opt Env_config_core.http_port_env_key |> trim_opt)
;;

let default_session_base_url () =
  match Sys.getenv_opt Env_config_core.http_base_url_env_key |> trim_opt with
  | Some base_url -> normalize_base_url base_url
  | None ->
    if http_listener_env_explicit ()
    then
      Printf.sprintf
        "http://%s:%s"
        (Env_config_core.masc_host ())
        (Env_config_core.masc_http_port ())
    else (
      match legacy_voice_base_url_opt () with
      | Some legacy_base_url -> normalize_base_url legacy_base_url
      | None ->
        Printf.sprintf
          "http://%s:%s"
          (Env_config_core.masc_host ())
          (Env_config_core.masc_http_port ()))
;;

let compose_endpoint_url ~base_url ~path =
  let base_uri = Uri.of_string base_url in
  let base_path = Uri.path base_uri in
  let base_path =
    if base_path = ""
    then "/"
    else if String.ends_with ~suffix:"/" base_path && String.length base_path > 1
    then String.sub base_path 0 (String.length base_path - 1)
    else base_path
  in
  let final_path =
    if path = "/mcp"
    then
      if String.ends_with ~suffix:"/mcp" base_path
      then base_path
      else if base_path = "/"
      then "/mcp"
      else base_path ^ "/mcp"
    else if path = "/health"
    then
      if String.ends_with ~suffix:"/health" base_path
      then base_path
      else if String.ends_with ~suffix:"/mcp" base_path
      then String.sub base_path 0 (String.length base_path - 4) ^ "/health"
      else if base_path = "/"
      then "/health"
      else base_path ^ "/health"
    else if base_path = "/"
    then path
    else base_path ^ path
  in
  Uri.with_path base_uri final_path |> Uri.to_string
;;

let default_session_url ~path =
  compose_endpoint_url ~base_url:(default_session_base_url ()) ~path
;;

let session_endpoint_result (config : Voice_config.t) =
  match Voice_config.select_endpoint config.session.endpoints with
  | Some endpoint ->
    let adapter = adapter_for_endpoint endpoint in
    if adapter.transport = Voice_mcp
    then Ok endpoint
    else Error (Printf.sprintf "session endpoint %s must use kind=voice_mcp" endpoint.id)
  | None -> Error "no configured session endpoint"
;;

let session_mcp_url_of_endpoint (endpoint : Voice_config.endpoint) =
  let adapter = adapter_for_endpoint endpoint in
  if adapter.transport <> Voice_mcp
  then
    Error (Printf.sprintf "session endpoint %s must use voice_mcp transport" endpoint.id)
  else (
    match endpoint.mcp_url with
    | Some url -> Ok url
    | None ->
      (match endpoint.base_url with
       | Some base_url -> Ok (compose_endpoint_url ~base_url ~path:"/mcp")
       | None -> Ok (default_session_url ~path:"/mcp")))
;;

let session_health_url_of_endpoint (endpoint : Voice_config.endpoint) =
  let adapter = adapter_for_endpoint endpoint in
  if adapter.transport <> Voice_mcp
  then
    Error (Printf.sprintf "session endpoint %s must use voice_mcp transport" endpoint.id)
  else (
    match endpoint.health_url with
    | Some url -> Ok url
    | None ->
      (match endpoint.base_url with
       | Some base_url -> Ok (compose_endpoint_url ~base_url ~path:"/health")
       | None -> Ok (default_session_url ~path:"/health")))
;;

let default_elevenlabs_base_url = Voice_config.default_elevenlabs_base_url

let endpoint_base_url (endpoint : Voice_config.endpoint) =
  match adapter_for_endpoint endpoint with
  | { transport = Elevenlabs_direct; _ } ->
    (match endpoint.base_url with
     | Some value -> Some (normalize_base_url value)
     | None -> Some default_elevenlabs_base_url)
  | _ -> Option.map normalize_base_url endpoint.base_url
;;

let elevenlabs_voice_id voice =
  match String.trim voice with
  | "Sarah" -> "EXAVITQu4vr4xnSDxMaL"
  | "Roger" -> "CwhRBWXzGAHq8TQ4Fs17"
  | "George" -> "JBFqnCBsd6RMkjVDRZzb"
  | "Laura" -> "FGY2WhTYpPnrIDTdsKH5"
  | "" -> "21m00Tcm4TlvDq8ikWAM"
  | value -> value
;;

let http_request_for_tts
      (endpoint : Voice_config.endpoint)
      ~api_key
      ~message
      ~voice
      ~model
      ~(tuning : Voice_config.voice_tuning)
  =
  let adapter = adapter_for_endpoint endpoint in
  match endpoint_base_url endpoint, adapter.transport with
  | None, _ ->
    Error (Printf.sprintf "voice config endpoint %s missing base_url" endpoint.id)
  | Some _, Voice_mcp ->
    Error
      (Printf.sprintf
         "voice config endpoint %s uses voice_mcp and cannot build HTTP TTS request"
         endpoint.id)
  | Some base_url, Openai_compat ->
    let headers =
      [ "Content-Type", "application/json"; "Accept", "audio/mpeg" ]
      @ if api_key = "" then [] else [ "Authorization", "Bearer " ^ api_key ]
    in
    let body_json =
      `Assoc
        [ "input", `String message
        ; "voice", `String voice
        ; "model", `String model
        ; "response_format", `String "mp3"
        ; ( "voice_settings"
          , `Assoc
              [ "stability", `Float tuning.stability
              ; "similarity_boost", `Float tuning.similarity_boost
              ; "style", `Float tuning.style
              ] )
        ]
    in
    Ok { url = base_url ^ "/audio/speech"; headers; body_json }
  | Some base_url, Elevenlabs_direct ->
    let headers =
      [ "xi-api-key", api_key
      ; "Content-Type", "application/json"
      ; "Accept", "audio/mpeg"
      ]
    in
    let body_json =
      `Assoc
        [ "text", `String message
        ; "model_id", `String model
        ; ( "voice_settings"
          , `Assoc
              [ "stability", `Float tuning.stability
              ; "similarity_boost", `Float tuning.similarity_boost
              ; "style", `Float tuning.style
              ] )
        ]
    in
    Ok
      { url = Printf.sprintf "%s/text-to-speech/%s" base_url (elevenlabs_voice_id voice)
      ; headers
      ; body_json
      }
;;

let stt_request_for_endpoint (endpoint : Voice_config.endpoint) ~api_key ~audio_file ~model =
  let adapter = adapter_for_endpoint endpoint in
  match endpoint_base_url endpoint, adapter.transport with
  | None, _ ->
    Error (Printf.sprintf "voice config endpoint %s missing base_url" endpoint.id)
  | Some _, Voice_mcp ->
    Error
      (Printf.sprintf
         "voice config endpoint %s uses voice_mcp and cannot build HTTP STT request"
         endpoint.id)
  | Some base_url, Openai_compat ->
    let headers = if api_key = "" then [] else [ "Authorization", "Bearer " ^ api_key ] in
    Ok
      { url = base_url ^ "/audio/transcriptions"
      ; headers
      ; form_fields = [ "model", model ]
      ; file_field = "file", audio_file
      }
  | Some base_url, Elevenlabs_direct ->
    let headers = [ "xi-api-key", api_key ] in
    Ok
      { url = base_url ^ "/speech-to-text"
      ; headers
      ; form_fields = [ "model_id", model ]
      ; file_field = "file", audio_file
      }
;;
