(** Trpg_round_keeper_parse — keeper reply sanitization and JSON parsing *)

include Trpg_round_fallback
open Yojson.Safe.Util

let is_placeholder_reply (raw : string) : bool =
  let normalized = String.lowercase_ascii (String.trim raw) in
  normalized = String.lowercase_ascii default_placeholder_reply
  || normalized = "assess the situation and prepare the next move."

let truncate_before_marker s marker =
  match find_substring s marker with
  | Some idx -> String.sub s 0 idx
  | None -> s

let sanitize_keeper_reply (raw : string) : string =
  let text =
    raw
    |> truncate_before_marker "\"visible_state_json\":"
    |> truncate_before_marker "visible_state_json:"
    |> truncate_before_marker "\"state_snapshot_json\":"
    |> truncate_before_marker "state_snapshot_json:"
    |> truncate_before_marker "\"[STATE]\""
    |> truncate_before_marker "[STATE]"
    |> truncate_before_marker "[/STATE]"
  in
  let rec strip_state_block in_state acc = function
    | [] -> List.rev acc
    | line :: tl ->
        let t = String.trim line in
        if in_state then
          if starts_with t "[/STATE]" then strip_state_block false acc tl
          else strip_state_block true acc tl
        else if starts_with t "[STATE]" then strip_state_block true acc tl
        else strip_state_block false (line :: acc) tl
  in
  let lines = strip_state_block false [] (String.split_on_char '\n' text) in
  let is_noise_line line =
    let t = String.trim line in
    let lowered = String.lowercase_ascii t in
    t = ""
    || starts_with lowered "structured_action:"
    || starts_with t "\"reply\":"
    || starts_with t "SKILL:"
    || starts_with t "SKILL_REASON:"
    || starts_with t "room_id="
    || starts_with t "phase="
    || starts_with t "turn="
    || starts_with t "role="
    || starts_with t "actor_id="
    || starts_with t "\"TRPG 실행 요청"
    || starts_with t "TRPG 실행 요청입니다."
    || starts_with t "TRPG execution request."
    || starts_with t "state_snapshot_json:"
    || starts_with t "내 기록상 가장 처음 물어본 건 이거야"
    || contains_substring t "visible_state_json:"
    || contains_substring t "state_snapshot_json:"
  in
  let rec drop_leading_noise = function
    | [] -> []
    | line :: tl when is_noise_line line -> drop_leading_noise tl
    | xs -> xs
  in
  let cleaned_lines =
    lines
    |> List.filter (fun line ->
           let t = String.trim line in
           let lowered = String.lowercase_ascii t in
           not
             (starts_with t "```json"
             || t = "```"
             || starts_with lowered "structured_action:"
             || starts_with t "[STATE]"
             || starts_with t "[/STATE]"
             || starts_with t "visible_state_json:"
             || starts_with t "state_snapshot_json:"))
    |> drop_leading_noise
  in
  String.concat "\n" cleaned_lines |> String.trim

let is_reply_noise_text (raw : string) : bool =
  let t = String.trim raw in
  let lowered = String.lowercase_ascii t in
  t = ""
  || starts_with t "```"
  || starts_with lowered "structured_action:"
  || starts_with t "[STATE]"
  || starts_with t "[/STATE]"
  || starts_with t "\"reply\":"
  || starts_with t "SKILL:"
  || starts_with t "SKILL_REASON:"
  || starts_with t "room_id="
  || starts_with t "phase="
  || starts_with t "turn="
  || starts_with t "role="
  || starts_with t "actor_id="
  || starts_with t "\"TRPG 실행 요청"
  || starts_with t "TRPG 실행 요청입니다."
  || starts_with t "TRPG execution request."
  || starts_with t "state_snapshot_json:"
  || starts_with t "내 기록상 가장 처음 물어본 건 이거야"
  || starts_with t "반드시 한국어로 응답하세요."
  || contains_substring t "visible_state_json:"
  || contains_substring t "state_snapshot_json:"

let extract_skill_hint_from_text (raw : string) : string option =
  let lines =
    raw |> String.split_on_char '\n' |> List.map String.trim
    |> List.filter (fun line -> line <> "")
  in
  let extract_skill line =
    let t = String.trim line in
    if starts_with t "SKILL:" then
      let payload =
        String.sub t (String.length "SKILL:") (String.length t - String.length "SKILL:")
        |> String.trim
      in
      if payload = "" then None else Some payload
    else None
  in
  List.find_map extract_skill lines

let fallback_reply_from_keeper_json keeper_json =
  let is_meta_skill_hint skill =
    let lowered = String.lowercase_ascii (String.trim skill) in
    (* TRPG skills are never meta-skills — they produce in-game content *)
    if starts_with lowered "trpg-" then false
    else
      starts_with lowered "masc-"
      || starts_with lowered "keeper-"
      || starts_with lowered "heartbeat"
      || contains_substring lowered "keeper"
      || contains_substring lowered "autonomy"
  in
  let skill_from_meta =
    match keeper_json |> member "skill_primary" with
    | `String s when String.trim s <> "" -> Some (String.trim s)
    | _ -> None
  in
  let skill_hint =
    match skill_from_meta with
    | Some skill -> Some skill
    | None -> (
        match keeper_json |> member "reply" with
        | `String s -> extract_skill_hint_from_text s
        | _ -> None )
  in
  match skill_hint with
  | Some skill when skill <> "" ->
      if is_meta_skill_hint skill then Some "상황을 살피며 다음 행동을 준비합니다."
      else Some (Printf.sprintf "%s 스킬을 활용해 행동을 이어갑니다." skill)
  | _ -> None

let parse_keeper_reply keeper_json =
  let default_fallback_reply = default_placeholder_reply in
  let raw_reply =
    match first_nonempty_string_field [ "reply"; "content"; "text"; "message" ] keeper_json with
    | Some raw -> Some raw
    | None -> (
        match keeper_json |> member "structured_action" with
        | `Assoc fields when fields <> [] ->
            Some (Yojson.Safe.to_string (`Assoc [ ("structured_action", `Assoc fields) ]))
        | _ -> None )
  in
  match raw_reply with
  | None -> (
      match fallback_reply_from_keeper_json keeper_json with
      | Some reply when String.trim reply <> "" -> Ok reply
      | _ -> Ok default_fallback_reply)
  | Some s ->
      let cleaned = sanitize_keeper_reply s in
      let fallback = String.trim s in
      let prompt_echo =
        (contains_substring s "visible_state_json:"
        || contains_substring s "state_snapshot_json:")
        && (contains_substring s "TRPG 실행 요청입니다."
           || contains_substring s "TRPG execution request."
           || contains_substring s "내 기록상 가장 처음 물어본 건 이거야"
           || contains_substring s "내 기록 기준으로는, 직전에 이런 질문을 했어"
           || contains_substring s "당신은 던전 마스터"
           || contains_substring s "You are the Dungeon Master"
           || contains_substring s "캐릭터에 맞게 행동하고"
           || contains_substring s "Respond in-character as")
      in
      let fallback_reply = fallback_reply_from_keeper_json keeper_json in
      let structured_action_description =
        match extract_structured_action keeper_json with
        | Some sa ->
            let desc = String.trim sa.description in
            if desc <> "" && not (is_low_signal_structured_description desc) then
              Some desc
            else None
        | _ -> None
      in
      let reply =
        if cleaned <> "" then Some cleaned
        else if structured_action_description <> None then structured_action_description
        else if prompt_echo || is_reply_noise_text fallback then fallback_reply
        else Some fallback
      in
      (match reply with
      | Some reply when String.trim reply <> "" -> Ok reply
      | _ -> (
          match fallback_reply with
          | Some reply when String.trim reply <> "" -> Ok reply
          | _ ->
              if is_reply_noise_text fallback then
                Error
                  "meta-only reply: response contained only state/noise \
                   markers"
              else Ok default_fallback_reply))

(** Attempt to recover truncated JSON by closing unclosed braces/brackets.
    Returns None if the input cannot be recovered. *)
let recover_truncated_json (raw : string) : Yojson.Safe.t option =
  let trimmed = String.trim raw in
  if String.length trimmed = 0 then None
  else
    let open_braces = ref 0 in
    let open_brackets = ref 0 in
    let in_string = ref false in
    let escaped = ref false in
    String.iter
      (fun c ->
        if !escaped then escaped := false
        else
          match c with
          | '\\' when !in_string -> escaped := true
          | '"' -> in_string := not !in_string
          | '{' when not !in_string -> incr open_braces
          | '}' when not !in_string -> decr open_braces
          | '[' when not !in_string -> incr open_brackets
          | ']' when not !in_string -> decr open_brackets
          | _ -> ())
      trimmed;
    if !in_string then begin
      (* Close unclosed string *)
      let buf = Buffer.create (String.length trimmed + 16) in
      Buffer.add_string buf trimmed;
      Buffer.add_char buf '"';
      for _ = 1 to !open_brackets do
        Buffer.add_char buf ']'
      done;
      for _ = 1 to !open_braces do
        Buffer.add_char buf '}'
      done;
      (try Some (Yojson.Safe.from_string (Buffer.contents buf))
       with Yojson.Json_error _ -> None)
    end
    else if !open_braces > 0 || !open_brackets > 0 then begin
      let buf = Buffer.create (String.length trimmed + 16) in
      Buffer.add_string buf trimmed;
      for _ = 1 to !open_brackets do
        Buffer.add_char buf ']'
      done;
      for _ = 1 to !open_braces do
        Buffer.add_char buf '}'
      done;
      (try Some (Yojson.Safe.from_string (Buffer.contents buf))
       with Yojson.Json_error _ -> None)
    end
    else None

(** Parse a raw string as keeper JSON, with truncated JSON recovery.
    Tries normal Yojson parse first. On failure, attempts to close unclosed
    braces/brackets and re-parse. Returns the parsed reply or an error. *)
let parse_keeper_reply_raw (raw : string) =
  let try_parse s =
    try Some (Yojson.Safe.from_string s) with Yojson.Json_error _ -> None
  in
  match try_parse raw with
  | Some json -> parse_keeper_reply json
  | None -> (
      match recover_truncated_json raw with
      | Some json ->
          Printf.eprintf
            "[WARN] parse_keeper_reply_raw: recovered truncated JSON\n%!";
          parse_keeper_reply json
      | None ->
          (* Not JSON at all — treat the raw text as the reply *)
          let trimmed = String.trim raw in
          if trimmed <> "" then Ok trimmed
          else Error "empty raw keeper response")

type prompt_language = [ `Ko | `En ]
