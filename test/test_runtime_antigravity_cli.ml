open Alcotest

let conversation_id = "9971bfe0-4e21-40f9-8b5d-715ec5096965"

let init_line ~cwd =
  Printf.sprintf
    {|{"event":"init","conversation_id":%S,"init":{"model":"gemini-3.6-flash-low","cwd":%S,"tools":["run_command","write_to_file"],"permission_mode":"always-proceed"}}|}
    conversation_id
    cwd
;;

let user_step =
  Printf.sprintf
    {|{"event":"step_update","step_update":{"conversation_id":%S,"step_index":0,"state":"DONE","step_type":"user_input"}}|}
    conversation_id
;;

let tool_step =
  Printf.sprintf
    {|{"event":"step_update","step_update":{"conversation_id":%S,"step_index":1,"state":"DONE","step_type":"tool","tool_name":"run_command","usage":{"input_tokens":10,"output_tokens":2,"thinking_tokens":0,"cache_read_tokens":4,"total_tokens":12}}}|}
    conversation_id
;;

let result_line ?(status = "SUCCESS") ?(turns = 1) () =
  Printf.sprintf
    {|{"event":"result","result":{"conversation_id":%S,"status":%S,"response":"MASC_AGY_OK\n","duration_seconds":1.25,"num_turns":%d,"usage":{"input_tokens":20,"output_tokens":3,"thinking_tokens":0,"cache_read_tokens":5,"total_tokens":23}}}|}
    conversation_id
    status
    turns
;;

let output ~cwd ?status ?turns () =
  String.concat "\n"
    [ init_line ~cwd; user_step; tool_step; result_line ?status ?turns (); "" ]
;;

let parse ~cwd ?(session_mode = Runtime_antigravity_cli.Start) value =
  Runtime_antigravity_cli.For_testing.parse_output
    ~expected_model:(Some "gemini-3.6-flash-low")
    ~expected_cwd:cwd
    ~session_mode
    value
;;

let test_strict_success_projection () =
  let result = parse ~cwd:"/tmp" (output ~cwd:"/tmp" ()) |> Result.get_ok in
  check string "conversation" conversation_id result.conversation_id;
  check string "model" "gemini-3.6-flash-low" result.model;
  check string "response" "MASC_AGY_OK\n" result.text;
  check int "turns" 1 result.num_turns;
  check int "tool calls" 1 result.tool_calls;
  check int "input usage" 20 result.usage.input_tokens;
  check int "output usage" 3 result.usage.output_tokens;
  check int "cache usage" 5 result.usage.cache_read_tokens;
  check bool "start is not resumed" false result.resumed
;;

let test_resume_requires_exact_identity () =
  let result =
    parse
      ~cwd:"/tmp"
      ~session_mode:(Runtime_antigravity_cli.Resume { conversation_id })
      (output ~cwd:"/tmp" ~turns:2 ())
    |> Result.get_ok
  in
  check bool "resumed" true result.resumed;
  match
    parse
      ~cwd:"/tmp"
      ~session_mode:
        (Runtime_antigravity_cli.Resume { conversation_id = "different" })
      (output ~cwd:"/tmp" ~turns:2 ())
  with
  | Error (Runtime_antigravity_cli.Protocol_error _) -> ()
  | Error error -> fail (Runtime_antigravity_cli.error_to_string error)
  | Ok _ -> fail "conversation identity mismatch was accepted"
;;

let test_duplicate_keys_fail_closed () =
  let duplicate =
    String.concat "\n"
      [ Printf.sprintf
          {|{"event":"init","event":"init","conversation_id":%S,"init":{"model":"gemini-3.6-flash-low","cwd":"/tmp","tools":[],"permission_mode":"always-proceed"}}|}
          conversation_id
      ; result_line ()
      ]
  in
  match parse ~cwd:"/tmp" duplicate with
  | Error (Runtime_antigravity_cli.Protocol_error _) -> ()
  | Error error -> fail (Runtime_antigravity_cli.error_to_string error)
  | Ok _ -> fail "duplicate JSON keys were accepted"
;;

let test_failed_status_is_not_completion () =
  match parse ~cwd:"/tmp" (output ~cwd:"/tmp" ~status:"FAILED" ()) with
  | Error (Runtime_antigravity_cli.Turn_failed "FAILED") -> ()
  | Error error -> fail (Runtime_antigravity_cli.error_to_string error)
  | Ok _ -> fail "failed Antigravity result was accepted"
;;

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let temp_workspace () =
  let path = Filename.temp_file "masc-agy-runtime-" "" in
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
  let path = Filename.temp_file "masc-agy-runtime-fixture-" ".sh" in
  let output_channel = open_out_bin path in
  let emit line =
    output_string output_channel
      ("printf '%s\\n' " ^ shell_quote line ^ "\n")
  in
  output_string output_channel "#!/bin/sh\n";
  output_string output_channel
    ("test \"$PWD\" = " ^ shell_quote workspace
     ^ " || { printf 'pwd=%s expected=%s\\n' \"$PWD\" "
     ^ shell_quote workspace ^ " >&2; exit 71; }\n");
  output_string output_channel
    "test -z \"$OPENAI_API_KEY$CODEX_API_KEY$GEMINI_API_KEY$GOOGLE_API_KEY$ANTHROPIC_API_KEY\" || exit 72\n";
  output_string output_channel "conversation='";
  output_string output_channel conversation_id;
  output_string output_channel "'\nturns=1\n";
  output_string output_channel "mode=\nsandbox=\ndangerous=\n";
  output_string output_channel
    "while test \"$#\" -gt 0; do case \"$1\" in --conversation) shift; conversation=\"$1\"; turns=2 ;; --mode) shift; mode=\"$1\" ;; --sandbox) sandbox=1 ;; --dangerously-skip-permissions) dangerous=1 ;; esac; shift; done\n";
  output_string output_channel
    "test \"$mode\" = plan && test \"$sandbox\" = 1 && test -z \"$dangerous\" || exit 73\n";
  emit (init_line ~cwd:workspace);
  emit user_step;
  output_string output_channel
    ("printf '%s\\n' \"{\\\"event\\\":\\\"result\\\",\\\"result\\\":{\\\"conversation_id\\\":\\\"$conversation\\\",\\\"status\\\":\\\"SUCCESS\\\",\\\"response\\\":\\\"MASC_AGY_PROCESS_OK\\\\n\\\",\\\"duration_seconds\\\":1.0,\\\"num_turns\\\":$turns,\\\"usage\\\":{\\\"input_tokens\\\":7,\\\"output_tokens\\\":2,\\\"thinking_tokens\\\":0,\\\"cache_read_tokens\\\":3,\\\"total_tokens\\\":9}}}\"\n");
  close_out output_channel;
  Unix.chmod path 0o700;
  path
;;

let with_api_key_environment f =
  let keys =
    [ "OPENAI_API_KEY"; "CODEX_API_KEY"; "GEMINI_API_KEY"; "GOOGLE_API_KEY"
    ; "ANTHROPIC_API_KEY"
    ]
  in
  let previous = List.map (fun key -> key, Sys.getenv_opt key) keys in
  List.iter (fun key -> Unix.putenv key "METERED_KEY_MUST_NOT_REACH_CHILD") keys;
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
       with_api_key_environment (fun () ->
         with_initialized_process_eio (fun () ->
                let config : Runtime_antigravity_cli.config =
                  { cli_path = script
                  ; cwd = workspace
                  ; model = Some "gemini-3.6-flash-low"
                  ; timeout_s = 5.0
                  }
                in
                let expect_ok = function
                  | Ok value -> value
                  | Error error ->
                    fail (Runtime_antigravity_cli.error_to_string error)
                in
                let first =
                  Runtime_antigravity_cli.run_turn config ~prompt:"fixture start"
                  |> expect_ok
                in
                check string
                  "process response"
                  "MASC_AGY_PROCESS_OK\n"
                  first.text;
                check bool "process start" false first.resumed;
                let resumed =
                  Runtime_antigravity_cli.run_turn
                    ~session_mode:(Resume { conversation_id })
                    config
                    ~prompt:"fixture resume"
                  |> expect_ok
                in
                check bool "process resume" true resumed.resumed;
                check int "process turn count" 2 resumed.num_turns)))
;;

let test_live_subscription_client () =
  if Sys.getenv_opt "MASC_ANTIGRAVITY_CLI_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let cli_path =
      match Sys.getenv_opt "MASC_ANTIGRAVITY_CLI_PATH" with
      | Some path when String.trim path <> "" -> path
      | _ -> fail "MASC_ANTIGRAVITY_CLI_PATH is required for the live test"
    in
    let cwd = Sys.getcwd () |> Unix.realpath in
    with_initialized_process_eio (fun () ->
      let config : Runtime_antigravity_cli.config =
        { cli_path
        ; cwd
        ; model = Some "gemini-3.6-flash-low"
        ; timeout_s = 60.0
        }
      in
      match
        Runtime_antigravity_cli.run_turn
          config
          ~prompt:"Reply exactly MASC_AGY_NATIVE_OK and nothing else."
      with
      | Error error -> fail (Runtime_antigravity_cli.error_to_string error)
      | Ok result ->
        check string "live response" "MASC_AGY_NATIVE_OK" (String.trim result.text);
        check bool "measured input usage" true (result.usage.input_tokens > 0);
        check bool "measured output usage" true (result.usage.output_tokens > 0))
;;

let test_subscription_environment_key_set_is_exact () =
  List.iter
    (fun key ->
      check bool key true
        (Runtime_subscription_cli_env.is_metered_api_credential key))
    [ "OPENAI_API_KEY"; "CODEX_API_KEY"; "GEMINI_API_KEY"; "GOOGLE_API_KEY"
    ; "ANTHROPIC_API_KEY"
    ];
  check bool "unrelated env survives" false
    (Runtime_subscription_cli_env.is_metered_api_credential "PATH")
;;

let test_runtime_observation_retains_internal_measured_labels () =
  let capture, _metrics =
    Runtime_observation.runtime_metrics_for_candidates ~candidate_count:1 ()
  in
  Runtime_observation.record_attempt_terminal
    capture
    ~model_id:"gemini-3.6-flash-low"
    ~latency_ms:(Some 12)
    ~error:None;
  let labels =
    [ "tool_owner=official_client"
    ; "permission_mode=always-proceed"
    ; "thinking_tokens=2"
    ]
  in
  let observation =
    Runtime_observation.runtime_observation_with_metrics
      ~runtime_id:"antigravity.gemini"
      ~configured_labels:labels
      ~candidate_count:1
      ~selected_model_raw:(Some "gemini-3.6-flash-low")
      ~capture
      ()
  in
  check (list string) "internal measured labels" labels observation.configured_labels
;;

let test_runtime_observation_publishes_typed_official_client_snapshot () =
  let capture, _metrics =
    Runtime_observation.runtime_metrics_for_candidates ~candidate_count:1 ()
  in
  let official_client : Runtime_observation.official_client_measurement =
    { client = Antigravity
    ; execution_mode = Plan_sandbox
    ; tool_owner = Official_client
    ; permission_mode = Some "always-proceed"
    ; session_bound = true
    ; resumed = false
    ; turn_count = 1
    ; tool_calls = 2
    ; usage =
        Some
          { input_tokens = 20
          ; output_tokens = 3
          ; thinking_tokens = Some 1
          ; cache_creation_input_tokens = None
          ; cache_read_input_tokens = 5
          ; total_tokens = Some 23
          ; total_cost_usd = None
          }
    }
  in
  let observation =
    Runtime_observation.runtime_observation_with_metrics
      ~runtime_id:"antigravity.typed-snapshot"
      ~configured_labels:[]
      ~official_client
      ~candidate_count:1
      ~selected_model_raw:(Some "gemini-3.6-flash-low")
      ~capture
      ()
  in
  Runtime_observation.record_runtime
    ~observation:(Some observation)
    ~runtime_id:"antigravity.typed-snapshot"
    ~outcome:`Success
    ();
  match
    Runtime_observation.latest_official_client_snapshot
      ~runtime_id:"antigravity.typed-snapshot"
  with
  | None -> fail "typed official-client snapshot was not published"
  | Some snapshot ->
    check string "runtime" "antigravity.typed-snapshot" snapshot.runtime_id;
    check bool "measurement" true (snapshot.measurement = official_client);
    let json = Runtime_observation.official_client_snapshot_to_json snapshot in
    check string
      "tool owner wire"
      "official_client"
      Yojson.Safe.Util.(json |> member "measurement" |> member "tool_owner" |> to_string)
;;

let () =
  run "runtime antigravity CLI"
    [ ( "typed stream-json boundary"
      , [ test_case "strict success projection" `Quick test_strict_success_projection
        ; test_case "resume identity" `Quick test_resume_requires_exact_identity
        ; test_case "duplicate keys" `Quick test_duplicate_keys_fail_closed
        ; test_case "failed status" `Quick test_failed_status_is_not_completion
        ; test_case "process start and resume" `Quick test_process_boundary_start_and_resume
        ; test_case "subscription env key set" `Quick test_subscription_environment_key_set_is_exact
        ; test_case
            "runtime observation keeps measured labels"
            `Quick
            test_runtime_observation_retains_internal_measured_labels
        ; test_case
            "runtime observation publishes typed official-client snapshot"
            `Quick
            test_runtime_observation_publishes_typed_official_client_snapshot
        ] )
    ; ( "live subscription"
      , [ test_case "official Antigravity CLI" `Slow test_live_subscription_client ] )
    ]
;;
