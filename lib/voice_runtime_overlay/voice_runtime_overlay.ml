(** Voice runtime overlay.

    This module owns voice-only runtime resolution so the LLM
    the removed provider-adapter boundary no longer needs to export TTS/STT/session
    helpers. *)

type transport =
  | Openai_compat
  | Elevenlabs_direct
  | Voice_mcp
  | Macos_say
  | Whisper_cli

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

type voice_listing_request =
  { listing_url : string
  ; listing_headers : (string * string) list
  }

(* A command to run, argv already split. No shell: a message to speak is
   arbitrary text, and handing it to a shell would make quoting the thing that
   decides what runs. *)
type command_request = { argv : string list }

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
  | Macos_say -> "macos_say"
  | Whisper_cli -> "whisper_cli"
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

(* The two that run a command rather than reach an address.

   They are separate kinds rather than one "local command" because the argv
   each takes is different -- say wants -v and -o, whisper-cli wants -m, -l and
   -f -- and picking between them by looking at the command name would be a
   string classifier deciding how to call a program. A kind names a calling
   convention here the same way it names a wire protocol for the other three.

   Neither takes a credential: nothing leaves the machine. *)
let macos_say_adapter =
  { canonical_name = "macos-say"
  ; transport = Macos_say
  ; auth_mode = No_auth
  ; aliases = [ "macos-say"; "macos_say"; "say" ]
  }
;;

let whisper_cli_adapter =
  { canonical_name = "whisper-cli"
  ; transport = Whisper_cli
  ; auth_mode = No_auth
  ; aliases = [ "whisper-cli"; "whisper_cli"; "whisper-cpp"; "whisper" ]
  }
;;

let adapters =
  [ openai_compat_adapter
  ; elevenlabs_direct_adapter
  ; voice_mcp_adapter
  ; macos_say_adapter
  ; whisper_cli_adapter
  ]
;;

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
  | Voice_config.Macos_say -> macos_say_adapter
  | Voice_config.Whisper_cli -> whisper_cli_adapter
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
  (* Neither of these speaks HTTP. They are reached by running a command, and
     the caller picks that path by asking for a command request instead. *)
  | Voice_mcp | Macos_say | Whisper_cli -> false
;;

let endpoint_supports_http_tts endpoint =
  adapter_for_endpoint endpoint |> transport_supports_http_tts
;;

(* RFC-0166: the default per-agent voice mapping was a closed roster
   of MCP-client names ("claude"/"codex"/"gemini"/"llama"). The
   server holds no such roster; operators supply per-agent voices
   through [voice_bridge_core] config (TOML/JSON). When the
   operator has not configured anything, callers fall back to this
   empty list and the voice runtime picks its provider default. *)
let default_agent_voices () = []
;;

let trim_opt = Env_config_core.trim_opt

let normalize_base_url value =
  let trimmed = String.trim value in
  if String.length trimmed > 1 && String.ends_with ~suffix:"/" trimmed
  then String.sub trimmed 0 (String.length trimmed - 1)
  else trimmed
;;

(* Where the overlay reaches the MASC server.

   [MASC_HTTP_BASE_URL] says it outright and wins. Without it the server is the
   one on this machine, so the address is loopback and the port is the one it
   listens on.

   It used to read MASC_HOST here. That is the server's bind address -- its
   documented non-default values are the wildcards 0.0.0.0 and ::, which
   [Masc_network_defaults.is_unspecified_host] names as "every interface"
   rather than a reachable peer -- so setting it the way the server's own help
   recommends built "http://0.0.0.0:<port>" and called it a base URL. A port
   has no such wildcard, so it is still read from the listener.

   The branch that chose between two spellings of this is gone with it: both
   arms produced the same string, and the predicate that picked between them
   had this as its only caller. *)
let default_session_base_url () =
  match Sys.getenv_opt Env_config_core.http_base_url_env_key |> trim_opt with
  | Some base_url -> normalize_base_url base_url
  | None ->
    Printf.sprintf
      "http://%s:%s"
      Masc_network_defaults.masc_http_loopback_peer
      (Env_config_core.masc_http_port ())
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

let default_elevenlabs_base_url = Voice_config.default_elevenlabs_base_url

let endpoint_base_url (endpoint : Voice_config.endpoint) =
  match adapter_for_endpoint endpoint with
  | { transport = Elevenlabs_direct; _ } ->
    (match endpoint.base_url with
     | Some value -> Some (normalize_base_url value)
     | None -> Some default_elevenlabs_base_url)
  | _ -> Option.map normalize_base_url endpoint.base_url
;;

let is_elevenlabs_voice_id value =
  let len = String.length value in
  len >= 20
  && len <= 64
  && String.for_all
       (function
         | '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' -> true
         | _ -> false)
       value
;;

let elevenlabs_voice_id_result voice =
  match String.trim voice with
  | "" ->
    Error
      "ElevenLabs direct TTS requires a configured voice_id; set tts.default_voice \
       or an agent-specific voice in voice config."
  | value ->
    if is_elevenlabs_voice_id value
    then Ok value
    else
      Error
        (Printf.sprintf
           "ElevenLabs direct TTS requires a configured voice_id (got %S). Add \
            shared/library voices to the account first, then store the resulting \
            voice_id in voice config."
           value)
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
  | Some _, (Macos_say | Whisper_cli) ->
    Error
      (Printf.sprintf
         "voice config endpoint %s runs a command and has no HTTP TTS request"
         endpoint.id)
  | Some base_url, Openai_compat ->
    let headers =
      [ "Content-Type", "application/json"; "Accept", "audio/mpeg" ]
      @ if api_key = "" then [] else [ "Authorization", "Bearer " ^ api_key ]
    in
    (* [voice_tuning] is stability / similarity_boost / style — the ElevenLabs
       voice_settings object. OpenAI's /v1/audio/speech takes model, input,
       voice, response_format and speed, so those three were spec-external
       fields sent to a server that never asked for them (#24068). There is no
       OpenAI-side tuning in the config to send instead: the record carries
       only the ElevenLabs three. Declaring a per-transport tuning type is the
       fuller fix and a config-schema change; this stops the leak. *)
    let body_json =
      `Assoc
        [ "input", `String message
        ; "voice", `String voice
        ; "model", `String model
        ; "response_format", `String "mp3"
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
    (match elevenlabs_voice_id_result voice with
     | Error err -> Error err
     | Ok voice_id ->
       Ok
         { url = Printf.sprintf "%s/text-to-speech/%s" base_url voice_id
         ; headers
         ; body_json
         })
;;

(* The voices an endpoint will admit to having.

   Only ElevenLabs answers this. Its list lives on a different API version than
   everything else masc sends it -- /v1 carries speech, /v2 carries the
   catalogue -- so the version is swapped rather than the path appended, and a
   base_url that does not end in a version is left alone and asked as it is.

   An OpenAI-compatible server has no such route: /v1/audio/speech takes a
   voice name and there is no listing beside it in the spec, and the two local
   servers this runbook names answer 404. Saying that is the honest answer, not
   a gap to fill with a guess at a vendor path. *)
let elevenlabs_catalogue_url base_url =
  let version = "/v1" in
  let length = String.length base_url and version_length = String.length version in
  if length >= version_length
     && String.equal (String.sub base_url (length - version_length) version_length) version
  then String.sub base_url 0 (length - version_length) ^ "/v2/voices"
  else base_url ^ "/voices"
;;

let voice_listing_request_for_endpoint (endpoint : Voice_config.endpoint) ~api_key =
  let adapter = adapter_for_endpoint endpoint in
  match adapter.transport with
  | Macos_say | Whisper_cli ->
    Error
      (Printf.sprintf
         "voice config endpoint %s runs a command and has no HTTP voice catalogue"
         endpoint.id)
  | Openai_compat ->
    Error
      (Printf.sprintf
         "voice config endpoint %s speaks the OpenAI shape, which has no voice list \
          to ask for: type the voice name the server expects"
         endpoint.id)
  | Voice_mcp ->
    Error
      (Printf.sprintf
         "voice config endpoint %s is reached through a tool, which is asked to \
          speak rather than asked what it can speak with"
         endpoint.id)
  | Elevenlabs_direct ->
    (match endpoint_base_url endpoint with
     | None -> Error (Printf.sprintf "voice config endpoint %s missing base_url" endpoint.id)
     | Some base_url ->
       Ok
         { listing_url = elevenlabs_catalogue_url base_url
         ; listing_headers = [ "xi-api-key", api_key ]
         })
;;

(* The two kinds that are a command rather than an address.

   Each argv below was run before it was written down. [say] is in the base
   system at /usr/bin/say and carries nine Korean voices, so speech out on a
   fresh mac needs nothing installed. [whisper-cli] comes from
   `brew install whisper-cpp` and takes the model as a file.

   masc records at 16 kHz mono 16-bit WAV already, which is the format
   whisper.cpp requires, so nothing is converted between the microphone and
   this. And -l auto detected Korean at p = 0.9986 on a sample from say, so
   there is no language to configure. *)
let macos_say_command = "say"
let whisper_cli_command = "whisper-cli"

let endpoint_command (endpoint : Voice_config.endpoint) ~default =
  match endpoint.Voice_config.command with
  | Some command when String.trim command <> "" -> String.trim command
  | Some _ | None -> default
;;

(* WAVE because it is what say can actually encode and what every player
   masc hands a clip to reads. LEI16@22050 is say's own default sample
   format for this container; naming it keeps the bytes the same across
   macOS releases rather than following whatever the default becomes. *)
let macos_say_file_format = "WAVE"
let macos_say_data_format = "LEI16@22050"

let tts_command_for_endpoint (endpoint : Voice_config.endpoint) ~voice ~message ~output_file =
  let adapter = adapter_for_endpoint endpoint in
  match adapter.transport with
  | Openai_compat | Elevenlabs_direct | Voice_mcp ->
    Error
      (Printf.sprintf
         "voice config endpoint %s is reached over %s, not by running a command"
         endpoint.Voice_config.id
         (string_of_transport adapter.transport))
  | Whisper_cli ->
    Error
      (Printf.sprintf "voice config endpoint %s transcribes and does not speak"
         endpoint.Voice_config.id)
  | Macos_say ->
    let command = endpoint_command endpoint ~default:macos_say_command in
    (* A blank voice is not an error: say then uses the system voice, which is
       what a reader who never picked one has been listening to all along. *)
    let voice_args = if String.trim voice = "" then [] else [ "-v"; String.trim voice ] in
    (* The container and the samples are stated, never left to the file
       name. say reads the extension only to pick an encoder, and it has no
       MP3 one: measured 2026-09-13 on macOS 26, [say -o clip.mp3] exits 0
       having written a 16-byte empty MP3 tag frame -- silence that reaches
       the listener with no error anywhere. Named here, the same sentence
       came back as 111KB of 16-bit mono WAVE. *)
    Ok
      { argv =
          (command :: voice_args)
          @ [ "--file-format=" ^ macos_say_file_format
            ; "--data-format=" ^ macos_say_data_format
            ; "-o"
            ; output_file
            ; message
            ]
      }
;;

(* The command that lists the voices installed on this machine.

   say publishes its own catalogue, and a fresh mac needs it more than a hosted
   provider does: say does not fail on a voice it does not have. It exits 0 and
   speaks in the system voice, so a mistyped name is silent -- measured
   2026-09-12, where "Eddy" alone gave an English voice reading Korean and
   "Eddy (한국어(한국))" gave the Korean one. A name typed from memory is a
   coin flip; a name picked from this list is not. *)
let voice_listing_command_for_endpoint (endpoint : Voice_config.endpoint) =
  let adapter = adapter_for_endpoint endpoint in
  match adapter.transport with
  | Macos_say ->
    let command = endpoint_command endpoint ~default:macos_say_command in
    Ok { argv = [ command; "-v"; "?" ] }
  | Whisper_cli ->
    Error
      (Printf.sprintf "voice config endpoint %s transcribes and has no voices"
         endpoint.Voice_config.id)
  | Openai_compat | Elevenlabs_direct | Voice_mcp ->
    Error
      (Printf.sprintf
         "voice config endpoint %s is reached over %s, which is not asked by running a \
          command"
         endpoint.Voice_config.id
         (string_of_transport adapter.transport))
;;

let stt_command_for_endpoint (endpoint : Voice_config.endpoint) ~audio_file ~model =
  let adapter = adapter_for_endpoint endpoint in
  match adapter.transport with
  | Openai_compat | Elevenlabs_direct | Voice_mcp ->
    Error
      (Printf.sprintf
         "voice config endpoint %s is reached over %s, not by running a command"
         endpoint.Voice_config.id
         (string_of_transport adapter.transport))
  | Macos_say ->
    Error
      (Printf.sprintf "voice config endpoint %s speaks and does not transcribe"
         endpoint.Voice_config.id)
  | Whisper_cli ->
    (* The model is a file here rather than a name, which is what the section's
       model already means to this command. Blank is refused rather than
       defaulted to a path that may not exist: a wrong path fails inside
       whisper with a message about the model, and a reader should be told
       which setting is empty instead. *)
    if String.trim model = ""
    then
      Error
        (Printf.sprintf
           "voice config endpoint %s needs the model file to transcribe with; set the \
            section's default_model to the path of a ggml model"
           endpoint.Voice_config.id)
    else (
      let command = endpoint_command endpoint ~default:whisper_cli_command in
      Ok
        { argv =
            [ command
            ; "-m"
            ; String.trim model
            ; "-l"
            ; "auto"
            ; "-nt"
            ; "-f"
            ; audio_file
            ]
        })
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
  | Some _, (Macos_say | Whisper_cli) ->
    Error
      (Printf.sprintf
         "voice config endpoint %s runs a command and has no HTTP STT request"
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
