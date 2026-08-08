open Alcotest

let session_id = "f72353c2-4462-476f-8398-82105a7f9cae"

let init_line ~cwd ?(api_key_source = "none") ?(permission_mode = "plan") () =
  Printf.sprintf
    {|{"type":"system","subtype":"init","cwd":%S,"session_id":%S,"tools":["Glob","Grep","Read","WebFetch","WebSearch"],"model":"claude-opus-5","permissionMode":%S,"apiKeySource":%S}|}
    cwd
    session_id
    permission_mode
    api_key_source
;;

let assistant_line =
  Printf.sprintf
    {|{"type":"assistant","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"checking"},{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"README.md"}}]},"session_id":%S}|}
    session_id
;;

let user_line =
  Printf.sprintf
    {|{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]},"session_id":%S}|}
    session_id
;;

let result_line ?(is_error = false) ?(subtype = "success")
    ?(result = "MASC_CLAUDE_OK") ?terminal_reason ?api_error_status () =
  let terminal_reason =
    match terminal_reason with
    | None -> "null"
    | Some value -> Printf.sprintf "%S" value
  in
  let api_error_status =
    match api_error_status with
    | None -> "null"
    | Some value -> string_of_int value
  in
  Printf.sprintf
    {|{"type":"result","subtype":%S,"is_error":%b,"duration_ms":1250,"duration_api_ms":900,"num_turns":1,"result":%S,"session_id":%S,"total_cost_usd":0.0125,"usage":{"input_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":5,"output_tokens":4},"terminal_reason":%s,"api_error_status":%s}|}
    subtype
    is_error
    result
    session_id
    terminal_reason
    api_error_status
;;

let rate_limit_line ?(status = "rejected") () =
  Printf.sprintf
    {|{"type":"rate_limit_event","rate_limit_info":{"status":%S,"resetsAt":1786356000,"rateLimitType":"seven_day"},"session_id":%S}|}
    status
    session_id
;;

let success_output ~cwd ?api_key_source ?permission_mode () =
  String.concat
    "\n"
    [ init_line ~cwd ?api_key_source ?permission_mode ()
    ; assistant_line
    ; user_line
    ; result_line ()
    ; ""
    ]
;;

let parse ~cwd ?(mode = Runtime_claude_code_cli.Start { session_id }) value =
  Runtime_claude_code_cli.For_testing.parse_output
    ~expected_model:(Some "claude-opus-5")
    ~expected_cwd:cwd
    ~session_mode:mode
    value
;;

let test_strict_success_projection () =
  let result = parse ~cwd:"/tmp" (success_output ~cwd:"/tmp" ()) |> Result.get_ok in
  check string "session" session_id result.session_id;
  check string "model" "claude-opus-5" result.model;
  check string "response" "MASC_CLAUDE_OK" result.text;
  check int "agent loop turns" 1 result.num_turns;
  check int "tool calls" 1 result.tool_calls;
  check int "input usage" 20 result.usage.input_tokens;
  check int "output usage" 4 result.usage.output_tokens;
  check int "cache creation" 3 result.usage.cache_creation_input_tokens;
  check int "cache read" 5 result.usage.cache_read_input_tokens;
  check (float 0.000001) "cost" 0.0125 result.usage.total_cost_usd;
  check bool "start" false result.resumed
;;

let test_resume_requires_exact_identity () =
  let resumed =
    parse
      ~cwd:"/tmp"
      ~mode:(Runtime_claude_code_cli.Resume { session_id })
      (success_output ~cwd:"/tmp" ())
    |> Result.get_ok
  in
  check bool "resumed" true resumed.resumed;
  match
    Runtime_claude_code_cli.For_testing.parse_output
      ~expected_model:(Some "claude-opus-5")
      ~expected_cwd:"/tmp"
      ~session_mode:(Resume { session_id = "different" })
      (success_output ~cwd:"/tmp" ())
  with
  | Error (Runtime_claude_code_cli.Protocol_error _) -> ()
  | Error error -> fail (Runtime_claude_code_cli.error_to_string error)
  | Ok _ -> fail "session identity mismatch was accepted"
;;

let test_rate_limit_rejection_beats_success_subtype () =
  let output =
    String.concat
      "\n"
      [ init_line ~cwd:"/tmp" ()
      ; rate_limit_line ()
      ; Printf.sprintf
          {|{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"limit"}]},"session_id":%S}|}
          session_id
      ; result_line
          ~is_error:true
          ~subtype:"success"
          ~result:"individual spend limit"
          ~terminal_reason:"api_error"
          ~api_error_status:429
          ()
      ]
  in
  match parse ~cwd:"/tmp" output with
  | Error
      (Runtime_claude_code_cli.Turn_rejected
         { status = "rejected"
         ; reset_at = Some 1786356000
         ; detail
         ; model
         ; num_turns
         ; usage
         ; tool_calls
         ; permission_mode
         ; resumed
         }) ->
    check string "detail" "individual spend limit" detail;
    check string "measured model" "claude-opus-5" model;
    check int "measured client turns" 1 num_turns;
    check int "measured input" 20 usage.input_tokens;
    check int "measured output" 4 usage.output_tokens;
    check int "measured tool calls" 0 tool_calls;
    check string "measured permission" "plan" permission_mode;
    check bool "measured start" false resumed
  | Error error -> fail (Runtime_claude_code_cli.error_to_string error)
  | Ok _ -> fail "rate-limit result with subtype=success was accepted"
;;

let test_api_key_source_and_permission_fail_closed () =
  let expect_protocol_error output =
    match parse ~cwd:"/tmp" output with
    | Error (Runtime_claude_code_cli.Protocol_error _) -> ()
    | Error error -> fail (Runtime_claude_code_cli.error_to_string error)
    | Ok _ -> fail "invalid init boundary was accepted"
  in
  expect_protocol_error (success_output ~cwd:"/tmp" ~api_key_source:"ANTHROPIC_API_KEY" ());
  expect_protocol_error (success_output ~cwd:"/tmp" ~permission_mode:"default" ())
;;

let test_duplicate_keys_fail_closed () =
  let duplicate =
    String.concat
      "\n"
      [ Printf.sprintf
          {|{"type":"system","type":"system","subtype":"init","cwd":"/tmp","session_id":%S,"tools":["Glob","Grep","Read","WebFetch","WebSearch"],"model":"claude-opus-5","permissionMode":"plan","apiKeySource":"none"}|}
          session_id
      ; result_line ()
      ]
  in
  match parse ~cwd:"/tmp" duplicate with
  | Error (Runtime_claude_code_cli.Protocol_error _) -> ()
  | Error error -> fail (Runtime_claude_code_cli.error_to_string error)
  | Ok _ -> fail "duplicate JSON keys were accepted"
;;

let test_init_must_precede_stream_events () =
  let output = String.concat "\n" [ assistant_line; init_line ~cwd:"/tmp" (); result_line () ] in
  match parse ~cwd:"/tmp" output with
  | Error (Runtime_claude_code_cli.Protocol_error _) -> ()
  | Error error -> fail (Runtime_claude_code_cli.error_to_string error)
  | Ok _ -> fail "assistant event before init was accepted"
;;

let test_success_cannot_carry_api_error () =
  let output =
    String.concat
      "\n"
      [ init_line ~cwd:"/tmp" ()
      ; result_line ~terminal_reason:"api_error" ~api_error_status:500 ()
      ]
  in
  match parse ~cwd:"/tmp" output with
  | Error (Runtime_claude_code_cli.Protocol_error _) -> ()
  | Error error -> fail (Runtime_claude_code_cli.error_to_string error)
  | Ok _ -> fail "successful result carrying API error metadata was accepted"
;;

let test_session_id_must_be_canonical_uuid () =
  let config : Runtime_claude_code_cli.config =
    { cli_path = "claude"
    ; cwd = "/tmp"
    ; model = None
    ; timeout_s = 5.0
    ; max_turns = 1
    }
  in
  match
    Runtime_claude_code_cli.validate_run
      config
      ~session_mode:(Start { session_id = "not-a-uuid" })
      ~prompt:"hello"
  with
  | Error (Runtime_claude_code_cli.Invalid_config _) -> ()
  | Error error -> fail (Runtime_claude_code_cli.error_to_string error)
  | Ok () -> fail "non-UUID session identity was accepted"
;;

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let temp_workspace () =
  let path = Filename.temp_file "masc-claude-runtime-" "" in
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

let fixture_script ~workspace =
  let path = Filename.temp_file "masc-claude-runtime-fixture-" ".sh" in
  let output_channel = open_out_bin path in
  let emit line =
    output_string output_channel ("printf '%s\\n' " ^ shell_quote line ^ "\n")
  in
  output_string output_channel "#!/bin/sh\n";
  output_string output_channel
    ("test \"$PWD\" = " ^ shell_quote workspace ^ " || exit 71\n");
  output_string output_channel
    "test -z \"$OPENAI_API_KEY$CODEX_API_KEY$GEMINI_API_KEY$GOOGLE_API_KEY$ANTHROPIC_API_KEY$ANTHROPIC_AUTH_TOKEN$ANTHROPIC_BASE_URL$CLAUDE_CODE_USE_BEDROCK$CLAUDE_CODE_USE_VERTEX$CLAUDE_CODE_USE_FOUNDRY\" || exit 72\n";
  output_string output_channel
    "session= mode= permission= tools= safe= slash= chrome= verbose= output= max_turns=\n";
  output_string output_channel
    "while test \"$#\" -gt 0; do case \"$1\" in --session-id) shift; session=\"$1\"; mode=start ;; --resume) shift; session=\"$1\"; mode=resume ;; --permission-mode) shift; permission=\"$1\" ;; --tools) shift; tools=\"$1\" ;; --max-turns) shift; max_turns=\"$1\" ;; --output-format) shift; output=\"$1\" ;; --safe-mode) safe=1 ;; --disable-slash-commands) slash=1 ;; --no-chrome) chrome=1 ;; --verbose) verbose=1 ;; esac; shift; done\n";
  output_string output_channel
    "test \"$session\" = 'f72353c2-4462-476f-8398-82105a7f9cae' && test -n \"$mode\" && test \"$permission\" = plan && test \"$tools\" = 'Glob,Grep,Read,WebFetch,WebSearch' && test \"$max_turns\" = 4 && test \"$output\" = stream-json && test \"$safe$slash$chrome$verbose\" = 1111 || exit 73\n";
  emit (init_line ~cwd:workspace ());
  emit
    (Printf.sprintf
       {|{"type":"assistant","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"MASC_CLAUDE_PROCESS_OK"}]},"session_id":%S}|}
       session_id);
  emit (result_line ~result:"MASC_CLAUDE_PROCESS_OK" ());
  close_out output_channel;
  Unix.chmod path 0o700;
  path
;;

let with_disallowed_environment f =
  let keys =
    [ "OPENAI_API_KEY"
    ; "CODEX_API_KEY"
    ; "GEMINI_API_KEY"
    ; "GOOGLE_API_KEY"
    ; "ANTHROPIC_API_KEY"
    ; "ANTHROPIC_AUTH_TOKEN"
    ; "ANTHROPIC_BASE_URL"
    ; "CLAUDE_CODE_USE_BEDROCK"
    ; "CLAUDE_CODE_USE_VERTEX"
    ; "CLAUDE_CODE_USE_FOUNDRY"
    ]
  in
  let previous = List.map (fun key -> key, Sys.getenv_opt key) keys in
  List.iter (fun key -> Unix.putenv key "DISALLOWED_OVERRIDE") keys;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (key, value) -> Unix.putenv key (Option.value value ~default:""))
        previous)
    f
;;

let with_initialized_process_eio f =
  Eio_main.run (fun env ->
    Process_eio.init
      ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / ".")
      ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env);
    Fun.protect ~finally:Process_eio.reset_for_testing f)
;;

let test_process_boundary_start_and_resume () =
  let workspace = temp_workspace () |> Unix.realpath in
  let script = fixture_script ~workspace in
  Fun.protect
    ~finally:(fun () -> Sys.remove script; cleanup_tree workspace)
    (fun () ->
       with_disallowed_environment (fun () ->
         with_initialized_process_eio (fun () ->
           let config : Runtime_claude_code_cli.config =
             { cli_path = script
             ; cwd = workspace
             ; model = Some "claude-opus-5"
             ; timeout_s = 5.0
             ; max_turns = 4
             }
           in
           let expect_ok = function
             | Ok value -> value
             | Error error -> fail (Runtime_claude_code_cli.error_to_string error)
           in
           let first =
             Runtime_claude_code_cli.run_turn
               config
               ~session_mode:(Start { session_id })
               ~prompt:"fixture start"
             |> expect_ok
           in
           check string "process response" "MASC_CLAUDE_PROCESS_OK" first.text;
           check bool "process start" false first.resumed;
           let resumed =
             Runtime_claude_code_cli.run_turn
               config
               ~session_mode:(Resume { session_id })
               ~prompt:"fixture resume"
             |> expect_ok
           in
           check bool "process resume" true resumed.resumed)))
;;

let test_environment_override_set_is_exact () =
  List.iter
    (fun key ->
      check bool key true
        (Runtime_claude_code_cli.For_testing.is_disallowed_environment_override key))
    [ "ANTHROPIC_API_KEY"
    ; "ANTHROPIC_AUTH_TOKEN"
    ; "ANTHROPIC_BASE_URL"
    ; "CLAUDE_CODE_USE_BEDROCK"
    ; "CLAUDE_CODE_USE_VERTEX"
    ; "CLAUDE_CODE_USE_FOUNDRY"
    ];
  check bool "OAuth subscription token remains official-client owned" false
    (Runtime_claude_code_cli.For_testing.is_disallowed_environment_override
       "CLAUDE_CODE_OAUTH_TOKEN");
  check bool "unrelated env survives" false
    (Runtime_claude_code_cli.For_testing.is_disallowed_environment_override "PATH")
;;

let () =
  run
    "runtime Claude Code CLI"
    [ ( "typed stream-json boundary"
      , [ test_case "strict success projection" `Quick test_strict_success_projection
        ; test_case "resume identity" `Quick test_resume_requires_exact_identity
        ; test_case
            "rate limit beats success subtype"
            `Quick
            test_rate_limit_rejection_beats_success_subtype
        ; test_case
            "auth and permission boundary"
            `Quick
            test_api_key_source_and_permission_fail_closed
        ; test_case "duplicate keys" `Quick test_duplicate_keys_fail_closed
        ; test_case "init precedes events" `Quick test_init_must_precede_stream_events
        ; test_case
            "success cannot carry API error"
            `Quick
            test_success_cannot_carry_api_error
        ; test_case
            "canonical UUID session"
            `Quick
            test_session_id_must_be_canonical_uuid
        ; test_case
            "process start and resume"
            `Quick
            test_process_boundary_start_and_resume
        ; test_case
            "environment override set"
            `Quick
            test_environment_override_set_is_exact
        ] )
    ]
;;
