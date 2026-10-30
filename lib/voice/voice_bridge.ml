(** Voice_bridge — TTS synthesis, speech-to-text, local playback. *)

include Voice_bridge_core

open Result.Syntax


(* ── Voice_catalogue re-exports (E09 Phase 1, task-2526): the pure catalogue
   layer moved to {!Voice_catalogue}; the names callers used are kept here.
   The command checks take the catalogue lister through {!Voice_probe}, which
   owns the transport-side lister (E09 Phase 2a). *)
let spoke_detail = Voice_catalogue.spoke_detail
let transcript_of_stt_json = Voice_catalogue.transcript_of_stt_json
type catalogue_voice = Voice_catalogue.catalogue_voice = {
  voice_id : string;
  voice_name : string option;
  voice_language : string option;
  voice_aliases : string list;
}
let catalogue_voice_json = Voice_catalogue.catalogue_voice_json
let say_catalogue_of_output = Voice_catalogue.say_catalogue_of_output
let espeak_catalogue_of_output = Voice_catalogue.espeak_catalogue_of_output
type say_voice = Voice_catalogue.say_voice =
  | Say_has_it
  | Say_lacks_it of { installed : int }
let say_voice_in_catalogue = Voice_catalogue.say_voice_in_catalogue
let espeak_voice_in_catalogue = Voice_catalogue.espeak_voice_in_catalogue
type transcriber = Voice_catalogue.transcriber =
  | Over_http
  | By_command
  | Does_not_transcribe

let transcriber_of_kind = Voice_catalogue.transcriber_of_kind

let list_voices_via_command_endpoint = Voice_probe.list_voices_via_command_endpoint

let check_say_voice endpoint ~voice =
  Voice_catalogue.check_say_voice
    ~lister:list_voices_via_command_endpoint endpoint ~voice
;;

let check_espeak_voice endpoint ~voice =
  Voice_catalogue.check_espeak_voice
    ~lister:list_voices_via_command_endpoint endpoint ~voice
;;


(* ── Voice_probe re-exports (E09 Phase 2a, task-2526): probe diagnostics and
   the shared STT chain moved to {!Voice_probe}; the names callers used are
   kept here so no consumer changes. *)
type capture_status = Voice_probe.capture_status =
  | Transcribed
  | No_audio
  | Discarded

let capture_status_to_string = Voice_probe.capture_status_to_string
let capture_status_of_string = Voice_probe.capture_status_of_string
let transcribe_audio = Voice_probe.transcribe_audio
type probe_outcome = Voice_probe.probe_outcome =
  | Answered of string
  | Refused of string
  | Skipped of string

type probe_attempt = Voice_probe.probe_attempt = {
  endpoint_id : string;
  kind : Voice_config.endpoint_kind;
  outcome : probe_outcome;
}

let probe_outcome_to_string = Voice_probe.probe_outcome_to_string
let probe_attempt_json = Voice_probe.probe_attempt_json
let catalogue_voices_of_json = Voice_probe.catalogue_voices_of_json
let list_voices = Voice_probe.list_voices
let probe_stt = Voice_probe.probe_stt
let public_config_json = Voice_probe.public_config_json


(* Whether say has a voice by this name. say does not refuse one it does not
   have: it exits 0 and speaks in another voice. Measured 2026-09-13 on macOS 26
   whose first language is Korean, writing WAVE files only: [-v NoSuchVoice]
   wrote the same bytes as [-v Yuna] for a Korean sentence and for an English
   one, and neither matched the voice say uses with no [-v]. So the audio cannot
   tell a mapping that took from one that did not; the catalogue can.

   say matched [yuna] and [YUNA] to Yuna, so the comparison ignores ASCII case.
   A bare name say prints only with a language is not one of its labels: [-v
   Eddy] read a Korean sentence in an English voice, 4.8KB against 147KB for
   [-v "Eddy (한국어(한국))"]. *)
(* E09 Phase 2c re-exports: the TTS speak pipeline lives in Voice_speak now;
   Voice_bridge keeps the historical surface for its callers. *)
let clip_format_for_kind = Voice_speak.clip_format_for_kind
type agent_speak_completion = Voice_speak.agent_speak_completion =
  | Spoken
  | Synthesized
  | Dedup_skipped
let agent_speak_completion_to_string = Voice_speak.agent_speak_completion_to_string
let agent_speak_completion_of_string = Voice_speak.agent_speak_completion_of_string
type agent_speak_result = Voice_speak.agent_speak_result = {
  completion : Voice_speak.agent_speak_completion;
  payload : Yojson.Safe.t;
}
type mcp_call_error = Voice_speak.mcp_call_error =
  | Timed_out of float
  | Connection_failed of string
  | Http_status of
      { code : int
      ; body : string
      }
  | Malformed_body of string
let mcp_call_error_to_string = Voice_speak.mcp_call_error_to_string
let probe_tts = Voice_speak.probe_tts
let agent_speak = Voice_speak.agent_speak
let get_agent_voice = Voice_speak.get_agent_voice

(* E09 Phase 2d re-exports: the capture pipeline lives in Voice_capture now. *)
let default_capture_timeout_seconds = Voice_capture.default_capture_timeout_seconds
let db_of_amplitude = Voice_capture.db_of_amplitude
let amplitude_of_db = Voice_capture.amplitude_of_db
let measure_noise_floor = Voice_capture.measure_noise_floor
let with_noise_reduced_audio = Voice_capture.with_noise_reduced_audio
type level_phase = Voice_capture.level_phase =
  | Calibrating of { until : float; floor : float option }
  | Listening of { floor : float }
  | Speaking of { floor : float; quiet_since : float option }
type stop_request = Voice_capture.stop_request =
  | Keep_what_was_heard
  | Discard
type capture_end = Voice_capture.capture_end =
  | Ended_after_speech
  | Ended_without_speech of float option
  | Stopped_before_speech of float option
  | Discarded_after_speech of float
type level_step = Voice_capture.level_step =
  | Continue of level_phase
  | Finish of capture_end
let advance_phase = Voice_capture.advance_phase
let end_at_deadline = Voice_capture.end_at_deadline
let end_at_operator_stop = Voice_capture.end_at_operator_stop
type capture_level = Voice_capture.capture_level =
  | Level_observed of float
  | Level_unavailable
  | Meter_closed
type capture_outcome = Voice_capture.capture_outcome =
  | Transcript of
      { text : string
      ; endpoint_id : string option
      }
  | Transcriber_returned_nothing of { endpoint_id : string option }
  | Nothing_heard of { message : string }
  | Discarded_recording of { message : string }
  | Unrecognized_status of string
  | Status_absent
let capture_outcome_of_json = Voice_capture.capture_outcome_of_json
let recorder_refusal_message = Voice_capture.recorder_refusal_message
let resolved_audio_device = Voice_capture.resolved_audio_device
let record_and_transcribe = Voice_capture.record_and_transcribe

module For_testing = struct
  let with_timeout = Voice_speak.with_timeout
end
