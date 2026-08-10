open Alcotest
open Masc

let init
    ?(conversation_id = "conversation-1")
    ?(model = "gemini-fixture")
    ?(permission_mode = "always-proceed")
    ()
  =
  Printf.sprintf
    {|{"event":"init","conversation_id":%S,"init":{"model":%S,"cwd":"/tmp","tools":["view_file"],"permission_mode":%S}}|}
    conversation_id
    model
    permission_mode
;;

let step
    ?(conversation_id = "conversation-1")
    ?(index = 1)
    ?(state = "DONE")
    ?(step_type = "agent_response")
    ()
  =
  Printf.sprintf
    {|{"event":"step_update","step_update":{"conversation_id":%S,"step_index":%d,"state":%S,"step_type":%S}}|}
    conversation_id
    index
    state
    step_type
;;

let result
    ?(conversation_id = "conversation-1")
    ?(status = "SUCCESS")
    ?(response = "MASC_ANTIGRAVITY_OK\n")
    ?error
    ?(num_turns = 1)
    ()
  =
  let error_field =
    match error with
    | None -> ""
    | Some value -> Printf.sprintf ",\"error\":%S" value
  in
  Printf.sprintf
    {|{"event":"result","result":{"conversation_id":%S,"status":%S,"response":%S%s,"duration_seconds":5.5,"num_turns":%d,"usage":{"input_tokens":100,"output_tokens":7,"thinking_tokens":3,"cache_read_tokens":50,"total_tokens":107}}}|}
    conversation_id
    status
    response
    error_field
    num_turns
;;

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let fixture_script
    ?(require_resume = false)
    ?required_home
    ?(sleep_s = 0.0)
    ?(exit_code = 0)
    lines
  =
  let path = Filename.temp_file "masc-antigravity-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output
    "test -z \"${GEMINI_API_KEY+x}\" && test -z \"${GEMINI_API_KEY_WORK+x}\" && test -z \"${GOOGLE_API_TOKEN+x}\" && test -z \"${OPENAI_API_KEY+x}\" && test -z \"${OPENAI_API_KEY_MAIN+x}\" && test -z \"${ANTHROPIC_API_KEY+x}\" && test -z \"${ANTHROPIC_API_KEY_WORK+x}\" && test -z \"${AGY_ADC_AUTH+x}\" && test -z \"${MASC_PUBLIC_FIXTURE+x}\" || exit 92\n";
  if require_resume
  then
    output_string
      output
      "case \" $* \" in *\" --conversation conversation-1 \"*) ;; *) exit 93 ;; esac\n";
  Option.iter
    (fun expected ->
      output_string
        output
        (Printf.sprintf "test \"$HOME\" = %s || exit 94\n" (shell_quote expected));
      output_string
        output
        "test -z \"${XDG_CACHE_HOME+x}\" && test -z \"${XDG_CONFIG_HOME+x}\" && test -z \"${XDG_DATA_HOME+x}\" || exit 95\n")
    required_home;
  if sleep_s > 0.0 then output_string output (Printf.sprintf "sleep %.3f\n" sleep_s);
  List.iter
    (fun line -> output_string output ("printf '%s\\n' " ^ shell_quote line ^ "\n"))
    lines;
  output_string output (Printf.sprintf "exit %d\n" exit_code);
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let with_fixture ?require_resume ?required_home ?sleep_s ?exit_code lines f =
  let path = fixture_script ?require_resume ?required_home ?sleep_s ?exit_code lines in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let run_fixture ?conversation_mode ?home_dir ?on_conversation_ready ?(timeout_s = 2.0) path =
  Eio_main.run (fun env ->
    let config =
      { (Runtime_antigravity.default_config ~cwd:"/tmp" ~model:"gemini-fixture") with
        cli_path = path
      ; timeout_s
      }
    in
    Runtime_antigravity.run_turn
      ?conversation_mode
      ?home_dir
      ?on_conversation_ready
      ~mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env)
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
      config
      ~prompt:"Return the fixture marker")
;;

let test_successful_official_client_turn () =
  with_fixture
    [ init ()
    ; step ~index:0 ~step_type:"user_input" ()
    ; step ~index:1 ~step_type:"unknown" ()
    ; step ~index:2 ~step_type:"agent_response" ()
    ; step ~index:3 ~step_type:"checkpoint" ()
    ; result ()
    ]
    (fun path ->
       match run_fixture path with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok turn ->
         check string "conversation" "conversation-1" turn.conversation_id;
         check string "model" "gemini-fixture" turn.model;
         check string "text" "MASC_ANTIGRAVITY_OK\n" turn.text;
         check int "turn count" 1 turn.num_turns;
         check int "input tokens" 100 turn.usage.input_tokens;
         check int "total tokens" 107 turn.usage.total_tokens;
         check
           bool
           "permission mode"
           true
           (turn.permission_mode = Runtime_antigravity.Always_proceed);
         check bool "new conversation" false turn.resumed;
         check bool "measured wall duration" true (turn.wall_duration_s >= 0.0))
;;

let test_child_environment_is_allowlisted () =
  Unix.putenv "MASC_PUBLIC_FIXTURE" "must-not-leak";
  with_fixture [ init (); result () ] (fun path ->
    match run_fixture path with
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok _ -> ())
;;

let test_isolated_home_replaces_inherited_directory_roots () =
  let home_dir = Filename.temp_dir "masc-antigravity-child-home-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree home_dir)
    (fun () ->
      with_fixture
        ~required_home:home_dir
        [ init (); result () ]
        (fun path ->
          match run_fixture ~home_dir path with
          | Error error -> fail (Runtime_antigravity.error_to_string error)
          | Ok _ -> ()))
;;

let test_resume_requires_exact_identity_and_argv () =
  with_fixture
    ~require_resume:true
    [ init (); step ~index:4 (); result ~num_turns:2 () ]
    (fun path ->
       match
         run_fixture
           ~conversation_mode:
             (Runtime_antigravity.Resume { conversation_id = "conversation-1" })
           path
       with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok turn ->
         check bool "resumed" true turn.resumed;
         check int "cumulative turn count" 2 turn.num_turns)
;;

let test_resume_identity_mismatch_fails_closed () =
  with_fixture
    [ init ~conversation_id:"different" (); result ~conversation_id:"different" () ]
    (fun path ->
       match
         run_fixture
           ~conversation_mode:
             (Runtime_antigravity.Resume { conversation_id = "conversation-1" })
           path
       with
       | Error (Runtime_antigravity.Protocol_error _) -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "resume admitted a different conversation")
;;

let test_conversation_callback_precedes_terminal_result () =
  let observed = ref None in
  with_fixture
    [ init (); result () ]
    (fun path ->
       match
         run_fixture
           ~on_conversation_ready:(fun ~conversation_id ->
             observed := Some conversation_id;
             Ok ())
           path
       with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> check (option string) "callback identity" (Some "conversation-1") !observed)
;;

let test_conversation_callback_failure_is_typed () =
  with_fixture [ init (); result () ] (fun path ->
    match
      run_fixture
        ~on_conversation_ready:(fun ~conversation_id:_ -> failwith "fixture callback")
        path
    with
    | Error (Runtime_antigravity.State_callback_failed _) -> ()
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok _ -> fail "callback exception was admitted as a successful turn")
;;

let test_tool_steps_and_errors_are_measured () =
  with_fixture
    [ init ()
    ; step ~index:1 ~state:"ACTIVE" ~step_type:"tool" ()
    ; step ~index:1 ~state:"ERROR" ~step_type:"tool" ()
    ; step ~index:2 ~state:"ACTIVE" ~step_type:"tool" ()
    ; step ~index:2 ~state:"DONE" ~step_type:"tool" ()
    ; result ()
    ]
    (fun path ->
       match run_fixture path with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok turn ->
         check int "tool starts" 2 turn.tool_steps;
         check int "tool errors" 1 turn.tool_errors)
;;

let test_result_error_is_not_success () =
  with_fixture
    ~exit_code:1
    [ init (); result ~status:"ERROR" ~response:"" ~error:"timeout waiting for response" () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Turn_failed "timeout waiting for response") -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "ERROR result was admitted as success")
;;

let test_duplicate_keys_fail_closed () =
  let duplicate =
    {|{"event":"init","event":"init","conversation_id":"conversation-1","init":{"model":"gemini-fixture","cwd":"/tmp","permission_mode":"always-proceed"}}|}
  in
  with_fixture
    [ duplicate; result () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Protocol_error _) -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "duplicate key was admitted")
;;

(* A live init event announced request-review. It was not modelled, the parse
   failed, and the resulting protocol error put the official-client session in
   Recovery_required -- which blocked every later turn for that keeper until an
   operator resolved it (taskmaster, 110 turns in one hour). Nothing in this
   tree branches on the value; the vocabulary is closed only to fail loudly on
   a member we have not seen. *)
let test_observed_permission_modes_are_admitted () =
  List.iter
    (fun (wire, expected) ->
      with_fixture [ init ~permission_mode:wire (); result () ] (fun path ->
        match run_fixture path with
        | Ok turn ->
          check bool ("permission mode " ^ wire) true (turn.permission_mode = expected)
        | Error error ->
          fail (wire ^ " was rejected: " ^ Runtime_antigravity.error_to_string error)))
    [ "always-proceed", Runtime_antigravity.Always_proceed
    ; "request-review", Runtime_antigravity.Request_review
    ]
;;

let test_unknown_protocol_vocabulary_fails_closed () =
  let unknown_permission =
    {|{"event":"init","conversation_id":"conversation-1","init":{"model":"gemini-fixture","cwd":"/tmp","permission_mode":"unreviewed"}}|}
  in
  let cases =
    [ "permission mode", [ unknown_permission; result () ]
    ; "step state", [ init (); step ~state:"PAUSED" (); result () ]
    ; "step type", [ init (); step ~step_type:"shell" (); result () ]
    ; "result status", [ init (); result ~status:"PARTIAL" () ]
    ]
  in
  List.iter
    (fun (name, lines) ->
      with_fixture lines (fun path ->
        match run_fixture path with
        | Error (Runtime_antigravity.Protocol_error _) -> ()
        | Error error -> fail (name ^ ": " ^ Runtime_antigravity.error_to_string error)
        | Ok _ -> fail (name ^ " was admitted")))
    cases
;;

let test_timeout_is_typed () =
  with_fixture
    ~sleep_s:1.0
    [ init (); result () ]
    (fun path ->
       match run_fixture ~timeout_s:0.05 path with
       | Error (Runtime_antigravity.Timeout _) -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "slow CLI ignored the runtime timeout")
;;

let test_admission_is_process_free () =
  let config =
    { (Runtime_antigravity.default_config ~cwd:"relative" ~model:"gemini-fixture") with
      cli_path = ""
    }
  in
  match Runtime_antigravity.validate_turn config ~prompt:"fixture" with
  | Error (Runtime_antigravity.Invalid_config "cli_path must not be empty") -> ()
  | Error error -> fail (Runtime_antigravity.error_to_string error)
  | Ok () -> fail "invalid deterministic config passed admission"
;;

let test_live_start_and_resume () =
  match Sys.getenv_opt "MASC_ANTIGRAVITY_LIVE", Sys.getenv_opt "MASC_ANTIGRAVITY_MODEL" with
  | Some "1", Some model ->
    let cwd = Sys.getcwd () in
    let cli_path = Option.value ~default:"agy" (Sys.getenv_opt "MASC_ANTIGRAVITY_CLI") in
    let first, second =
      Eio_main.run (fun env ->
        let config =
          { (Runtime_antigravity.default_config ~cwd ~model) with
            cli_path
          ; timeout_s = 60.0
          }
        in
        let run ?conversation_mode prompt =
          Runtime_antigravity.run_turn
            ?conversation_mode
            ~mgr:(Eio.Stdenv.process_mgr env)
            ~clock:(Eio.Stdenv.clock env)
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / cwd)
            config
            ~prompt
        in
        let first = run "Reply with exactly: MASC_ANTIGRAVITY_LIVE_OK" in
        let second =
          match first with
          | Error _ as error -> error
          | Ok turn ->
            run
              ~conversation_mode:
                (Runtime_antigravity.Resume
                   { conversation_id = turn.conversation_id })
              "Reply with exactly: MASC_ANTIGRAVITY_LIVE_RESUMED"
        in
        first, second)
    in
    (match first, second with
     | Ok first, Ok second ->
       check string "first live response" "MASC_ANTIGRAVITY_LIVE_OK\n" first.text;
       check string
         "resumed live response"
         "MASC_ANTIGRAVITY_LIVE_RESUMED\n"
         second.text;
       check string "same conversation" first.conversation_id second.conversation_id;
       check bool "cumulative turns" true (second.num_turns >= 2)
     | Error error, _ | _, Error error ->
       fail (Runtime_antigravity.error_to_string error))
  | _ -> Alcotest.skip ()
;;

let () =
  run
    "runtime_antigravity"
    [ ( "stream-json"
      , [ test_case
            "successful official-client turn"
            `Quick
            test_successful_official_client_turn
        ; test_case
            "resume identity and argv"
            `Quick
            test_resume_requires_exact_identity_and_argv
        ; test_case
            "resume mismatch"
            `Quick
            test_resume_identity_mismatch_fails_closed
        ; test_case
            "child environment allowlist"
            `Quick
            test_child_environment_is_allowlisted
        ; test_case
            "isolated HOME"
            `Quick
            test_isolated_home_replaces_inherited_directory_roots
        ; test_case
            "conversation callback"
            `Quick
            test_conversation_callback_precedes_terminal_result
        ; test_case
            "conversation callback failure"
            `Quick
            test_conversation_callback_failure_is_typed
        ; test_case "tool measurements" `Quick test_tool_steps_and_errors_are_measured
        ; test_case "error result" `Quick test_result_error_is_not_success
        ; test_case "duplicate keys" `Quick test_duplicate_keys_fail_closed
        ; test_case
            "observed permission modes are admitted"
            `Quick
            test_observed_permission_modes_are_admitted
        ; test_case
            "unknown protocol vocabulary fails closed"
            `Quick
            test_unknown_protocol_vocabulary_fails_closed
        ; test_case "typed timeout" `Quick test_timeout_is_typed
        ; test_case "process-free admission" `Quick test_admission_is_process_free
        ] )
    ; "live official client", [ test_case "official agy start and resume" `Slow test_live_start_and_resume ]
    ]
;;
