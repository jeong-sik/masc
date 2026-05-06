type channel =
  | Hint
  | Approve
  | Reject
  | Redirect

type entry =
  { id : string
  ; at : string
  ; channel : channel
  ; to_ : string list
  ; body : string
  ; ack : bool
  }

let channel_to_string = function
  | Hint -> "hint"
  | Approve -> "approve"
  | Reject -> "reject"
  | Redirect -> "redirect"
;;

let channel_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "hint" -> Some Hint
  | "approve" -> Some Approve
  | "reject" -> Some Reject
  | "redirect" -> Some Redirect
  | _ -> None
;;

let clamp ~min_v ~max_v value = max min_v (min max_v value)
let clamp_limit limit = clamp ~min_v:1 ~max_v:200 limit
let fetch_limit limit = clamp ~min_v:limit ~max_v:1000 (limit * 10)

let take n xs =
  let rec loop acc remaining = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | x :: rest -> loop (x :: acc) (remaining - 1) rest
  in
  loop [] n xs
;;

let assoc_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let string_member key json =
  match assoc_opt key json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let bool_member key json =
  match assoc_opt key json with
  | Some (`Bool value) -> Some value
  | _ -> None
;;

let first_string_member keys json = List.find_map (fun key -> string_member key json) keys

let string_list_member key json =
  match assoc_opt key json with
  | Some (`List items) ->
    items
    |> List.filter_map (function
      | `String value ->
        let value = String.trim value in
        if value = "" then None else Some value
      | _ -> None)
  | Some (`String value) ->
    let value = String.trim value in
    if value = "" then [] else [ value ]
  | _ -> []
;;

let target_list json =
  match string_list_member "to" json with
  | [] -> string_list_member "targets" json
  | targets -> targets
;;

let is_operator_kind json =
  match first_string_member [ "kind"; "type" ] json with
  | Some raw ->
    (match String.lowercase_ascii (String.trim raw) with
     | "operator_nudge" | "operator-nudge" | "nudge" -> true
     | _ -> false)
  | None -> false
;;

let message_is_structured_nudge (msg : Masc_domain.message) =
  match String.lowercase_ascii (String.trim msg.msg_type) with
  | "operator_nudge" | "operator-nudge" | "nudge" -> true
  | _ -> false
;;

let fallback_targets (msg : Masc_domain.message) =
  match msg.mention with
  | Some target when String.trim target <> "" -> [ String.trim target ]
  | _ -> []
;;

let nudge_id (msg : Masc_domain.message) = Printf.sprintf "n-%09d" msg.seq

let decode_message_entities content =
  content
  |> String_util.replace_substring ~needle:"&quot;" ~by:"\""
  |> String_util.replace_substring ~needle:"&#x27;" ~by:"'"
  |> String_util.replace_substring ~needle:"&apos;" ~by:"'"
  |> String_util.replace_substring ~needle:"&lt;" ~by:"<"
  |> String_util.replace_substring ~needle:"&gt;" ~by:">"
  |> String_util.replace_substring ~needle:"&amp;" ~by:"&"
;;

let structured_entry_of_json ~(msg : Masc_domain.message) json =
  let structured_msg = message_is_structured_nudge msg in
  if (not structured_msg) && not (is_operator_kind json)
  then None
  else (
    match Option.bind (first_string_member [ "channel" ] json) channel_of_string with
    | None -> None
    | Some channel ->
      let body =
        first_string_member [ "body"; "message"; "content" ] json
        |> Option.value ~default:""
        |> String.trim
      in
      let targets =
        match target_list json with
        | [] -> fallback_targets msg
        | xs -> xs
      in
      Some
        { id = nudge_id msg
        ; at = msg.timestamp
        ; channel
        ; to_ = targets
        ; body
        ; ack = Option.value ~default:false (bool_member "ack" json)
        })
;;

let is_space = function
  | ' ' | '\t' | '\r' | '\n' -> true
  | _ -> false
;;

let words s =
  let len = String.length s in
  let rec skip i = if i < len && is_space s.[i] then skip (i + 1) else i in
  let rec take_word acc i =
    let i = skip i in
    if i >= len
    then List.rev acc
    else (
      let j = ref i in
      while !j < len && not (is_space s.[!j]) do
        incr j
      done;
      take_word (String.sub s i (!j - i) :: acc) !j)
  in
  take_word [] 0
;;

let strip_target_punct s =
  let rec right i =
    if i < 0
    then ""
    else (
      match s.[i] with
      | ',' | ';' | ':' | '.' -> right (i - 1)
      | _ -> String.sub s 0 (i + 1))
  in
  right (String.length s - 1)
;;

let target_of_word word =
  if String.length word <= 1 || word.[0] <> '@'
  then None
  else (
    let target = String.sub word 1 (String.length word - 1) |> strip_target_punct in
    if target = "" then None else Some target)
;;

let unique_preserving_order xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: rest when List.mem x seen -> loop seen acc rest
    | x :: rest -> loop (x :: seen) (x :: acc) rest
  in
  loop [] [] xs
;;

let tagged_targets_and_body rest =
  let tokens = words rest in
  let targets = tokens |> List.filter_map target_of_word |> unique_preserving_order in
  let body_tokens =
    let rec drop_leading_targets = function
      | word :: rest when Option.is_some (target_of_word word) ->
        drop_leading_targets rest
      | remaining -> remaining
    in
    drop_leading_targets tokens
  in
  let body =
    match body_tokens with
    | [] -> String.trim rest
    | xs -> String.concat " " xs |> String.trim
  in
  targets, body
;;

let tagged_channel_and_body content =
  let content = String.trim content in
  if String.length content < 4 || content.[0] <> '['
  then None
  else (
    match String.index_opt content ']' with
    | None -> None
    | Some close_idx ->
      let tag = String.sub content 1 (close_idx - 1) |> String.trim in
      let rest =
        String.sub content (close_idx + 1) (String.length content - close_idx - 1)
        |> String.trim
      in
      let label, channel_raw =
        match String.index_opt tag ':' with
        | None -> tag, ""
        | Some idx ->
          String.sub tag 0 idx, String.sub tag (idx + 1) (String.length tag - idx - 1)
      in
      let label = String.lowercase_ascii (String.trim label) in
      if label = "nudge" || label = "operator_nudge" || label = "operator-nudge"
      then
        channel_of_string channel_raw
        |> Option.map (fun channel ->
          let targets, body = tagged_targets_and_body rest in
          channel, targets, body)
      else None)
;;

let tagged_entry_of_message (msg : Masc_domain.message) =
  match tagged_channel_and_body msg.content with
  | None -> None
  | Some (channel, targets, body) ->
    Some
      { id = nudge_id msg
      ; at = msg.timestamp
      ; channel
      ; to_ = (if targets = [] then fallback_targets msg else targets)
      ; body
      ; ack = false
      }
;;

let entry_of_message (msg : Masc_domain.message) =
  let msg = { msg with content = decode_message_entities msg.content } in
  match Yojson.Safe.from_string msg.content with
  | json ->
    (match structured_entry_of_json ~msg json with
     | Some _ as entry -> entry
     | None -> tagged_entry_of_message msg)
  | exception Yojson.Json_error _ -> tagged_entry_of_message msg
  | exception Sys_error _ -> tagged_entry_of_message msg
;;

let recent ~config ~limit =
  let limit = clamp_limit limit in
  Coord.get_messages_raw config ~since_seq:0 ~limit:(fetch_limit limit)
  |> List.filter_map entry_of_message
  |> take limit
;;

let entry_to_yojson entry =
  `Assoc
    [ "id", `String entry.id
    ; "at", `String entry.at
    ; "channel", `String (channel_to_string entry.channel)
    ; "to", `List (List.map (fun target -> `String target) entry.to_)
    ; "body", `String entry.body
    ; "ack", `Bool entry.ack
    ]
;;

let json ~config ~limit () =
  let limit = clamp_limit limit in
  let nudges = recent ~config ~limit in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "limit", `Int limit
    ; "count", `Int (List.length nudges)
    ; "nudges", `List (List.map entry_to_yojson nudges)
    ]
;;
