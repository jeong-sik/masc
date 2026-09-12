(** Transport helpers for {!Voice_bridge}. *)

val safe_agent_id : string -> string
val make_audio_file : unit -> string

val run_voice_status
  :  ?timeout_sec:float
  -> ?stdin_content:string
  -> string list
  -> Unix.process_status * string

val speak_via_http_tts_to_file
  :  Voice_config.endpoint
  -> agent_id:string
  -> message:string
  -> voice:string
  -> model:string
  -> output_file:string
  -> (int, string) result

val transcribe_via_http_stt
  :  Voice_config.endpoint
  -> audio_file:string
  -> model:string
  -> (Yojson.Safe.t, string) result

(** Speak one message by running a command, writing audio to [output_file] and
    answering its size. A command that exits cleanly having written nothing is
    an [Error]: a caller told "spoke" about an empty file has been told the
    wrong thing. A missing executable is named as such rather than reported as
    an exit code. *)
val speak_via_command_to_file
  :  Voice_config.endpoint
  -> message:string
  -> voice:string
  -> output_file:string
  -> (int, string) result

(** Transcribe one file by running a command. The transcript is the command's
    own output, so this answers text where the HTTP path answers JSON. *)
val transcribe_via_command
  :  Voice_config.endpoint
  -> audio_file:string
  -> model:string
  -> (string, string) result

(** Ask a command which voices it has, answering its stdout. Parsing that into
    names belongs to the caller: this is the transport. *)
val list_voices_via_command : Voice_config.endpoint -> (string, string) result
