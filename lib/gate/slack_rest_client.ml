(* Slack_rest_client — outbound Slack Web API (chat.postMessage / chat.update).

   Thin wrapper over {!Masc_http_client.post_sync}, mirroring
   {!Discord_rest_client}. Slack uses a bot token ([xoxb-...]) for outbound
   REST, distinct from the app token ([xapp-...]) the Socket Mode client
   ({!Slack_socket_client}) uses for [apps.connections.open].

   Slack's response model differs from Discord's: every Web API call returns
   JSON [{ ok: bool, error?: string, ... }] with HTTP 200 even on logical
   failure. So the failure mode is [{ ok: false, error }] (typed as
   [Slack_api]), not HTTP status. See RFC-0317. *)

type error =
  | Network of string
  | Http_status of { code : int; body : string }
  | Slack_api of { error : string }
  | Other of string

let pp_error fmt = function
  | Network msg -> Format.fprintf fmt "network: %s" msg
  | Http_status { code; body } -> Format.fprintf fmt "http %d: %s" code body
  | Slack_api { error } -> Format.fprintf fmt "slack api: %s" error
  | Other msg -> Format.fprintf fmt "other: %s" msg

(* Slack's native [markdown_text] field accepts at most 12,000 characters.
   We don't split here (caller responsibility, matching
   Discord_rest_client's stance on overflow) but expose the documented wire
   limit for callers that do. *)
let message_text_limit = 12_000

(* Slack's agent guidance says streaming messages updated through
   [chat.update] must be edited no more than once every three seconds. Keep
   this wire constraint beside the endpoint contract rather than duplicating
   it in the gateway. *)
let streaming_update_min_interval_sec = 3.0

(* Default outbound-request timeout. [Masc_http_client.post_sync] applies a
   deadline only when a clock {b and} [timeout_sec > 0.0] are both supplied, so
   this default takes effect once a caller threads [~clock] (the in-process
   gateway does); clock-less callers keep the prior unbounded behavior. Matches
   the socket client's [fetch_wss_url] default so all Slack HTTP shares one
   ceiling. *)
let default_http_timeout_sec = Masc_http_client.default_request_timeout_sec

let user_agent =
  Printf.sprintf
    "masc-slack-bot/%s (https://github.com/jeong-sik/masc)"
    Build_version.current
;;

let auth_headers ~token =
  [ ("Authorization", "Bearer " ^ token); ("User-Agent", user_agent) ]

(* [Safe_ops.parse_json_safe] is the parser for this shape: it trims, treats an
   empty body as an empty object, repairs UTF-8, and hands back the decoder's
   message. The copy that used to sit here did none of that and dropped the
   message, so a malformed connector response arrived as a bare [None]. *)
let parse_json_safe s = Gate_rest_json.parse ~context:"slack_rest_client" s

let build_post_message_request ~token ~channel_id ~text ?thread_ts () =
  let url = "https://slack.com/api/chat.postMessage" in
  let headers = ("Content-Type", "application/json") :: auth_headers ~token in
  (* Slack owns Markdown parsing at this protocol boundary. Using its native
     [markdown_text] field preserves the authored document without a local,
     incomplete Markdown-to-mrkdwn heuristic. Slack rejects combining this
     field with [text] or [blocks], so this builder emits exactly one content
     representation. *)
  let fields =
    [ ("channel", `String channel_id); ("markdown_text", `String text) ]
  in
  let fields =
    match thread_ts with
    | None -> fields
    | Some ts -> ("thread_ts", `String ts) :: fields
  in
  let body = Yojson.Safe.to_string (`Assoc fields) in
  (url, headers, body)

(* Slack returns HTTP 200 with [{ ok }] even on logical failure; after the
   transport-level 2xx check, branch on Slack's [ok] flag. *)
let parse_post_json_response ~body =
  match parse_json_safe body with
  | Error msg -> Error (Other (Printf.sprintf "response rejected (%s): %s" msg body))
  | Ok json ->
    let ok =
      match Gate_rest_json.bool_field "ok" json with Some b -> b | None -> false
    in
    if not ok then
      let err =
        match Gate_rest_json.string_field "error" json with
        | Some e -> e
        | None -> "unknown error"
      in
      Error (Slack_api { error = err })
    else
      (match Gate_rest_json.string_field "ts" json with
       | Some ts -> Ok ts
       | None -> Error (Other "ok=true but missing 'ts'"))

let parse_post_response ~status ~body =
  if status < 200 || status >= 300 then Error (Http_status { code = status; body })
  else parse_post_json_response ~body

let send_message ?clock ?(timeout_sec = default_http_timeout_sec) ~token
    ~channel_id ~text ?thread_ts () =
  let (url, headers, body) =
    build_post_message_request ~token ~channel_id ~text ?thread_ts ()
  in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_post_response ~status ~body

let build_update_request ~token ~channel_id ~ts ~text () =
  let url = "https://slack.com/api/chat.update" in
  let headers = ("Content-Type", "application/json") :: auth_headers ~token in
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [ ("channel", `String channel_id)
         ; ("ts", `String ts)
         ; ("markdown_text", `String text)
         ])
  in
  (url, headers, body)

let parse_update_response ~status ~body =
  if status < 200 || status >= 300 then Error (Http_status { code = status; body })
  else
    match parse_json_safe body with
    | Error msg -> Error (Other (Printf.sprintf "response rejected (%s): %s" msg body))
    | Ok json ->
        let ok =
          match Gate_rest_json.bool_field "ok" json with Some b -> b | None -> false
        in
        if ok then Ok ()
        else
          let err =
            match Gate_rest_json.string_field "error" json with
            | Some e -> e
            | None -> "update failed"
          in
          Error (Slack_api { error = err })

let edit_message ?clock ?(timeout_sec = default_http_timeout_sec) ~token
    ~channel_id ~ts ~text () =
  let (url, headers, body) =
    build_update_request ~token ~channel_id ~ts ~text ()
  in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_update_response ~status ~body

(* auth.test — resolve the bot's own identity. [user_id] gates inbound mention
   detection ([Slack_gateway_state.parse_envelope ~bot_user_id]) and [team_id]
   fills the Slack surface. Called once at gateway start with the bot token
   ([xoxb-...]); a failure is non-fatal (the gateway still triggers on
   [app_mention] events, which are mentions by construction). *)
type auth_test_ok = {
  user_id : string;
  team_id : string option;
}

let build_auth_test_request ~token =
  let url = "https://slack.com/api/auth.test" in
  let headers =
    ("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
    :: auth_headers ~token
  in
  (url, headers, "")

let parse_auth_test_response ~status ~body =
  if status < 200 || status >= 300 then Error (Http_status { code = status; body })
  else
    match parse_json_safe body with
    | Error msg -> Error (Other (Printf.sprintf "response rejected (%s): %s" msg body))
    | Ok json ->
      let ok =
        match Gate_rest_json.bool_field "ok" json with Some b -> b | None -> false
      in
      if not ok then
        let err =
          match Gate_rest_json.string_field "error" json with
          | Some e -> e
          | None -> "auth.test failed"
        in
        Error (Slack_api { error = err })
      else
        (match Gate_rest_json.string_field "user_id" json with
         | Some user_id ->
           let team_id = Gate_rest_json.string_field "team_id" json in
           Ok { user_id; team_id }
         | None -> Error (Other "ok=true but missing 'user_id'"))

let auth_test ?clock ?(timeout_sec = default_http_timeout_sec) ~token () =
  let (url, headers, body) = build_auth_test_request ~token in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_auth_test_response ~status ~body

(* users.info — resolve one user's profile names for inbound identity
   rendering (issue #28376). Slack Web API accepts form-encoded POST for this
   method; ids come from Slack's own events ([A-Z0-9], no URL escaping
   needed). A missing [users:read] scope surfaces as [Slack_api]. *)
type user_info_ok = {
  user_id : string;
  name : string option;
  real_name : string option;
  display_name : string option;
}

let build_users_info_request ~token ~user_id =
  let url = "https://slack.com/api/users.info" in
  let headers =
    ("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
    :: auth_headers ~token
  in
  (url, headers, "user=" ^ user_id)

let parse_users_info_response ~status ~body =
  if status < 200 || status >= 300 then Error (Http_status { code = status; body })
  else
    match parse_json_safe body with
    | Error msg -> Error (Other (Printf.sprintf "response rejected (%s): %s" msg body))
    | Ok json ->
      let ok =
        match Gate_rest_json.bool_field "ok" json with Some b -> b | None -> false
      in
      if not ok then
        let err =
          match Gate_rest_json.string_field "error" json with
          | Some e -> e
          | None -> "users.info failed"
        in
        Error (Slack_api { error = err })
      else
        (match Gate_rest_json.object_field "user" json with
         | Some user ->
           (match Gate_rest_json.string_field "id" user with
            | Some user_id ->
              (* Blank profile fields are represented as absent, not as empty
                 labels a renderer would print verbatim. *)
              let non_blank = function
                | Some s when String.trim s <> "" -> Some s
                | Some _ | None -> None
              in
              let profile = Gate_rest_json.object_field "profile" user in
              let profile_field key =
                Option.bind profile (fun p ->
                  non_blank (Gate_rest_json.string_field key p))
              in
              Ok
                { user_id
                ; name = non_blank (Gate_rest_json.string_field "name" user)
                ; real_name = profile_field "real_name"
                ; display_name = profile_field "display_name"
                }
            | None -> Error (Other "ok=true but missing user.id"))
         | None -> Error (Other "ok=true but missing 'user'"))

type conversation_info_ok = {
  channel_id : string;
  channel_name : string option;
}

let build_conversations_info_request ~token ~channel_id =
  let url = "https://slack.com/api/conversations.info" in
  let headers =
    ("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
    :: auth_headers ~token
  in
  (url, headers, "channel=" ^ channel_id)

let parse_conversations_info_response ~status ~body =
  if status < 200 || status >= 300 then Error (Http_status { code = status; body })
  else
    match parse_json_safe body with
    | Error msg -> Error (Other (Printf.sprintf "response rejected (%s): %s" msg body))
    | Ok json ->
      let ok =
        match Gate_rest_json.bool_field "ok" json with Some b -> b | None -> false
      in
      if not ok then
        let err =
          match Gate_rest_json.string_field "error" json with
          | Some e -> e
          | None -> "conversations.info failed"
        in
        Error (Slack_api { error = err })
      else
        (match Gate_rest_json.object_field "channel" json with
         | Some channel ->
           (match Gate_rest_json.string_field "id" channel with
            | Some channel_id ->
              (* A direct message has no [name]. Absent rather than blank, so a
                 renderer never prints an empty label where a channel goes. *)
              let channel_name =
                match Gate_rest_json.string_field "name" channel with
                | Some name when String.trim name <> "" -> Some name
                | Some _ | None -> None
              in
              Ok { channel_id; channel_name }
            | None -> Error (Other "ok=true but missing channel.id"))
         | None -> Error (Other "ok=true but missing 'channel'"))

let conversations_info ?clock ?(timeout_sec = default_http_timeout_sec) ~token
    ~channel_id () =
  let (url, headers, body) =
    build_conversations_info_request ~token ~channel_id
  in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_conversations_info_response ~status ~body

let users_info ?clock ?(timeout_sec = default_http_timeout_sec) ~token ~user_id
    () =
  let (url, headers, body) = build_users_info_request ~token ~user_id in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_users_info_response ~status ~body

(* ── conversations.history — the slack-lane poll fiber's read ──── *)

type history_message = {
  ts : string;
  user_id : string option;   (* Absent when the author is an app/bot. *)
  bot_id : string option;    (* Present for app/bot authors. *)
  subtype : string option;   (* Present for message_changed, joins, … *)
  thread_ts : string option; (* Present when this is a thread reply. *)
  text : string;
}

type conversations_history_ok = {
  messages : history_message list;  (* Slack order: newest first. *)
  has_more : bool;
  next_cursor : string option;      (* response_metadata.next_cursor. *)
}

let build_conversations_history_request ~token ~channel_id ?oldest ?limit ?cursor () =
  let url = "https://slack.com/api/conversations.history" in
  let headers =
    ("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
    :: auth_headers ~token
  in
  let parts = [ "channel=" ^ channel_id ] in
  let parts =
    match oldest with Some oldest -> parts @ [ "oldest=" ^ oldest ] | None -> parts
  in
  let parts =
    match limit with Some limit -> parts @ [ "limit=" ^ string_of_int limit ] | None -> parts
  in
  let parts =
    match cursor with Some cursor -> parts @ [ "cursor=" ^ cursor ] | None -> parts
  in
  (url, headers, String.concat "&" parts)

(* Gate_rest_json exposes no array field; messages are destructured over
   Yojson with a local string extractor rather than widening the shared
   gate JSON surface for one caller. *)
let yojson_string_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String value) -> Some value
     | _ -> None)
  | _ -> None
;;

let parse_conversations_history_response ~status ~body =
  if status < 200 || status >= 300 then Error (Http_status { code = status; body })
  else
    match parse_json_safe body with
    | Error msg -> Error (Other (Printf.sprintf "response rejected (%s): %s" msg body))
    | Ok json ->
      let ok =
        match Gate_rest_json.bool_field "ok" json with Some b -> b | None -> false
      in
      if not ok then
        let err =
          match Gate_rest_json.string_field "error" json with
          | Some e -> e
          | None -> "conversations.history failed"
        in
        Error (Slack_api { error = err })
      else
        match Gate_rest_json.to_yojson json with
        | `Assoc fields ->
          let parsed =
            match List.assoc_opt "messages" fields with
            | Some (`List items) ->
              List.map
                (fun item ->
                  match yojson_string_field "ts" item with
                  | Some ts ->
                    Ok
                      { ts
                      ; user_id = yojson_string_field "user" item
                      ; bot_id = yojson_string_field "bot_id" item
                      ; subtype = yojson_string_field "subtype" item
                      ; thread_ts = yojson_string_field "thread_ts" item
                      ; text =
                          (match yojson_string_field "text" item with
                           | Some text -> text
                           | None -> "")
                      }
                  | None -> Error "message without ts")
                items
            | _ -> []
          in
          (match List.find_opt Result.is_error parsed with
           | Some (Error msg) -> Error (Other msg)
           | Some (Ok _) | None ->
             let has_more =
               match List.assoc_opt "has_more" fields with
               | Some (`Bool b) -> b
               | _ -> false
             in
             let next_cursor =
               match List.assoc_opt "response_metadata" fields with
               | Some (`Assoc md) ->
                 (match List.assoc_opt "next_cursor" md with
                  | Some (`String cursor) when cursor <> "" -> Some cursor
                  | _ -> None)
               | _ -> None
             in
             Ok
               { messages = List.map Result.get_ok parsed
               ; has_more
               ; next_cursor
               })
        | _ -> Error (Other "ok=true but response is not an object")

let conversations_history ?clock ?(timeout_sec = default_http_timeout_sec) ~token
    ~channel_id ?oldest ?limit ?cursor () =
  let (url, headers, body) =
    build_conversations_history_request ~token ~channel_id ?oldest ?limit ?cursor ()
  in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_conversations_history_response ~status ~body
