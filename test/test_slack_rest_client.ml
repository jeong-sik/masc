(* RFC-0317 Slack_rest_client pure-helper tests.

   Verifies request shape and response classification without any HTTP
   round trip. *)

open Alcotest
module R = Slack_rest_client

let header_value headers name =
  match List.assoc_opt name headers with
  | Some v -> v
  | None -> failf "missing header %s" name

let field_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> value
  | Some value ->
      failf "field %s was not a string: %s" name (Yojson.Safe.to_string value)
  | None -> failf "missing field %s" name

let assoc_fields body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> fields
  | json -> failf "body was not object: %s" (Yojson.Safe.to_string json)

let check_field_absent fields name =
  check bool (name ^ " absent") true
    (Option.is_none (List.assoc_opt name fields))

let test_build_post_message_request_url_and_headers () =
  let url, headers, _ =
    R.build_post_message_request ~token:"xoxb-secret" ~channel_id:"C123"
      ~text:"hello" ()
  in
  check string "url" "https://slack.com/api/chat.postMessage" url;
  check string "Authorization" "Bearer xoxb-secret"
    (header_value headers "Authorization");
  check string "Content-Type" "application/json"
    (header_value headers "Content-Type");
  check bool "User-Agent present" true
    (String.length (header_value headers "User-Agent") > 0);
  check int "native markdown limit" 12_000 R.message_text_limit;
  check (float 0.0) "streaming update interval" 3.0
    R.streaming_update_min_interval_sec

let test_build_post_message_request_body_with_thread () =
  let _, _, body =
    R.build_post_message_request ~token:"t" ~channel_id:"C123"
      ~text:"**hello** [world](https://example.com)"
      ~thread_ts:"1710000000.123456" ()
  in
  let fields = assoc_fields body in
  check string "channel" "C123" (field_string fields "channel");
  check string "markdown preserved" "**hello** [world](https://example.com)"
    (field_string fields "markdown_text");
  check_field_absent fields "text";
  check_field_absent fields "blocks";
  check string "thread_ts" "1710000000.123456" (field_string fields "thread_ts")

let test_parse_post_response_2xx_ok_returns_ts () =
  match R.parse_post_response ~status:200 ~body:{|{"ok":true,"ts":"171.42"}|} with
  | Ok "171.42" -> ()
  | Ok other -> failf "expected ts 171.42, got %s" other
  | Error err -> failf "expected Ok, got %s" (Format.asprintf "%a" R.pp_error err)

let test_parse_post_response_slack_error () =
  match
    R.parse_post_response ~status:200
      ~body:{|{"ok":false,"error":"channel_not_found"}|}
  with
  | Error (R.Slack_api { error = "channel_not_found" }) -> ()
  | Ok _ -> fail "expected Slack_api error"
  | Error err ->
      failf "expected Slack_api channel_not_found, got %s"
        (Format.asprintf "%a" R.pp_error err)

(* Both connectors read the same kind of REST body, and they used to disagree
   about a repeated object key: this one took the first value through
   [List.assoc_opt], so {"ok":false,"ok":true} answered "not ok", while
   discord_rest_client rejected it. test_discord_rest_client.ml sends the same
   two bodies. *)
let test_parse_post_response_repeated_key_is_rejected () =
  match R.parse_post_response ~status:200 ~body:{|{"ok":false,"ok":true}|} with
  | Error (R.Other detail) ->
      check bool "names the repeated key" true
        (String_util.string_contains_substring ~needle:{|repeats object key "ok"|}
           detail)
  | Ok ts -> failf "expected a rejection, got ts %S" ts
  | Error err ->
      failf "expected Other, got %s" (Format.asprintf "%a" R.pp_error err)

let test_parse_post_response_repeated_key_nested_is_rejected () =
  match
    R.parse_post_response ~status:200
      ~body:{|{"ok":true,"ts":"1.0","meta":{"id":"a","id":"b"}}|}
  with
  | Error (R.Other detail) ->
      check bool "names the nested key" true
        (String_util.string_contains_substring ~needle:{|repeats object key "id"|}
           detail)
  | Ok ts -> failf "expected a rejection, got ts %S" ts
  | Error err ->
      failf "expected Other, got %s" (Format.asprintf "%a" R.pp_error err)

let test_parse_post_response_non2xx_is_http_status () =
  let body = {|{"ok":true,"ts":"171.42"}|} in
  match R.parse_post_response ~status:500 ~body with
  | Error (R.Http_status { code = 500; body = got }) ->
      check string "body" body got
  | Ok _ -> fail "expected Http_status for non-2xx"
  | Error err ->
      failf "expected Http_status, got %s" (Format.asprintf "%a" R.pp_error err)

let test_parse_post_response_2xx_non_json_is_other () =
  match R.parse_post_response ~status:200 ~body:"<html>oops</html>" with
  | Error (R.Other _) -> ()
  | Ok _ -> fail "expected Other for non-JSON"
  | Error err ->
      failf "expected Other, got %s" (Format.asprintf "%a" R.pp_error err)

let test_build_update_request_body () =
  let url, headers, body =
    R.build_update_request ~token:"xoxb-secret" ~channel_id:"C123"
      ~ts:"171.42" ~text:"updated **bold**" ()
  in
  check string "url" "https://slack.com/api/chat.update" url;
  check string "Authorization" "Bearer xoxb-secret"
    (header_value headers "Authorization");
  let fields = assoc_fields body in
  check string "channel" "C123" (field_string fields "channel");
  check string "ts" "171.42" (field_string fields "ts");
  check string "markdown preserved" "updated **bold**"
    (field_string fields "markdown_text");
  check_field_absent fields "text";
  check_field_absent fields "blocks"

let test_parse_update_response_2xx_ok () =
  match R.parse_update_response ~status:200 ~body:{|{"ok":true}|} with
  | Ok () -> ()
  | Error err -> failf "expected Ok, got %s" (Format.asprintf "%a" R.pp_error err)

let test_parse_update_response_slack_error () =
  match
    R.parse_update_response ~status:200
      ~body:{|{"ok":false,"error":"message_not_found"}|}
  with
  | Error (R.Slack_api { error = "message_not_found" }) -> ()
  | Ok _ -> fail "expected Slack_api error"
  | Error err ->
      failf "expected Slack_api message_not_found, got %s"
        (Format.asprintf "%a" R.pp_error err)

let test_parse_update_response_non2xx_is_http_status () =
  let body = {|{"ok":false,"error":"ratelimited"}|} in
  match R.parse_update_response ~status:429 ~body with
  | Error (R.Http_status { code = 429; body = got }) ->
      check string "body" body got
  | Ok _ -> fail "expected Http_status for non-2xx"
  | Error err ->
      failf "expected Http_status, got %s" (Format.asprintf "%a" R.pp_error err)

let test_build_auth_test_request_url_and_headers () =
  let url, headers, body = R.build_auth_test_request ~token:"xoxb-secret" in
  check string "url" "https://slack.com/api/auth.test" url;
  check string "Authorization" "Bearer xoxb-secret"
    (header_value headers "Authorization");
  check string "empty body" "" body

let test_parse_auth_test_response_ok_returns_identity () =
  match
    R.parse_auth_test_response ~status:200
      ~body:{|{"ok":true,"user_id":"U123","team_id":"T999"}|}
  with
  | Ok { R.user_id; team_id } ->
      check string "user_id" "U123" user_id;
      check (option string) "team_id" (Some "T999") team_id
  | Error err ->
      failf "expected Ok identity, got %s" (Format.asprintf "%a" R.pp_error err)

let test_parse_auth_test_response_ok_without_team () =
  match
    R.parse_auth_test_response ~status:200 ~body:{|{"ok":true,"user_id":"U123"}|}
  with
  | Ok { R.user_id; team_id } ->
      check string "user_id" "U123" user_id;
      check (option string) "team_id absent" None team_id
  | Error err ->
      failf "unexpected error: %s" (Format.asprintf "%a" R.pp_error err)

let test_parse_auth_test_response_slack_error () =
  match
    R.parse_auth_test_response ~status:200
      ~body:{|{"ok":false,"error":"invalid_auth"}|}
  with
  | Error (R.Slack_api { error = "invalid_auth" }) -> ()
  | Ok _ -> fail "expected Slack_api error"
  | Error err ->
      failf "expected invalid_auth, got %s" (Format.asprintf "%a" R.pp_error err)

let test_parse_auth_test_response_ok_missing_user_id_is_other () =
  match R.parse_auth_test_response ~status:200 ~body:{|{"ok":true}|} with
  | Error (R.Other _) -> ()
  | Ok ok -> failf "expected Other, got Ok user_id=%s" ok.R.user_id
  | Error err ->
      failf "expected Other, got %s" (Format.asprintf "%a" R.pp_error err)

let test_build_users_info_request_shape () =
  let url, headers, body =
    R.build_users_info_request ~token:"xoxb-secret" ~user_id:"U09L0RHPW7P"
  in
  check string "url" "https://slack.com/api/users.info" url;
  check string "Authorization" "Bearer xoxb-secret"
    (header_value headers "Authorization");
  check string "Content-Type"
    "application/x-www-form-urlencoded; charset=utf-8"
    (header_value headers "Content-Type");
  check string "body" "user=U09L0RHPW7P" body

let test_parse_users_info_ok_extracts_names () =
  let body =
    {|{"ok":true,"user":{"id":"U1","name":"vincent",
       "profile":{"display_name":"Vincent","real_name":"윤정식"}}}|}
  in
  match R.parse_users_info_response ~status:200 ~body with
  | Ok { user_id; name; real_name; display_name } ->
      check string "id" "U1" user_id;
      check (option string) "name" (Some "vincent") name;
      check (option string) "real_name" (Some "윤정식") real_name;
      check (option string) "display_name" (Some "Vincent") display_name
  | Error e -> failf "unexpected error: %a" R.pp_error e

let test_parse_users_info_blank_names_are_absent () =
  let body =
    {|{"ok":true,"user":{"id":"U1","name":"  ",
       "profile":{"display_name":"","real_name":"Real"}}}|}
  in
  match R.parse_users_info_response ~status:200 ~body with
  | Ok { name; real_name; display_name; _ } ->
      check (option string) "blank name absent" None name;
      check (option string) "blank display_name absent" None display_name;
      check (option string) "real_name kept" (Some "Real") real_name
  | Error e -> failf "unexpected error: %a" R.pp_error e

let test_parse_users_info_failures_are_typed () =
  (match
     R.parse_users_info_response ~status:200
       ~body:{|{"ok":false,"error":"missing_scope"}|}
   with
  | Error (R.Slack_api { error }) -> check string "error" "missing_scope" error
  | Ok _ | Error _ -> fail "ok=false must be Slack_api");
  (match R.parse_users_info_response ~status:429 ~body:"rate limited" with
  | Error (R.Http_status { code; _ }) -> check int "status" 429 code
  | Ok _ | Error _ -> fail "non-2xx must be Http_status");
  match
    R.parse_users_info_response ~status:200 ~body:{|{"ok":true,"user":{}}|}
  with
  | Error (R.Other _) -> ()
  | Ok _ | Error _ -> fail "missing user.id must be Other"

let () =
  run "Slack_rest_client"
    [
      ( "build_post_message_request",
        [
          test_case "url and headers" `Quick
            test_build_post_message_request_url_and_headers;
          test_case "body with thread" `Quick
            test_build_post_message_request_body_with_thread;
        ] );
      ( "parse_post_response",
        [
          test_case "2xx ok returns ts" `Quick
            test_parse_post_response_2xx_ok_returns_ts;
          test_case "2xx ok=false is Slack_api" `Quick
            test_parse_post_response_slack_error;
          test_case "repeated key is rejected" `Quick
            test_parse_post_response_repeated_key_is_rejected;
          test_case "nested repeated key is rejected" `Quick
            test_parse_post_response_repeated_key_nested_is_rejected;
          test_case "non-2xx is Http_status" `Quick
            test_parse_post_response_non2xx_is_http_status;
          test_case "2xx non-json is Other" `Quick
            test_parse_post_response_2xx_non_json_is_other;
        ] );
      ( "build_update_request",
        [ test_case "body" `Quick test_build_update_request_body ] );
      ( "parse_update_response",
        [
          test_case "2xx ok" `Quick test_parse_update_response_2xx_ok;
          test_case "2xx ok=false is Slack_api" `Quick
            test_parse_update_response_slack_error;
          test_case "non-2xx is Http_status" `Quick
            test_parse_update_response_non2xx_is_http_status;
        ] );
      ( "auth_test",
        [
          test_case "request url and headers" `Quick
            test_build_auth_test_request_url_and_headers;
          test_case "ok returns identity" `Quick
            test_parse_auth_test_response_ok_returns_identity;
          test_case "ok without team_id" `Quick
            test_parse_auth_test_response_ok_without_team;
          test_case "ok=false is Slack_api" `Quick
            test_parse_auth_test_response_slack_error;
          test_case "ok missing user_id is Other" `Quick
            test_parse_auth_test_response_ok_missing_user_id_is_other;
        ] );
      ( "users_info",
        [
          test_case "request shape" `Quick test_build_users_info_request_shape;
          test_case "ok extracts names" `Quick
            test_parse_users_info_ok_extracts_names;
          test_case "blank names are absent" `Quick
            test_parse_users_info_blank_names_are_absent;
          test_case "failures are typed" `Quick
            test_parse_users_info_failures_are_typed;
        ] );
    ]
