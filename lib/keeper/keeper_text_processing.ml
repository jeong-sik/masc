(** Keeper_text_processing — text processing functions shared by
    [Keeper_exec_context] and [Keeper_prompt].

    Handles reply markup stripping, proactive text normalisation,
    quality checks, and fragment detection. *)

open Keeper_memory_policy

(* Pre-compiled regex patterns — compiled once at module init. *)
let re_state_start = Re.str "[STATE]" |> Re.compile
let re_state_end = Re.str "[/STATE]" |> Re.compile
let re_whitespace = Re.Pcre.re "[ \t\r\n]+" |> Re.compile
let re_terminal_punct = Re.Pcre.re "[.!?。！？]$" |> Re.compile

let re_korean_ending = Re.Pcre.re "(다|요|니다|습니다|중입니다|함)$" |> Re.compile

let re_unclosed_bracket = Re.Pcre.re {|["'(\[{]$|} |> Re.compile
let re_trailing_punct = Re.Pcre.re "[:;,\\-]$" |> Re.compile

let re_trailing_connector = Re.Pcre.re "(and|or|with|to|for|그리고|또는|및)$" |> Re.compile

let strip_state_blocks_text (s : string) : string =
  let start_marker = "[STATE]" in
  let end_marker = "[/STATE]" in
  let len = String.length s in
  let rec loop from (buf : Buffer.t) =
    if from >= len
    then ()
    else (
      match Re.exec_opt ~pos:from re_state_start s with
      | None -> Buffer.add_substring buf s from (len - from)
      | Some g ->
        let i = Re.Group.start g 0 in
        if i > from then Buffer.add_substring buf s from (i - from);
        let block_start = i + String.length start_marker in
        let next_from =
          match Re.exec_opt ~pos:block_start re_state_end s with
          | None -> len
          | Some g2 -> Re.Group.start g2 0 + String.length end_marker
        in
        loop next_from buf)
  in
  let buf = Buffer.create len in
  loop 0 buf;
  Buffer.contents buf
;;

let trim_to_option (s : string) : string option =
  let trimmed = String.trim s in
  if trimmed = "" then None else Some trimmed
;;

let state_snapshot_reply_fallback (snapshot : keeper_state_snapshot option)
  : string option
  =
  match snapshot with
  | Some { progress = Some progress; _ } -> trim_to_option progress
  | Some { goal = Some goal; _ } -> trim_to_option goal
  | _ -> None
;;

let strip_internal_reply_markup (raw : string) : string =
  raw
  |> Keeper_skill_routing.strip_skill_route_lines
  |> strip_state_blocks_text
  |> String.trim
;;

let user_visible_reply_text ?fallback (raw : string) : string =
  match trim_to_option (strip_internal_reply_markup raw) with
  | Some text -> text
  | None ->
    (match Option.bind fallback trim_to_option with
     | Some text -> text
     | None ->
       (match state_snapshot_reply_fallback (parse_state_snapshot_from_reply raw) with
        | Some text -> text
        | None -> "State updated."))
;;

let normalize_proactive_text (raw : string) : string =
  raw
  |> strip_internal_reply_markup
  |> Re.replace_string re_whitespace ~by:" "
  |> String.trim
;;

let extract_checkin_text (raw : string) : string option =
  let cleaned = normalize_proactive_text raw in
  if cleaned = ""
  then None
  else (
    let lines =
      raw
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.filter (fun line -> line <> "")
    in
    let checkin_line =
      List.find_map
        (fun line ->
           match strip_prefix_ci ~prefix:"CHECKIN:" line with
           | Some s ->
             let s = normalize_proactive_text s in
             if s = "" then None else Some s
           | None -> None)
        lines
    in
    match checkin_line with
    | Some s -> Some s
    | None -> Some cleaned)
;;

let proactive_has_terminal_punct (s : string) : bool =
  let t = String.trim s in
  t <> "" && Re.execp re_terminal_punct t
;;

let proactive_has_terminal_korean_ending (s : string) : bool =
  let t = String.trim s in
  t <> "" && Re.execp re_korean_ending t
;;

let proactive_has_terminal_ending (s : string) : bool =
  proactive_has_terminal_punct s || proactive_has_terminal_korean_ending s
;;

let proactive_looks_fragmentary (s : string) : bool =
  let t = String.trim s in
  t = "" || Re.execp re_unclosed_bracket t || Re.execp re_trailing_punct t
;;

let looks_fragmentary_history_text (raw : string) : bool =
  let t = normalize_proactive_text raw in
  if t = ""
  then true
  else (
    let hard_fragment = proactive_looks_fragmentary t in
    let has_terminal = proactive_has_terminal_ending t in
    let ends_korean_sentence = Re.execp re_korean_ending t in
    let short_unterminated =
      (not has_terminal) && (not ends_korean_sentence) && String.length t <= 24
    in
    let trailing_connector =
      (not has_terminal) && Re.execp re_trailing_connector (String.lowercase_ascii t)
    in
    hard_fragment || short_unterminated || trailing_connector)
;;
