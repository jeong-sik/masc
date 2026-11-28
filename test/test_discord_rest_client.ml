(* Discord_rest_client pure helper tests.

   Verifies wire-format contract of build_request and the four
   response classifications of parse_response. No HTTP round trip;
   send_message itself is not called here. *)

open Alcotest
module R = Discord_rest_client

let sf value =
  match R.snowflake_of_string value with
  | Ok value -> value
  | Error message -> failf "invalid test snowflake: %s" message

(* ---------------------------------------------------------------- *)
(* build_request                                                    *)
(* ---------------------------------------------------------------- *)

let header_value headers name =
  match List.assoc_opt name headers with
  | Some v -> v
  | None -> failf "missing header %s" name

let test_build_request_url_targets_channel () =
  let url, _, _ =
    R.build_request ~token:"abc" ~channel_id:(sf "1234567890") ~content:"hi" ()
  in
  check string "v10 channel URL"
    "https://discord.com/api/v10/channels/1234567890/messages"
    url

let test_build_request_authorization_uses_bot_scheme () =
  let _, headers, _ =
    R.build_request ~token:"sekret" ~channel_id:(sf "123") ~content:"." ()
  in
  check string "Authorization header" "Bot sekret"
    (header_value headers "Authorization");
  check string "Content-Type header" "application/json"
    (header_value headers "Content-Type")

let test_build_request_user_agent_present () =
  let _, headers, _ =
    R.build_request ~token:"t" ~channel_id:(sf "1") ~content:"." ()
  in
  let ua = header_value headers "User-Agent" in
  (* Discord requires DiscordBot ($url, $version) shape. *)
  check bool "User-Agent starts with DiscordBot" true
    (String.length ua >= 10
     && String.sub ua 0 10 = "DiscordBot")

let test_build_request_body_is_content_object () =
  let _, _, body =
    R.build_request ~token:"t" ~channel_id:(sf "1") ~content:"hello \"world\"" ()
  in
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc
      [ ("content", `String "hello \"world\"")
      ; ("allowed_mentions", `Assoc [ ("parse", `List []) ])
      ] -> ()
  | _ ->
      failf
        "body shape wrong: %s"
        (Yojson.Safe.to_string json)

let test_build_request_allows_only_explicit_users () =
  let _, _, body =
    R.build_request ~token:"t" ~channel_id:(sf "1")
      ~content:"<@123> @everyone <@&456>"
      ~allowed_user_mentions:[ sf "123" ] ()
  in
  let open Yojson.Safe.Util in
  let allowed =
    Yojson.Safe.from_string body |> member "allowed_mentions"
  in
  check (list string) "only explicit user snowflakes"
    [ "123" ] (allowed |> member "users" |> to_list |> List.map to_string);
  check bool "broad parse modes absent" true
    (allowed |> member "parse" = `Null)

let test_build_reply_requires_the_original_without_an_author_ping () =
  let channel_id = sf "101" in
  let reply_to_message_id = sf "901" in
  let text = R.build_request ~token:"t" ~channel_id ~content:"answer" ~reply_to_message_id () in
  let embed = R.image_embed ~url:"https://example.com/image.png" ~caption:None in
  let image =
    R.build_embed_request ~token:"t" ~channel_id ~content:"" ~reply_to_message_id
      ~embeds:[embed] ()
  in
  List.iter (fun (url, _, body) ->
    let open Yojson.Safe.Util in
    let message = Yojson.Safe.from_string body in
    let reference = member "message_reference" message in
    let mentions = member "allowed_mentions" message in
    check bool "the original thread is the POST target" true
      (String.ends_with ~suffix:"/channels/101/messages" url);
    check string "original message" "901" (reference |> member "message_id" |> to_string);
    check bool "missing original fails delivery" true
      (reference |> member "fail_if_not_exists" |> to_bool);
    check bool "no automatic author ping" false
      (mentions |> member "replied_user" |> to_bool))
    [text; image]

(* Discord dedupes a repeated create-message request only when the body names
   a nonce of at most 25 characters and sets enforce_nonce. *)
let test_build_request_nonce_asks_discord_to_dedupe () =
  let nonce = R.fresh_nonce () in
  let _, _, body =
    R.build_request ~token:"t" ~channel_id:(sf "1") ~content:"." ~nonce ()
  in
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string body in
  let sent = json |> member "nonce" |> to_string in
  check string "nonce is sent as given" (R.nonce_to_string nonce) sent;
  check bool "nonce fits Discord's 25-character limit" true
    (String.length sent <= 25);
  check bool "enforce_nonce is set" true
    (json |> member "enforce_nonce" |> to_bool)

let test_nonce_decoder_holds_the_discord_length_limit () =
  (match R.nonce_of_string (String.make 25 'a') with
   | Ok _ -> ()
   | Error message -> failf "rejected a 25-character nonce: %s" message);
  List.iter
    (fun value ->
      match R.nonce_of_string value with
      | Ok _ -> failf "accepted an invalid Discord nonce %S" value
      | Error _ -> ())
    [ ""; String.make 26 'a' ]

let test_build_typing_request_url_targets_channel () =
  let url, _, body =
    R.build_typing_request ~token:"abc" ~channel_id:(sf "1234567890") ()
  in
  check string "v10 typing URL"
    "https://discord.com/api/v10/channels/1234567890/typing"
    url;
  check string "empty typing body" "" body

let test_build_typing_request_authorization_uses_bot_scheme () =
  let _, headers, _ =
    R.build_typing_request ~token:"sekret" ~channel_id:(sf "123") ()
  in
  check string "Authorization header" "Bot sekret"
    (header_value headers "Authorization");
  let ua = header_value headers "User-Agent" in
  check bool "User-Agent starts with DiscordBot" true
    (String.length ua >= 10
     && String.sub ua 0 10 = "DiscordBot")

let test_snowflake_decoder_rejects_non_decimal_ids () =
  List.iter
    (fun value ->
      match R.snowflake_of_string value with
      | Ok _ -> failf "accepted invalid Discord snowflake %S" value
      | Error _ -> ())
    [ ""; " 123"; "123 "; "123/456"; "abc" ]

let test_error_rendering_does_not_disclose_response_body () =
  let secret = "gateway secret response" in
  match R.parse_response ~request_id:"req-1" ~status:502 ~body:secret () with
  | Ok _ -> fail "expected a redacted HTTP error"
  | Error error ->
    let rendered = Format.asprintf "%a" R.pp_error error in
    check bool "raw response is not rendered" false
      (String_util.string_contains_substring ~needle:secret rendered);
    check bool "request correlation is rendered" true
      (String_util.string_contains_substring ~needle:"req-1" rendered)

let test_build_channel_read_request_url () =
  let url, headers, body =
    R.build_channel_request ~token:"sekret" ~channel_id:(sf "123") ()
  in
  check string "channel read URL"
    "https://discord.com/api/v10/channels/123" url;
  check string "channel read auth" "Bot sekret"
    (header_value headers "Authorization");
  check string "channel read body" "" body

let test_build_guild_directory_request_urls () =
  let guild_url, _, _ =
    R.build_guild_request ~token:"t" ~guild_id:(sf "123") ()
  in
  let channels_url, _, _ =
    R.build_guild_channels_request ~token:"t" ~guild_id:(sf "123") ()
  in
  check string "guild URL" "https://discord.com/api/v10/guilds/123" guild_url;
  check string "guild channels URL"
    "https://discord.com/api/v10/guilds/123/channels" channels_url

let test_build_messages_read_request_query () =
  let url, _, body =
    R.build_channel_messages_request ~token:"t" ~channel_id:(sf "123")
      ~limit:25 ~before:(sf "456") ()
  in
  check bool "messages read path"
    true (String_util.string_contains_substring ~needle:"/channels/123/messages?" url);
  check bool "messages limit" true
    (String_util.string_contains_substring ~needle:"limit=25" url);
  check bool "messages before" true
    (String_util.string_contains_substring ~needle:"before=456" url);
  check string "GET body" "" body

let test_build_member_search_request_escapes_query () =
  let url, _, _ =
    R.build_guild_members_request ~token:"t" ~guild_id:(sf "123")
      ~query:"min su" ~limit:10 ()
  in
  check bool "member search path" true
    (String_util.string_contains_substring ~needle:"/guilds/123/members/search?" url);
  check bool "member search query" true
    (String_util.string_contains_substring ~needle:"query=min%20su" url);
  check bool "member search limit" true
    (String_util.string_contains_substring ~needle:"limit=10" url)

let test_build_member_request_url () =
  let url, _, _ =
    R.build_guild_member_request ~token:"t" ~guild_id:(sf "123")
      ~user_id:(sf "456") ()
  in
  check string "guild member URL"
    "https://discord.com/api/v10/guilds/123/members/456" url

let test_parse_json_response_accepts_array () =
  match R.parse_json_response ~status:200 ~body:"[{\"id\":\"USER\"}]" () with
  | Ok (`List [ `Assoc [ ("id", `String "USER") ] ]) -> ()
  | Ok json -> failf "unexpected JSON: %s" (Yojson.Safe.to_string json)
  | Error _ -> fail "expected JSON response to parse"

(* ---------------------------------------------------------------- *)
(* build_edit_request                                               *)
(* ---------------------------------------------------------------- *)

let test_build_edit_request_url_targets_message () =
  let url, _, _ =
    R.build_edit_request ~token:"abc" ~channel_id:(sf "123")
      ~message_id:(sf "456") ~content:"hi" ()
  in
  check string "v10 edit URL"
    "https://discord.com/api/v10/channels/123/messages/456"
    url

let test_build_edit_request_authorization_uses_bot_scheme () =
  let _, headers, _ =
    R.build_edit_request ~token:"sekret" ~channel_id:(sf "1")
      ~message_id:(sf "2") ~content:"." ()
  in
  check string "Authorization header" "Bot sekret"
    (header_value headers "Authorization");
  check string "Content-Type header" "application/json"
    (header_value headers "Content-Type")

let test_build_edit_request_body_is_content_object () =
  let _, _, body =
    R.build_edit_request ~token:"t" ~channel_id:(sf "1")
      ~message_id:(sf "2") ~content:"updated text" ()
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
    R.build_edit_request ~token:"t" ~channel_id:(sf "1")
      ~message_id:(sf "2") ~content:long_content ()
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
    R.build_edit_request ~token:"t" ~channel_id:(sf "1")
      ~message_id:(sf "2") ~content:short_content ()
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
  match R.parse_response ~status:200 ~body () with
  | Ok "MSG123" -> ()
  | Ok other -> failf "expected MSG123, got %s" other
  | Error e ->
      failf "expected Ok, got %s"
        (Format.asprintf "%a" R.pp_error e)

let test_parse_response_2xx_without_id_is_other () =
  let body = {|{"foo":"bar"}|} in
  match R.parse_response ~status:201 ~body () with
  | Error (R.Other _) -> ()
  | Ok _ -> fail "expected Error Other for 2xx without id"
  | Error e ->
      failf "expected Other, got %s"
        (Format.asprintf "%a" R.pp_error e)

let test_parse_response_rejects_duplicate_id () =
  let body = {|{"id":"first","id":"second"}|} in
  match R.parse_response ~status:200 ~body () with
  | Error (R.Other { reason; _ }) ->
    check bool "duplicate id is named" true
      (String_util.string_contains_substring ~needle:"repeats object key \"id\"" reason)
  | Ok _ -> fail "duplicate response id must not be selected"
  | Error error ->
    failf "expected duplicate id rejection, got %s"
      (Format.asprintf "%a" R.pp_error error)

let test_parse_response_2xx_non_json_is_other () =
  match R.parse_response ~status:200 ~body:"<html>oops</html>" () with
  | Error (R.Other _) -> ()
  | _ -> fail "expected Error Other for 2xx non-JSON body"

let test_parse_response_discord_error_envelope () =
  (* 50007: Cannot send messages to this user — real Discord error
     code from the published API documentation. *)
  let body =
    {|{"code":50007,"message":"Cannot send messages to this user"}|}
  in
  match R.parse_response ~status:403 ~body () with
  | Error
      (R.Discord_api { http_status = 403; code = 50007; request_id = _ }) ->
      ()
  | _ -> fail "expected Discord_api { 50007; ... }"

let test_parse_response_5xx_non_json_is_http_status () =
  match R.parse_response ~status:502 ~body:"Bad Gateway" () with
  | Error (R.Http_status { code = 502; body_bytes = 11; request_id = _ }) -> ()
  | _ -> fail "expected redacted Http_status { 502; body_bytes=11 }"

let test_parse_response_non2xx_json_without_envelope_is_redacted () =
  (* Non-2xx JSON without a Discord error envelope remains redacted. *)
  let body = {|{"hint":"bad request"}|} in
  match R.parse_response ~status:400 ~body () with
  | Error (R.Http_status { code = 400; body_bytes = 22; request_id = _ }) -> ()
  | _ ->
      fail
        "expected redacted Http_status when JSON lacks an error envelope"

let test_parse_empty_response_204_returns_ok () =
  match R.parse_empty_response ~status:204 ~body:"" () with
  | Ok () -> ()
  | Error e ->
      failf "expected Ok, got %s" (Format.asprintf "%a" R.pp_error e)

let test_parse_empty_response_discord_error_envelope () =
  let body = {|{"code":50013,"message":"Missing Permissions"}|} in
  match R.parse_empty_response ~status:403 ~body () with
  | Error
      (R.Discord_api { http_status = 403; code = 50013; request_id = _ }) ->
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
    { title = "Tool"
    ; description = None
    ; url = None
    ; color = 0x3498DB
    ; image = None
    ; fields = []
    }
  in
  let json = R.embed_to_json embed in
  match json with
  | `Assoc fields ->
      check bool "has title" true (List.mem_assoc "title" fields);
      check bool "has color" true (List.mem_assoc "color" fields);
      check bool "no description" false (List.mem_assoc "description" fields);
      check bool "no url" false (List.mem_assoc "url" fields);
      check bool "no image" false (List.mem_assoc "image" fields);
      check bool "no fields" false (List.mem_assoc "fields" fields)
  | _ -> fail "embed_to_json: expected Assoc"

let test_embed_to_json_full () =
  let embed : R.embed =
    { title = "My Tool"
    ; description = Some "Running..."
    ; url = Some "https://example.com"
    ; color = 0x2ECC71
    ; image = Some "https://example.com/img.png"
    ; fields = [ ("key", "val", true) ]
    }
  in
  let json = R.embed_to_json embed in
  match json with
  | `Assoc fields ->
      check bool "has url" true (List.mem_assoc "url" fields);
      check bool "has image" true (List.mem_assoc "image" fields);
      (match List.assoc_opt "image" fields with
       | Some (`Assoc img_items) ->
           check bool "image has url" true (List.mem_assoc "url" img_items)
       | _ -> fail "image shape wrong");
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

let test_link_embed_to_json () =
  let embed = R.link_embed ~url:"https://example.com"
    ~title:"Example" ~description:(Some "desc")
    ~image:(Some "https://example.com/i.png")
  in
  let json = R.embed_to_json embed in
  match json with
  | `Assoc fields ->
      check string "title" "Example"
        (match List.assoc_opt "title" fields with
         | Some (`String s) -> s
         | _ -> fail "title shape wrong");
      check bool "has url" true (List.mem_assoc "url" fields);
      check bool "has image" true (List.mem_assoc "image" fields)
  | _ -> fail "embed_to_json: expected Assoc"

let test_image_embed_to_json () =
  let embed = R.image_embed ~url:"https://example.com/pic.png"
    ~caption:(Some "a caption")
  in
  let json = R.embed_to_json embed in
  match json with
  | `Assoc fields ->
      check bool "has image" true (List.mem_assoc "image" fields);
      check bool "has description" true (List.mem_assoc "description" fields)
  | _ -> fail "embed_to_json: expected Assoc"

(* ---------------------------------------------------------------- *)
(* build_embed_request                                               *)
(* ---------------------------------------------------------------- *)

let test_build_embed_request_url_targets_channel () =
  let url, _, _ =
    R.build_embed_request ~token:"t" ~channel_id:(sf "1")
      ~content:"hi" ~embeds:[] ()
  in
  check string "URL targets channel"
    "https://discord.com/api/v10/channels/1/messages" url

let test_build_embed_request_empty_content_omits_field () =
  let _, _, body =
    R.build_embed_request ~token:"t" ~channel_id:(sf "1")
      ~content:"" ~embeds:[] ()
  in
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc [] -> ()  (* empty content + no embeds = empty object *)
  | _ -> failf "expected empty Assoc, got: %s" (Yojson.Safe.to_string json)

let test_build_embed_request_embeds_included () =
  let embed : R.embed =
    { title = "T"; description = None; url = None; color = 1; image = None; fields = [] }
  in
  let _, _, body =
    R.build_embed_request ~token:"t" ~channel_id:(sf "1")
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
(* split_at_codepoint / truncate_to_limit                           *)
(* ---------------------------------------------------------------- *)

(* Count Unicode scalar values in a UTF-8 string by stepping the
   stdlib decoder. Invalid sequences advance one byte (utf_decode_length
   is >= 1), so this terminates on any input. *)
let count_codepoints s =
  let n = String.length s in
  let rec go i acc =
    if i >= n then acc
    else
      let d = String.get_utf_8_uchar s i in
      go (i + Uchar.utf_decode_length d) (acc + 1)
  in
  go 0 0

(* "가" U+AC00 — a 3-byte UTF-8 char. byte 2000 lands mid-codepoint
   (2000 / 3 = 666.7), so a byte cut would split it. *)
let hangul = "\xea\xb0\x80"

let repeat_hangul n =
  let b = Buffer.create (n * 3) in
  for _ = 1 to n do Buffer.add_string b hangul done;
  Buffer.contents b

let test_split_at_codepoint_korean_head_valid_utf8 () =
  let s = repeat_hangul 2500 in
  let head, tail = R.split_at_codepoint s ~limit:2000 in
  check bool "head is valid UTF-8" true (String.is_valid_utf_8 head);
  check bool "tail is valid UTF-8" true (String.is_valid_utf_8 tail);
  check int "head is exactly 2000 codepoints" 2000 (count_codepoints head);
  check int "tail is the remaining 500 codepoints" 500 (count_codepoints tail);
  check string "head ^ tail reconstructs the original" s (head ^ tail)

let test_split_at_codepoint_short_fits () =
  let s = "hello" in
  let head, tail = R.split_at_codepoint s ~limit:2000 in
  check string "short head is the whole string" "hello" head;
  check string "short tail is empty" "" tail

let test_truncate_to_limit_korean_valid_utf8 () =
  let s = repeat_hangul 2500 in
  let t = R.truncate_to_limit s in
  check bool "truncated is valid UTF-8" true (String.is_valid_utf_8 t);
  check int "truncated to message_content_limit codepoints"
    R.message_content_limit (count_codepoints t)

(* ---------------------------------------------------------------- *)
(* Entry                                                            *)
(* ---------------------------------------------------------------- *)

(* ---------------------------------------------------------------- *)
(* build_upload_request                                             *)
(* ---------------------------------------------------------------- *)

let test_boundary value =
  match R.boundary_of_string value with
  | Ok boundary -> boundary
  | Error message -> failf "invalid test boundary: %s" message

let test_upload ?description ~filename ~media_type bytes =
  match R.upload ~filename ~media_type ?description bytes with
  | Ok upload -> upload
  | Error message -> failf "upload rejected: %s" message

(* Splits [body] on [sep] the way a multipart reader does: no escaping, the
   first occurrence ends the piece. *)
let split_on_string ~sep body =
  let rec go pos acc =
    match String_util.find_substring ~pos body sep with
    | None -> List.rev (String.sub body pos (String.length body - pos) :: acc)
    | Some index ->
      go (index + String.length sep) (String.sub body pos (index - pos) :: acc)
  in
  go 0 []

(* (header block, part body) for each part, read with the RFC 2046 framing:
   the first delimiter opens the body, CRLF+delimiter separates parts, and
   CRLF+delimiter+"--" closes it. *)
let multipart_parts ~boundary body =
  let delimiter = "--" ^ boundary in
  let opening = delimiter ^ "\r\n" in
  let closing = "\r\n" ^ delimiter ^ "--\r\n" in
  if not (String.starts_with ~prefix:opening body) then
    fail "body does not open with the delimiter";
  if not (String.ends_with ~suffix:closing body) then
    fail "body does not end with the close delimiter";
  let inner =
    String.sub body (String.length opening)
      (String.length body - String.length opening - String.length closing)
  in
  split_on_string ~sep:("\r\n" ^ opening) inner
  |> List.map (fun part ->
       match split_on_string ~sep:"\r\n\r\n" part with
       | headers :: rest -> (headers, String.concat "\r\n\r\n" rest)
       | [] -> fail "part without a header block")

(* Binary bytes that hold CRLF, NUL and a lone "--": a part body is not text. *)
let png_bytes = "\x89PNG\r\n\x1a\n\x00\x00--\r\n\xff"
let midi_bytes = "MThd\x00\x00\x00\x06\x00\x01"

(* An Ogg page header followed by bytes that hold CRLF and NUL. *)
let ogg_bytes = "OggS\x00\x02\r\n\x00\xff"

let test_voice_clip ~duration_secs ~waveform ogg =
  match R.voice_clip ~duration_secs ~waveform ogg with
  | Ok clip -> clip
  | Error message -> failf "voice clip rejected: %s" message

(* A voice message is one audio/ogg file with the IS_VOICE_MESSAGE flag and
   no content; its attachment entry carries duration_secs and the base64
   waveform Discord draws. *)
let test_voice_message_request_shape () =
  let boundary = "test-boundary-voice" in
  let clip =
    test_voice_clip ~duration_secs:2.5 ~waveform:"\x00\x7f\xff" ogg_bytes
  in
  match
    R.build_voice_message_request ~token:"sekret" ~channel_id:(sf "123")
      ~boundary:(test_boundary boundary) ~reply_to_message_id:(sf "42") ~clip ()
  with
  | Error R.Boundary_in_payload -> fail "unexpected boundary collision"
  | Ok (url, headers, body) ->
    check string "create-message URL"
      "https://discord.com/api/v10/channels/123/messages" url;
    check string "multipart Content-Type names the boundary"
      ("multipart/form-data; boundary=" ^ boundary)
      (header_value headers "Content-Type");
    (match multipart_parts ~boundary body with
     | [ (_, payload); (audio_headers, audio) ] ->
       let open Yojson.Safe.Util in
       let json = Yojson.Safe.from_string payload in
       check int "IS_VOICE_MESSAGE flag" 8192 (json |> member "flags" |> to_int);
       check bool "no content" true (json |> member "content" = `Null);
       check string "reply reference" "42"
         (json |> member "message_reference" |> member "message_id" |> to_string);
       (match json |> member "attachments" |> to_list with
        | [ attachment ] ->
          check int "attachment id is files[0]" 0
            (attachment |> member "id" |> to_int);
          check string "filename" "voice-message.ogg"
            (attachment |> member "filename" |> to_string);
          check (float 0.0) "duration_secs" 2.5
            (attachment |> member "duration_secs" |> to_number);
          check string "waveform is base64 of the points" "AH//"
            (attachment |> member "waveform" |> to_string)
        | _ -> fail "a voice message names exactly one attachment");
       check string "audio part headers"
         "Content-Disposition: form-data; name=\"files[0]\"; \
          filename=\"voice-message.ogg\"\r\nContent-Type: audio/ogg"
         audio_headers;
       check string "Ogg bytes unchanged" ogg_bytes audio
     | parts -> failf "expected payload and one audio part, got %d" (List.length parts))

let test_voice_clip_refuses_what_discord_cannot_draw () =
  let refused label = function
    | Error (_ : string) -> ()
    | Ok _ -> failf "%s was accepted" label
  in
  let clip ?(duration_secs = 1.0) ?(waveform = "\x10") ogg =
    R.voice_clip ~duration_secs ~waveform ogg
  in
  refused "zero duration" (clip ~duration_secs:0.0 ogg_bytes);
  refused "NaN duration" (clip ~duration_secs:Float.nan ogg_bytes);
  refused "infinite duration" (clip ~duration_secs:Float.infinity ogg_bytes);
  refused "empty waveform" (clip ~waveform:"" ogg_bytes);
  refused "waveform over the limit"
    (clip ~waveform:(String.make (R.voice_waveform_max_points + 1) 'a') ogg_bytes);
  refused "bytes that are not Ogg" (clip "ID3\x04");
  check bool "the full waveform fits" true
    (Result.is_ok
       (clip ~waveform:(String.make R.voice_waveform_max_points 'a') ogg_bytes))

(* [samples] mono s16le samples, each [value]. *)
let pcm_of_samples values =
  let buffer = Bytes.create (2 * List.length values) in
  List.iteri (fun index value -> Bytes.set_int16_le buffer (2 * index) value) values;
  Bytes.to_string buffer

let constant_pcm ~samples value = pcm_of_samples (List.init samples (fun _ -> value))

let test_voice_waveform_one_point_per_100ms () =
  let rate = Discord_voice_clip.waveform_sample_rate in
  (match
     Discord_voice_clip.waveform_of_pcm_s16le ~sample_rate:rate
       (constant_pcm ~samples:(2 * rate) 16384)
   with
   | Some (duration_secs, waveform) ->
     check (float 1e-9) "two seconds" 2.0 duration_secs;
     check int "20 points for 2 s" 20 (String.length waveform);
     check bool "half scale maps to 127" true
       (String.for_all (fun c -> Char.code c = 127) waveform)
   | None -> fail "two seconds of audio gave no waveform");
  (match
     Discord_voice_clip.waveform_of_pcm_s16le ~sample_rate:rate
       (constant_pcm ~samples:(60 * rate) 1000)
   with
   | Some (_, waveform) ->
     check int "a minute is capped at the point limit"
       R.voice_waveform_max_points (String.length waveform)
   | None -> fail "a minute of audio gave no waveform");
  (* Loud then silent: the waveform follows the signal in time. *)
  let rate = 100 in
  let half = constant_pcm ~samples:50 (-32768) ^ constant_pcm ~samples:50 0 in
  match Discord_voice_clip.waveform_of_pcm_s16le ~sample_rate:rate half with
  | Some (_, waveform) ->
    check int "10 points for 1 s" 10 (String.length waveform);
    check int "the most negative sample is the top byte" 255 (Char.code waveform.[0]);
    check int "silence is zero" 0 (Char.code waveform.[9])
  | None -> fail "one second of audio gave no waveform"

let test_voice_waveform_edges () =
  let rate = Discord_voice_clip.waveform_sample_rate in
  check bool "no samples" true
    (Discord_voice_clip.waveform_of_pcm_s16le ~sample_rate:rate "" = None);
  check bool "half a sample" true
    (Discord_voice_clip.waveform_of_pcm_s16le ~sample_rate:rate "\x01" = None);
  check bool "no sample rate" true
    (Discord_voice_clip.waveform_of_pcm_s16le ~sample_rate:0 (pcm_of_samples [ 1 ])
     = None);
  match
    Discord_voice_clip.waveform_of_pcm_s16le ~sample_rate:rate
      (pcm_of_samples [ 32767 ] ^ "\x7f")
  with
  | Some (_, waveform) ->
    check string "one sample is one full point; a trailing byte is ignored"
      "\xff" waveform
  | None -> fail "one sample gave no waveform"

let test_upload_request_is_payload_json_then_files_in_order () =
  let boundary = "test-boundary-1" in
  let nonce =
    match R.nonce_of_string "upload-nonce-1" with
    | Ok nonce -> nonce
    | Error message -> failf "invalid test nonce: %s" message
  in
  let files =
    ( test_upload ~filename:"고양이.png" ~media_type:"image/png"
        ~description:"창가의 고양이" png_bytes
    , [ test_upload ~filename:"riff.mid" ~media_type:"audio/midi" midi_bytes ] )
  in
  match
    R.build_upload_request ~token:"sekret" ~channel_id:(sf "123")
      ~boundary:(test_boundary boundary) ~content:"악보예요"
      ~reply_to_message_id:(sf "42") ~nonce ~files ()
  with
  | Error R.Boundary_in_payload -> fail "unexpected boundary collision"
  | Ok (url, headers, body) ->
    check string "create-message URL"
      "https://discord.com/api/v10/channels/123/messages" url;
    check string "multipart Content-Type names the boundary"
      ("multipart/form-data; boundary=" ^ boundary)
      (header_value headers "Content-Type");
    check string "Authorization header" "Bot sekret"
      (header_value headers "Authorization");
    (match multipart_parts ~boundary body with
     | [ (payload_headers, payload); (png_headers, png); (midi_headers, midi) ] ->
       check string "payload_json part headers"
         "Content-Disposition: form-data; name=\"payload_json\"\r\n\
          Content-Type: application/json"
         payload_headers;
       let open Yojson.Safe.Util in
       let json = Yojson.Safe.from_string payload in
       check string "content" "악보예요" (json |> member "content" |> to_string);
       check string "attachments name files[n] by id, in order"
         "[{\"id\":0,\"filename\":\"고양이.png\",\"description\":\"창가의 고양이\"},\
          {\"id\":1,\"filename\":\"riff.mid\"}]"
         (json |> member "attachments" |> Yojson.Safe.to_string);
       check string "mentions suppressed, original author not pinged"
         "{\"parse\":[],\"replied_user\":false}"
         (json |> member "allowed_mentions" |> Yojson.Safe.to_string);
       check string "reply reference"
         "{\"message_id\":\"42\",\"fail_if_not_exists\":true}"
         (json |> member "message_reference" |> Yojson.Safe.to_string);
       check string "nonce" "upload-nonce-1" (json |> member "nonce" |> to_string);
       check bool "enforce_nonce" true (json |> member "enforce_nonce" |> to_bool);
       check string "files[0] part headers"
         "Content-Disposition: form-data; name=\"files[0]\"; filename=\"고양이.png\"\r\n\
          Content-Type: image/png"
         png_headers;
       check string "files[0] bytes unchanged" png_bytes png;
       check string "files[1] part headers"
         "Content-Disposition: form-data; name=\"files[1]\"; filename=\"riff.mid\"\r\n\
          Content-Type: audio/midi"
         midi_headers;
       check string "files[1] bytes unchanged" midi_bytes midi
     | parts -> failf "expected 3 parts, got %d" (List.length parts));
    (match
       R.build_upload_request ~token:"t" ~channel_id:(sf "123")
         ~boundary:(test_boundary boundary) ~content:"<@77> 들어 보세요"
         ~allowed_user_mentions:[ sf "77" ] ~files ()
     with
     | Error R.Boundary_in_payload -> fail "unexpected boundary collision"
     | Ok (_, _, body) ->
       (match multipart_parts ~boundary body with
        | (_, payload) :: _ ->
          let open Yojson.Safe.Util in
          check string "only the explicit user may be notified"
            "{\"users\":[\"77\"]}"
            (Yojson.Safe.from_string payload |> member "allowed_mentions"
             |> Yojson.Safe.to_string)
        | [] -> fail "no payload part"))

let test_upload_refuses_values_that_break_part_headers () =
  let refused label = function
    | Ok _ -> failf "%s: accepted" label
    | Error (_ : string) -> ()
  in
  let upload ?description ?(media_type = "image/png") filename =
    R.upload ~filename ~media_type ?description "x"
  in
  refused "empty filename" (upload "");
  refused "quote ends the filename parameter" (upload "a\".png");
  refused "CRLF starts a new header" (upload "a\r\nX-Injected: 1.png");
  refused "backslash" (upload "a\\b.png");
  refused "path" (upload "../a.png");
  refused "NUL" (upload "a\000.png");
  refused "invalid UTF-8" (upload "a\xff.png");
  refused "CRLF in media type" (upload ~media_type:"image/png\r\nX-Injected: 1" "a.png");
  refused "media type without subtype" (upload ~media_type:"image" "a.png");
  refused "media type parameter" (upload ~media_type:"image/png; charset=x" "a.png");
  refused "alt text over 1024 characters"
    (upload ~description:(String.concat "" (List.init 1025 (fun _ -> "가"))) "a.png");
  (match upload ~description:(String.concat "" (List.init 1024 (fun _ -> "가"))) "a.png" with
   | Ok _ -> ()
   | Error message -> failf "1024-character alt text refused: %s" message);
  (match upload ~media_type:"audio/midi" "riff.mid" with
   | Ok upload -> check string "filename kept" "riff.mid" (R.upload_filename upload)
   | Error message -> failf "audio/midi refused: %s" message);
  refused "boundary over 70 characters"
    (R.boundary_of_string (String.make 71 'a'));
  refused "boundary with a quote" (R.boundary_of_string "a\"b")

let test_upload_request_refuses_a_boundary_inside_a_part () =
  let boundary = test_boundary "b1" in
  let build ?content bytes =
    R.build_upload_request ~token:"t" ~channel_id:(sf "1") ~boundary ?content
      ~files:(test_upload ~filename:"a.bin" ~media_type:"application/octet-stream" bytes, [])
      ()
  in
  (match build "head\r\n--b1\r\ntail" with
   | Error R.Boundary_in_payload -> ()
   | Ok _ -> fail "delimiter inside file bytes was accepted");
  (match build ~content:"see --b1" "x" with
   | Error R.Boundary_in_payload -> ()
   | Ok _ -> fail "delimiter inside payload_json was accepted");
  match build "-b1 is not the delimiter" with
  | Ok _ -> ()
  | Error R.Boundary_in_payload -> fail "a non-delimiter was refused"

let () =
  run "discord_rest_client"
    [ ( "build_upload_request"
      , [ test_case "payload_json then files[n] in order, bytes unchanged"
            `Quick test_upload_request_is_payload_json_then_files_in_order
        ; test_case "values that break part headers are refused" `Quick
            test_upload_refuses_values_that_break_part_headers
        ; test_case "a boundary inside a part is refused" `Quick
            test_upload_request_refuses_a_boundary_inside_a_part
        ] )
    ; ( "build_voice_message_request"
      , [ test_case "one audio/ogg file, the voice flag, no content" `Quick
            test_voice_message_request_shape
        ; test_case "a clip Discord cannot draw is refused" `Quick
            test_voice_clip_refuses_what_discord_cannot_draw
        ] )
    ; ( "voice waveform"
      , [ test_case "one point per 100 ms, capped, in time order" `Quick
            test_voice_waveform_one_point_per_100ms
        ; test_case "no samples, half a sample, one sample" `Quick
            test_voice_waveform_edges
        ] )
    ; ( "snowflake"
      , [ test_case "rejects non-decimal IDs" `Quick
            test_snowflake_decoder_rejects_non_decimal_ids ] )
    ; ( "nonce"
      , [ test_case "holds the 25-character limit" `Quick
            test_nonce_decoder_holds_the_discord_length_limit ] )
    ; ( "build_request"
      , [ test_case "URL targets channel" `Quick
            test_build_request_url_targets_channel
        ; test_case "Authorization uses Bot scheme" `Quick
            test_build_request_authorization_uses_bot_scheme
        ; test_case "User-Agent present (Discord-required)" `Quick
            test_build_request_user_agent_present
        ; test_case "body is { content: <content> } JSON" `Quick
            test_build_request_body_is_content_object
        ; test_case "only explicit user mentions are allowed" `Quick
            test_build_request_allows_only_explicit_users
        ; test_case "reply keeps the original without an author ping" `Quick
            test_build_reply_requires_the_original_without_an_author_ping
        ; test_case "nonce asks Discord to dedupe" `Quick
            test_build_request_nonce_asks_discord_to_dedupe
        ; test_case "typing URL targets channel" `Quick
            test_build_typing_request_url_targets_channel
        ; test_case "typing Authorization uses Bot scheme" `Quick
            test_build_typing_request_authorization_uses_bot_scheme
        ; test_case "channel read URL and headers" `Quick
            test_build_channel_read_request_url
        ; test_case "guild directory URLs" `Quick
            test_build_guild_directory_request_urls
        ; test_case "messages read query" `Quick
            test_build_messages_read_request_query
        ; test_case "member search query escaping" `Quick
            test_build_member_search_request_escapes_query
        ; test_case "guild member URL" `Quick
            test_build_member_request_url
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
        ; test_case "link embed builder" `Quick
            test_link_embed_to_json
        ; test_case "image embed builder" `Quick
            test_image_embed_to_json
        ] )
    ; ( "build_embed_request"
      , [ test_case "URL targets channel" `Quick
            test_build_embed_request_url_targets_channel
        ; test_case "empty content omits content field" `Quick
            test_build_embed_request_empty_content_omits_field
        ; test_case "embeds included in body" `Quick
            test_build_embed_request_embeds_included
        ] )
    ; ( "codepoint_chunking"
      , [ test_case "Korean split head/tail valid UTF-8 on boundary" `Quick
            test_split_at_codepoint_korean_head_valid_utf8
        ; test_case "short string fits without splitting" `Quick
            test_split_at_codepoint_short_fits
        ; test_case "truncate_to_limit keeps valid UTF-8" `Quick
            test_truncate_to_limit_korean_valid_utf8
        ] )
    ; ( "parse_response"
      , [ test_case "2xx with id => Ok id" `Quick
            test_parse_response_2xx_with_id_returns_ok
        ; test_case "2xx without id => Other" `Quick
            test_parse_response_2xx_without_id_is_other
        ; test_case "duplicate response id => Other" `Quick
            test_parse_response_rejects_duplicate_id
        ; test_case "2xx non-JSON => Other" `Quick
            test_parse_response_2xx_non_json_is_other
        ; test_case "Discord error envelope => Discord_api" `Quick
            test_parse_response_discord_error_envelope
        ; test_case "5xx non-JSON => Http_status" `Quick
            test_parse_response_5xx_non_json_is_http_status
        ; test_case "error rendering omits raw response body" `Quick
            test_error_rendering_does_not_disclose_response_body
        ; test_case "non-2xx JSON without envelope => redacted Http_status"
            `Quick test_parse_response_non2xx_json_without_envelope_is_redacted
        ; test_case "empty 204 => Ok" `Quick
            test_parse_empty_response_204_returns_ok
        ; test_case "empty non-2xx Discord envelope => Discord_api"
            `Quick test_parse_empty_response_discord_error_envelope
        ; test_case "JSON response accepts array" `Quick
            test_parse_json_response_accepts_array
        ] )
    ]
