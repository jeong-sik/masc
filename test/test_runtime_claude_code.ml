open Alcotest
open Masc

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let auth_subscription =
  {|{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team","apiProvider":"firstParty"}|}
;;

let assistant =
  {|{"type":"assistant","session_id":"__SESSION__","uuid":"assistant-fixture-1","message":{"role":"assistant","model":"claude-fixture","content":[{"type":"text","text":"MASC_CLAUDE_OK"}]}}|}
;;

let result =
  {|{"type":"result","subtype":"success","is_error":false,"session_id":"__SESSION__","uuid":"turn-fixture-1","result":"MASC_CLAUDE_OK","api_error_status":null}|}
;;

type fixture_step =
  | Emit of string
  | Emit_and_read of string
  | Emit_and_expect_request_id of string * string

let fixture_script ?(auth_json = auth_subscription) steps =
  let path = Filename.temp_file "masc-claude-code-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output "set -eu\n";
  List.iter
    (fun name ->
       output_string output
         (Printf.sprintf "[ \"${%s+x}\" != x ] || exit 90\n" name))
    [ "ANTHROPIC_API_KEY"
    ; "ANTHROPIC_AUTH_TOKEN"
    ; "ANTHROPIC_API_URL"
    ; "ANTHROPIC_BASE_URL"
    ; "ANTHROPIC_BEDROCK_BASE_URL"
    ; "ANTHROPIC_VERTEX_BASE_URL"
    ; "ANTHROPIC_VERTEX_PROJECT_ID"
    ; "CLAUDE_CODE_OAUTH_TOKEN"
    ; "CLAUDE_CODE_SKIP_BEDROCK_AUTH"
    ; "CLAUDE_CODE_SKIP_VERTEX_AUTH"
    ; "CLAUDE_CODE_USE_BEDROCK"
    ; "CLAUDE_CODE_USE_VERTEX"
    ; "CLOUD_ML_REGION"
    ; "MASC_CLAUDE_SECRET_CANARY"
    ];
  output_string output "[ -n \"${HOME-}\" ] || exit 91\n";
  output_string output
    "[ \"${CLAUDE_CODE_ENTRYPOINT-}\" = masc ] || exit 92\n";
  output_string output
    "[ \"${CLAUDE_AGENT_SDK_VERSION-}\" = masc-ocaml ] || exit 93\n";
  output_string output "if [ \"${1-}\" = auth ]; then\n";
  output_string output
    ("  printf '%s\\n' " ^ shell_quote auth_json ^ "\n");
  output_string output "  exit 0\n";
  output_string output "fi\n";
  output_string output "session=''\n";
  output_string output "for arg in \"$@\"; do\n";
  output_string output "  case \"$arg\" in\n";
  output_string output "    --session-id=*) session=${arg#--session-id=} ;;\n";
  output_string output "    --resume=*) session=${arg#--resume=} ;;\n";
  output_string output "  esac\n";
  output_string output "done\n";
  output_string output "[ -n \"$session\" ] || exit 94\n";
  output_string output "emit() { printf '%s\\n' \"$1\" | sed \"s/__SESSION__/$session/g\"; }\n";
  output_string output "IFS= read -r initialize\n";
  output_string output
    "request_id=$(printf '%s' \"$initialize\" | sed -n 's/.*\"request_id\":\"\\([^\"]*\\)\".*/\\1/p')\n";
  output_string output "[ -n \"$request_id\" ] || exit 95\n";
  output_string output
    "printf '{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"%s\",\"response\":{}}}\\n' \"$request_id\"\n";
  output_string output "IFS= read -r user_message\n";
  List.iter
    (function
      | Emit line ->
        output_string output ("emit " ^ shell_quote line ^ "\n")
      | Emit_and_read line ->
        output_string output ("emit " ^ shell_quote line ^ "\n");
        output_string output "IFS= read -r ignored_response\n"
      | Emit_and_expect_request_id (line, request_id) ->
        output_string output ("emit " ^ shell_quote line ^ "\n");
        output_string output "IFS= read -r control_response\n";
        output_string output
          (Printf.sprintf
             "printf '%%s' \"$control_response\" | grep -F '\"request_id\":\"%s\"' >/dev/null || exit 96\n"
             request_id))
    steps;
  output_string output "while IFS= read -r ignored; do :; done\n";
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let with_fixture ?auth_json steps f =
  let path = fixture_script ?auth_json steps in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let run_fixture ?(dynamic_tools = []) ?session_mode path =
  Eio_main.run (fun env ->
    let config =
      { (Runtime_claude_code.default_config ~cwd:"/tmp") with
        cli_path = path
      ; timeout_s = 2.0
      }
    in
    Runtime_claude_code.run_turn
      ~mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env)
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
      ~dynamic_tools
      ?session_mode
      config
      ~prompt:"Return the fixture marker")
;;

let test_validation_is_process_free () =
  let config =
    { (Runtime_claude_code.default_config ~cwd:"/tmp") with cli_path = "" }
  in
  match Runtime_claude_code.validate_turn config ~prompt:"fixture" with
  | Error (Runtime_claude_code.Invalid_config "cli_path must not be empty") -> ()
  | Error error -> fail (Runtime_claude_code.error_to_string error)
  | Ok () -> fail "invalid Claude Code config passed admission"
;;

let test_subscription_turn_and_env_scrub () =
  List.iter
    (fun name -> Unix.putenv name "hostile-fixture-value")
    [ "ANTHROPIC_API_KEY"
    ; "ANTHROPIC_AUTH_TOKEN"
    ; "ANTHROPIC_API_URL"
    ; "ANTHROPIC_BASE_URL"
    ; "ANTHROPIC_BEDROCK_BASE_URL"
    ; "ANTHROPIC_VERTEX_BASE_URL"
    ; "ANTHROPIC_VERTEX_PROJECT_ID"
    ; "CLAUDE_CODE_OAUTH_TOKEN"
    ; "CLAUDE_CODE_SKIP_BEDROCK_AUTH"
    ; "CLAUDE_CODE_SKIP_VERTEX_AUTH"
    ; "CLAUDE_CODE_USE_BEDROCK"
    ; "CLAUDE_CODE_USE_VERTEX"
    ; "CLOUD_ML_REGION"
    ; "MASC_CLAUDE_SECRET_CANARY"
    ];
  with_fixture [ Emit assistant; Emit result ] (fun path ->
    match run_fixture path with
    | Error error -> fail (Runtime_claude_code.error_to_string error)
    | Ok turn ->
      check string "text" "MASC_CLAUDE_OK" turn.text;
      check string "turn" "turn-fixture-1" turn.turn_id;
      check string "model" "claude-fixture" turn.model;
      check string "subscription" "team" turn.subscription.subscription_type;
      check bool "new session" false turn.resumed)
;;

let test_non_subscription_auth_is_rejected () =
  let auth_json =
    {|{"loggedIn":true,"authMethod":"apiKey","subscriptionType":"api","apiProvider":"firstParty"}|}
  in
  with_fixture ~auth_json [] (fun path ->
    match run_fixture path with
    | Error (Runtime_claude_code.Subscription_required _) -> ()
    | Error error -> fail (Runtime_claude_code.error_to_string error)
    | Ok _ -> fail "API-key Claude auth was admitted as subscription")
;;

let rate_limit_rejected =
  {|{"type":"rate_limit_event","session_id":"__SESSION__","uuid":"limit-1","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day","resetsAt":1786356000,"overageStatus":"rejected","overageDisabledReason":"org_level_disabled_until"}}|}
;;

let quota_result =
  {|{"type":"result","subtype":"success","is_error":true,"session_id":"__SESSION__","uuid":"turn-quota-1","result":"not inspected","api_error_status":429,"terminal_reason":"api_error"}|}
;;

let test_quota_is_structurally_classified () =
  with_fixture [ Emit rate_limit_rejected; Emit quota_result ] (fun path ->
    match run_fixture path with
    | Error
        (Runtime_claude_code.Quota_blocked
          { api_error_status = Some 429
          ; rate_limit = Some { status = "rejected"; _ }
          }) -> ()
    | Error error -> fail (Runtime_claude_code.error_to_string error)
    | Ok _ -> fail "typed quota rejection was reported as completion")
;;

let mcp_initialize =
  {|{"type":"control_request","request_id":"mcp-init-1","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}}}|}
;;

let mcp_list =
  {|{"type":"control_request","request_id":"mcp-list-1","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}}}|}
;;

let mcp_initialized_notification =
  {|{"type":"control_request","request_id":"mcp-notify-1","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}}}|}
;;

let mcp_list_after_notification =
  {|{"type":"control_request","request_id":"mcp-list-after-notification","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}}}|}
;;

let mcp_call =
  {|{"type":"control_request","request_id":"mcp-call-1","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","id":"call-1","method":"tools/call","params":{"name":"masc_probe","arguments":{"marker":"from-claude"}}}}}|}
;;

let test_dynamic_tool_callback () =
  let observed_call_id = ref None in
  let observed_input = ref `Null in
  let tool : Runtime_claude_code.dynamic_tool =
    { name = "masc_probe"
    ; description = "Return a fixture marker"
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "marker", `Assoc [ "type", `String "string" ] ]
          ]
    ; call =
        (fun ~call_id input ->
          observed_call_id := Some call_id;
          observed_input := input;
          { success = true; content = "MASC_TOOL_RESULT" })
    }
  in
  with_fixture
    [ Emit_and_read mcp_initialize
    ; Emit_and_read mcp_list
    ; Emit_and_read mcp_call
    ; Emit assistant
    ; Emit result
    ]
    (fun path ->
      match run_fixture ~dynamic_tools:[ tool ] path with
      | Error error -> fail (Runtime_claude_code.error_to_string error)
      | Ok turn ->
        check int "measured calls" 1 turn.dynamic_tool_calls;
        check (option string) "call id" (Some "call-1") !observed_call_id;
        check string
          "arguments"
          {|{"marker":"from-claude"}|}
          (Yojson.Safe.to_string !observed_input))
;;

let test_mcp_notification_has_no_response () =
  with_fixture
    [ Emit mcp_initialized_notification
    ; Emit_and_expect_request_id
        (mcp_list_after_notification, "mcp-list-after-notification")
    ; Emit assistant
    ; Emit result
    ]
    (fun path ->
      match run_fixture path with
      | Error error -> fail (Runtime_claude_code.error_to_string error)
      | Ok turn -> check string "text" "MASC_CLAUDE_OK" turn.text)
;;

let test_shared_mcp_bridge_owns_exact_dispatch () =
  let tool_specs () =
    [ `Assoc
        [ "name", `String "masc_probe"
        ; "description", `String "fixture"
        ; "inputSchema", `Assoc [ "type", `String "object" ]
        ]
    ]
  in
  let call_tool ~name:_ ~call_id:_ ~arguments:_ =
    fail "unknown tool dispatch reached the callback"
  in
  let dispatch json =
    Runtime_official_client_mcp.handle_message
      ~server_name:"masc"
      ~tool_specs
      ~call_tool
      json
    |> Result.get_ok
  in
  let list =
    dispatch
      (`Assoc
         [ "jsonrpc", `String "2.0"
         ; "id", `Int 1
         ; "method", `String "tools/list"
         ; "params", `Assoc []
         ])
  in
  check bool "list has response" true (Option.is_some list.response);
  check bool "list did not call a tool" false list.tool_called;
  let notification =
    dispatch
      (`Assoc
         [ "jsonrpc", `String "2.0"
         ; "method", `String "notifications/initialized"
         ; "params", `Assoc []
         ])
  in
  check (option string) "notification has no response" None
    (Option.map Yojson.Safe.to_string notification.response);
  let unknown =
    dispatch
      (`Assoc
         [ "jsonrpc", `String "2.0"
         ; "id", `String "call-unknown"
         ; "method", `String "tools/call"
         ; ( "params"
           , `Assoc
               [ "name", `String "missing"
               ; "arguments", `Assoc []
               ] )
         ])
  in
  check bool "unknown tool did not execute" false unknown.tool_called;
  let open Yojson.Safe.Util in
  check int
    "unknown tool JSON-RPC code"
    (-32602)
    (unknown.response |> Option.get |> member "error" |> member "code" |> to_int);
  (match
     Runtime_official_client_mcp.handle_message
       ~server_name:"masc"
       ~tool_specs
       ~call_tool
       (`Assoc
          [ "jsonrpc", `String "2.0"
          ; "id", `Bool true
          ; "method", `String "tools/list"
          ])
   with
   | Error { stage = "MCP message"; _ } -> ()
   | Error _ -> fail "invalid request id had the wrong error stage"
   | Ok _ -> fail "boolean JSON-RPC request id was admitted")
;;

let test_malformed_json_fails_closed () =
  with_fixture [ Emit "not-json" ] (fun path ->
    match run_fixture path with
    | Error (Runtime_claude_code.Protocol_error _) -> ()
    | Error error -> fail (Runtime_claude_code.error_to_string error)
    | Ok _ -> fail "malformed stream JSON was admitted")
;;

let test_duplicate_keys_fail_closed () =
  let duplicate =
    {|{"type":"assistant","type":"result","session_id":"__SESSION__","uuid":"duplicate-1"}|}
  in
  with_fixture [ Emit duplicate ] (fun path ->
    match run_fixture path with
    | Error (Runtime_claude_code.Protocol_error _) -> ()
    | Error error -> fail (Runtime_claude_code.error_to_string error)
    | Ok _ -> fail "duplicate stream JSON key was admitted")
;;

let test_unsupported_control_request_fails_closed () =
  let request =
    {|{"type":"control_request","request_id":"permission-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}|}
  in
  with_fixture [ Emit request ] (fun path ->
    match run_fixture path with
    | Error (Runtime_claude_code.Unsupported_control_request "can_use_tool") -> ()
    | Error error -> fail (Runtime_claude_code.error_to_string error)
    | Ok _ -> fail "unsupported permission request was admitted")
;;

let test_unknown_stream_type_fails_closed () =
  let unknown =
    {|{"type":"future_magic","session_id":"__SESSION__","uuid":"future-1"}|}
  in
  with_fixture [ Emit unknown ] (fun path ->
    match run_fixture path with
    | Error (Runtime_claude_code.Protocol_error _) -> ()
    | Error error -> fail (Runtime_claude_code.error_to_string error)
    | Ok _ -> fail "unknown stream type was silently ignored")
;;

let test_allowed_tools_tokenizer_chars_are_validated () =
  let tool : Runtime_claude_code.dynamic_tool =
    { name = "bad,tool"
    ; description = "invalid fixture"
    ; input_schema = `Assoc []
    ; call = (fun ~call_id:_ _ -> { success = true; content = "unused" })
    }
  in
  let config = Runtime_claude_code.default_config ~cwd:"/tmp" in
  match
    Runtime_claude_code.validate_turn
      ~dynamic_tools:[ tool ]
      config
      ~prompt:"fixture"
  with
  | Error (Runtime_claude_code.Invalid_config _) -> ()
  | Error error -> fail (Runtime_claude_code.error_to_string error)
  | Ok () -> fail "allowedTools delimiter was admitted in a tool name"
;;

let test_resume_preserves_session_identity () =
  with_fixture [ Emit assistant; Emit result ] (fun path ->
    match
      run_fixture
        ~session_mode:
          (Runtime_claude_code.Resume { session_id = "fixture-session-resume" })
        path
    with
    | Error error -> fail (Runtime_claude_code.error_to_string error)
    | Ok turn ->
      check string "session" "fixture-session-resume" turn.session_id;
      check bool "resumed" true turn.resumed)
;;

let test_live_subscription () =
  if Sys.getenv_opt "MASC_CLAUDE_CODE_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let outcome =
      Eio_main.run (fun env ->
        let config =
          { (Runtime_claude_code.default_config ~cwd:"/tmp") with timeout_s = 60.0 }
        in
        Runtime_claude_code.run_turn
          ~mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env)
          ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
          config
          ~prompt:"Reply with exactly MASC_CLAUDE_LIVE_OK")
    in
    match outcome with
    | Ok turn -> check string "live response" "MASC_CLAUDE_LIVE_OK" turn.text
    | Error error -> fail (Runtime_claude_code.error_to_string error)
;;

let () =
  run
    "runtime_claude_code"
    [ ( "admission"
      , [ test_case "validation is process-free" `Quick test_validation_is_process_free
        ; test_case
            "subscription auth and env scrub"
            `Quick
            test_subscription_turn_and_env_scrub
        ; test_case
            "non-subscription rejected"
            `Quick
            test_non_subscription_auth_is_rejected
        ] )
    ; ( "terminal"
      , [ test_case
            "quota is structurally classified"
            `Quick
            test_quota_is_structurally_classified
        ; test_case "malformed JSON fails closed" `Quick test_malformed_json_fails_closed
        ; test_case "duplicate keys fail closed" `Quick test_duplicate_keys_fail_closed
        ] )
    ; ( "mcp"
      , [ test_case "dynamic tool callback" `Quick test_dynamic_tool_callback
        ; test_case
            "shared bridge owns exact dispatch"
            `Quick
            test_shared_mcp_bridge_owns_exact_dispatch
        ; test_case
            "notification has no response"
            `Quick
            test_mcp_notification_has_no_response
        ; test_case
            "unsupported control request fails closed"
            `Quick
            test_unsupported_control_request_fails_closed
        ; test_case
            "allowedTools tokenizer chars validated"
            `Quick
            test_allowed_tools_tokenizer_chars_are_validated
        ] )
    ; ( "hard-cut"
      , [ test_case
            "unknown stream type fails closed"
            `Quick
            test_unknown_stream_type_fails_closed
        ] )
    ; "session", [ test_case "resume identity" `Quick test_resume_preserves_session_identity ]
    ; "live", [ test_case "subscription turn" `Slow test_live_subscription ]
    ]
;;
