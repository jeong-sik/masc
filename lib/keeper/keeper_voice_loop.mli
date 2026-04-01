(** Keeper_voice_loop — voice ping-pong turn loop.

    Transparent I/O adapter: record → turn → speak → repeat.
    The keeper LLM does not know it is in voice mode.

    Stop commands: "stop", "exit", "종료", "끝", "그만", etc.

    @since 2.201.0 *)

val extract_text_from_stt : Yojson.Safe.t -> string option
val extract_reply_text : string -> string option
val is_stop_command : string -> bool

(** Run the voice ping-pong loop.
    @param agent_id keeper name (for STT agent_id tag)
    @param send_message callback: user text -> (success, result_json)
    @param speak callback: reply text -> (Ok json, Error msg)
    @param max_turns default 50
    @param language_code optional BCP-47 hint for STT *)
val run :
  agent_id:string ->
  send_message:(string -> bool * string) ->
  speak:(string -> (Yojson.Safe.t, string) result) ->
  ?record:(agent_id:string -> ?language_code:string -> unit ->
           (Yojson.Safe.t, string) result) ->
  ?max_turns:int ->
  ?language_code:string ->
  unit ->
  bool * string
