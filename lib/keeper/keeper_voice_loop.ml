(** Keeper_voice_loop — voice ping-pong turn loop.

    Wraps keeper text turns with voice I/O: record user speech via
    microphone (STT), run a keeper turn, then speak the response (TTS).
    The keeper LLM is unaware of voice mode — this module acts as a
    transparent I/O adapter.

    To avoid circular module dependencies, [run] takes a [send_message]
    callback instead of calling [Keeper_turn] directly.

    @since 2.201.0 *)

(** Extract transcribed text from STT JSON response.
    Returns None if no text or if status is "no_audio". *)
let extract_text_from_stt (json : Yojson.Safe.t) : string option =
  try
    let open Yojson.Safe.Util in
    match member "status" json with
    | `String "no_audio" -> None
    | _ ->
        (match member "text" json with
        | `String s when String.trim s <> "" -> Some (String.trim s)
        | _ -> None)
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None

(** Extract reply text from keeper_msg tool_result.
    The result_str is JSON with ["reply"]. *)
let extract_reply_text (result_str : string) : string option =
  try
    let json = Yojson.Safe.from_string result_str in
    match Yojson.Safe.Util.member "reply" json with
    | `String s when String.trim s <> "" -> Some (String.trim s)
    | _ -> None
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None

let parse_reply_text (result_str : string) : (string, string) result =
  try
    let json = Yojson.Safe.from_string result_str in
    match Yojson.Safe.Util.member "reply" json with
    | `String s when String.trim s <> "" -> Ok (String.trim s)
    | _ -> Error "keeper reply missing or empty"
  with Yojson.Json_error msg ->
    Error (Printf.sprintf "invalid keeper reply JSON: %s" msg)

(** Stop words that end the voice loop. *)
let is_stop_command (text : string) : bool =
  let lower = String.lowercase_ascii (String.trim text) in
  List.exists (fun w -> lower = w)
    [ "stop"; "exit"; "quit"; "bye"; "end";
      "종료"; "끝"; "그만"; "멈춰"; "바이" ]

(** Single voice turn: listen → send_message → speak.
    @param send_message takes text, returns [(success, result_json_string)]
    @param speak takes text, returns [(Yojson.Safe.t, string) result] *)
let default_record ~agent_id ?language_code () =
  Voice_bridge.record_and_transcribe ~agent_id ?language_code ()

let run_one_voice_turn ~agent_id ~send_message ~speak
    ?(record = default_record) ?language_code () =
  match record ~agent_id ?language_code () with
  | Error err ->
      Log.Keeper.warn "voice_loop: listen failed: %s" err;
      Error (Printf.sprintf "listen failed: %s" err)
  | Ok stt_json ->
      match extract_text_from_stt stt_json with
      | None ->
          Log.Keeper.info "voice_loop: no text from STT, skipping turn";
          Ok `Empty
      | Some text ->
          if is_stop_command text then (
            Log.Keeper.info "voice_loop: stop command: %s" text;
            Ok `Stop)
          else
            let (success, result_str) = send_message text in
            if not success then (
              Log.Keeper.error "voice_loop: turn failed: %s" result_str;
              Error (Printf.sprintf "turn failed: %s" result_str))
            else
              match parse_reply_text result_str with
              | Error err ->
                  Log.Keeper.error "voice_loop: %s" err;
                  Error err
              | Ok reply ->
                  (match speak reply with
                   | Ok _ -> Ok `Continue
                   | Error err ->
                       Log.Keeper.error "voice_loop: speak failed: %s" err;
                       Error (Printf.sprintf "speak failed: %s" err))

(** Run the voice ping-pong loop.
    @param send_message callback: text -> (success, result_json_string)
    @param speak callback: text -> (Ok json, Error msg)
    @param max_turns default 50 *)
let max_consecutive_empty = 5

let run ~agent_id ~send_message ~speak
    ?(record = default_record)
    ?(max_turns = 50) ?language_code () : bool * string =
  let rec loop turn_count empty_count =
    if turn_count >= max_turns then
      (true, Printf.sprintf "voice loop ended after %d turns (max reached)"
         max_turns)
    else
      match run_one_voice_turn ~agent_id ~send_message ~speak
              ~record ?language_code () with
      | Error err ->
          if turn_count = 0 then
            (false, Printf.sprintf "voice loop failed on first turn: %s" err)
          else
            (false, Printf.sprintf "voice loop failed after %d turns: %s"
               turn_count err)
      | Ok `Stop ->
          (true, Printf.sprintf "voice loop ended after %d turns (user exit)"
             (turn_count + 1))
      | Ok `Empty ->
          if empty_count + 1 >= max_consecutive_empty then
            (true, Printf.sprintf
               "voice loop ended: %d consecutive empty STT responses"
               (empty_count + 1))
          else
            loop turn_count (empty_count + 1)
      | Ok `Continue ->
          loop (turn_count + 1) 0
  in
  loop 0 0
