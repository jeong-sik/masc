(** Voice_bridge — TTS synthesis, MCP voice sessions, conferences.

    Re-exports [Voice_bridge_core] (config, helpers, local playback)
    and adds higher-level session, conference, and agent_speak APIs.

    External callers use [agent_speak], [get_agent_voice],
    and [public_config_json]. *)

include module type of Voice_bridge_core

(** {1 Types} *)

type voice_session_status =
  { session_id : string
  ; agent_id : string
  ; voice : string
  ; is_active : bool
  ; turn_count : int
  ; duration_seconds : float option
  }

type conference_status =
  { conference_id : string
  ; state : string
  ; participants : string list
  ; current_speaker : string option
  ; queue_size : int
  ; turn_count : int
  }

type turn_request_result =
  { status : string
  ; agent_id : string
  ; message_preview : string
  ; voice : string
  ; queue_position : int
  }

exception Timeout of string

(** {1 Public API} *)

val public_config_json : unit -> (Yojson.Safe.t, Yojson.Safe.t) result

val agent_speak
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:_ Eio.Net.t
  -> agent_id:string
  -> message:string
  -> ?provider:string
  -> ?priority:int
  -> unit
  -> (Yojson.Safe.t, string) result

val get_agent_voice : agent_id:string -> (Yojson.Safe.t, string) result
val available_tts_endpoints : ?provider:string -> unit -> Voice_config.endpoint list
val tts_preview_bytes_from_request_json : Yojson.Safe.t -> (string, string) result

(** {1 Speech-to-Text} *)

val transcribe_audio
  :  audio_file:string
  -> ?language_code:string
  -> unit
  -> (Yojson.Safe.t, string) result

val available_stt_endpoints : unit -> Voice_config.endpoint list

(** {1 Voice Session Management} *)

val start_voice_session
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:_ Eio.Net.t
  -> agent_id:string
  -> ?session_name:string
  -> unit
  -> (Yojson.Safe.t, string) result

val end_voice_session
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:_ Eio.Net.t
  -> agent_id:string
  -> (Yojson.Safe.t, string) result

val list_voice_sessions
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:_ Eio.Net.t
  -> (Yojson.Safe.t, string) result

(** {1 Conference Management} *)

val start_conference
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:_ Eio.Net.t
  -> agent_ids:string list
  -> ?conference_name:string
  -> unit
  -> (Yojson.Safe.t, string) result

val end_conference
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:_ Eio.Net.t
  -> agent_ids:string list
  -> unit
  -> (Yojson.Safe.t, string) result

val get_transcript
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:_ Eio.Net.t
  -> unit
  -> (Yojson.Safe.t, string) result

val health_check
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> net:_ Eio.Net.t
  -> unit
  -> (Yojson.Safe.t, string) result

(** {1 Microphone record + transcribe} *)

(** Play a short sine beep at the given frequency. *)
val play_tone : float -> unit

(** Record from microphone (with beep tones), transcribe via STT.
    Returns transcription JSON on success. *)
val record_and_transcribe
  :  agent_id:string
  -> ?timeout_sec:float
  -> ?language_code:string
  -> unit
  -> (Yojson.Safe.t, string) result
