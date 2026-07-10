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

(* Slack's per-message text limit is 40000 chars; we don't split here (caller
   responsibility, matching Discord_rest_client's stance on overflow) but
   expose it for callers that do. *)
let message_text_limit = 40_000

(* Default outbound-request timeout. [Masc_http_client.post_sync] applies a
   deadline only when a clock {b and} [timeout_sec > 0.0] are both supplied, so
   this default takes effect once a caller threads [~clock] (the in-process
   gateway does); clock-less callers keep the prior unbounded behavior. Matches
   the socket client's [fetch_wss_url] default so all Slack HTTP shares one
   ceiling. *)
let default_http_timeout_sec = 10.0

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

(* Slack returns HTTP 200 with [{ ok }] even on logical failure; after the
   transport-level 2xx check, branch on Slack's [ok] flag. *)
let parse_post_json_response ~body =
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
         [ ("channel", `String channel_id); ("ts", `String ts); ("text", `String text) ])
  in
  (url, headers, body)

let parse_update_response ~status ~body =
  if status < 200 || status >= 300 then Error (Http_status { code = status; body })
  else
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
    | None -> Error (Other ("response not JSON: " ^ body))
    | Some json ->
      let ok =
        match field_opt "ok" json with Some (`Bool b) -> b | _ -> false
      in
      if not ok then
        let err =
          match field_opt "error" json with
          | Some (`String e) -> e
          | _ -> "auth.test failed"
        in
        Error (Slack_api { error = err })
      else
        (match field_opt "user_id" json with
         | Some (`String user_id) ->
           let team_id =
             match field_opt "team_id" json with
             | Some (`String t) -> Some t
             | _ -> None
           in
           Ok { user_id; team_id }
         | _ -> Error (Other "ok=true but missing 'user_id'"))

let auth_test ?clock ?(timeout_sec = default_http_timeout_sec) ~token () =
  let (url, headers, body) = build_auth_test_request ~token in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_auth_test_response ~status ~body
