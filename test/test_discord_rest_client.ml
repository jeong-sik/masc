(* RFC-0203 Phase 2 — Discord_rest_client pure helper tests.

   Verifies wire-format contract of build_request and the four
   response classifications of parse_response. No HTTP round trip;
   send_message itself is exercised by Phase 4 dual-run. *)

open Alcotest
module R = Discord_rest_client

(* ---------------------------------------------------------------- *)
(* build_request                                                    *)
(* ---------------------------------------------------------------- *)

let header_value headers name =
  match List.assoc_opt name headers with
  | Some v -> v
  | None -> failf "missing header %s" name

let test_build_request_url_targets_channel () =
  let url, _, _ =
    R.build_request ~token:"abc" ~channel_id:"1234567890" ~content:"hi" ()
  in
  check string "v10 channel URL"
    "https://discord.com/api/v10/channels/1234567890/messages"
    url

let test_build_request_authorization_uses_bot_scheme () =
  let _, headers, _ =
    R.build_request ~token:"sekret" ~channel_id:"CH" ~content:"." ()
  in
  check string "Authorization header" "Bot sekret"
    (header_value headers "Authorization");
  check string "Content-Type header" "application/json"
    (header_value headers "Content-Type")

let test_build_request_user_agent_present () =
  let _, headers, _ =
    R.build_request ~token:"t" ~channel_id:"c" ~content:"." ()
  in
  let ua = header_value headers "User-Agent" in
  (* Discord requires DiscordBot ($url, $version) shape. *)
  check bool "User-Agent starts with DiscordBot" true
    (String.length ua >= 10
     && String.sub ua 0 10 = "DiscordBot")

let test_build_request_body_is_content_object () =
  let _, _, body =
    R.build_request ~token:"t" ~channel_id:"c" ~content:"hello \"world\"" ()
  in
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc [ ("content", `String "hello \"world\"") ] -> ()
  | _ ->
      failf
        "body shape wrong: %s"
        (Yojson.Safe.to_string json)

let test_build_typing_request_url_targets_channel () =
  let url, _, body =
    R.build_typing_request ~token:"abc" ~channel_id:"1234567890" ()
  in
  check string "v10 typing URL"
    "https://discord.com/api/v10/channels/1234567890/typing"
    url;
  check string "empty typing body" "" body

let test_build_typing_request_authorization_uses_bot_scheme () =
  let _, headers, _ =
    R.build_typing_request ~token:"sekret" ~channel_id:"CH" ()
  in
  check string "Authorization header" "Bot sekret"
    (header_value headers "Authorization");
  let ua = header_value headers "User-Agent" in
  check bool "User-Agent starts with DiscordBot" true
    (String.length ua >= 10
     && String.sub ua 0 10 = "DiscordBot")

(* ---------------------------------------------------------------- *)
(* build_edit_request                                               *)
(* ---------------------------------------------------------------- *)

let test_build_edit_request_url_targets_message () =
  let url, _, _ =
    R.build_edit_request ~token:"abc" ~channel_id:"CH123"
      ~message_id:"MSG456" ~content:"hi" ()
  in
  check string "v10 edit URL"
    "https://discord.com/api/v10/channels/CH123/messages/MSG456"
    url

let test_build_edit_request_authorization_uses_bot_scheme () =
  let _, headers, _ =
    R.build_edit_request ~token:"sekret" ~channel_id:"c"
      ~message_id:"m" ~content:"." ()
  in
  check string "Authorization header" "Bot sekret"
    (header_value headers "Authorization");
  check string "Content-Type header" "application/json"
    (header_value headers "Content-Type")

let test_build_edit_request_body_is_content_object () =
  let _, _, body =
    R.build_edit_request ~token:"t" ~channel_id:"c"
      ~message_id:"m" ~content:"updated text" ()
  in
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc [ ("content", `String "updated text") ] -> ()
  | _ ->
      failf
        "body shape wrong: %s"
        (Yojson.Safe.to_string json)

let test_build_edit_request_content_truncated_at_limit () =
  let long_content = String.make 2500 'x' in
  let _, _, body =
    R.build_edit_request ~token:"t" ~channel_id:"c"
      ~message_id:"m" ~content:long_content ()
  in
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc [ ("content", `String truncated) ] ->
      check int "truncated length" 2000 (String.length truncated)
  | _ ->
      failf "body shape wrong: %s" (Yojson.Safe.to_string json)

let test_build_edit_request_short_content_not_truncated () =
  let short_content = "hello" in
  let _, _, body =
    R.build_edit_request ~token:"t" ~channel_id:"c"
      ~message_id:"m" ~content:short_content ()
  in
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc [ ("content", `String "hello") ] -> ()
  | _ ->
      failf "body shape wrong: %s" (Yojson.Safe.to_string json)

(* ---------------------------------------------------------------- *)
(* parse_response                                                   *)
(* ---------------------------------------------------------------- *)

let test_parse_response_2xx_with_id_returns_ok () =
  let body =
    {|{"id":"MSG123","channel_id":"CH","content":"hi","author":{"id":"BOT"}}|}
  in
  match R.parse_response ~status:200 ~body with
  | Ok "MSG123" -> ()
  | Ok other -> failf "expected MSG123, got %s" other
  | Error e ->
      failf "expected Ok, got %s"
        (Format.asprintf "%a" R.pp_error e)

let test_parse_response_2xx_without_id_is_other () =
  let body = {|{"foo":"bar"}|} in
  match R.parse_response ~status:201 ~body with
  | Error (R.Other _) -> ()
  | Ok _ -> fail "expected Error Other for 2xx without id"
  | Error e ->
      failf "expected Other, got %s"
        (Format.asprintf "%a" R.pp_error e)

let test_parse_response_2xx_non_json_is_other () =
  match R.parse_response ~status:200 ~body:"<html>oops</html>" with
  | Error (R.Other _) -> ()
  | _ -> fail "expected Error Other for 2xx non-JSON body"

let test_parse_response_discord_error_envelope () =
  (* 50007: Cannot send messages to this user — real Discord error
     code from the published API documentation. *)
  let body =
    {|{"code":50007,"message":"Cannot send messages to this user"}|}
  in
  match R.parse_response ~status:403 ~body with
  | Error
      (R.Discord_api
        { code = 50007
        ; message = "Cannot send messages to this user"
        }) ->
      ()
  | _ -> fail "expected Discord_api { 50007; ... }"

let test_parse_response_5xx_non_json_is_http_status () =
  match R.parse_response ~status:502 ~body:"Bad Gateway" with
  | Error (R.Http_status { code = 502; body = "Bad Gateway" }) -> ()
  | _ -> fail "expected Http_status { 502; \"Bad Gateway\" }"

let test_parse_response_non2xx_json_without_envelope_falls_back () =
  (* Non-2xx with a JSON object that has no Discord code/message —
     parse_response falls back to (status, body) as code/message. *)
  let body = {|{"hint":"bad request"}|} in
  match R.parse_response ~status:400 ~body with
  | Error (R.Discord_api { code = 400; _ }) -> ()
  | _ ->
      fail
        "expected Discord_api with code=400 fallback when JSON lacks \
         'code' field"

let test_parse_empty_response_204_returns_ok () =
  match R.parse_empty_response ~status:204 ~body:"" with
  | Ok () -> ()
  | Error e ->
      failf "expected Ok, got %s" (Format.asprintf "%a" R.pp_error e)

let test_parse_empty_response_discord_error_envelope () =
  let body = {|{"code":50013,"message":"Missing Permissions"}|} in
  match R.parse_empty_response ~status:403 ~body with
  | Error (R.Discord_api { code = 50013; message = "Missing Permissions" }) ->
      ()
  | Ok () -> fail "expected Discord_api error"
  | Error e ->
      failf
        "expected Discord_api 50013, got %s"
        (Format.asprintf "%a" R.pp_error e)

(* ---------------------------------------------------------------- *)
(* embed_to_json                                                     *)
(* ---------------------------------------------------------------- *)

let test_embed_to_json_minimal () =
  let embed : R.embed =
    { title = "Tool"; description = None; color = 0x3498DB; fields = [] }
  in
  let json = R.embed_to_json embed in
  match json with
  | `Assoc fields ->
      check bool "has title" true (List.mem_assoc "title" fields);
      check bool "has color" true (List.mem_assoc "color" fields);
      check bool "no description" false (List.mem_assoc "description" fields);
      check bool "no fields" false (List.mem_assoc "fields" fields)
  | _ -> fail "embed_to_json: expected Assoc"

let test_embed_to_json_full () =
  let embed : R.embed =
    { title = "My Tool"
    ; description = Some "Running..."
    ; color = 0x2ECC71
    ; fields = [ ("key", "val", true) ]
    }
  in
  let json = R.embed_to_json embed in
  match json with
  | `Assoc fields ->
      (match List.assoc_opt "fields" fields with
       | Some (`List [ `Assoc field_items ]) ->
           check bool "field has name" true
             (List.mem_assoc "name" field_items);
           check bool "field has value" true
             (List.mem_assoc "value" field_items);
           check bool "field has inline" true
             (List.mem_assoc "inline" field_items)
       | _ -> fail "fields shape wrong")
  | _ -> fail "embed_to_json: expected Assoc"

(* ---------------------------------------------------------------- *)
(* build_embed_request                                               *)
(* ---------------------------------------------------------------- *)

let test_build_embed_request_url_targets_channel () =
  let url, _, _ =
    R.build_embed_request ~token:"t" ~channel_id:"CH1"
      ~content:"hi" ~embeds:[] ()
  in
  check string "URL targets channel"
    "https://discord.com/api/v10/channels/CH1/messages" url

let test_build_embed_request_empty_content_omits_field () =
  let _, _, body =
    R.build_embed_request ~token:"t" ~channel_id:"c"
      ~content:"" ~embeds:[] ()
  in
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc [] -> ()  (* empty content + no embeds = empty object *)
  | _ -> failf "expected empty Assoc, got: %s" (Yojson.Safe.to_string json)

let test_build_embed_request_embeds_included () =
  let embed : R.embed =
    { title = "T"; description = None; color = 1; fields = [] }
  in
  let _, _, body =
    R.build_embed_request ~token:"t" ~channel_id:"c"
      ~content:"" ~embeds:[embed] ()
  in
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc fields ->
      check bool "has embeds key" true (List.mem_assoc "embeds" fields);
      (match List.assoc_opt "embeds" fields with
       | Some (`List [ _ ]) -> ()  (* one embed *)
       | _ -> fail "embeds should be a list with one element")
  | _ -> fail "expected Assoc"

(* ---------------------------------------------------------------- *)
(* build_edit_embed_request                                          *)
(* ---------------------------------------------------------------- *)

let test_build_edit_embed_request_url_targets_message () =
  let url, _, _ =
    R.build_edit_embed_request ~token:"t" ~channel_id:"CH"
      ~message_id:"MSG1" ~content:"hi" ~embeds:[] ()
  in
  check string "URL targets message"
    "https://discord.com/api/v10/channels/CH/messages/MSG1" url

let test_build_edit_embed_request_embeds_and_content () =
  let embed : R.embed =
    { title = "Done"; description = Some "Done"; color = 0x2ECC71
    ; fields = [] }
  in
  let _, _, body =
    R.build_edit_embed_request ~token:"t" ~channel_id:"c"
      ~message_id:"m" ~content:"ok" ~embeds:[embed] ()
  in
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc fields ->
      check bool "has content" true (List.mem_assoc "content" fields);
      check bool "has embeds" true (List.mem_assoc "embeds" fields)
  | _ -> fail "expected Assoc"

(* ---------------------------------------------------------------- *)
(* Entry                                                            *)
(* ---------------------------------------------------------------- *)

let () =
  run "discord_rest_client"
    [ ( "build_request"
      , [ test_case "URL targets channel" `Quick
            test_build_request_url_targets_channel
        ; test_case "Authorization uses Bot scheme" `Quick
            test_build_request_authorization_uses_bot_scheme
        ; test_case "User-Agent present (Discord-required)" `Quick
            test_build_request_user_agent_present
        ; test_case "body is { content: <content> } JSON" `Quick
            test_build_request_body_is_content_object
        ; test_case "typing URL targets channel" `Quick
            test_build_typing_request_url_targets_channel
        ; test_case "typing Authorization uses Bot scheme" `Quick
            test_build_typing_request_authorization_uses_bot_scheme
        ] )
    ; ( "build_edit_request"
      , [ test_case "URL targets channel/message" `Quick
            test_build_edit_request_url_targets_message
        ; test_case "Authorization uses Bot scheme" `Quick
            test_build_edit_request_authorization_uses_bot_scheme
        ; test_case "body is { content: <content> } JSON" `Quick
            test_build_edit_request_body_is_content_object
        ; test_case "content truncated at 2000 chars" `Quick
            test_build_edit_request_content_truncated_at_limit
        ; test_case "short content not truncated" `Quick
            test_build_edit_request_short_content_not_truncated
        ] )
    ; ( "embed_to_json"
      , [ test_case "minimal embed (no description/fields)" `Quick
            test_embed_to_json_minimal
        ; test_case "full embed (description + fields)" `Quick
            test_embed_to_json_full
        ] )
    ; ( "build_embed_request"
      , [ test_case "URL targets channel" `Quick
            test_build_embed_request_url_targets_channel
        ; test_case "empty content omits content field" `Quick
            test_build_embed_request_empty_content_omits_field
        ; test_case "embeds included in body" `Quick
            test_build_embed_request_embeds_included
        ] )
    ; ( "build_edit_embed_request"
      , [ test_case "URL targets channel/message" `Quick
            test_build_edit_embed_request_url_targets_message
        ; test_case "embeds and content both present" `Quick
            test_build_edit_embed_request_embeds_and_content
        ] )
    ; ( "parse_response"
      , [ test_case "2xx with id => Ok id" `Quick
            test_parse_response_2xx_with_id_returns_ok
        ; test_case "2xx without id => Other" `Quick
            test_parse_response_2xx_without_id_is_other
        ; test_case "2xx non-JSON => Other" `Quick
            test_parse_response_2xx_non_json_is_other
        ; test_case "Discord error envelope => Discord_api" `Quick
            test_parse_response_discord_error_envelope
        ; test_case "5xx non-JSON => Http_status" `Quick
            test_parse_response_5xx_non_json_is_http_status
        ; test_case "non-2xx JSON without envelope => Discord_api fallback"
            `Quick test_parse_response_non2xx_json_without_envelope_falls_back
        ; test_case "empty 204 => Ok" `Quick
            test_parse_empty_response_204_returns_ok
        ; test_case "empty non-2xx Discord envelope => Discord_api"
            `Quick test_parse_empty_response_discord_error_envelope
        ] )
    ]
