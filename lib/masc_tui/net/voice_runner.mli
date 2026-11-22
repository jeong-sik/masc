(** Non-blocking Voice PTT recording, STT transcription, and TTS probe/playback
    command runner executing on {!Io_domain} and short systhreads (never
    occupying the CPU {!Worker_pool}).

    Dispatching any command returns immediately without blocking the UI domain.
    All external audio/process work is injected through {!backend} so tests can
    exercise state transitions and cancellation races deterministically without
    audio hardware. *)

open Masc_tui_core

val voice_config_path : string
val voice_transcribe_path : string
val voice_probe_tts_path : string
val voice_probe_stt_path : string

type phase =
  | Voice_idle
  | Voice_recording of { started_ns : Clock.Mono.t; level_db : float option }
  | Voice_transcribing
  | Voice_speaking
  | Voice_failed of string

type command =
  | Start_ptt of { device : string option }
  | Stop_ptt
  | Cancel_ptt
  | Speak of { text : string; voice_id : string option }
  | Probe_capabilities

type capabilities = {
  recorder_available : bool;
  recorder_cmd : string option;
  stt_available : bool;
  tts_available : bool;
}

val decode_voice_config :
  recorder_cmd:string option -> Yojson.Safe.t -> (capabilities, string) result
(** Decode [GET /api/v1/voice/config] ([tts.active_endpoint.enabled] and
    [stt.active_endpoint.enabled]) into {!capabilities}. *)

val encode_tts_probe_request : text:string -> Yojson.Safe.t
(** Encode [POST /api/v1/voice/probe/tts] body ([{ "message": text }]). *)

type event =
  | Phase_changed of phase
  | Level_meter of float
  | Transcript_ready of string
  | Speak_done
  | Capabilities of capabilities
  | Voice_error of string

type backend = {
  probe : unit -> (capabilities, string) result;
  record_until_stopped :
    device:string option ->
    stop_signal:unit Eio.Promise.t ->
    on_level:(float -> unit) ->
    (string, string) result;
  transcribe : audio_path:string -> (string, string) result;
  speak : text:string -> voice_id:string option -> (unit, string) result;
  cleanup_audio : audio_path:string -> unit;
}

val http_and_local_backend :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  endpoint:Http_client.endpoint ->
  backend
(** Production backend resolving local audio tools via [$PATH] (never hardcoded
    paths) in a systhread with [/dev/null] stdio redirection and
    [SIGINT -> SIGTERM -> SIGKILL] child reaping, reading raw WAV bytes and
    posting them to [POST /api/v1/voice/transcribe] ([Content-Type: audio/wav])
    on {!Io_domain}, and unlinking temporary audio files on every exit path. *)

type t

val create :
  sw:Eio.Switch.t ->
  backend:backend ->
  on_event:(event -> unit) ->
  t

val dispatch : t -> command -> unit
(** Non-blocking command dispatch. Safe to invoke directly from the UI loop. *)

val phase : t -> phase
val stop : t -> unit
(** Cancel any active recording session cleanly. *)
