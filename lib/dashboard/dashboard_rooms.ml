let clamp ~min_v ~max_v value = max min_v (min max_v value)
let clamp_limit limit = clamp ~min_v:1 ~max_v:200 limit
let fetch_limit limit = clamp ~min_v:limit ~max_v:1000 (limit * 5)
let default_room_id = "default"
let default_room_name = "Room timeline"

let take n xs =
  let rec loop acc remaining = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | x :: rest -> loop (x :: acc) (remaining - 1) rest
  in
  loop [] n xs
;;

let decode_message_entities content =
  content
  |> String_util.replace_substring ~needle:"&quot;" ~by:"\""
  |> String_util.replace_substring ~needle:"&#x27;" ~by:"'"
  |> String_util.replace_substring ~needle:"&apos;" ~by:"'"
  |> String_util.replace_substring ~needle:"&lt;" ~by:"<"
  |> String_util.replace_substring ~needle:"&gt;" ~by:">"
  |> String_util.replace_substring ~needle:"&amp;" ~by:"&"
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

let is_mention_punct = function
  | ',' | ';' | ':' | '.' | '!' | '?'
  | ')' | ']' | '}' | '>'
  | '(' | '[' | '{' | '<'
  | '"' | '\'' | '`' -> true
  | _ -> false
;;

let strip_mention_punct s =
  (* Strip both leading and trailing punctuation so common shapes like
     "(@bob)", "@bob!", '"@bob"' resolve to the same target. The
     previous helper trimmed only the trailing side and a smaller set
     of characters, dropping otherwise-valid mentions or polluting
     extracted targets with punctuation. *)
  let len = String.length s in
  let rec left i = if i < len && is_mention_punct s.[i] then left (i + 1) else i in
  let lo = left 0 in
  let rec right i =
    if i < lo then lo - 1
    else if is_mention_punct s.[i] then right (i - 1)
    else i
  in
  let hi = right (len - 1) in
  if hi < lo then "" else String.sub s lo (hi - lo + 1)
;;

let mention_of_word word =
  let trimmed_word = strip_mention_punct word in
  if String.length trimmed_word <= 1 || trimmed_word.[0] <> '@'
  then None
  else (
    let target =
      String.sub trimmed_word 1 (String.length trimmed_word - 1)
      |> strip_mention_punct
    in
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

let mentions_of_message (msg : Masc_domain.message) =
  let body_mentions =
    decode_message_entities msg.content |> words |> List.filter_map mention_of_word
  in
  let direct =
    match msg.mention with
    | Some value when String.trim value <> "" -> [ String.trim value ]
    | _ -> []
  in
  unique_preserving_order (direct @ body_mentions)
;;

let message_id (msg : Masc_domain.message) = Printf.sprintf "msg-%09d" msg.seq

let is_room_message (msg : Masc_domain.message) =
  let msg_type = String.lowercase_ascii (String.trim msg.msg_type) in
  not (String.starts_with ~prefix:"lifecycle_" msg_type)
;;

let block_kind_of_message (msg : Masc_domain.message) =
  (* Restrict block_kind to messages whose msg_type explicitly carries
     a [state_block:<kind>] / [state-block:<kind>] discriminator. The
     previous fall-through (`else Some lower`) surfaced operational
     msg_types like "cache_invalidated" as block_kind, which clients
     interpreted as a structural state-block name and rendered as a
     fake panel. An empty suffix (e.g. "state_block:") returns None
     too — a missing discriminator is no signal at all, not a
     [block_kind: ""] field that downstream consumers cannot decode. *)
  let msg_type = String.trim msg.msg_type in
  let lower = String.lowercase_ascii msg_type in
  let extract_suffix prefix =
    let n = String.length prefix in
    String.sub msg_type n (String.length msg_type - n)
    |> String.trim
    |> String.lowercase_ascii
  in
  let prefixes = [ "state_block:"; "state-block:" ] in
  match List.find_opt (fun p -> String.starts_with ~prefix:p lower) prefixes with
  | None -> None
  | Some prefix ->
    let suffix = extract_suffix prefix in
    if suffix = "" then None else Some suffix
;;

let message_json (msg : Masc_domain.message) =
  let body = decode_message_entities msg.content in
  let mentions = mentions_of_message msg in
  let base =
    [ "id", `String (message_id msg)
    ; "room_id", `String default_room_id
    ; "ts", `String msg.timestamp
    ; "sender", `String msg.from_agent
    ; "type", `String msg.msg_type
    ; "body", `String body
    ; "mentions", `List (List.map (fun target -> `String target) mentions)
    ; ( "expires_at"
      , match msg.expires_at with Some value -> `Float value | None -> `Null )
    ; "relevance", `String msg.relevance
    ]
  in
  let fields =
    match block_kind_of_message msg with
    | None -> base
    | Some kind -> base @ [ "block_kind", `String kind ]
  in
  `Assoc fields
;;

let snippet text =
  let text = String.trim text in
  let max_len = 160 in
  if String.length text <= max_len then text else String.sub text 0 (max_len - 3) ^ "..."
;;

let mention_matches ?me mentions =
  match Option.map String.trim me with
  | Some target when target <> "" -> List.exists (String.equal target) mentions
  | _ -> mentions <> []
;;

let mention_inbox_json ?me (msg : Masc_domain.message) =
  let mentions = mentions_of_message msg in
  if not (mention_matches ?me mentions)
  then None
  else
    Some
      (`Assoc
          [ "message_id", `String (message_id msg)
          ; "room_id", `String default_room_id
          ; "ts", `String msg.timestamp
          ; "sender", `String msg.from_agent
          ; "snippet", `String (decode_message_entities msg.content |> snippet)
          ; "ack_at", `Null
          ])
;;

let active_agent_names config =
  if not (Coord.is_initialized config)
  then []
  else (
    try
      (* Use [get_active_agents] (filtered to currently-active agents)
         instead of [get_agents_raw] which also returned tombstones /
         left agents. The function name and the rooms participants
         contract both expect "active only". *)
      Coord.get_active_agents config
      |> List.map (fun (agent : Masc_domain.agent) -> agent.name)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> [])
;;

let room_json ~config messages =
  let participants =
    let senders = List.map (fun (msg : Masc_domain.message) -> msg.from_agent) messages in
    let mentions = messages |> List.concat_map mentions_of_message in
    active_agent_names config @ senders @ mentions |> unique_preserving_order
  in
  let last_message_at =
    match messages with
    | latest :: _ -> `String latest.timestamp
    | [] -> `Null
  in
  `Assoc
    [ "id", `String default_room_id
    ; "name", `String default_room_name
    ; "participants", `List (List.map (fun name -> `String name) participants)
    ; "last_message_at", last_message_at
    ]
;;

let json ~config ?me ~limit () =
  let limit = clamp_limit limit in
  let recent_desc =
    Coord.get_messages_raw config ~since_seq:0 ~limit:(fetch_limit limit)
    |> List.filter is_room_message
    |> take limit
  in
  let timeline = List.rev recent_desc in
  let messages_json = List.map message_json timeline in
  let mentions_inbox =
    recent_desc |> List.filter_map (mention_inbox_json ?me) |> take limit
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "limit", `Int limit
    ; ( "me"
      , match me with
        | Some value -> `String value
        | None -> `Null )
    ; "rooms", `List [ room_json ~config recent_desc ]
    ; "messages", `List messages_json
    ; "mentions_inbox", `List mentions_inbox
    ]
;;
