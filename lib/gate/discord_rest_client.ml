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

(* Discord requires a specific User-Agent format:
   "DiscordBot ($url, $version)". *)
let user_agent =
  "DiscordBot (https://github.com/jeong-sik/masc, 0.1)"

let build_request ~token ~channel_id ~content =
  let url =
    Printf.sprintf
      "https://discord.com/api/v10/channels/%s/messages"
      channel_id
  in
  let headers =
    [ "Authorization", "Bot " ^ token
    ; "Content-Type", "application/json"
    ; "User-Agent", user_agent
    ]
  in
  let body =
    Yojson.Safe.to_string (`Assoc [ "content", `String content ])
  in
  (url, headers, body)

let parse_response ~status ~body =
  let parse_json_safe s =
    try Some (Yojson.Safe.from_string s) with Yojson.Json_error _ -> None
  in
  let field_opt name = function
    | `Assoc fields -> List.assoc_opt name fields
    | _ -> None
  in
  if status >= 200 && status < 300 then
    match parse_json_safe body with
    | None ->
        Error (Other ("2xx response body is not valid JSON: " ^ body))
    | Some json ->
        (match field_opt "id" json with
         | Some (`String id) -> Ok id
         | _ -> Error (Other "2xx response missing 'id' string"))
  else
    match parse_json_safe body with
    | None -> Error (Http_status { code = status; body })
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
        Error (Discord_api { code; message })

let send_message ~token ~channel_id ~content =
  let (url, headers, body) = build_request ~token ~channel_id ~content in
  match Masc_http_client.post_sync ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_response ~status ~body
