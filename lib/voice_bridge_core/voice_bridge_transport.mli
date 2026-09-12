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

(** Ask one endpoint which voices it has, as it answers. Parsing that answer
    into names belongs to the caller: this is the transport. [Error] when the
    endpoint kind has no catalogue to ask for, when the credential is missing,
    or when the request failed -- each said in words a reader can act on. *)
val list_voices_via_http : Voice_config.endpoint -> (Yojson.Safe.t, string) result
