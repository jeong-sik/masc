let clamp_limit limit = Server_utils.clamp ~min_v:1 ~max_v:200 limit
let fetch_limit limit = Server_utils.clamp ~min_v:limit ~max_v:1000 (limit * 5)
let workspace_id = "workspace"
let workspace_name = "Workspace timeline"

let take = List.take

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
    | Some value -> Option.to_list (String_util.trim_to_option value)
    | _ -> []
  in
  unique_preserving_order (direct @ body_mentions)
;;

let message_id (msg : Masc_domain.message) = Printf.sprintf "msg-%09d" msg.seq

let is_workspace_message (msg : Masc_domain.message) =
  let msg_type = String.lowercase_ascii (String.trim msg.msg_type) in
  match msg_type with
  | "session_bound" | "session_rebound" | "session_ended" -> false
  | _ -> not (String.starts_with ~prefix:"lifecycle_" msg_type)
;;

let message_json (msg : Masc_domain.message) =
  let body = decode_message_entities msg.content in
  let mentions = mentions_of_message msg in
  let base =
    [ "id", `String (message_id msg)
    ; "workspace_id", `String workspace_id
    ; "ts", `String msg.timestamp
    ; "sender", `String msg.from_agent
    ; "type", `String msg.msg_type
    ; "body", `String body
    ; "mentions", `List (List.map (fun target -> `String target) mentions)
    ; ("expires_at", Json_util.float_opt_to_json msg.expires_at)
    ; "relevance", `String msg.relevance
    ]
  in
  `Assoc base
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
          ; "workspace_id", `String workspace_id
          ; "ts", `String msg.timestamp
          ; "sender", `String msg.from_agent
          ; "snippet", `String (decode_message_entities msg.content |> snippet)
          ; "ack_at", `Null
          ])
;;

let active_agent_names config =
  if not (Workspace.is_initialized config)
  then []
  else (
    try
      (* Use [get_active_agents] (filtered to currently-active agents)
         instead of [get_agents_raw] which also returned tombstones /
         left agents. The function name and the workspace participants
         contract both expect "active only". *)
      Workspace.get_active_agents config
      |> List.map (fun (agent : Masc_domain.agent) -> agent.name)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> [])
;;

let workspace_json ~config messages =
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
    [ "id", `String workspace_id
    ; "name", `String workspace_name
    ; "participants", `List (List.map (fun name -> `String name) participants)
    ; "last_message_at", last_message_at
    ]
;;

let compute_json ~config ?me ~limit () =
  let limit = clamp_limit limit in
  let recent_desc =
    Workspace.get_messages_raw config ~since_seq:0 ~limit:(fetch_limit limit)
    |> List.filter is_workspace_message
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
    ; ( "me", Json_util.string_opt_to_json me )
    ; "workspace", workspace_json ~config recent_desc
    ; "messages", `List messages_json
    ; "mentions_inbox", `List mentions_inbox
    ]
;;

(* /api/v1/dashboard/workspace was measured at 8-9s under live load.
   [Workspace.get_messages_raw] is a synchronous scan over the message
   store and was being executed on the Eio main domain, so other
   HTTP fibers sharing the domain stalled for the duration.  Cache
   the response with stale-while-revalidate and run the underlying
   compute on a worker domain via Domain_pool. *)
let cache_ttl_sec = 5.0

let json ~config ?me ~limit () =
  let key =
    Printf.sprintf
      "dashboard.workspace:%s;%s;%d"
      config.Workspace.base_path
      (Option.value ~default:"-" me)
      limit
  in
  Dashboard_cache.get_or_compute key ~ttl:cache_ttl_sec (fun () ->
    Domain_pool_ref.submit_io_or_inline (fun () -> compute_json ~config ?me ~limit ()))
;;
