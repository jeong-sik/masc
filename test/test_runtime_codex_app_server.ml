open Alcotest
open Masc

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

let test_duplicate_object_keys_fail_closed () =
  let assert_protocol_error label lines =
    with_fixture lines (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Protocol_error _) -> ()
      | Error error -> fail (label ^ ": " ^ Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail (label ^ ": duplicate key incorrectly admitted"))
  in
  assert_protocol_error
    "top-level"
    [ {|{"id":1,"id":1,"result":{"userAgent":"fixture/0.147.0","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux"}}|}
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; item_completed
    ; turn_completed
    ];
  assert_protocol_error
    "nested"
    [ init_result
    ; {|{"id":2,"result":{"account":{"type":"chatgpt","type":"apiKey","email":"fixture@example.test","planType":"pro"},"requiresOpenaiAuth":true}}|}
    ; thread_result
    ; turn_result
    ; item_completed
    ; turn_completed
    ]
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

let test_retry_notifications_are_bounded () =
  let retry = {|{"method":"error","params":{"willRetry":true}}|} in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; retry
    ; retry
    ; retry
    ; retry
    ]
    (fun path ->
       match run_fixture path with
       | Error
           (Runtime_codex_app_server.Turn_failed
             "app-server retry notification limit exceeded") -> ()
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok _ -> fail "retry notifications were unbounded")
;;

let test_unknown_notifications_are_bounded () =
  let unknown = {|{"method":"fixture/unknown","params":{}}|} in
  let lines =
    [ init_result; account_chatgpt; thread_result; turn_result ]
    @ List.init 129 (fun _ -> unknown)
  in
  with_fixture lines (fun path ->
    match run_fixture path with
    | Error (Runtime_codex_app_server.Protocol_error _) -> ()
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    | Ok _ -> fail "unknown notifications were unbounded")
;;

let codex_runtime_toml ~model cli_path =
  Printf.sprintf
    "[providers.codex]\n\
     protocol = \"codex-app-server\"\n\
     command = %S\n\
     is-non-interactive = true\n\
     \n\
     [models.codex]\n\
     api-name = %S\n\
     max-context = 400000\n\
     \n\
     [codex.codex]\n\
     \n\
     [runtime]\n\
     default = \"codex.codex\"\n"
    cli_path
    model
;;

let with_runtime_config ~model cli_path f =
  let path = Filename.temp_file "masc-codex-runtime-" ".toml" in
  let output = open_out_bin path in
  output_string output (codex_runtime_toml ~model cli_path);
  close_out output;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let keeper_response_text (result : Runtime_agent.run_result) =
  result.response.content
  |> List.filter_map (function Agent_sdk.Types.Text text -> Some text | _ -> None)
  |> String.concat ""
;;

let temp_workspace prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let cleanup_tree root =
  let rec remove path =
    if Sys.file_exists path
    then if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove root with
  | _ -> ()
;;

let production_keeper_meta ~base_path =
  let name = "codex-production-fixture" in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "agent_name", `String (Keeper_identity.keeper_agent_name name)
         ; "trace_id", `String "codex-production-fixture-trace"
         ; "allowed_paths", `List [ `String base_path ]
         ])
  with
  | Ok meta -> meta
  | Error detail -> fail ("production Keeper meta fixture failed: " ^ detail)
;;

let run_production_keeper_turn ~cli_path ~model =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_runtime_config ~model cli_path (fun runtime_path ->
         let base_path = temp_workspace "masc-codex-production-" in
         Fun.protect
           ~finally:(fun () -> cleanup_tree base_path)
           (fun () ->
              Eio_main.run (fun env ->
                Eio.Switch.run (fun sw ->
                  Fs_compat.set_fs (Eio.Stdenv.fs env);
                  Eio_context.set_env env;
                  Eio_context.with_test_env
                    ~net:(Eio.Stdenv.net env)
                    ~clock:(Eio.Stdenv.clock env)
                    ~mono_clock:(Eio.Stdenv.mono_clock env)
                    ~sw
                    (fun () ->
                       match Runtime.init_default ~config_path:runtime_path with
                       | Error error -> fail error
                       | Ok () ->
                         let config = Workspace.default_config base_path in
                         let meta = production_keeper_meta ~base_path in
                         ignore
                           (Keeper_registry.For_testing.register
                              ~base_path
                              meta.name
                              meta);
                         Eio.Switch.on_release sw (fun () ->
                           Keeper_registry.For_testing.unregister
                             ~base_path
                             meta.name);
                         Masc_test_deps.with_publication_recovery_registry
                           ~sw
                           ~fs:(Eio.Stdenv.fs env)
                           ~registry_root:base_path
                           (fun publication_recovery_registry ->
                              let publication_recovery =
                                { Keeper_publication_recovery_availability.provider =
                                    Masc_test_deps.publication_recovery_provider
                                      publication_recovery_registry
                                ; keeper_name = meta.name
                                }
                              in
                              Keeper_agent_run.run_turn
                                ~config
                                ~meta
                                ~publication_recovery
                                ~profile_defaults:
                                  Keeper_types_profile_defaults.empty_keeper_profile_defaults
                                ~turn_ctx_cell:
                                  (Keeper_tool_call_log.create_turn_ctx_cell ())
                                ~base_dir:(Filename.concat base_path "keeper-sessions")
                                ~max_context:400_000
                                ~build_turn_prompt:
                                  (fun ~base_system_prompt ~messages:_ ->
                                    { Keeper_agent_run.system_prompt = base_system_prompt
                                    ; dynamic_context = ""
                                    })
                                ~user_message:
                                  "Reply with exactly MASC_SUBSCRIPTION_OK and do not use tools."
                                ~turn_kind:Turn_record.Direct
                                ~runtime_id:"codex.codex"
                                ~generation:1
                                ())))))))
;;

let run_keeper_turn ?(tools = []) ?hooks ?context_injector ?model_input_projection
    ?(goal = "Reply with exactly MASC_SUBSCRIPTION_OK and do not use tools.")
    ~cli_path ~model () =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_runtime_config ~model cli_path (fun runtime_path ->
         Eio_main.run (fun env ->
           Eio.Switch.run (fun sw ->
             Eio_context.set_env env;
             Eio_context.with_test_env
               ~net:(Eio.Stdenv.net env)
               ~clock:(Eio.Stdenv.clock env)
               ~mono_clock:(Eio.Stdenv.mono_clock env)
               ~sw
               (fun () ->
                  match Runtime.init_default ~config_path:runtime_path with
                  | Error error -> fail error
                  | Ok () ->
                    let context =
                      match tools with
                      | [] -> None
                      | _ :: _ -> Some (Agent_sdk.Context.create ())
                    in
                    Keeper_turn_driver.run_named
                      ~runtime_id:"codex.codex"
                      ~keeper_name:"codex-fixture"
                      ~base_path:"/tmp"
                      ~goal
                      ~tools
                      ~initial_messages:[]
                      ?model_input_projection
                      ?hooks
                      ?context_injector
                      ?context
                      ~sw
                      ~net:(Eio.Stdenv.net env)
                      ())))))
;;

let test_keeper_dispatches_codex_turn_runtime () =
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; item_completed; turn_completed ]
    (fun cli_path ->
       match run_keeper_turn ~cli_path ~model:"gpt-fixture" () with
       | Error error -> fail (Agent_sdk.Error.to_string error)
       | Ok result ->
         check string "Keeper response" "MASC_SUBSCRIPTION_OK" (keeper_response_text result);
         check bool "measured observation" true (Option.is_some result.runtime_observation))
;;

let assert_production_keeper_result result =
  check string
    "production Keeper response"
    "MASC_SUBSCRIPTION_OK"
    result.Keeper_agent_run.response_text;
  check int "production Keeper turn count" 1 result.turn_count;
  check int "production after-turn ordinal" 1 result.final_oas_turn_ordinal;
  check bool "production measured observation" true
    (Option.is_some result.runtime_observation);
  check bool "official client does not fabricate OAS checkpoint" true
    (Option.is_none result.checkpoint)
;;

let test_production_keeper_dispatches_codex_runtime () =
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; item_completed
    ; turn_completed
    ]
    (fun cli_path ->
       match run_production_keeper_turn ~cli_path ~model:"gpt-fixture" with
       | Error error -> fail (Agent_sdk.Error.to_string error)
       | Ok result -> assert_production_keeper_result result)
;;

let test_keeper_projects_typed_tools_and_hooks () =
  let tool_calls = ref 0 in
  let before_turn_calls = ref 0 in
  let before_params_calls = ref 0 in
  let pre_tool_calls = ref 0 in
  let post_tool_calls = ref 0 in
  let after_turn_calls = ref 0 in
  let on_stop_calls = ref 0 in
  let projection_saw_context = ref false in
  let injector_calls = ref 0 in
  let tool =
    Agent_sdk.Tool.create
      ~name:"masc_probe"
      ~description:"Return a deterministic Keeper fixture marker"
      ~parameters:
        [ { Agent_sdk.Types.name = "marker"
          ; description = "Fixture marker"
          ; param_type = String
          ; required = true
          }
        ]
      (fun input ->
        incr tool_calls;
        check string
          "typed tool input"
          "from-codex"
          Yojson.Safe.Util.(input |> member "marker" |> to_string);
        Ok { Agent_sdk.Types.content = "MASC_TOOL_RESULT"; _meta = None })
  in
  let hooks : Agent_sdk.Hooks.hooks =
    { Agent_sdk.Hooks.empty with
      before_turn =
        Some
          (fun _ ->
            incr before_turn_calls;
            Continue)
    ; before_turn_params =
        Some
          (function
            | BeforeTurnParams { current_params; _ } ->
              incr before_params_calls;
              AdjustParams
                { current_params with extra_system_context = Some "fixture-context" }
            | _ -> Continue)
    ; pre_tool_use =
        Some
          (fun _ ->
            incr pre_tool_calls;
            Continue)
    ; post_tool_use =
        Some
          (fun _ ->
            incr post_tool_calls;
            Continue)
    ; after_turn =
        Some
          (fun _ ->
            incr after_turn_calls;
            Continue)
    ; on_stop =
        Some
          (fun _ ->
            incr on_stop_calls;
            Continue)
    }
  in
  let model_input_projection messages =
    projection_saw_context :=
      List.exists
        (fun (message : Agent_sdk.Types.message) ->
          message.role = System
          && String.equal
               "fixture-context"
               (Agent_sdk.Types.text_of_content message.content))
        messages;
    Ok messages
  in
  let context_injector ~tool_name:_ ~input:_ ~output:_ =
    incr injector_calls;
    Some
      { Agent_sdk.Hooks.context_updates = [ "fixture_tool_seen", `Bool true ]
      ; extra_messages = []
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
    (fun cli_path ->
       match
         run_keeper_turn
           ~tools:[ tool ]
           ~hooks
           ~context_injector
           ~model_input_projection
           ~cli_path
           ~model:"gpt-fixture"
           ()
       with
       | Error error -> fail (Agent_sdk.Error.to_string error)
       | Ok result ->
         check string "Keeper response" "MASC_SUBSCRIPTION_OK" (keeper_response_text result);
         List.iter
           (fun (label, expected, actual) -> check int label expected !actual)
           [ "tool handler", 1, tool_calls
           ; "before turn hook", 1, before_turn_calls
           ; "before params hook", 1, before_params_calls
           ; "pre tool hook", 1, pre_tool_calls
           ; "post tool hook", 1, post_tool_calls
           ; "after turn hook", 1, after_turn_calls
           ; "on stop hook", 1, on_stop_calls
           ; "context injector", 1, injector_calls
           ];
         check bool "projection saw hook context" true !projection_saw_context)
;;

let test_keeper_rejects_unprojected_turn_parameters () =
  let hooks : Agent_sdk.Hooks.hooks =
    { Agent_sdk.Hooks.empty with
      before_turn_params =
        Some
          (function
            | BeforeTurnParams { current_params; _ } ->
              AdjustParams { current_params with temperature = Some 0.2 }
            | _ -> Continue)
    }
  in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; item_completed
    ; turn_completed
    ]
    (fun cli_path ->
       match run_keeper_turn ~hooks ~cli_path ~model:"gpt-fixture" () with
       | Error
           (Agent_sdk.Error.Config
             (Agent_sdk.Error.InvalidConfig { field; detail = _ })) ->
         check string "rejected parameter" "temperature" field
       | Error error -> fail (Agent_sdk.Error.to_string error)
       | Ok _ -> fail "unprojected temperature was silently ignored")
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

let test_live_keeper_chatgpt_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    match run_keeper_turn ~cli_path:"codex" ~model:"gpt-5.6-sol" () with
    | Error error -> fail (Agent_sdk.Error.to_string error)
    | Ok result ->
      check string "live Keeper response" "MASC_SUBSCRIPTION_OK" (keeper_response_text result)
;;

let test_live_keeper_dynamic_tool_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let tool_calls = ref 0 in
    let tool =
      Agent_sdk.Tool.create
        ~name:"masc_probe"
        ~description:"Return the exact marker MASC_TOOL_RESULT"
        ~parameters:[]
        (fun _ ->
          incr tool_calls;
          Ok { Agent_sdk.Types.content = "MASC_TOOL_RESULT"; _meta = None })
    in
    match
      run_keeper_turn
        ~tools:[ tool ]
        ~goal:
          "Call the dynamic tool masc_probe exactly once. After it returns, reply with exactly MASC_TOOL_OK and no other text."
        ~cli_path:"codex"
        ~model:"gpt-5.6-sol"
        ()
    with
    | Error error -> fail (Agent_sdk.Error.to_string error)
    | Ok result ->
      check int "live typed tool calls" 1 !tool_calls;
      check string "live tool Keeper response" "MASC_TOOL_OK" (keeper_response_text result)
;;

let test_live_production_keeper_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    match run_production_keeper_turn ~cli_path:"codex" ~model:"gpt-5.6-sol" with
    | Error error -> fail (Agent_sdk.Error.to_string error)
    | Ok result -> assert_production_keeper_result result
;;

let () =
  run "runtime codex app-server"
    [ ( "subscription boundary"
      , [ test_case "ChatGPT turn completes" `Quick test_chatgpt_subscription_turn
        ; test_case "API key is rejected" `Quick test_api_key_account_is_rejected
        ; test_case "malformed JSON fails closed" `Quick test_malformed_json_fails_closed
        ; test_case
            "duplicate object keys fail closed"
            `Quick
            test_duplicate_object_keys_fail_closed
        ; test_case
            "notification without params fails closed"
            `Quick
            test_notification_without_params_fails_closed
        ; test_case "server request fails closed" `Quick test_server_request_fails_closed
        ; test_case "failed turn stays failed" `Quick test_failed_turn_is_not_completion
        ; test_case
            "retry notifications are bounded"
            `Quick
            test_retry_notifications_are_bounded
        ; test_case
            "unknown notifications are bounded"
            `Quick
            test_unknown_notifications_are_bounded
        ; test_case "dynamic tool callback" `Quick test_dynamic_tool_callback
        ; test_case "history injects before turn" `Quick test_history_is_injected_before_turn
        ; test_case
            "Keeper dispatches Codex runtime"
            `Quick
            test_keeper_dispatches_codex_turn_runtime
        ; test_case
            "production Keeper dispatches Codex runtime"
            `Quick
            test_production_keeper_dispatches_codex_runtime
        ; test_case
            "Keeper projects typed tools and hooks"
            `Quick
            test_keeper_projects_typed_tools_and_hooks
        ; test_case
            "Keeper rejects unprojected turn parameters"
            `Quick
            test_keeper_rejects_unprojected_turn_parameters
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
        ; test_case
            "Keeper through official Codex app-server"
            `Slow
            test_live_keeper_chatgpt_subscription
        ; test_case
            "Keeper typed tool through official Codex app-server"
            `Slow
            test_live_keeper_dynamic_tool_subscription
        ; test_case
            "production Keeper through official Codex app-server"
            `Slow
            test_live_production_keeper_subscription
        ] )
    ]
;;
