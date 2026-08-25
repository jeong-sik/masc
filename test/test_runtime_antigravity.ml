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
    ?line_delay_s
    ?after_first_line_delay_s
    ?stdout_holder_s
    ?exit_delay_s
    ?(exit_code = 0)
    lines
  =
  let path = Filename.temp_file "masc-antigravity-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output
    "test -z \"${GEMINI_API_KEY+x}\" && test -z \"${GEMINI_API_KEY_WORK+x}\" && test -z \"${GOOGLE_API_TOKEN+x}\" && test -z \"${OPENAI_API_KEY+x}\" && test -z \"${OPENAI_API_KEY_MAIN+x}\" && test -z \"${ANTHROPIC_API_KEY+x}\" && test -z \"${ANTHROPIC_API_KEY_WORK+x}\" && test -z \"${AGY_ADC_AUTH+x}\" && test -z \"${MASC_PUBLIC_FIXTURE+x}\" || exit 92\n";
  output_string output "case \" $* \" in *\" --print \"*) exit 98 ;; esac\n";
  output_string
    output
    "case \" $* \" in *\" --print-timeout 2562047h47m16.854775807s \"*) ;; *) exit 99 ;; esac\n";
  if require_resume
  then (
    output_string
      output
      "case \" $* \" in *\" --conversation conversation-1 \"*) ;; *) exit 93 ;; esac\n";
    output_string output "case \" $* \" in *\" --new-project \"*) exit 96 ;; esac\n")
  else (
    output_string output "case \" $* \" in *\" --new-project \"*) ;; *) exit 96 ;; esac\n";
    output_string output "case \" $* \" in *\" --conversation \"*) exit 97 ;; esac\n");
  Option.iter
    (fun expected ->
      output_string
        output
        (Printf.sprintf "test \"$HOME\" = %s || exit 94\n" (shell_quote expected));
      output_string
        output
        "test -z \"${XDG_CACHE_HOME+x}\" && test -z \"${XDG_CONFIG_HOME+x}\" && test -z \"${XDG_DATA_HOME+x}\" || exit 95\n")
    required_home;
  output_string output "cat >/dev/null\n";
  if sleep_s > 0.0 then output_string output (Printf.sprintf "sleep %.3f\n" sleep_s);
  List.iteri
    (fun index line ->
       Option.iter
         (fun seconds ->
            output_string output (Printf.sprintf "sleep %.3f\n" seconds))
         line_delay_s;
       if index = 1
       then
         Option.iter
           (fun seconds ->
              output_string output (Printf.sprintf "sleep %.3f\n" seconds))
           after_first_line_delay_s;
       output_string output ("printf '%s\\n' " ^ shell_quote line ^ "\n"))
    lines;
  (* The two #28912 shutdown shapes: a background child inheriting stdout
     (so EOF never arrives even though the CLI exits), and the CLI itself
     stalling before exit. *)
  Option.iter
    (fun seconds -> output_string output (Printf.sprintf "sleep %.3f &\n" seconds))
    stdout_holder_s;
  Option.iter
    (fun seconds -> output_string output (Printf.sprintf "sleep %.3f\n" seconds))
    exit_delay_s;
  output_string output (Printf.sprintf "exit %d\n" exit_code);
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let with_fixture ?require_resume ?required_home ?sleep_s ?line_delay_s
    ?after_first_line_delay_s ?stdout_holder_s ?exit_delay_s ?exit_code lines f =
  let path =
    fixture_script
      ?require_resume
      ?required_home
      ?sleep_s
      ?line_delay_s
      ?after_first_line_delay_s
      ?stdout_holder_s
      ?exit_delay_s
      ?exit_code
      lines
  in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let run_fixture
    ?conversation_mode
    ?home_dir
    ?on_conversation_ready
    ?on_stream_event
    ?(timeout_s = 2.0)
    ?admission_timeout_s
    ?(no_turn_deadline = false)
    ?(prompt = "Return the fixture marker")
    path
  =
  Eio_main.run (fun env ->
    let config =
      { (Runtime_antigravity.default_config ~cwd:"/tmp" ~model:"gemini-fixture") with
        cli_path = path
      ; admission_timeout_s = Option.value admission_timeout_s ~default:timeout_s
      ; timeout_s = if no_turn_deadline then None else Some timeout_s
      }
    in
    Runtime_antigravity.run_turn
      ?conversation_mode
      ?home_dir
      ?on_conversation_ready
      ?on_stream_event
      ~mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env)
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
      config
      ~prompt)
;;

(* The CLI restates the conversation id in step_update and result. When it
   leaves that restatement blank, the turn used to die at attempt=1 with
   [field "conversation_id" must not be empty] -- 110 turns over five days
   across three keepers. The id the turn carries comes from init, and a blank
   restatement makes no claim, so the turn completes. The check itself is not
   gone: a restatement that names a different conversation still fails. *)
let result_without_conversation_id
      ?(status = "SUCCESS")
      ?(response = "MASC_ANTIGRAVITY_OK\n")
      ?(num_turns = 1)
      ()
  =
  Printf.sprintf
    {|{"event":"result","result":{"status":%S,"response":%S,"duration_seconds":5.5,"num_turns":%d,"usage":{"input_tokens":100,"output_tokens":7,"thinking_tokens":3,"cache_read_tokens":50,"total_tokens":107}}}|}
    status
    response
    num_turns
;;

let test_blank_result_conversation_id_completes_the_turn () =
  with_fixture
    [ init (); result ~conversation_id:"" () ]
    (fun path ->
       match run_fixture path with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok turn ->
         check string "identity still comes from init" "conversation-1"
           turn.conversation_id;
         check string "text" "MASC_ANTIGRAVITY_OK\n" turn.text)
;;

let test_missing_result_conversation_id_completes_the_turn () =
  with_fixture
    [ init (); result_without_conversation_id () ]
    (fun path ->
       match run_fixture path with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok turn ->
         check string "identity still comes from init" "conversation-1"
           turn.conversation_id)
;;

let test_blank_step_conversation_id_completes_the_turn () =
  with_fixture
    [ init (); step ~conversation_id:"" (); result () ]
    (fun path ->
       match run_fixture path with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok turn ->
         check string "identity still comes from init" "conversation-1"
           turn.conversation_id)
;;

let test_a_restated_mismatch_still_fails () =
  with_fixture
    [ init (); result ~conversation_id:"another-conversation" () ]
    (fun path ->
       match run_fixture path with
       | Ok _ -> fail "a restated identity that disagrees with init must fail"
       | Error (Runtime_antigravity.Protocol_error { stage; detail }) ->
         check string "stage" "result event" stage;
         check bool "detail names the mismatch" true
           (let needle = "conversation identity mismatch" in
            let rec found i =
              i + String.length needle <= String.length detail
              && (String.sub detail i (String.length needle) = needle
                  || found (i + 1))
            in
            found 0)
       | Error error -> fail (Runtime_antigravity.error_to_string error))
;;

let test_stream_events_preserve_available_wire_data () =
  let events = ref [] in
  with_fixture
    [ init (); result () ]
    (fun path ->
       match
         run_fixture
           ~on_stream_event:(fun event -> events := event :: !events)
           path
       with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ ->
         match List.rev !events with
         | [ Runtime_antigravity.Turn_started
               { conversation_id = "conversation-1"
               ; model = "gemini-fixture"
               }
           ; Text_delta "MASC_ANTIGRAVITY_OK\n"
           ; Turn_finished { text = "MASC_ANTIGRAVITY_OK\n" }
           ] -> ()
         | _ -> fail "Antigravity stream did not preserve available wire data")
;;

let test_successful_official_client_turn () =
  with_fixture
    [ init ()
    ; step ~index:0 ~step_type:"user_input" ()
    ; step ~index:1 ~step_type:"unknown" ()
    ; step ~index:2 ~step_type:"agent_response" ()
    ; step ~index:3 ~step_type:"system_message" ()
    ; step ~index:4 ~step_type:"checkpoint" ()
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

let test_large_prompt_streams_over_stdin () =
  let prompt = String.make 1_100_000 'x' in
  with_fixture [ init (); result () ] (fun path ->
    match run_fixture ~prompt path with
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok turn ->
      check string "response" "MASC_ANTIGRAVITY_OK\n" turn.text;
      check int "turn count" 1 turn.num_turns)
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
    ~require_resume:true
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

(* Live wire from agy 1.1.12 (2026-08-25): an invocation the CLI refuses
   produces this single line and nothing else. Before the fix MASC reported
   [field "conversation_id" must not be empty] and the vendor's own account of
   the refusal never reached an operator. *)
let cli_rejection_error =
  "invalid model selection (--model \"gemini-3.7-flash\" --effort \"\"): \
   --model gemini-3.7-flash requires --effort (available: low, medium, high)"
;;

let test_pre_init_error_result_carries_the_cli_reason () =
  with_fixture
    [ result
        ~conversation_id:""
        ~status:"ERROR"
        ~response:""
        ~error:cli_rejection_error
        ~num_turns:0
        ()
    ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Turn_failed detail) ->
         check string "cli reason" cli_rejection_error detail
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a refused invocation completed a turn")
;;

let test_pre_init_success_result_stays_a_protocol_error () =
  with_fixture
    [ result ~conversation_id:"" () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Protocol_error _) -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a success without init was admitted")
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

let test_callback_timeout_origin_is_preserved_without_deadline () =
  with_fixture [ init (); result () ] (fun path ->
    check_raises
      "callback-origin timeout escapes unchanged"
      Eio.Time.Timeout
      (fun () ->
         Eio_main.run (fun env ->
           let config =
             { (Runtime_antigravity.default_config
                  ~cwd:"/tmp"
                  ~model:"gemini-fixture") with
               cli_path = path
             ; timeout_s = None
             }
           in
           Runtime_antigravity.run_turn
             ~mgr:(Eio.Stdenv.process_mgr env)
             ~clock:(Eio.Stdenv.clock env)
             ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
             ~on_conversation_ready:(fun ~conversation_id:_ -> raise Eio.Time.Timeout)
             config
             ~prompt:"fixture"
           |> ignore)))
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

(* The CLI marks the whole result ERROR when any trajectory step errored,
   even a tool call the model corrected and went on from (analyst,
   2026-08-22T01:39Z: rejection, retry 3s later, post created, reply
   written, status=ERROR). A reply means the turn completed. *)
let test_error_result_with_reply_completes_the_turn () =
  with_fixture
    ~exit_code:1
    [ init ()
    ; step ~index:1 ~state:"ACTIVE" ~step_type:"tool" ()
    ; step ~index:1 ~state:"ERROR" ~step_type:"tool" ()
    ; step ~index:2 ~state:"ACTIVE" ~step_type:"tool" ()
    ; step ~index:2 ~state:"DONE" ~step_type:"tool" ()
    ; result
        ~status:"ERROR"
        ~response:"Posted the summary to the board.\n"
        ~error:"Tool 'masc_board_post' received unsupported field(s): agent"
        ()
    ]
    (fun path ->
       match run_fixture path with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok turn ->
         check string "reply kept" "Posted the summary to the board.\n" turn.text;
         check int "tool errors counted" 1 turn.tool_errors;
         check
           (option string)
           "step error carried"
           (Some "Tool 'masc_board_post' received unsupported field(s): agent")
           turn.trajectory_error)
;;

let test_error_result_without_reply_fails_the_turn () =
  with_fixture
    ~exit_code:1
    [ init (); result ~status:"ERROR" ~response:" \n" ~error:"cortex unavailable" () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Turn_failed "cortex unavailable") -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "ERROR result without a reply was admitted as a completed turn")
;;

let test_success_with_blank_response_is_not_success () =
  with_fixture
    [ init (); result ~response:" \n\t" () ]
    (fun path ->
       match run_fixture path with
       | Error
           (Runtime_antigravity.Turn_failed
              "successful result response has no deliverable content") ->
         ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "blank SUCCESS result was admitted as a completed turn")
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
   Recovery_required -- fixture-keeper, 110 turns in one hour (#28008).

   Nothing branches on [permission_mode]: the only read of the field is its own
   parse site. Naming the one member that stalled a keeper leaves the next one
   to stall it again, so an unseen mode is carried in
   [Unrecognized_permission_mode] -- the drift stays visible without ending a
   turn. *)
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
    ; ( "supervised-2027"
      , Runtime_antigravity.Unrecognized_permission_mode "supervised-2027" )
    ]
;;

(* #28029 opened step_type with [Unrecognized] after Antigravity began emitting
   "system_message" and fixture-keeper stopped. #28037 closed it again and named
   [System_message] instead -- which admits the value that already stalled a
   keeper and leaves the next one to stall it again. Nothing branches on
   [System_message]: it appears at its declaration and at the parse site only.

   This is the control for reopening it: a step_type no one has seen must not
   end the turn.

   It does not check that the value survives, because nothing surfaces it --
   [step_type] is not in [turn_result], and every non-[Tool] value feeds the
   same counters. Normalising an unseen value to [Internal] passes this test,
   verified by mutation. [Unrecognized] is still the better carrier: it keeps a
   future consumer from reading an unseen value as a known one. But "the drift
   stays visible" is not true today, and no test here can make it so. *)
let test_unseen_step_type_does_not_end_the_turn () =
  with_fixture
    [ init (); step ~step_type:"shell" (); result () ]
    (fun path ->
       match run_fixture path with
       | Ok _ -> ()
       | Error error ->
         fail ("an unseen step_type ended the turn: "
               ^ Runtime_antigravity.error_to_string error))
;;

let test_unknown_protocol_vocabulary_fails_closed () =
  (* step_type left this list in #28027 and permission_mode followed: both are
     vocabularies nothing branches on, so an unseen value carries no ambiguity
     to fail closed over (see [test_observed_permission_modes_are_admitted] and
     [test_unseen_step_type_does_not_end_the_turn]).

     step state and result status stay: [Done] vs [Step_error] and [Success] vs
     [Result_error] each select a different terminal outcome, so a value we
     cannot place is a real ambiguity. *)
  let cases =
    [ "step state", [ init (); step ~state:"PAUSED" (); result () ]
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

let test_progress_resets_stream_idle_timeout () =
  with_fixture
    ~line_delay_s:0.4
    [ init (); step ~index:1 (); result () ]
    (fun path ->
       match run_fixture ~timeout_s:0.75 path with
       | Ok turn ->
         check string "progressing turn completes" "MASC_ANTIGRAVITY_OK\n" turn.text
       | Error error -> fail (Runtime_antigravity.error_to_string error))
;;

let test_stream_idle_timeout_is_typed () =
  with_fixture
    ~sleep_s:1.0
    [ init (); result () ]
    (fun path ->
       match run_fixture ~timeout_s:0.05 path with
       | Error (Runtime_antigravity.Timeout seconds) ->
         check (float 0.001) "exact idle timeout" 0.05 seconds
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "silent Antigravity stream ignored its idle timeout")
;;

let test_no_deadline_keeps_init_bounded () =
  with_fixture
    ~sleep_s:0.2
    [ init (); result () ]
    (fun path ->
       match
         run_fixture
           ~admission_timeout_s:0.05
           ~no_turn_deadline:true
           path
       with
       | Error (Runtime_antigravity.Timeout seconds) ->
         check (float 0.001) "admission timeout" 0.05 seconds
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "an unbounded turn disabled the Antigravity init bound")
;;

let test_no_deadline_starts_after_init () =
  with_fixture
    ~after_first_line_delay_s:0.2
    [ init (); result () ]
    (fun path ->
       match
         run_fixture
           ~admission_timeout_s:0.05
           ~no_turn_deadline:true
           path
       with
       | Ok turn ->
         check string "unbounded result" "MASC_ANTIGRAVITY_OK\n" turn.text
       | Error error -> fail (Runtime_antigravity.error_to_string error))
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
          ; timeout_s = Some 60.0
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

(* #28912 first shape: the CLI exits after the result but a background
   child inherited stdout, so EOF never arrives. Completion must come from
   the parsed result event, not from EOF. *)
let test_result_completes_even_when_stdout_stays_open () =
  with_fixture ~stdout_holder_s:10.0 [ init (); result () ] (fun path ->
    match run_fixture ~timeout_s:2.0 path with
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok turn ->
      check string "reply" "MASC_ANTIGRAVITY_OK\n" turn.Runtime_antigravity.text)
;;

(* #28912 second shape: the CLI itself never exits after the result
   ("Waiting for migrations to complete"). The bounded exit grace reaps it
   and the already-served turn still succeeds even though the process ends
   by signal. *)
let test_result_completes_when_the_cli_hangs_in_shutdown () =
  with_fixture ~exit_delay_s:15.0 [ init (); result () ] (fun path ->
    match run_fixture ~timeout_s:2.0 path with
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok turn ->
      check string "reply" "MASC_ANTIGRAVITY_OK\n" turn.Runtime_antigravity.text)
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
            "stream preserves available wire data"
            `Quick
            test_stream_events_preserve_available_wire_data
        ; test_case
            "resume identity and argv"
            `Quick
            test_resume_requires_exact_identity_and_argv
        ; test_case
            "large prompt uses stdin"
            `Quick
            test_large_prompt_streams_over_stdin
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
        ; test_case
            "callback timeout origin is preserved without deadline"
            `Quick
            test_callback_timeout_origin_is_preserved_without_deadline
        ; test_case "tool measurements" `Quick test_tool_steps_and_errors_are_measured
        ; test_case "error result" `Quick test_result_error_is_not_success
        ; test_case
            "error result with a reply completes"
            `Quick
            test_error_result_with_reply_completes_the_turn
        ; test_case
            "error result without a reply fails"
            `Quick
            test_error_result_without_reply_fails_the_turn
        ; test_case
            "blank success"
            `Quick
            test_success_with_blank_response_is_not_success
        ; test_case "duplicate keys" `Quick test_duplicate_keys_fail_closed
        ; test_case
            "observed permission modes are admitted"
            `Quick
            test_observed_permission_modes_are_admitted
        ; test_case
            "unseen step type does not end the turn"
            `Quick
            test_unseen_step_type_does_not_end_the_turn
        ; test_case
            "unknown protocol vocabulary fails closed"
            `Quick
            test_unknown_protocol_vocabulary_fails_closed
        ; test_case
            "progress resets stream idle timeout"
            `Quick
            test_progress_resets_stream_idle_timeout
        ; test_case
            "result completes despite an open stdout holder"
            `Quick
            test_result_completes_even_when_stdout_stays_open
        ; test_case
            "result completes despite a shutdown hang"
            `Quick
            test_result_completes_when_the_cli_hangs_in_shutdown
        ; test_case
            "stream idle timeout is typed"
            `Quick
            test_stream_idle_timeout_is_typed
        ; test_case
            "no deadline keeps init bounded"
            `Quick
            test_no_deadline_keeps_init_bounded
        ; test_case
            "no deadline starts after init"
            `Quick
            test_no_deadline_starts_after_init
        ; test_case
            "blank restated conversation id completes the turn"
            `Quick
            test_blank_result_conversation_id_completes_the_turn
        ; test_case
            "missing restated conversation id completes the turn"
            `Quick
            test_missing_result_conversation_id_completes_the_turn
        ; test_case
            "blank step conversation id completes the turn"
            `Quick
            test_blank_step_conversation_id_completes_the_turn
        ; test_case
            "a restated identity mismatch still fails"
            `Quick
            test_a_restated_mismatch_still_fails
        ; test_case "process-free admission" `Quick test_admission_is_process_free
        ; test_case
            "pre-init error result carries the CLI reason"
            `Quick
            test_pre_init_error_result_carries_the_cli_reason
        ; test_case
            "pre-init success result stays a protocol error"
            `Quick
            test_pre_init_success_result_stays_a_protocol_error
        ] )
    ; "live official client", [ test_case "official agy start and resume" `Slow test_live_start_and_resume ]
    ]
;;
