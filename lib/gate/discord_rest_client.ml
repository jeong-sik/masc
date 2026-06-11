(* RFC-0203 Phase 2 — Discord REST send_message.

   Thin wrapper over Masc_http_client.post_sync. Splits into pure
   build_request and parse_response helpers so the wire-format
   contract can be unit-tested without a network round trip. *)

type error =
  | Network of string
  | Http_status of { code : int; body : string }
  | Discord_api of { code : int; message : string }
  | Other of string

let pp_error fmt = function
  | Network msg -> Format.fprintf fmt "network: %s" msg
  | Http_status { code; body } ->
      Format.fprintf fmt "http %d: %s" code body
  | Discord_api { code; message } ->
      Format.fprintf fmt "discord %d: %s" code message
  | Other msg -> Format.fprintf fmt "other: %s" msg

(* Discord text-message content limit, in Unicode scalar units.
   Messages longer than this must be split into multiple payloads. *)
let message_content_limit = 2000

(* Discord requires a specific User-Agent format:
   "DiscordBot ($url, $version)". *)
let user_agent =
  "DiscordBot (https://github.com/jeong-sik/masc, 0.1)"

let auth_headers ~token =
  [ "Authorization", "Bot " ^ token
  ; "User-Agent", user_agent
  ]

let build_request ~token ~channel_id ~content ?reply_to_message_id () =
  let url =
    Printf.sprintf
      "https://discord.com/api/v10/channels/%s/messages"
      channel_id
  in
  let headers =
    ("Content-Type", "application/json") :: auth_headers ~token
  in
  let fields = [ "content", `String content ] in
  let fields =
    match reply_to_message_id with
    | None -> fields
    | Some ref_id ->
        ("message_reference", `Assoc [ "message_id", `String ref_id ])
        :: fields
  in
  let body = Yojson.Safe.to_string (`Assoc fields) in
  (url, headers, body)

let build_typing_request ~token ~channel_id () =
  let url =
    Printf.sprintf
      "https://discord.com/api/v10/channels/%s/typing"
      channel_id
  in
  (url, auth_headers ~token, "")

let parse_json_safe s =
  try Some (Yojson.Safe.from_string s) with Yojson.Json_error _ -> None

let field_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let error_of_non2xx ~status ~body =
  match parse_json_safe body with
  | None -> Http_status { code = status; body }
  | Some json ->
      let code =
        match field_opt "code" json with
        | Some (`Int c) -> c
        | _ -> status
      in
      let message =
        match field_opt "message" json with
        | Some (`String s) -> s
        | _ -> body
      in
      Discord_api { code; message }

let parse_response ~status ~body =
  if status >= 200 && status < 300 then
    match parse_json_safe body with
    | None ->
        Error (Other ("2xx response body is not valid JSON: " ^ body))
    | Some json ->
        (match field_opt "id" json with
         | Some (`String id) -> Ok id
         | _ -> Error (Other "2xx response missing 'id' string"))
  else
    Error (error_of_non2xx ~status ~body)

let parse_empty_response ~status ~body =
  if status >= 200 && status < 300 then Ok ()
  else Error (error_of_non2xx ~status ~body)

let send_message ~token ~channel_id ~content ?reply_to_message_id () =
  let (url, headers, body) =
    build_request ~token ~channel_id ~content ?reply_to_message_id ()
  in
  match Masc_http_client.post_sync ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_response ~status ~body

let trigger_typing ~token ~channel_id () =
  let url, headers, body = build_typing_request ~token ~channel_id () in
  match Masc_http_client.post_sync ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_empty_response ~status ~body
