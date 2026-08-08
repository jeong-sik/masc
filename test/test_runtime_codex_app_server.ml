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

let run_fixture ?(dynamic_tools = []) ?(history = []) path =
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
      ~dynamic_tools
      ~history
      config
      ~prompt:"Return the fixture marker")
;;

let tool_call_request =
  {|{"id":"tool-request-1","method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","tool":"masc_probe","namespace":null,"arguments":{"marker":"from-codex"}}}|}
;;

let test_dynamic_tool_callback () =
  let call_id = ref None in
  let arguments = ref `Null in
  let tool : Runtime_codex_app_server.dynamic_tool =
    { name = "masc_probe"
    ; description = "Return a deterministic fixture marker"
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "marker", `Assoc [ "type", `String "string" ] ]
          ; "required", `List [ `String "marker" ]
          ]
    ; call =
        (fun ~call_id:id input ->
          call_id := Some id;
          arguments := input;
          { success = true; content = "MASC_TOOL_RESULT" })
    }
  in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; tool_call_request
    ; item_completed
    ; turn_completed
    ]
    (fun path ->
       match run_fixture ~dynamic_tools:[ tool ] path with
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok result ->
         check int "measured tool calls" 1 result.dynamic_tool_calls;
         check (option string) "call id" (Some "call-1") !call_id;
         check string
           "arguments"
           {|{"marker":"from-codex"}|}
           (Yojson.Safe.to_string !arguments))
;;

let test_history_is_injected_before_turn () =
  let injected = {|{"id":4,"result":{}}|} in
  let turn_after_injection = {|{"id":5,"result":{"turn":{"id":"turn-1"}}}|} in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; injected
    ; turn_after_injection
    ; item_completed
    ; turn_completed
    ]
    (fun path ->
       let history =
         [ { Runtime_codex_app_server.role = User; text = "previous user" }
         ; { Runtime_codex_app_server.role = Assistant; text = "previous assistant" }
         ]
       in
       match run_fixture ~history path with
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok result -> check string "text" "MASC_SUBSCRIPTION_OK" result.text)
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

let test_notification_without_params_fails_closed () =
  let missing_params = {|{"method":"item/completed"}|} in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; missing_params ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Protocol_error _) -> ()
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "notification without params incorrectly admitted")
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

let test_live_dynamic_tool_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let tool_calls = ref 0 in
    let tool : Runtime_codex_app_server.dynamic_tool =
      { name = "masc_probe"
      ; description = "Return the exact marker MASC_TOOL_RESULT"
      ; input_schema =
          `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
      ; call =
          (fun ~call_id:_ _ ->
            incr tool_calls;
            { success = true; content = "MASC_TOOL_RESULT" })
      }
    in
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
          ~dynamic_tools:[ tool ]
          config
          ~prompt:
            "Call masc_probe exactly once, then reply with exactly MASC_TOOL_OK.")
    in
    match result with
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    | Ok result ->
      check int "live dynamic tool calls" 1 !tool_calls;
      check int "live measured tool calls" 1 result.dynamic_tool_calls;
      check string "live tool response" "MASC_TOOL_OK" result.text
;;

let test_live_history_injection_subscription () =
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
          ~history:
            [ { role = User; text = "The continuity marker is MASC_HISTORY_OK." }
            ; { role = Assistant; text = "I will retain that marker." }
            ]
          config
          ~prompt:"Reply with exactly the continuity marker from the prior history.")
    in
    match result with
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    | Ok result -> check string "live history response" "MASC_HISTORY_OK" result.text
;;

let () =
  run "runtime codex app-server"
    [ ( "subscription boundary"
      , [ test_case "ChatGPT turn completes" `Quick test_chatgpt_subscription_turn
        ; test_case "API key is rejected" `Quick test_api_key_account_is_rejected
        ; test_case "malformed JSON fails closed" `Quick test_malformed_json_fails_closed
        ; test_case
            "notification without params fails closed"
            `Quick
            test_notification_without_params_fails_closed
        ; test_case "server request fails closed" `Quick test_server_request_fails_closed
        ; test_case "failed turn stays failed" `Quick test_failed_turn_is_not_completion
        ; test_case "dynamic tool callback" `Quick test_dynamic_tool_callback
        ; test_case "history injects before turn" `Quick test_history_is_injected_before_turn
        ] )
    ; ( "live subscription"
      , [ test_case
            "official Codex app-server"
            `Slow
            test_live_chatgpt_subscription
        ; test_case
            "official Codex dynamic tool"
            `Slow
            test_live_dynamic_tool_subscription
        ; test_case
            "official Codex history injection"
            `Slow
            test_live_history_injection_subscription
        ] )
    ]
;;
