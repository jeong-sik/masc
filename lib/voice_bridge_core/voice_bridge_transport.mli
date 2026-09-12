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
    own output, so this answers text where the HTTP path answers JSON. *)
val transcribe_via_command
  :  Voice_config.endpoint
  -> audio_file:string
  -> model:string
  -> (string, string) result

(** Ask a command which voices it has, answering its stdout. Parsing that into
    names belongs to the caller: this is the transport. *)
val list_voices_via_command : Voice_config.endpoint -> (string, string) result
