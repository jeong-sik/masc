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
    ?tool_name
    ?text_delta
    ()
  =
  let tool_name_field =
    match tool_name with
    | Some value -> Printf.sprintf ",\"tool_name\":%S" value
    | None -> ""
  in
  let text_delta_field =
    match text_delta with
    | Some value -> Printf.sprintf ",\"text_delta\":%S" value
    | None -> ""
  in
  Printf.sprintf
    {|{"event":"step_update","step_update":{"conversation_id":%S,"step_index":%d,"state":%S,"step_type":%S%s%s}}|}
    conversation_id
    index
    state
    step_type
    tool_name_field
    text_delta_field
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

(* What the fixture does with the prompt on stdin. [Close_unread] hangs up on
   it; [Leave_unread] answers with the prompt still sitting in the pipe, which
   is what a write outside the lane's window waits on forever. *)
type fixture_stdin =
  | Read_to_end
  | Close_unread
  | Leave_unread

(* [line_delays]: seconds the fixture sleeps before printing the line at that
   index, so one gap can be placed inside or after a chosen step. *)
let fixture_script
    ?(require_resume = false)
    ?required_home
    ?(sleep_s = 0.0)
    ?capture_prompt
    ?(stdin = Read_to_end)
    ?line_delay_s
    ?(line_delays = [])
    ?pipe_holder_s
    ?exit_delay_s
    ?(stderr_line = "")
    ?(exit_code = 0)
    lines
  =
  let path = Filename.temp_file "masc-antigravity-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  (* A line the fixture shouts on its own stderr, so a test can pin what the
     runtime's stderr tail carried into an error detail. *)
  if stderr_line <> "" then
    output_string output (Printf.sprintf "echo %s >&2\n" (shell_quote stderr_line));
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
  (match stdin with
   | Close_unread -> output_string output "exec 0<&-\nexit 62\n"
   | Leave_unread -> ()
   | Read_to_end ->
     output_string output
       (match capture_prompt with
        | None -> "cat >/dev/null\n"
        | Some path -> "cat >" ^ shell_quote path ^ "\n"));
  if sleep_s > 0.0 then output_string output (Printf.sprintf "sleep %.3f\n" sleep_s);
  List.iteri
    (fun index line ->
       Option.iter
         (fun seconds ->
            output_string output (Printf.sprintf "sleep %.3f\n" seconds))
         line_delay_s;
       Option.iter
         (fun seconds ->
            output_string output (Printf.sprintf "sleep %.3f\n" seconds))
         (List.assoc_opt index line_delays);
       (* The first #28912 shutdown shape: a background child inheriting
          stdout and stderr, so EOF never arrives on either pipe even though
          the CLI exits. It starts before the last line so the race with the
          runtime's termination cannot skip it. *)
       if index = List.length lines - 1
       then
         Option.iter
           (fun seconds ->
              output_string output (Printf.sprintf "sleep %.3f &\n" seconds))
           pipe_holder_s;
       output_string output ("printf '%s\\n' " ^ shell_quote line ^ "\n"))
    lines;
  (* The second #28912 shutdown shape: the CLI itself stalling before exit. *)
  Option.iter
    (fun seconds -> output_string output (Printf.sprintf "sleep %.3f\n" seconds))
    exit_delay_s;
  output_string output (Printf.sprintf "exit %d\n" exit_code);
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let with_fixture ?require_resume ?required_home ?sleep_s ?capture_prompt ?stdin ?line_delay_s
    ?line_delays ?pipe_holder_s ?exit_delay_s ?stderr_line ?exit_code lines f =
  let path =
    fixture_script
      ?require_resume
      ?required_home
      ?sleep_s
      ?capture_prompt
      ?stdin
      ?line_delay_s
      ?line_delays
      ?pipe_holder_s
      ?exit_delay_s
      ?stderr_line
      ?exit_code
      lines
  in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let run_fixture
    ?conversation_mode
    ?home_dir
    ?on_conversation_ready
    ?on_prompt_sent
    ?on_spawned
    ?on_stream_event
    ?(timeout_s = 2.0)
    ?admission_timeout_s
    ?(no_turn_deadline = false)
    ?wall_clock_ceiling_s
    ?(prompt = "Return the fixture marker")
    path
  =
  Eio_main.run (fun env ->
    let config =
      { (Runtime_antigravity.default_config ~cwd:"/tmp" ~model:"gemini-fixture") with
        cli_path = path
      ; admission_timeout_s = Option.value admission_timeout_s ~default:timeout_s
      ; timeout_s = if no_turn_deadline then None else Some timeout_s
      ; wall_clock_ceiling_s
      }
    in
    Runtime_antigravity.run_turn
      ?conversation_mode
      ?home_dir
      ?on_conversation_ready
      ?on_prompt_sent
      ?on_spawned
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
           ; Text_delta { step_index = None; text = "MASC_ANTIGRAVITY_OK\n" }
           ; Usage_reported
               { model = "gemini-fixture"
               ; usage = { input_tokens = 100; output_tokens = 7; _ }
               ; _
               }
           ; Turn_finished { text = "MASC_ANTIGRAVITY_OK\n" }
           ] -> ()
         | _ -> fail "Antigravity stream did not preserve available wire data")
;;

(* agy carries the answer on the agent_response steps as the model writes it
   (measured 2026-09-18, agy 1.2.6), and the result event then repeats the
   whole thing. Both reaching the reader would print the answer twice, so the
   pieces go out as they arrive and the result adds nothing. The stream above
   with no piece at all is the other half of this: there the result is the
   only account of the answer and still goes out. *)
let test_answer_pieces_reach_the_reader_and_the_result_adds_nothing () =
  let events = ref [] in
  with_fixture
    [ init ()
    ; step ~index:1 ~state:"ACTIVE" ~step_type:"agent_response" ~text_delta:"PO" ()
    ; step ~index:1 ~state:"DONE" ~step_type:"agent_response" ~text_delta:"NG\n" ()
    ; result ~response:"PONG\n" ()
    ]
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
               { conversation_id = "conversation-1"; model = "gemini-fixture" }
           ; Text_delta { step_index = Some 1; text = "PO" }
           ; Text_delta { step_index = Some 1; text = "NG\n" }
           ; Usage_reported
               { model = "gemini-fixture"
               ; usage = { input_tokens = 100; output_tokens = 7; _ }
               ; _
               }
           ; Turn_finished { text = "PONG\n" }
           ] -> ()
         | _ ->
           fail "Antigravity answer pieces did not reach the reader exactly once")
;;

(* An empty piece says nothing, and forwarding it would make a reader show a
   delta that carries no character. *)
let test_an_empty_piece_is_not_forwarded () =
  let events = ref [] in
  with_fixture
    [ init ()
    ; step ~index:1 ~state:"ACTIVE" ~step_type:"agent_response" ~text_delta:"" ()
    ; result ~response:"PONG\n" ()
    ]
    (fun path ->
       match
         run_fixture
           ~on_stream_event:(fun event -> events := event :: !events)
           path
       with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ ->
         match List.rev !events with
         | [ Runtime_antigravity.Turn_started _
           ; Text_delta { step_index = None; text = "PONG\n" }
           ; Usage_reported
               { model = "gemini-fixture"
               ; usage = { input_tokens = 100; output_tokens = 7; _ }
               ; _
               }
           ; Turn_finished { text = "PONG\n" }
           ] -> ()
         | _ -> fail "An empty piece changed what the reader was shown")
;;

(* Two response steps around a tool step, as agy 1.2.11 wrote them
   (measured 2026-09-25): each response step ends its text with "\n", and the
   result repeats both steps' text. *)
let two_response_steps =
  [ init ()
  ; step ~index:0 ~step_type:"user_input" ()
  ; step ~index:1 ~state:"ACTIVE" ~step_type:"agent_response" ~text_delta:"CHECKING" ()
  ; step ~index:1 ~state:"DONE" ~step_type:"agent_response" ~text_delta:"\n" ()
  ; step ~index:2 ~state:"ACTIVE" ~step_type:"tool" ~tool_name:"run_command" ()
  ; step ~index:2 ~state:"DONE" ~step_type:"tool" ~tool_name:"run_command" ()
  ; step ~index:3 ~state:"ACTIVE" ~step_type:"agent_response" ~text_delta:"DONE" ()
  ; step ~index:3 ~state:"DONE" ~step_type:"agent_response" ~text_delta:"\n" ()
  ; result ~response:"CHECKING\nDONE\n" ()
  ]
;;

(* Each piece names the step that carried it: that is what tells the two
   assistant messages apart. *)
let test_answer_pieces_name_their_step () =
  let events = ref [] in
  with_fixture two_response_steps (fun path ->
    match run_fixture ~on_stream_event:(fun event -> events := event :: !events) path with
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok turn ->
      check string "recorded text" "CHECKING\nDONE\n" turn.text;
      let pieces =
        List.filter_map
          (function
            | Runtime_antigravity.Text_delta { step_index; text } -> Some (step_index, text)
            | Turn_started _ | Native_tool_started _ | Native_tool_finished _
            | Usage_reported _ | Turn_finished _ -> None)
          (List.rev !events)
      in
      check
        (list (pair (option int) string))
        "pieces and their steps"
        [ Some 1, "CHECKING"; Some 1, "\n"; Some 3, "DONE"; Some 3, "\n" ]
        pieces)
;;

(* The Keeper live stream appends the pieces, and a native tool step draws no
   row between them, so the two steps read as one paragraph on a Markdown
   surface. The projection completes a paragraph break in front of the second
   step: agy already ended the first with "\n", so one more. Nothing repeats,
   and the result adds nothing because the steps carried the text. *)
let test_keeper_streams_two_response_steps_apart () =
  let events = ref [] in
  with_fixture two_response_steps (fun path ->
    match run_fixture ~on_stream_event:(fun event -> events := event :: !events) path with
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok _ ->
      let texts =
        Keeper_antigravity_runtime.For_testing.project_stream (List.rev !events)
        |> List.filter_map (function
          | Agent_core.Types.ContentBlockDelta
              { index = 0; delta = Agent_core.Types.TextDelta text } -> Some text
          | _ -> None)
      in
      check (list string) "pieces with the break" [ "CHECKING"; "\n"; "\nDONE"; "\n" ] texts;
      check string "each step once, apart" "CHECKING\n\nDONE\n" (String.concat "" texts))
;;

let describe_keeper_event = function
  | Agent_core.Types.MessageStart { id; model; usage = None } ->
    Printf.sprintf "start %s %s" id model
  | Agent_core.Types.MessageStart { usage = Some _; _ } -> "start with usage"
  | Agent_core.Types.ContentBlockStart { index; content_type; tool_id; tool_name } ->
    Printf.sprintf
      "block %d %s %s %s"
      index
      content_type
      (Option.value tool_id ~default:"-")
      (Option.value tool_name ~default:"-")
  | Agent_core.Types.ContentBlockDelta
      { index; delta = Agent_core.Types.InputJsonSnapshot arguments } ->
    Printf.sprintf "arguments %d %s" index arguments
  | Agent_core.Types.ContentBlockDelta { index; delta = Agent_core.Types.TextDelta text } ->
    Printf.sprintf "text %d %S" index text
  | Agent_core.Types.ContentBlockDelta { index; _ } -> Printf.sprintf "other delta %d" index
  | Agent_core.Types.ContentBlockStop { index } -> Printf.sprintf "stop %d" index
  | Agent_core.Types.MessageDelta
      { stop_reason = Some Agent_core.Types.EndTurn; usage = None } -> "end turn"
  | Agent_core.Types.MessageDelta _ -> "other message delta"
  | Agent_core.Types.MessageStop -> "message stop"
  | _ -> "other"
;;

let mcp_probe_call call_id =
  Keeper_antigravity_runtime.For_testing.Mcp_tool_started
    { call_id; tool_name = "masc_probe"; arguments = `Assoc [ "marker", `String call_id ] }
;;

let antigravity_turn_started =
  Keeper_antigravity_runtime.For_testing.Cli_event
    (Runtime_antigravity.Turn_started
       { conversation_id = "conversation-1"; model = "gemini-fixture" })
;;

let antigravity_turn_finished =
  Keeper_antigravity_runtime.For_testing.Cli_event
    (Runtime_antigravity.Turn_finished { text = "" })
;;

(* #37118: agy prints init before it calls a MASC tool, but the MCP server
   can answer the call while init is still writing the session. The call's
   blocks come after MessageStart, in the order they were answered. *)
let test_keeper_mcp_blocks_follow_message_start () =
  let events =
    Keeper_antigravity_runtime.For_testing.project_stream_inputs
      ~during:(fun _ -> [])
      [ mcp_probe_call "call-1"
      ; Keeper_antigravity_runtime.For_testing.Mcp_tool_finished { call_id = "call-1" }
      ; antigravity_turn_started
      ; mcp_probe_call "call-2"
      ; Keeper_antigravity_runtime.For_testing.Mcp_tool_finished { call_id = "call-2" }
      ; antigravity_turn_finished
      ]
  in
  check
    (list string)
    "message first, then each call in order"
    [ "start conversation-1:ordinal:1 gemini-fixture"
    ; "block 1 tool_use call-1 masc_probe"
    ; {|arguments 1 {"marker":"call-1"}|}
    ; "stop 1"
    ; "block 2 tool_use call-2 masc_probe"
    ; {|arguments 2 {"marker":"call-2"}|}
    ; "stop 2"
    ; "end turn"
    ; "message stop"
    ]
    (List.map describe_keeper_event events)
;;

(* Emitting can yield to the MCP server's fiber. A call answered while the
   held blocks go out waits behind them, so no block is emitted before its
   own start. *)
let test_keeper_mcp_blocks_answered_while_releasing_wait_their_turn () =
  let events =
    Keeper_antigravity_runtime.For_testing.project_stream_inputs
      ~during:(function
        | Agent_core.Types.MessageStart _ -> [ mcp_probe_call "call-2" ]
        | Agent_core.Types.ContentBlockStart { tool_id = Some "call-2"; _ } ->
          [ Keeper_antigravity_runtime.For_testing.Mcp_tool_finished { call_id = "call-2" } ]
        | Agent_core.Types.ContentBlockStart { tool_id = Some "call-1"; _ } ->
          [ Keeper_antigravity_runtime.For_testing.Mcp_tool_finished { call_id = "call-1" } ]
        | _ -> [])
      [ mcp_probe_call "call-1"; antigravity_turn_started; antigravity_turn_finished ]
  in
  check
    (list string)
    "each block after its own start"
    [ "start conversation-1:ordinal:1 gemini-fixture"
    ; "block 1 tool_use call-1 masc_probe"
    ; {|arguments 1 {"marker":"call-1"}|}
    ; "block 2 tool_use call-2 masc_probe"
    ; {|arguments 2 {"marker":"call-2"}|}
    ; "stop 1"
    ; "stop 2"
    ; "end turn"
    ; "message stop"
    ]
    (List.map describe_keeper_event events)
;;

let test_stream_events_preserve_exact_native_tool_steps () =
  let events = ref [] in
  with_fixture
    [ init ()
    ; step ~index:7 ~state:"ACTIVE" ~step_type:"tool" ~tool_name:"run_command" ()
    ; step ~index:7 ~state:"DONE" ~step_type:"tool" ~tool_name:"run_command" ()
    ; result ()
    ]
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
               { conversation_id = "conversation-1"; model = "gemini-fixture" }
           ; Native_tool_started
               { identity =
                   Some
                     (Runtime_native_tools.Provider_step
                        { conversation_id = "conversation-1"; step_index = 7 })
               ; tool_name = Some "run_command"
               ; origin = Runtime_native_tools.Built_in
               }
           ; Native_tool_finished
               { identity =
                   Some
                     (Runtime_native_tools.Provider_step
                        { conversation_id = "conversation-1"; step_index = 7 })
               ; tool_name = Some "run_command"
               ; origin = Runtime_native_tools.Built_in
               }
           ; Text_delta { step_index = None; text = "MASC_ANTIGRAVITY_OK\n" }
           ; Usage_reported
               { model = "gemini-fixture"
               ; usage = { input_tokens = 100; output_tokens = 7; _ }
               ; _
               }
           ; Turn_finished { text = "MASC_ANTIGRAVITY_OK\n" }
           ] -> ()
         | _ -> fail "Antigravity tool step lost its exact provider identity")
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
  let captured = Filename.temp_file "antigravity-prompt-" ".txt" in
  Fun.protect ~finally:(fun () -> Sys.remove captured) (fun () ->
    let sent = ref 0 in
    with_fixture ~capture_prompt:captured [ init (); result () ] (fun path ->
      match run_fixture ~prompt ~on_prompt_sent:(fun () -> incr sent) path with
      | Error error -> fail (Runtime_antigravity.error_to_string error)
      | Ok turn ->
        check string "response" "MASC_ANTIGRAVITY_OK\n" turn.text;
        check int "turn count" 1 turn.num_turns;
        check int "one complete prompt transmission" 1 !sent;
        check string "client received exact complete prompt" prompt
          (In_channel.with_open_bin captured In_channel.input_all)))
;;

let test_incomplete_prompt_is_not_reported () =
  let sent = ref 0 in
  let spawned = ref 0 in
  let missing = Filename.temp_file "missing-antigravity-" ".sh" in
  Sys.remove missing;
  (match run_fixture ~on_prompt_sent:(fun () -> incr sent) missing with
   | Error (Runtime_antigravity.Spawn_failed _) -> ()
   | _ -> fail "missing CLI did not fail at spawn");
  check int "spawn failure does not report transmission" 0 !sent;
  with_fixture ~stdin:Close_unread [] (fun path ->
    (* Larger than the pipe buffer: the child closes stdin without consuming
       it, so a successful spawn cannot imply a complete prompt write. *)
    let result = run_fixture ~prompt:(String.make 1_100_000 'x')
      ~on_spawned:(fun () -> incr spawned)
      ~on_prompt_sent:(fun () -> incr sent) path in
    check int "write failure occurs after real spawn" 1 !spawned;
    check bool "incomplete input does not complete a turn" true (Result.is_error result);
    check int "partial write does not report transmission" 0 !sent)
;;

let test_a_cli_that_answers_without_reading_the_prompt_does_not_hold_the_turn () =
  (* The CLI never reads stdin and lingers after answering, so a prompt past
     the pipe buffer is still in the pipe when the answer arrives. The turn
     ends on the lane's own admission window; before it covered the write, it
     ended only when the CLI finally left. *)
  let ready = ref false in
  with_fixture ~stdin:Leave_unread ~exit_delay_s:5.0 [ init (); result () ] (fun path ->
    match
      run_fixture
        ~prompt:(String.make 1_100_000 'x')
        ~admission_timeout_s:0.5
        ~timeout_s:5.0
        ~on_conversation_ready:(fun ~conversation_id:_ ->
          ready := true;
          Ok ())
        path
    with
    | Error (Runtime_antigravity.Timeout seconds) ->
      check bool "the CLI had answered while the prompt was still in the pipe" true !ready;
      check (float 0.001) "the window is the lane's admission window" 0.5 seconds
    | Error error ->
      fail
        ("an unread prompt ended the turn some other way: "
         ^ Runtime_antigravity.error_to_string error)
    | Ok _ -> fail "an unread prompt produced a completed turn")
;;

let test_transmitted_prompt_survives_provider_rejection () =
  let sent = ref 0 in
  with_fixture [ init (); result ~status:"ERROR" ~response:"" ~error:"fixture rejected" () ]
    (fun path ->
      let result = run_fixture ~on_prompt_sent:(fun () -> incr sent) path in
      (match result with
       | Error (Runtime_antigravity.Turn_failed "fixture rejected") -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "provider rejection became a completed response");
      check int "transmission is retained despite provider rejection" 1 !sent)
;;

(* The result event of a refused turn still carries the conversation's
   usage, and it is reported before the refusal fails the turn. *)
let test_refused_result_still_reports_usage () =
  let reported = ref [] in
  let on_stream_event = function
    | Runtime_antigravity.Usage_reported { model; usage; _ } ->
      reported := (model, usage.input_tokens, usage.cache_read_tokens) :: !reported
    | Turn_started _ | Text_delta _ | Native_tool_started _ | Native_tool_finished _
    | Turn_finished _ -> ()
  in
  with_fixture [ init (); result ~status:"ERROR" ~response:"" ~error:"fixture rejected" () ]
    (fun path ->
      (match run_fixture ~on_stream_event path with
       | Error (Runtime_antigravity.Turn_failed "fixture rejected") -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "provider rejection became a completed response");
      match !reported with
      | [ ("gemini-fixture", 100, 50) ] -> ()
      | reports ->
        failf "expected the refused result's usage reported once, got %d"
          (List.length reports))
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

let test_operator_interrupt_callback_keeps_typed_cause () =
  with_fixture [ init (); result () ] (fun path ->
    let interrupt = Keeper_registry_types.Operator_interrupt in
    let backtrace = Printexc.get_callstack 0 in
    let combined = Eio.Exn.Multiple
      [ (Eio.Cancel.Cancelled interrupt, backtrace)
      ; (Stdlib.Fun.Finally_raised (Eio.Cancel.Cancelled interrupt), backtrace) ] in
    let raised =
      try
        Eio_main.run (fun env ->
          let config = { (Runtime_antigravity.default_config
            ~cwd:"/tmp" ~model:"gemini-fixture") with
            cli_path = path; timeout_s = None } in
          Runtime_antigravity.run_turn
            ~mgr:(Eio.Stdenv.process_mgr env)
            ~clock:(Eio.Stdenv.clock env)
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
            ~on_conversation_ready:(fun ~conversation_id:_ -> raise combined)
            config ~prompt:"fixture" |> ignore);
        None
      with exn -> Some exn in
    check bool "combined operator interrupt survives the Antigravity transport" true
      (Option.fold ~none:false ~some:Keeper_registry_types.is_operator_interrupt raised))
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
       | Error (Runtime_antigravity.Turn_failed detail) ->
         (* The diagnostic fields ride after the fixed rejection sentence, so
            downstream substring checks (keeper runtime tests) keep working. *)
         check bool "detail keeps the rejection sentence" true
           (String.starts_with
              ~prefix:"successful result response has no deliverable content"
              detail);
         check bool "detail names the model" true
           (String_util.contains_substring detail "model=gemini-fixture");
         check bool "detail reports zero tool steps" true
           (String_util.contains_substring detail "tool_steps=0");
         check bool "detail records an empty stderr" true
           (String_util.contains_substring detail "stderr=<empty>")
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "blank SUCCESS result was admitted as a completed turn")
;;

(* One tool step and a blank answer: the count, the model, and the fixture's
   stderr line must all arrive in the failure so an operator can tell a
   tool-only turn from a vendor-side empty success. *)
let test_empty_success_after_a_tool_step_carries_diagnostics () =
  with_fixture
    ~stderr_line:"antigravity: WARNING model streamed nothing"
    [ init ()
    ; step ~index:1 ~state:"ACTIVE" ~step_type:"tool" ()
    ; step ~index:1 ~state:"DONE" ~step_type:"tool" ()
    ; result ~response:"" () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Turn_failed detail) ->
         check bool "rejection sentence kept" true
           (String.starts_with
              ~prefix:"successful result response has no deliverable content"
              detail);
         check bool "model named" true
           (String_util.contains_substring detail "model=gemini-fixture");
         check bool "tool step counted" true
           (String_util.contains_substring detail "tool_steps=1");
         check bool "stderr tail carried" true
           (String_util.contains_substring detail "stderr tail: antigravity: WARNING model streamed nothing")
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "blank SUCCESS after a tool step was admitted")
;;

(* A Korean stderr line longer than the byte budget must come back cut at a
   character boundary, never with a torn Hangul character at its head
   (#39090 made String_util the SSOT for that rule). *)
let index_of_substring hay needle =
  let n = String.length hay and m = String.length needle in
  let rec go i =
    if i + m > n then None
    else if String.sub hay i m = needle then Some i
    else go (i + 1)
  in
  go 0
;;

let test_empty_success_stderr_tail_cuts_at_a_character_boundary () =
  let korean =
    "안녕하세요 검증 메시지입니다 " ^ String.concat "" (List.init 40 (fun _ -> "토큰"))
  in
  assert (String.length korean > 200);
  with_fixture
    ~stderr_line:korean
    [ init (); result ~response:"" () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Turn_failed detail) ->
         let rest =
           match index_of_substring detail "stderr tail: " with
           | Some i -> String.sub detail (i + String.length "stderr tail: ")
                        (String.length detail - i - String.length "stderr tail: ")
           | None -> fail "no stderr tail in the failure detail"
         in
         check bool "tail kept the last characters" true
           (String_util.contains_substring rest "토큰");
         check bool "tail dropped the line's head" true
           (not (String_util.contains_substring rest "안녕하세요"));
         check bool "tail cut at a character boundary" true
           (String.is_valid_utf_8 rest);
         check bool "tail stayed within the byte budget" true
           (String.length rest <= 200 + 1 (* closing paren *))
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "blank SUCCESS with a Korean stderr was admitted")
;;

(* A stderr line that echoes a credential must never reach an error detail.
   The whole line is replaced by a placeholder; unrelated diagnostics on
   their own lines survive byte-identical. *)
let test_stderr_tail_redacts_sensitive_lines () =
  let redacted = Runtime_antigravity.redact_stderr_tail in
  check string "no stderr means no detail change" "" (redacted "");
  check string "an Authorization header line is replaced wholesale" "[redacted]"
    (redacted "Authorization: Bearer ya29.aBcDeFgHi");
  check string "a home path line is replaced" "[redacted]"
    (redacted "spawn: /Users/dancer/bin/agy: no such file");
  check string "an api key line is replaced in any case" "[redacted]"
    (redacted "OPENAI_API_KEY=sk-s3cr3t");
  check string "a bearer line without a header prefix is replaced" "[redacted]"
    (redacted "bearer token leaked into the log");
  check string "plain diagnostic lines survive untouched"
    "antigravity: WARNING model streamed nothing"
    (redacted "antigravity: WARNING model streamed nothing");
  check string "only the sensitive line is replaced"
    "line1 stays\n[redacted]\nline3 stays"
    (redacted "line1 stays\nAuthorization: Bearer sk-9\nline3 stays")
;;

(* End to end: the 8KB Process_exited detail and the 200-byte empty-success
   tail share the same redaction point, so a fixture stderr carrying a
   credential produces a detail an operator can paste without leaking. *)
let test_process_exit_detail_masks_the_stderr_line () =
  with_fixture
    ~exit_code:1
    ~stderr_line:"Authorization: Bearer ya29.aBcDeFgHi"
    (* No result event: with a parsed result the blank-success arm would own
       this shape, so this fixture pins the bare process-exit path, whose
       detail is exactly the stderr tail. *)
    [ init () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Process_exited detail) ->
         check bool "detail carries the exit code" true
           (String.starts_with ~prefix:"exit code 1: " detail);
         check bool "detail masks the credential" true
           (String_util.contains_substring detail "[redacted]");
         check bool "detail never carries the token" true
           (not (String_util.contains_substring detail "ya29"))
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a blank result after a nonzero exit was admitted")
;;

(* The same redaction point owns the empty-success path (#39164): a blank
   result with a credential-bearing stderr must produce a Turn_failed
   detail the operator can paste without leaking. *)
let test_empty_success_detail_masks_the_stderr_line () =
  with_fixture
    ~stderr_line:"Authorization: Bearer ya29.aBcDeFgHi"
    [ init (); result ~response:"" () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Turn_failed detail) ->
         check bool
           "detail carries the empty-success prefix" true
           (String.starts_with
              ~prefix:"successful result response has no deliverable content"
              detail);
         check bool "detail masks the credential" true
           (String_util.contains_substring detail "[redacted]");
         check bool "detail never carries the token" true
           (not (String_util.contains_substring detail "ya29"))
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a blank result was admitted")
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

let test_wall_clock_ceiling_ends_a_dripping_turn () =
  (* Lines arrive inside every idle window (0.2s apart < 2.0s), so the idle
     timeout never fires; only the whole-turn ceiling can end this turn. *)
  with_fixture
    ~line_delay_s:0.2
    [ init ()
    ; step (); step (); step (); step (); step (); step ()
    ; step (); step (); step (); step (); step (); step ()
    ]
    (fun path ->
       match run_fixture ~timeout_s:2.0 ~wall_clock_ceiling_s:0.7 path with
       | Error (Runtime_antigravity.Timeout seconds) ->
         check bool
           "ceiling bounds the reported timeout"
           true
           (seconds > 0.0 && seconds <= 0.7)
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a dripping stream outlived the wall-clock ceiling")
;;

let test_wall_clock_ceiling_bounds_a_turn_without_idle_deadline () =
  (* [no_turn_deadline] leaves the idle timeout at [None]; the ceiling is
     still a deadline, so a silently held stdout cannot outlive it. *)
  with_fixture
    ~pipe_holder_s:5.0
    [ init () ]
    (fun path ->
       match
         run_fixture ~no_turn_deadline:true ~wall_clock_ceiling_s:0.3 path
       with
       | Error (Runtime_antigravity.Timeout seconds) ->
         check bool
           "ceiling bounds the reported timeout"
           true
           (seconds > 0.0 && seconds <= 0.3)
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "an unbounded silent turn outlived the wall-clock ceiling")
;;

(* #29230: hang-duration distribution. The two ceiling tests above prove
   single-shot bounds; this one measures the escape repeatedly and reports
   the observed wall-clock hang-duration distribution, so drift in *when*
   the ceiling ends a stuck turn (not just whether it does) shows up in CI.

   Measured value: elapsed wall time around run_turn, i.e. how long the
   turn actually stayed hung before the typed Timeout ended it. The
   [Timeout seconds] payload alone cannot serve here: it reports the idle
   window that expired, which for a dripping stream is the ceiling-capped
   remainder (small), not the hang duration. Two shapes mirror the 8/21
   field report: a stream that keeps dripping events (idle window never
   expires) and a silently held stdout with no idle deadline at all. *)
let test_wall_clock_ceiling_hang_duration_distribution () =
  let runs = 8 in
  let percentile p (a : float array) =
    let sorted = Array.copy a in
    Array.sort compare sorted;
    sorted.(int_of_float (float_of_int (Array.length sorted - 1) *. p))
  in
  let measure_one ?no_turn_deadline ~timeout_s ~ceiling_s path =
    let started = Unix.gettimeofday () in
    let outcome =
      run_fixture ?no_turn_deadline ~timeout_s ~wall_clock_ceiling_s:ceiling_s path
    in
    let elapsed = Unix.gettimeofday () -. started in
    (match outcome with
     | Error (Runtime_antigravity.Timeout _) -> ()
     | Error error -> fail (Runtime_antigravity.error_to_string error)
     | Ok _ -> fail "the turn completed; the hang escape never fired");
    elapsed
  in
  (* dripping: 0.2s lines inside a 2.0s idle window, ceiling 0.7s. Without
     the ceiling this shape runs to EOF (~2.4s) without ever tripping the
     idle deadline, so an elapsed under ~0.9s means the ceiling fired. *)
  let dripping = Array.init runs (fun _ ->
      with_fixture
        ~line_delay_s:0.2
        [ init ()
        ; step (); step (); step (); step (); step (); step ()
        ; step (); step (); step (); step (); step (); step ()
        ]
        (fun path -> measure_one ~timeout_s:2.0 ~ceiling_s:0.7 path)) in
  (* silent, no idle deadline: the ceiling is the only deadline *)
  let silent = Array.init runs (fun _ ->
      with_fixture
        ~pipe_holder_s:5.0
        [ init () ]
        (fun path ->
           measure_one ~no_turn_deadline:true ~timeout_s:2.0 ~ceiling_s:0.3 path)) in
  Printf.printf
    "#29230 hang-duration distribution (%d runs per shape)\n\
     | shape | runs | min | p50 | p90 | max | ceiling |\n\
     | dripping (idle 2.0s) | %d | %.3f | %.3f | %.3f | %.3f | 0.7 |\n\
     | silent (no idle deadline) | %d | %.3f | %.3f | %.3f | %.3f | 0.3 |\n%!"
    runs
    runs
    (percentile 0.0 dripping) (percentile 0.5 dripping)
    (percentile 0.9 dripping) (percentile 1.0 dripping)
    runs
    (percentile 0.0 silent) (percentile 0.5 silent)
    (percentile 0.9 silent) (percentile 1.0 silent);
  (* every run's hang must be bounded by its ceiling plus process-spawn
     slack (the ceiling clock starts after spawn; the measurement wraps
     run_turn, so it includes it) *)
  check bool
    "dripping hang duration stays under ceiling + spawn slack (all runs)"
    true
    (Array.for_all (fun s -> s > 0.0 && s <= 0.9) dripping);
  check bool
    "silent hang duration stays under ceiling + spawn slack (all runs)"
    true
    (Array.for_all (fun s -> s > 0.0 && s <= 0.5) silent)
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

(* A tool step that outlasts the idle window. The window is short and the gap
   several times longer, so a window that stayed armed through the step would
   fire long before the DONE update. Admission keeps a wide bound because the
   fixture's first line is not what is under test (#28919). *)
let tool_step_idle_window_s = 0.3
let tool_step_gap_s = 1.0
let tool_step_admission_s = 5.0

let test_tool_step_outlasting_the_idle_window_completes () =
  with_fixture
    ~line_delays:[ 2, tool_step_gap_s ]
    [ init ()
    ; step ~index:1 ~state:"ACTIVE" ~step_type:"tool" ~tool_name:"run_command" ()
    ; step ~index:1 ~state:"DONE" ~step_type:"tool" ~tool_name:"run_command" ()
    ; result ()
    ]
    (fun path ->
       match
         run_fixture
           ~timeout_s:tool_step_idle_window_s
           ~admission_timeout_s:tool_step_admission_s
           path
       with
       | Ok turn ->
         check string "tool step completed" "MASC_ANTIGRAVITY_OK\n" turn.text
       | Error error -> fail (Runtime_antigravity.error_to_string error))
;;

(* The same gap after the tool step has ended, whichever way it ended, is
   silence from the model turn again and the idle window ends it. *)
let test_idle_window_rearms_when_the_tool_step_ends () =
  List.iter
    (fun final_state ->
       with_fixture
         ~line_delays:[ 3, tool_step_gap_s ]
         [ init ()
         ; step ~index:1 ~state:"ACTIVE" ~step_type:"tool" ()
         ; step ~index:1 ~state:final_state ~step_type:"tool" ()
         ; result ()
         ]
         (fun path ->
            match
              run_fixture
                ~timeout_s:tool_step_idle_window_s
                ~admission_timeout_s:tool_step_admission_s
                path
            with
            | Error (Runtime_antigravity.Timeout seconds) ->
              check
                (float 0.001)
                (final_state ^ ": the idle window fired")
                tool_step_idle_window_s
                seconds
            | Error error ->
              fail (final_state ^ ": " ^ Runtime_antigravity.error_to_string error)
            | Ok _ ->
              fail
                (final_state
                 ^ ": silence after a finished tool step was not bounded")))
    [ "DONE"; "ERROR" ]
;;

(* A tool step with no end is bounded by the ceiling alone: the fixture goes
   silent inside the step and exits long after the ceiling. The ceiling sits
   above the idle window, so the budget the timeout reports tells which of the
   two ended the turn: an armed idle window reports exactly
   [tool_step_idle_window_s], the ceiling reports its larger remainder. *)
let test_wall_clock_ceiling_bounds_a_tool_step_that_never_ends () =
  let fixture_exit_delay_s = 10.0 in
  let ceiling_s = 1.0 in
  with_fixture
    ~exit_delay_s:fixture_exit_delay_s
    [ init (); step ~index:1 ~state:"ACTIVE" ~step_type:"tool" () ]
    (fun path ->
       let started = Unix.gettimeofday () in
       let outcome =
         run_fixture
           ~timeout_s:tool_step_idle_window_s
           ~admission_timeout_s:tool_step_admission_s
           ~wall_clock_ceiling_s:ceiling_s
           path
       in
       let elapsed = Unix.gettimeofday () -. started in
       match outcome with
       | Error (Runtime_antigravity.Timeout seconds) ->
         check bool
           "ceiling bounds the reported timeout"
           true
           (seconds > 0.0 && seconds <= ceiling_s);
         check bool
           "the ceiling, not the idle window, ended the turn"
           true
           (seconds > tool_step_idle_window_s);
         check bool
           "the turn ended at the ceiling, not when the fixture exited"
           true
           (elapsed < fixture_exit_delay_s)
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a tool step with no end outlived the wall-clock ceiling")
;;

let test_no_deadline_starts_after_init () =
  with_fixture
    ~line_delays:[ 1, 0.2 ]
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
    let effort =
      match Sys.getenv_opt "MASC_ANTIGRAVITY_EFFORT" with
      | None -> None
      | Some "low" -> Some Runtime_antigravity.Low
      | Some "medium" -> Some Runtime_antigravity.Medium
      | Some "high" -> Some Runtime_antigravity.High
      | Some value -> failf "invalid MASC_ANTIGRAVITY_EFFORT %S" value
    in
    let first, second =
      Eio_main.run (fun env ->
        let config =
          { (Runtime_antigravity.default_config ~cwd ~model) with
            cli_path
          ; effort
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
  with_fixture ~pipe_holder_s:10.0 [ init (); result () ] (fun path ->
    match run_fixture ~timeout_s:2.0 path with
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok turn ->
      check string "reply" "MASC_ANTIGRAVITY_OK\n" turn.Runtime_antigravity.text)
;;

(* The first shape, measured. The stderr drain used to be an ordinary fiber
   of the process switch, so a served turn waited for the background child to
   release stderr: 10 s in the test above, unbounded for an orphaned MCP
   server in production. [turn_return_window_s] bounds the whole measured
   run (Eio_main start, spawn, protocol, exit): spawning the shell measured
   p50 12 ms with a 409 ms tail under load on this repo's machine, and the
   regression it guards against takes the holder's full 20 s. *)
let turn_return_window_s = 5.0
let pipe_holder_outliving_the_turn_s = 20.0

let test_result_returns_before_a_background_child_releases_the_pipes () =
  with_fixture ~pipe_holder_s:pipe_holder_outliving_the_turn_s [ init (); result () ] (fun path ->
    let started = Unix.gettimeofday () in
    match run_fixture ~timeout_s:2.0 path with
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok turn ->
      let elapsed = Unix.gettimeofday () -. started in
      check string "reply" "MASC_ANTIGRAVITY_OK\n" turn.Runtime_antigravity.text;
      check bool
        (Printf.sprintf "turn returned in %.3fs, before the holder released the pipes" elapsed)
        true
        (elapsed < turn_return_window_s))
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
            "answer pieces reach the reader once"
            `Quick
            test_answer_pieces_reach_the_reader_and_the_result_adds_nothing
        ; test_case
            "an empty piece is not forwarded"
            `Quick
            test_an_empty_piece_is_not_forwarded
        ; test_case
            "answer pieces name their step"
            `Quick
            test_answer_pieces_name_their_step
        ; test_case
            "Keeper streams two response steps apart"
            `Quick
            test_keeper_streams_two_response_steps_apart
        ; test_case
            "Keeper MCP blocks follow MessageStart"
            `Quick
            test_keeper_mcp_blocks_follow_message_start
        ; test_case
            "Keeper MCP blocks answered while releasing wait their turn"
            `Quick
            test_keeper_mcp_blocks_answered_while_releasing_wait_their_turn
        ; test_case
            "stream preserves exact native tool steps"
            `Quick
            test_stream_events_preserve_exact_native_tool_steps
        ; test_case
            "resume identity and argv"
            `Quick
            test_resume_requires_exact_identity_and_argv
        ; test_case
            "large prompt uses stdin"
            `Quick
            test_large_prompt_streams_over_stdin
        ; test_case "incomplete prompt is not reported as transmitted" `Quick
            test_incomplete_prompt_is_not_reported
        ; test_case "a CLI that answers without reading the prompt does not hold the turn"
            `Quick test_a_cli_that_answers_without_reading_the_prompt_does_not_hold_the_turn
        ; test_case "transmission survives provider rejection" `Quick
            test_transmitted_prompt_survives_provider_rejection
        ; test_case "refused result still reports usage" `Quick
            test_refused_result_still_reports_usage
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
        ; test_case "operator interrupt callback keeps typed cause" `Quick
            test_operator_interrupt_callback_keeps_typed_cause
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
        ; test_case
            "blank success after a tool step carries diagnostics"
            `Quick
            test_empty_success_after_a_tool_step_carries_diagnostics
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
            "result returns before a background child releases the pipes"
            `Quick
            test_result_returns_before_a_background_child_releases_the_pipes
        ; test_case
            "result completes despite a shutdown hang"
            `Quick
            test_result_completes_when_the_cli_hangs_in_shutdown
        ; test_case
            "stream idle timeout is typed"
            `Quick
            test_stream_idle_timeout_is_typed
        ; test_case
            "wall-clock ceiling ends a dripping turn"
            `Quick
            test_wall_clock_ceiling_ends_a_dripping_turn
        ; test_case
            "wall-clock ceiling bounds a turn without idle deadline"
            `Quick
            test_wall_clock_ceiling_bounds_a_turn_without_idle_deadline
        ; test_case
            "tool step outlasting the idle window completes"
            `Quick
            test_tool_step_outlasting_the_idle_window_completes
        ; test_case
            "idle window re-arms when the tool step ends"
            `Quick
            test_idle_window_rearms_when_the_tool_step_ends
        ; test_case
            "wall-clock ceiling bounds a tool step that never ends"
            `Quick
            test_wall_clock_ceiling_bounds_a_tool_step_that_never_ends
        ; test_case
            "wall-clock ceiling hang-duration distribution"
            `Quick
            test_wall_clock_ceiling_hang_duration_distribution
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
        ; test_case
            "an empty success stderr tail cuts at a character boundary"
            `Quick
            test_empty_success_stderr_tail_cuts_at_a_character_boundary
        ; test_case
            "a stderr tail with credentials is redacted line by line"
            `Quick
            test_stderr_tail_redacts_sensitive_lines
        ; test_case
            "a process exit detail masks the stderr line"
            `Quick
            test_process_exit_detail_masks_the_stderr_line
        ; test_case
            "an empty success detail masks the stderr line"
            `Quick
            test_empty_success_detail_masks_the_stderr_line
        ] )
    ; "live official client", [ test_case "official agy start and resume" `Slow test_live_start_and_resume ]
    ]
;;
