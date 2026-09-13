(** Transport helpers for {!Voice_bridge}. *)

val safe_agent_id : string -> string

val command_refusal_reason : command:string -> Process_eio.spawn_refusal -> string
(** Why a voice command never started. Only a program that is not there is
    called not installed; a permission denied or a working directory that
    would not open keeps the runner's own sentence, because naming an install
    for those sends the operator to fetch what they already have. *)

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
