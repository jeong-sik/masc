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

(** Scan the paginated catalogue under one caller-owned deadline.
    [remaining_seconds] observes that deadline; [fetch_page] receives its
    remaining time, never a fresh per-page allowance. Exposed for deterministic
    transport tests without sleeping or contacting a provider. *)
val collect_voice_catalogue
  :  remaining_seconds:(unit -> float)
  -> fetch_page:(timeout_sec:float -> Voice_runtime_overlay.voice_listing_request
                -> (Yojson.Safe.t, string) result)
  -> Voice_runtime_overlay.voice_listing_request
  -> (Yojson.Safe.t, string) result

(** Ask one endpoint for its complete catalogue. Parsing the collected voices
    into names belongs to the caller: this is the transport. [Error] when the
    endpoint kind has no catalogue to ask for, when the credential is missing,
    or when any page failed or its continuation was malformed. All pages share
    the existing configured HTTP deadline; partial catalogues are not returned. *)
val list_voices_via_http : Voice_config.endpoint -> (Yojson.Safe.t, string) result

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
    own output, so this answers text where the HTTP path answers JSON.

    A file whose first bytes name a container whisper-cli does not read
    (WebM, Ogg Opus, AIFF, MP4) is refused before the command runs, with the
    container named; so is a file that cannot be read. *)
val transcribe_via_command
  :  Voice_config.endpoint
  -> audio_file:string
  -> model:string
  -> (string, string) result

(** Ask a command which voices it has, answering its stdout. Parsing that into
    names belongs to the caller: this is the transport. *)
val list_voices_via_command : Voice_config.endpoint -> (string, string) result
