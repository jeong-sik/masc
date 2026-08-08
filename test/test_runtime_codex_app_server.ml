open Alcotest

let init_result =
  {|{"id":1,"result":{"userAgent":"fixture/0.147.0","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux"}}|}
;;

let account_chatgpt =
  {|{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.test","planType":"pro"},"requiresOpenaiAuth":true}}|}
;;

let thread_result =
  {|{"id":3,"result":{"thread":{"id":"thread-1"},"model":"gpt-fixture"}}|}
;;

let turn_result = {|{"id":4,"result":{"turn":{"id":"turn-1"}}}|}

let item_completed =
  {|{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":1,"item":{"type":"agentMessage","id":"message-1","text":"MASC_SUBSCRIPTION_OK","phase":"final_answer"}}}|}
;;

let turn_completed =
  {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[{"type":"agentMessage","id":"message-1","text":"MASC_SUBSCRIPTION_OK","phase":"final_answer"}],"status":"completed"}}}|}
;;

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let rec drop count values =
  if count <= 0
  then values
  else
    match values with
    | [] -> []
    | _ :: rest -> drop (count - 1) rest
;;

let fixture_script lines =
  let path = Filename.temp_file "masc-codex-app-server-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output "IFS= read -r ignored\n";
  output_string output ("printf '%s\\n' " ^ shell_quote (List.nth lines 0) ^ "\n");
  output_string output "IFS= read -r ignored\n";
  output_string output "IFS= read -r ignored\n";
  output_string output ("printf '%s\\n' " ^ shell_quote (List.nth lines 1) ^ "\n");
  output_string output "IFS= read -r ignored\n";
  output_string output ("printf '%s\\n' " ^ shell_quote (List.nth lines 2) ^ "\n");
  output_string output "IFS= read -r ignored\n";
  List.iter
    (fun line -> output_string output ("printf '%s\\n' " ^ shell_quote line ^ "\n"))
    (drop 3 lines);
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let with_fixture lines f =
  let path = fixture_script lines in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let run_fixture path =
  Eio_main.run (fun env ->
    let config =
      { (Runtime_codex_app_server.default_config ~cwd:"/tmp") with
        cli_path = path
      ; timeout_s = 2.0
      }
    in
    Runtime_codex_app_server.run_turn
      ~mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env)
      config
      ~prompt:"Return the fixture marker")
;;

let test_chatgpt_subscription_turn () =
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; item_completed; turn_completed ]
    (fun path ->
      match run_fixture path with
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok result ->
        check string "text" "MASC_SUBSCRIPTION_OK" result.text;
        check string "thread" "thread-1" result.thread_id;
        check string "turn" "turn-1" result.turn_id;
        check string "model" "gpt-fixture" result.model;
        check string "plan" "pro" result.subscription.plan_type)
;;

let test_api_key_account_is_rejected () =
  let api_key_account =
    {|{"id":2,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}|}
  in
  with_fixture
    [ init_result; api_key_account; thread_result; turn_result; item_completed; turn_completed ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Subscription_required _) -> ()
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "API-key account incorrectly admitted as subscription")
;;

let test_malformed_json_fails_closed () =
  with_fixture
    [ "not-json"; account_chatgpt; thread_result; turn_result; item_completed; turn_completed ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Protocol_error _) -> ()
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "malformed JSON incorrectly admitted")
;;

let test_server_request_fails_closed () =
  let request =
    {|{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; request ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Unsupported_server_request method_) ->
        check string
          "method"
          "item/commandExecution/requestApproval"
          method_
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "unsupported server request incorrectly admitted")
;;

let test_failed_turn_is_not_completion () =
  let failed =
    {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"fixture failure"}}}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; failed ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Turn_failed "fixture failure") -> ()
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "failed turn incorrectly reported as completed")
;;

let test_live_chatgpt_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let result =
      Eio_main.run (fun env ->
        let config =
          { (Runtime_codex_app_server.default_config ~cwd:"/tmp") with
            timeout_s = 60.0
          }
        in
        Runtime_codex_app_server.run_turn
          ~mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env)
          config
          ~prompt:"Reply with exactly MASC_SUBSCRIPTION_OK and do not use tools.")
    in
    match result with
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    | Ok result ->
      check string "live response" "MASC_SUBSCRIPTION_OK" result.text;
      check bool "subscription plan is present" true
        (String.trim result.subscription.plan_type <> "")
;;

let () =
  run "runtime codex app-server"
    [ ( "subscription boundary"
      , [ test_case "ChatGPT turn completes" `Quick test_chatgpt_subscription_turn
        ; test_case "API key is rejected" `Quick test_api_key_account_is_rejected
        ; test_case "malformed JSON fails closed" `Quick test_malformed_json_fails_closed
        ; test_case "server request fails closed" `Quick test_server_request_fails_closed
        ; test_case "failed turn stays failed" `Quick test_failed_turn_is_not_completion
        ] )
    ; ( "live subscription"
      , [ test_case
            "official Codex app-server"
            `Slow
            test_live_chatgpt_subscription
        ] )
    ]
;;
