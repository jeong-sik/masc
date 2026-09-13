(** Voice runtime overlay.

    Voice TTS/STT/session endpoint rules are local MASC runtime concerns. They
    intentionally live outside the removed provider-adapter boundary; voice is
    separate from LLM provider routing and capability projection. *)

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

(** What to send an endpoint to ask which voices it has. Separate from
    {!http_request} because this one carries no body: it is a read. *)
type voice_listing_request =
  { listing_url : string
  ; listing_headers : (string * string) list
  }

(** A command to run, argv already split. No shell: a message to speak is
    arbitrary text, and handing it to a shell would make quoting decide what
    runs. *)
type command_request = { argv : string list }
type stt_request =
  { url : string
  ; headers : (string * string) list
  ; form_fields : (string * string) list
  ; file_field : string * string
  }

val resolve_adapter : string -> adapter option
val adapter_for_endpoint_kind : Voice_config.endpoint_kind -> adapter
(** The adapter a kind names, with no id consulted. {!adapter_for_endpoint}
    resolves the id first and falls back to this, so a caller that needs to know
    whether an id is pulling an endpoint away from its declared kind compares
    the two. *)

val adapter_for_endpoint : Voice_config.endpoint -> adapter
val select_endpoints : ?provider:string -> Voice_config.endpoint list -> Voice_config.endpoint list
val auth_env_name : ?endpoint_api_key_env:string -> adapter -> string option
val endpoint_auth_env_name : Voice_config.endpoint -> string option
val transport_supports_http_tts : adapter -> bool
val endpoint_supports_http_tts : Voice_config.endpoint -> bool
val default_agent_voices : unit -> (string * string) list
val default_session_url : path:string -> string
val session_endpoint_result : Voice_config.t -> (Voice_config.endpoint, string) result
val session_mcp_url_of_endpoint : Voice_config.endpoint -> (string, string) result
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

(** The request that asks an endpoint which voices it has, or why there is
    nothing to ask. Only ElevenLabs publishes a catalogue; an OpenAI-compatible
    server takes a voice name and offers no listing beside it, and an endpoint
    reached through a tool is asked to speak rather than asked what it can
    speak with. Both of those are [Error] with that said in words, because the
    caller shows the reason to a reader who is about to type the name instead. *)
val voice_listing_request_for_endpoint
  :  Voice_config.endpoint
  -> api_key:string
  -> (voice_listing_request, string) result

(** The command that speaks one message, for the kinds that run one rather than
    reach an address. [Error] names the transport when the endpoint is reached
    another way, or says the endpoint transcribes rather than speaks. A blank
    [voice] is not an error: the command then uses the system voice. *)
val tts_command_for_endpoint
  :  Voice_config.endpoint
  -> voice:string
  -> message:string
  -> output_file:string
  -> (command_request, string) result

(** The command that transcribes one file. [model] is a path here rather than a
    name, which is what the section's model means to this command; blank is
    refused by name rather than defaulted to a path that may not exist. *)
type audio_container =
  | Wave
  | Flac
  | Mp3
  | Webm
  | Ogg_opus
  | Aiff
  | Mp4
  | Unrecognized
(** The container an audio file declares in its first bytes. *)

val audio_container_probe_bytes : int
(** How many leading bytes {!audio_container_of_leading_bytes} reads. *)

val audio_container_of_leading_bytes : string -> audio_container
(** The container named by a file's first {!audio_container_probe_bytes} bytes
    (fewer is fine; a short prefix is [Unrecognized] unless it already names
    one). *)

val audio_container_name : audio_container -> string

type whisper_cli_input =
  | Reads
  | Does_not_read
  | Not_measured

val whisper_cli_input : audio_container -> whisper_cli_input
(** Whether whisper-cli reads a container, measured with whisper-cpp 1.9.2:
    WAV, FLAC and MP3 are read; WebM, Ogg Opus, AIFF and MP4 are not, and for
    those whisper-cli exits 0 with an empty transcript rather than failing.
    [Not_measured] is left for whisper-cli to answer. *)

val stt_command_for_endpoint
  :  Voice_config.endpoint
  -> audio_file:string
  -> model:string
  -> (command_request, string) result

(** The command that lists the voices installed on this machine, for the kinds
    that publish one. [Error] says why there is nothing to ask for otherwise. *)
val voice_listing_command_for_endpoint
  :  Voice_config.endpoint
  -> (command_request, string) result
