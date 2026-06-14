(** Transport helpers for {!Voice_bridge}. *)

val safe_agent_id : string -> string
val make_audio_file : unit -> string
(** [make_audio_file ()] returns a fresh path under
    [$MASC_BASE_PATH/audio/<token>.mp3] where [token] is a 128-bit
    unguessable [Random_id.hex] value. The token doubles as the HTTP
    capability for [/api/v1/voice/audio/:token] (RFC-0235 P1). The
    legacy [<ts>_<agent>.mp3] name exposed agent identity in the
    filename and was enumerable; callers that need the token call
    [Filename.basename path |> Filename.chop_extension]. *)
val read_file : string -> string

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
