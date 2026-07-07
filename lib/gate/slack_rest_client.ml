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
  | Slack_api of { error : string }
  | Other of string

let pp_error fmt = function
  | Network msg -> Format.fprintf fmt "network: %s" msg
  | Slack_api { error } -> Format.fprintf fmt "slack api: %s" error
  | Other msg -> Format.fprintf fmt "other: %s" msg

(* Slack's per-message text limit is 40000 chars; we don't split here (caller
   responsibility, matching Discord_rest_client's stance on overflow) but
   expose it for callers that do. *)
let message_text_limit = 40_000

let user_agent = "masc-slack-bot/0.1 (https://github.com/jeong-sik/masc)"

let auth_headers ~token =
  [ ("Authorization", "Bearer " ^ token); ("User-Agent", user_agent) ]

let parse_json_safe s =
  try Some (Yojson.Safe.from_string s) with Yojson.Json_error _ -> None

let field_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let build_post_message_request ~token ~channel_id ~text ?thread_ts () =
  let url = "https://slack.com/api/chat.postMessage" in
  let headers = ("Content-Type", "application/json") :: auth_headers ~token in
  let fields = [ ("channel", `String channel_id); ("text", `String text) ] in
  let fields =
    match thread_ts with
    | None -> fields
    | Some ts -> ("thread_ts", `String ts) :: fields
  in
  let body = Yojson.Safe.to_string (`Assoc fields) in
  (url, headers, body)

(* Slack returns HTTP 200 with [{ ok }] even on logical failure, so the parse
   branches on the [ok] flag rather than the HTTP status. *)
let parse_post_response ~body =
  match parse_json_safe body with
  | None -> Error (Other ("response not JSON: " ^ body))
  | Some json ->
    let ok =
      match field_opt "ok" json with Some (`Bool b) -> b | _ -> false
    in
    if not ok then
      let err =
        match field_opt "error" json with
        | Some (`String e) -> e
        | _ -> "unknown error"
      in
      Error (Slack_api { error = err })
    else
      (match field_opt "ts" json with
       | Some (`String ts) -> Ok ts
       | _ -> Error (Other "ok=true but missing 'ts'"))

let send_message ~token ~channel_id ~text ?thread_ts () =
  let (url, headers, body) =
    build_post_message_request ~token ~channel_id ~text ?thread_ts ()
  in
  match Masc_http_client.post_sync ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (_status, body) -> parse_post_response ~body

let build_update_request ~token ~channel_id ~ts ~text () =
  let url = "https://slack.com/api/chat.update" in
  let headers = ("Content-Type", "application/json") :: auth_headers ~token in
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [ ("channel", `String channel_id); ("ts", `String ts); ("text", `String text) ])
  in
  (url, headers, body)

let edit_message ~token ~channel_id ~ts ~text () =
  let (url, headers, body) =
    build_update_request ~token ~channel_id ~ts ~text ()
  in
  match Masc_http_client.post_sync ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (_status, body) -> (
    match parse_json_safe body with
    | None -> Error (Other ("response not JSON: " ^ body))
    | Some json ->
      let ok =
        match field_opt "ok" json with Some (`Bool b) -> b | _ -> false
      in
      if ok then Ok ()
      else
        let err =
          match field_opt "error" json with
          | Some (`String e) -> e
          | _ -> "update failed"
        in
        Error (Slack_api { error = err }))
