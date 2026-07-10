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
    (String.length (header_value headers "User-Agent") > 0)

let test_build_post_message_request_body_with_thread () =
  let _, _, body =
    R.build_post_message_request ~token:"t" ~channel_id:"C123"
      ~text:"hello \"world\"" ~thread_ts:"1710000000.123456" ()
  in
  let fields = assoc_fields body in
  check string "channel" "C123" (field_string fields "channel");
  check string "text" "hello \"world\"" (field_string fields "text");
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
      ~ts:"171.42" ~text:"updated" ()
  in
  check string "url" "https://slack.com/api/chat.update" url;
  check string "Authorization" "Bearer xoxb-secret"
    (header_value headers "Authorization");
  let fields = assoc_fields body in
  check string "channel" "C123" (field_string fields "channel");
  check string "ts" "171.42" (field_string fields "ts");
  check string "text" "updated" (field_string fields "text")

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
    ]
