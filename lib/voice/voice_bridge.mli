(** Voice_bridge — TTS synthesis, MCP voice sessions, conferences.

    Re-exports [Voice_bridge_core] (config, helpers, local playback)
    and adds higher-level session, conference, and agent_speak APIs.

    External callers use [agent_speak], [get_agent_voice],
    and [public_config_json]. *)

include module type of Voice_bridge_core

(** {1 Types} *)

type voice_session_status = {
  session_id : string;
  agent_id : string;
  voice : string;
  is_active : bool;
  turn_count : int;
  duration_seconds : float option;
}

type conference_status = {
  conference_id : string;
  state : string;
  participants : string list;
  current_speaker : string option;
  queue_size : int;
  turn_count : int;
}

type turn_request_result = {
  status : string;
  agent_id : string;
  message_preview : string;
  voice : string;
  queue_position : int;
}

exception Timeout of string

(** {1 Public API} *)

val public_config_json : unit -> (Yojson.Safe.t, Yojson.Safe.t) result

val agent_speak :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  agent_id:string ->
  message:string ->
  ?provider:string ->
  ?priority:int ->
  unit ->
  (Yojson.Safe.t, string) result
(** Synthesize [message] via the configured TTS endpoint chain and play it
    locally, blocking the calling fiber until playback finishes. Concurrent
    callers are serialized by the global playback mutex. Returns
    [status="spoken"] (with [played_seconds] when local playback ran) or
    [status="dedup_skipped"] when the identical message played within the
    dedup window; TTS/endpoint failures return [Error] so the caller — and
    the LLM driving it — sees the failure instead of a fake success.

    This is the only speak path: the former fire-and-forget
    [enqueue_agent_speak] queue was removed after the 2026-06-10 voice
    repeat incident (schema promised blocking semantics while the
    implementation returned [status="queued"] immediately, so keepers
    re-spoke the same content every sub-turn). *)

val get_agent_voice :
  agent_id:string -> (Yojson.Safe.t, string) result

val available_tts_endpoints :
  ?provider:string -> unit -> Voice_config.endpoint list

val tts_preview_bytes_from_request_json :
  Yojson.Safe.t -> (string, string) result

(** {1 Speech-to-Text} *)

val transcribe_audio :
  audio_file:string ->
  ?language_code:string ->
  unit ->
  (Yojson.Safe.t, string) result

val available_stt_endpoints : unit -> Voice_config.endpoint list

(** {1 Voice Session Management} *)

val start_voice_session :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  agent_id:string ->
  ?session_name:string ->
  unit ->
  (Yojson.Safe.t, string) result

val end_voice_session :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  agent_id:string ->
  (Yojson.Safe.t, string) result

val list_voice_sessions :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  (Yojson.Safe.t, string) result

(** {1 Conference Management} *)

val start_conference :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  agent_ids:string list ->
  ?conference_name:string ->
  unit ->
  (Yojson.Safe.t, string) result

val end_conference :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  agent_ids:string list ->
  unit ->
  (Yojson.Safe.t, string) result

val get_transcript :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  unit ->
  (Yojson.Safe.t, string) result

val health_check :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  unit ->
  (Yojson.Safe.t, string) result

(** {1 Microphone record + transcribe} *)

val play_tone : float -> unit
(** Play a short sine beep at the given frequency. *)

val record_and_transcribe :
  agent_id:string ->
  ?timeout_sec:float ->
  ?language_code:string ->
  unit ->
  (Yojson.Safe.t, string) result
(** Record from microphone (with beep tones), transcribe via STT.
    Returns transcription JSON on success. *)
