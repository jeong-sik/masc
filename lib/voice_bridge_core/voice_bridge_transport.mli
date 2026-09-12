(** Transport helpers for {!Voice_bridge}. *)

val safe_agent_id : string -> string

val command_failure_reason : string -> string
(** A failed command's output, trimmed to the end. The reason a command
    failed is its last line, not its first: whisper-cli prints nine lines of
    backend loading before it says which model file it could not open, so a
    head-first trim reported which Metal library loaded and never the
    missing file. *)
val make_audio_file : format:Voice_bridge_core.clip_format -> string
(** A fresh clip path under {!Voice_bridge_core.audio_dir}, named
    [<token><extension>] for the format the caller is about to write. The
    128-bit token is also the HTTP capability the dashboard fetches it by. *)

val endpoint_timeout_sec : Voice_config.endpoint -> float
(** How long this endpoint is given, in seconds: its own [timeout_seconds]
    when it names one above zero, otherwise the workspace-wide voice request
    timeout. Every voice subprocess -- HTTP or command -- is bounded by this
    and carries it to curl as [--max-time], so the two deadlines agree.

    The field was in the configuration, its writer, the HTTP routes and the
    wizard before anything read it. *)

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
