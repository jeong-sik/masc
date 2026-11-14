(* A start of Antigravity, by the access the suite publishes first. *)
let antigravity_host () =
  Masc_test_deps.host_account Runtime_account_access.Antigravity

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
    ?denied_actions_json
    ?(num_turns = 1)
    ()
  =
  let error_field =
    match error with
    | None -> ""
    | Some value -> Printf.sprintf ",\"error\":%S" value
  in
  let denied_field =
    match denied_actions_json with
    | None -> ""
    | Some value -> Printf.sprintf ",\"denied_actions\":%s" value
  in
  Printf.sprintf
    {|{"event":"result","result":{"conversation_id":%S,"status":%S,"response":%S%s%s,"duration_seconds":5.5,"num_turns":%d,"usage":{"input_tokens":100,"output_tokens":7,"thinking_tokens":3,"cache_read_tokens":50,"total_tokens":107}}}|}
    conversation_id
    status
    response
    error_field
    denied_field
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
   index, so one gap can be placed inside or after a chosen step.
   [line_gates] waits for a callback's marker before starting that gap. *)
let fixture_script
    ?(require_resume = false)
    ?required_home
    ?(sleep_s = 0.0)
    ?capture_prompt
    ?capture_pid
    ?capture_stdout
    ?(stdin = Read_to_end)
    ?line_delay_s
    ?(line_delays = [])
    ?(line_gates = [])
    ?pipe_holder_s
    ?exit_delay_s
    ?(stderr_line = "")
    ?(exit_code = 0)
    lines
  =
  let path = Filename.temp_file "masc-antigravity-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  Option.iter
    (fun path ->
       output_string output ("printf '%s\\n' \"$$\" >" ^ shell_quote path ^ "\n"))
    capture_pid;
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
         (fun path ->
            output_string output
              (Printf.sprintf "while [ ! -f %s ]; do sleep 0.01; done\n"
                 (shell_quote path)))
         (List.assoc_opt index line_gates);
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
       let print = "printf '%s\\n' " ^ shell_quote line in
       output_string output print;
       Option.iter (fun path ->
         (* Journal only a successful stdout write, never a planned event. *)
         output_string output (" && " ^ print ^ " >>" ^ shell_quote path ^ " || exit 91"))
         capture_stdout;
       output_char output '\n')
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

let with_fixture ?require_resume ?required_home ?sleep_s ?capture_prompt ?capture_pid ?capture_stdout ?stdin ?line_delay_s
    ?line_delays ?line_gates ?pipe_holder_s ?exit_delay_s ?stderr_line ?exit_code lines f =
  let path =
    fixture_script
      ?require_resume
      ?required_home
      ?sleep_s
      ?capture_prompt
      ?capture_pid
      ?capture_stdout
      ?stdin
      ?line_delay_s
      ?line_delays
      ?line_gates
      ?pipe_holder_s
      ?exit_delay_s
      ?stderr_line
      ?exit_code
      lines
  in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

(* A deadline a test asserts *fires* wants to be short (0.05 s); a deadline a
   test needs to *not* fire must cover spawning the fixture shell as well as
   any pre-admission pause (#43596; see the matching note in
   [test_runtime_claude_code.ml]). *)
let window_outlasting_process_start_s = 5.0

let run_fixture
    ?conversation_mode
    ?home_dir
    ?on_conversation_ready
    ?on_prompt_sent
    ?on_context_submission
    ?on_terminal_received
    ?on_spawned
    ?before_spawn
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
    Runtime_antigravity.run_turn ~host:(antigravity_host ())
      ?conversation_mode
      ?home_dir
      ?on_conversation_ready
      ?on_prompt_sent
      ?on_context_submission
      ?on_terminal_received
      ?on_spawned
      ?before_spawn
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
           ; Text_completed {step_index=1; ending=Response_done}
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

(* Text on a step that is not a response step is not the answer. When the
   response step carries the answer, only its pieces reach the reader; when
   no response step does, the result is the account of the answer. *)
let test_text_on_other_steps_is_not_an_answer_piece () =
  let pieces fixture =
    let events = ref [] in
    with_fixture fixture (fun path ->
      match run_fixture ~on_stream_event:(fun event -> events := event :: !events) path with
      | Error error -> fail (Runtime_antigravity.error_to_string error)
      | Ok _ ->
        List.filter_map
          (function
            | Runtime_antigravity.Text_delta { step_index; text } -> Some (step_index, text)
            | Turn_started _ | Text_completed _ | Native_tool_started _ | Native_tool_finished _
            | Usage_reported _ | Turn_finished _ -> None)
          (List.rev !events))
  in
  check
    (list (pair (option int) string))
    "only the response step's pieces"
    [ Some 3, "PONG\n" ]
    (pieces
       [ init ()
       ; step ~index:0 ~step_type:"system_message" ~text_delta:"NOTICE" ()
       ; step ~index:1 ~state:"ACTIVE" ~step_type:"tool" ~tool_name:"run_command"
           ~text_delta:"$ ls" ()
       ; step ~index:1 ~step_type:"tool" ~tool_name:"run_command" ()
       ; step ~index:2 ~step_type:"unknown" ~text_delta:"plan" ()
       ; step ~index:3 ~step_type:"agent_response" ~text_delta:"PONG\n" ()
       ; result ~response:"PONG\n" ()
       ]);
  check
    (list (pair (option int) string))
    "the result when no response step carried text"
    [ None, "PONG\n" ]
    (pieces
       [ init ()
       ; step ~index:0 ~step_type:"system_message" ~text_delta:"NOTICE" ()
       ; result ~response:"PONG\n" ()
       ])
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
            | Turn_started _ | Text_completed _ | Native_tool_started _ | Native_tool_finished _
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
let test_keeper_preserves_final_suffix_after_partial_steps () =
  List.iter (fun (state, expected) ->
    let events = ref [] in
    with_fixture [init (); step ~state ~text_delta:"PO" ();
        step ~index:2 ~state:"ACTIVE" ~step_type:"tool" ~tool_name:"run_command" ();
        step ~index:2 ~state:"DONE" ~step_type:"tool" ~tool_name:"run_command" ();
        result ~response:"PONG\n" ()] (fun path ->
      match run_fixture ~on_stream_event:(fun event -> events := event :: !events) path with
      | Error error -> fail (Runtime_antigravity.error_to_string error)
      | Ok _ ->
        let content = Keeper_antigravity_runtime.For_testing.project_stream (List.rev !events)
          |> List.filter_map (function
            | Agent_core.Types.ContentBlockDelta {index; delta=TextDelta text} -> Some (`Text (index,text))
            | ContentBlockStop {index} -> Some (`Stop index)
            | _ -> None) in
        check bool "final suffix continues only content that is still open" true (content=expected)))
    ["ACTIVE", [`Text (0,"PO"); `Stop 1; `Text (0,"NG\n"); `Stop 0];
     "DONE", [`Text (0,"PO"); `Stop 0; `Stop 1; `Text (2,"NG\n"); `Stop 2]]
;;

let test_keeper_reconciles_raw_current_and_previous_messages () =
  let module Stream = Keeper_official_client_text_stream in
  let t = Stream.create ~equal:String.equal () in
  ignore (Stream.forward t ~message:(Some "first") "첫째\n");
  ignore (Stream.forward t ~message:(Some "second") "둘째");
  let finish final_text = Stream.finish_response t ~final_text in
  check (option string) "raw continuation forwards only its suffix" (Some "!")
    (finish "첫째\n둘째!");
  check (option string) "current message continuation forwards only its suffix" (Some "!")
    (finish "둘째!");
  check (option string) "raw text is not repeated" None (finish "첫째\n둘째");
  check (option string) "current text is not repeated" None (finish "둘째");
  check (option string) "an earlier message is not repeated" None (finish "첫째\n");
  check (option string) "empty final text adds nothing" None (finish "");
  check (option string) "a different response begins a new paragraph" (Some "\n\n완료")
    (finish "완료");
  Stream.tool_row t;
  check (option string) "a tool row separates the different response" (Some "완료")
    (finish "완료");
  check (option string) "reconciliation does not change retained text" (Some "!")
    (finish "둘째!")
;;

let test_keeper_reconciles_four_response_steps_and_new_final () =
  List.iter (fun response ->
    let events = ref [] in
    with_fixture [init (); step ~index:0 ~text_delta:"ZERO\n" ();
        step ~index:1 ~text_delta:"ONE\n" (); step ~index:2 ~text_delta:"TWO\n" ();
        step ~index:3 ~state:"ACTIVE" ~text_delta:"TH" (); result ~response ()]
      (fun path ->
        match run_fixture ~on_stream_event:(fun event -> events := event :: !events) path with
        | Error error -> fail (Runtime_antigravity.error_to_string error)
        | Ok _ ->
            let pieces = Keeper_antigravity_runtime.For_testing.project_stream (List.rev !events)
              |> List.filter_map (function
                | Agent_core.Types.ContentBlockDelta {delta=TextDelta text; _} -> Some text
                | _ -> None) in
            let tail = List.hd (List.rev pieces) in
            let expected = if response = "ZERO\nONE\nTWO\nTHREE\n" then "REE\n"
              else if response = "ONE\n" then "\nTH" else "\n\nDONE\n" in
            check string "raw provider response reconciles across four displayed steps" expected tail;
            let shown = "ZERO\n\nONE\n\nTWO\n\nTH" in
            let expected_text = if response = "ZERO\nONE\nTWO\nTHREE\n" then shown ^ "REE\n"
              else if response = "ONE\n" then shown else shown ^ "\n\nDONE\n" in
            check string "four steps and final appear exactly once" expected_text (String.concat "" pieces)))
    ["ZERO\nONE\nTWO\nTHREE\n"; "DONE\n"; "ONE\n"]
;;

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
              { delta = Agent_core.Types.TextDelta text; _ } -> Some text
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

let test_response_step_ends_preserve_content_identity () =
  List.iter (fun (terminal_state, expected_ending) ->
    let events = ref [] in
    let first_end = step ~index:1 ~state:terminal_state ~text_delta:"" () in
    with_fixture [init ();
        step ~index:1 ~state:"ACTIVE" ~text_delta:"first" ();
        step ~index:7 ~state:"ACTIVE" ~step_type:"tool" ~tool_name:"run_command" ();
        step ~index:2 ~state:"ACTIVE" ~text_delta:"second" ();
        first_end; first_end;
        (* Ending the background tool cannot end response step 2. *)
        step ~index:7 ~state:"DONE" ~step_type:"tool" ~tool_name:"run_command" ();
        step ~index:2 ~state:"DONE" ~text_delta:" tail" ();
        result ~response:"firstsecond tail" ()]
      (fun path -> match run_fixture ~on_stream_event:(fun event -> events := event :: !events) path with
        | Error error -> fail (Runtime_antigravity.error_to_string error)
        | Ok _ ->
            let events = List.rev !events in
            let ends = List.filter_map (function
              | Runtime_antigravity.Text_completed {step_index; ending} -> Some (step_index,ending)
              | _ -> None) events in
            check bool "only response steps provide one typed content ending" true
              (ends=[1,expected_ending; 2,Runtime_antigravity.Response_done]);
            let projected = Keeper_antigravity_runtime.For_testing.project_stream events in
            let relevant = List.filter_map (function
              | Agent_core.Types.ContentBlockDelta {index; delta=TextDelta text} -> Some (`Text (index,text))
              | ContentBlockStart {index; content_type="native_tool_use"; _} -> Some (`Tool index)
              | ContentBlockStop {index} -> Some (`Stop index)
              | MessageStop -> Some `Turn_stop
              | ContentBlockDelta {delta=(ThinkingDelta _ | ThinkingSnapshot _); _} -> fail "provider supplied no thinking text"
              | _ -> None) projected in
            check bool "model and native closures never alias another open response" true
              (relevant=[`Text (0,"first"); `Tool 1; `Text (2,"\n\nsecond");
                `Stop 0; `Stop 1; `Text (2," tail"); `Stop 2; `Turn_stop])))
    ["DONE",Runtime_antigravity.Response_done; "ERROR",Runtime_antigravity.Response_error]
;;

let test_done_only_response_closes_before_next_tool () =
  let events = ref [] in
  let done_frame = step ~index:1 ~state:"DONE" ~text_delta:"before" () in
  with_fixture [init (); done_frame; done_frame;
      step ~index:2 ~state:"ACTIVE" ~step_type:"tool" ~tool_name:"run_command" ();
      step ~index:2 ~state:"DONE" ~step_type:"tool" ~tool_name:"run_command" ();
      result ~response:"before" ()]
    (fun path -> match run_fixture ~on_stream_event:(fun event -> events := event :: !events) path with
      | Error error -> fail (Runtime_antigravity.error_to_string error)
      | Ok _ ->
          let projected = Keeper_antigravity_runtime.For_testing.project_stream (List.rev !events) in
          match projected with
          | Agent_core.Types.MessageStart _ ::
            ContentBlockDelta {index=0; delta=TextDelta "before"} ::
            ContentBlockStop {index=0} ::
            ContentBlockStart {index=1; content_type="native_tool_use"; _} :: _ -> ()
          | _ -> fail "a complete unnewline response stayed open until a tool event")
;;

let test_late_or_conflicting_response_update_is_rejected () =
  List.iter (fun late ->
    with_fixture [init (); step ~index:1 ~text_delta:"done" (); late; result ()]
      (fun path -> match run_fixture path with
        | Error (Runtime_antigravity.Protocol_error _) -> ()
        | Error error -> fail (Runtime_antigravity.error_to_string error)
        | Ok _ -> fail "a completed response admitted changed or reopened content"))
    [step ~index:1 ~state:"ACTIVE" ~text_delta:"late" ();
     step ~index:1 ~state:"DONE" ~text_delta:"changed" ();
     step ~index:1 ~state:"ERROR" ~text_delta:"done" ()]
;;

let test_unassigned_ends_cannot_close_named_content () =
  let without_index frame = match Yojson.Safe.from_string frame with
    | `Assoc [("event",event); ("step_update",`Assoc fields)] ->
        Yojson.Safe.to_string (`Assoc ["event",event; "step_update",`Assoc (List.remove_assoc "step_index" fields)])
    | _ -> fail "invalid step fixture" in
  let events = ref [] in
  with_fixture [init (); step ~index:1 ~state:"ACTIVE" ~text_delta:"named" ();
      without_index (step ~state:"DONE" ());
      step ~index:99 ~state:"DONE" ();
      step ~index:1 ~state:"DONE" ~text_delta:" tail" ();
      result ~response:"named tail" ()]
    (fun path -> match run_fixture ~on_stream_event:(fun event -> events := event :: !events) path with
      | Error error -> fail (Runtime_antigravity.error_to_string error)
      | Ok _ ->
          let projected = Keeper_antigravity_runtime.For_testing.project_stream (List.rev !events) in
          let content = List.filter_map (function
            | Agent_core.Types.ContentBlockDelta {index; delta=TextDelta text} -> Some (`Text (index,text))
            | ContentBlockStop {index} -> Some (`Stop index)
            | _ -> None) projected in
          check bool "only the matching identified DONE releases named content" true
            (content=[`Text (0,"named"); `Text (0," tail"); `Stop 0]))
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
               { observation = { identity =
                   Some
                     (Runtime_native_tools.Provider_step
                        { conversation_id = "conversation-1"; step_index = 7 })
               ; tool_name = Some "run_command"
               ; origin = Runtime_native_tools.Built_in
               }; completion = _ }
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

let test_repeated_active_native_step_keeps_one_chat_occurrence () =
  let events = ref [] in
  List.iter (fun terminal_state ->
    events := [];
    with_fixture
      [init ();
       step ~index:7 ~state:"ACTIVE" ~step_type:"tool" ~tool_name:"run_command" ();
       step ~index:7 ~state:"ACTIVE" ~step_type:"tool" ~tool_name:"run_command" ();
       step ~index:7 ~state:terminal_state ~step_type:"tool" ~tool_name:"run_command" ();
       result ()]
      (fun path ->
        match run_fixture ~on_stream_event:(fun event -> events := event :: !events) path with
        | Error error -> fail (Runtime_antigravity.error_to_string error)
        | Ok _ ->
            let fixture = Native_tool_outcome_fixture.create () in
            ignore (Keeper_antigravity_runtime.For_testing.project_stream
              ~on_event:(Native_tool_outcome_fixture.on_event fixture)
              ~on_native_tool_completion:(Native_tool_outcome_fixture.on_completion fixture)
              (List.rev !events));
            let outcome = if terminal_state = "DONE" then Runtime_native_tools.Completion_reported
              else Runtime_native_tools.Error_reported in
            Native_tool_outcome_fixture.check fixture ~expected:[{outcome; exit_code=None}];
            let chat = Native_tool_outcome_fixture.events fixture in
            let native = List.filter_map (function
              | Keeper_chat_events.Native_tool_start tool -> Some (true, tool.occurrence.block_index)
              | Native_tool_end (tool, _) -> Some (false, tool.occurrence.block_index)
              | _ -> None) chat in
            check (list (pair bool int)) "repeated active frames open one row and terminal step closes it"
              [true, 1; false, 1] native;
            check bool "native observation is not a MASC execution receipt" false
              (List.exists (function Keeper_chat_events.Tool_result_ready _ -> true | _ -> false) chat)))
    ["DONE"; "ERROR"]
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
    let receipts = ref [] in
    with_fixture ~capture_prompt:captured [ init (); result () ] (fun path ->
      match
        run_fixture ~prompt ~on_prompt_sent:(fun () -> incr sent)
          ~on_context_submission:(fun write -> receipts := (write, !sent) :: !receipts) path
      with
      | Error error -> fail (Runtime_antigravity.error_to_string error)
      | Ok turn ->
        check string "response" "MASC_ANTIGRAVITY_OK\n" turn.text;
        check int "turn count" 1 turn.num_turns;
        check int "one complete prompt transmission" 1 !sent;
        let received = In_channel.with_open_bin captured In_channel.input_all in
        check string "client received exact complete prompt" prompt received;
        match !receipts with
        | [ ((write : Runtime_official_client_write.t), sent_before) ] ->
          check int "the receipt comes before the transmission report" 0 sent_before;
          check int "receipt counts the bytes the client received"
            (String.length received) write.bytes;
          check string "receipt hashes the bytes the client received"
            Agent_core_sha256.(digest_string received |> to_hex) write.sha256;
          check bool "the whole write is the one slot" true
            (Option.is_some
               (Runtime_official_client_write.matching_fragment write
                  ~slot:Whole_write prompt))
        | receipts -> failf "expected one receipt, got %d" (List.length receipts)))
;;

let test_spawn_observer_receives_the_actual_child_pid () =
  let captured = Filename.temp_file "masc-antigravity-pid-" ".txt" in
  Fun.protect ~finally:(fun () -> Sys.remove captured) @@ fun () ->
  let observed = ref None in
  let transitions = ref [] in
  with_fixture ~capture_pid:captured [ init (); result () ] (fun path ->
    match run_fixture
      ~before_spawn:(fun () -> transitions := `Before_spawn :: !transitions)
      ~on_spawned:(fun ~pid ->
        observed := Some pid;
        transitions := `Spawned :: !transitions)
      path with
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok _ ->
      let actual = In_channel.with_open_bin captured In_channel.input_all
        |> String.trim |> int_of_string in
      check bool "fixture PID is a child process" true
        (actual > 0 && actual <> Unix.getpid ());
      check (option int) "spawn observer names the actual CLI process"
        (Some actual) !observed;
      check bool "ownership publication brackets the actual spawn" true
        (!transitions = [ `Spawned; `Before_spawn ]))
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
      ~on_spawned:(fun ~pid:_ -> incr spawned)
      ~on_prompt_sent:(fun () -> incr sent)
      ~on_context_submission:(fun _ -> incr sent) path in
    check int "write failure occurs after real spawn" 1 !spawned;
    check bool "incomplete input does not complete a turn" true (Result.is_error result);
    check int "partial write does not report transmission" 0 !sent)
;;

let test_a_cli_that_answers_without_reading_the_prompt_does_not_hold_the_turn () =
  (* The CLI never reads stdin and lingers after answering, so a prompt past
     the pipe buffer is still in the pipe when the answer arrives. The turn
     ends on the lane's own admission window. The child's write journal proves
     the answer independently of the first-event FD probe, which can outlast
     that window before the init callback runs. *)
  let journal = Filename.temp_file "masc-antigravity-unread-" ".jsonl" in
  Fun.protect ~finally:(fun () -> Sys.remove journal) @@ fun () ->
  let frames = [ init (); result () ] in
  let sent = ref 0 in
  let receipts = ref 0 in
  with_fixture ~stdin:Leave_unread ~capture_stdout:journal ~exit_delay_s:5.0 frames (fun path ->
    match
      run_fixture
        ~prompt:(String.make 1_100_000 'x')
        ~admission_timeout_s:1.5
        ~timeout_s:5.0
        ~on_prompt_sent:(fun () -> incr sent)
        ~on_context_submission:(fun _ -> incr receipts)
        path
    with
    | Error (Runtime_antigravity.Timeout seconds) ->
      check string "the child wrote the exact init and terminal frames to stdout"
        (String.concat "\n" frames ^ "\n")
        (In_channel.with_open_bin journal In_channel.input_all);
      check int "the unread prompt never completed transmission" 0 !sent;
      check int "the unread prompt has no complete-write receipt" 0 !receipts;
      check (float 0.001) "the window is the lane's admission window" 1.5 seconds
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
    | Turn_started _ | Text_delta _ | Text_completed _ | Native_tool_started _ | Native_tool_finished _
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

(* RFC-0490 §2.4: every agy masc launches gets the one value that stops its
   self-update, even when the operator's shell sets another. *)
let test_environment_turns_off_agy_auto_update_once () =
  let key = "AGY_CLI_DISABLE_AUTO_UPDATE" in
  let previous = Sys.getenv_opt key in
  (* OCaml has no unsetenv: an absent key comes back as an empty value, which
     the allowlist drops from every child all the same. *)
  Fun.protect ~finally:(fun () -> Unix.putenv key (Option.value previous ~default:""))
  @@ fun () ->
  Unix.putenv key "0";
  let entries environment =
    Array.to_list environment
    |> List.filter (fun entry ->
      match String.index_opt entry '=' with
      | Some i -> String.equal (String.sub entry 0 i) "AGY_CLI_DISABLE_AUTO_UPDATE"
      | None -> false)
  in
  let expected = [ "AGY_CLI_DISABLE_AUTO_UPDATE=true" ] in
  check (list string) "without a private home" expected
    (entries (Runtime_antigravity.official_client_environment ()));
  check (list string) "with a private home" expected
    (entries (Runtime_antigravity.official_client_environment ~home_dir:"/tmp/masc-agy-home" ()))
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
  let rejected on_conversation_ready =
    let admitted = ref [] in
    let events = ref [] in
    let terminals = ref 0 in
    with_fixture [ init (); result () ] (fun path ->
      (match
         run_fixture
           ~on_conversation_ready:(fun ~conversation_id ->
             admitted := conversation_id :: !admitted;
             on_conversation_ready ~conversation_id)
           ~on_terminal_received:(fun () -> incr terminals)
           ~on_stream_event:(fun event -> events := event :: !events)
           path
       with
       | Error (Runtime_antigravity.State_callback_failed _) -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "callback failure was admitted as a successful turn");
      check (list string) "matching identity reaches admission once"
        [ "conversation-1" ] !admitted;
      check int "rejected admission emits no start, text, usage or completion"
        0 (List.length !events);
      check int "rejected admission never observes the buffered result" 0 !terminals)
  in
  rejected (fun ~conversation_id:_ -> Error "fixture callback");
  rejected (fun ~conversation_id:_ -> failwith "fixture callback")
;;

(* #39768: an exception raised where the runtime expects none -- the spawn
   observer here -- leaves [run_turn] as [Unhandled_exception]. As a protocol
   error it read as a misread CLI reply. *)
let test_unexpected_exception_is_unhandled () =
  with_fixture [ init (); result () ] (fun path ->
    match
      run_fixture ~on_spawned:(fun ~pid:_ -> failwith "fixture spawn observer") path
    with
    | Error (Runtime_antigravity.Unhandled_exception detail) ->
      check bool "names the exception" true
        (String_util.contains_substring detail "fixture spawn observer")
    | Error error -> fail (Runtime_antigravity.error_to_string error)
    | Ok _ -> fail "an observer exception was admitted as a successful turn")
;;

(* #39824: the exceptions [Reserved_exn] names belong to the process, not to
   the runtime to type. Raised where the test above raises its [Failure], they
   reach the outermost catch-all, which re-raises them. *)
let test_reserved_exceptions_leave_run_turn () =
  List.iter
    (fun exn ->
       with_fixture [ init (); result () ] (fun path ->
         check_raises
           (Printexc.to_string exn ^ " leaves run_turn untyped")
           exn
           (fun () ->
              ignore (run_fixture ~on_spawned:(fun ~pid:_ -> raise exn) path))))
    [ Out_of_memory; Stack_overflow; Sys.Break ]
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
           Runtime_antigravity.run_turn ~host:(antigravity_host ())
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
          Runtime_antigravity.run_turn ~host:(antigravity_host ())
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

let noncompletion_statuses =
  [ "CANCELED", Runtime_antigravity.Canceled
  ; "INTERRUPTED", Runtime_antigravity.Interrupted
  ; "INVALID", Runtime_antigravity.Invalid
  ; "WAITING", Runtime_antigravity.Waiting
  ; "RUNNING", Runtime_antigravity.Running
  ]
;;

let test_documented_noncompletion_results_never_complete () =
  List.iter
    (fun (wire_status, expected_status) ->
       let admitted = ref [] in
       let received = ref 0 in
       let events = ref [] in
       with_fixture ~require_resume:true
         [ init (); result ~conversation_id:"" ~status:wire_status
             ~response:"a partial reply" ~error:"fixture stopped" () ]
         (fun path ->
            (match run_fixture path
                ~conversation_mode:(Runtime_antigravity.Resume { conversation_id = "conversation-1" })
                ~on_conversation_ready:(fun ~conversation_id ->
                  admitted := conversation_id :: !admitted;
                  Ok ())
                ~on_terminal_received:(fun () -> incr received)
                ~on_stream_event:(fun event -> events := event :: !events)
             with
             | Error (Runtime_antigravity.Result_not_completed
                 { status; conversation_id; response; error; num_turns; usage; denied = None }) ->
               check bool "exact typed status" true (status = expected_status);
               check (option string) "init identity survives blank restatement"
                 (Some "conversation-1") conversation_id;
               check string "partial reply retained" "a partial reply" response;
               check (option string) "wire reason retained" (Some "fixture stopped") error;
               check int "reported turn count retained" 1 num_turns;
               check int "raw exclusive input retained" 100 usage.input_tokens;
               check int "raw cache input retained" 50 usage.cache_read_tokens
             | Error error -> fail (Runtime_antigravity.error_to_string error)
             | Ok _ -> failf "%s became a completed turn" wire_status);
            check (list string) "resume identity admitted once" [ "conversation-1" ] !admitted;
            check int "matching result observed without granting completion" 1 !received;
            let usage_reports = List.filter_map (function
              | Runtime_antigravity.Usage_reported { conversation_id; num_turns; usage; _ } ->
                Some (conversation_id, num_turns, usage.input_tokens)
              | _ -> None) !events in
            check (list (triple string int int)) "failed result keeps usage"
              [ "conversation-1", 1, 100 ] usage_reports;
            check int "no success or result-only answer emitted" 0
              (List.length (List.filter (function
                | Runtime_antigravity.Turn_finished _ | Text_delta _ -> true
                | _ -> false) !events))))
    noncompletion_statuses
;;

let test_pre_init_noncompletion_keeps_unbound_identity () =
  List.iter (fun (wire_status, expected_status) ->
    let admitted = ref false in
    let events = ref [] in
    with_fixture [ result ~conversation_id:"unbound-conversation" ~status:wire_status
        ~response:"unbound partial\n  retained  " ~error:"not admitted" ~num_turns:7 () ]
      (fun path ->
        (match run_fixture path
            ~on_conversation_ready:(fun ~conversation_id:_ -> admitted := true; Ok ())
            ~on_stream_event:(fun event -> events := event :: !events) with
         | Error (Runtime_antigravity.Result_not_completed
             { status; conversation_id; response; error; num_turns; usage; denied = None }) ->
           check bool "typed pre-init state" true (status = expected_status);
           check (option string) "unbound identity retained"
             (Some "unbound-conversation") conversation_id;
           check string "unbound partial retained byte-exact" "unbound partial\n  retained  " response;
           check (option string) "wire reason retained" (Some "not admitted") error;
           check int "unbound reported turn count retained" 7 num_turns;
           check (list int) "unbound raw counts retained" [100; 7; 3; 50; 107]
             [usage.input_tokens; usage.output_tokens; usage.thinking_tokens;
              usage.cache_read_tokens; usage.total_tokens]
         | Error error -> fail (Runtime_antigravity.error_to_string error)
         | Ok _ -> fail "a non-completed invocation was admitted");
        check bool "result alone never admits a session" false !admitted;
        check int "unbound counts never emit attributed usage or reply events" 0 (List.length !events)))
    noncompletion_statuses
;;

let test_interrupted_partial_stream_is_not_a_completed_reply () =
  let pieces = ref [] in
  let completed = ref false in
  with_fixture
    [ init (); step ~state:"ACTIVE" ~text_delta:"partial " ()
    ; result ~status:"INTERRUPTED" ~response:"partial final fragment" () ]
    (fun path ->
      (match run_fixture path ~on_stream_event:(function
          | Runtime_antigravity.Text_delta { text; _ } -> pieces := text :: !pieces
          | Turn_finished _ -> completed := true
          | _ -> ()) with
       | Error (Runtime_antigravity.Result_not_completed
           { status = Interrupted; response = "partial final fragment"; _ }) -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a streamed fragment completed an interrupted turn");
      check (list string) "partial stream is not duplicated by the result" [ "partial " ] !pieces;
      check bool "no successful turn ending" false !completed)
;;

let test_noncompletion_identity_mismatch_is_refused () =
  let received = ref 0 in
  with_fixture [ init (); result ~conversation_id:"other-conversation" ~status:"RUNNING" () ]
    (fun path ->
      (match run_fixture ~on_terminal_received:(fun () -> incr received) path with
       | Error (Runtime_antigravity.Protocol_error _) -> ()
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a mismatched non-completed result was admitted");
      check int "unrelated result never closes delivery frontier" 0 !received)
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

let index_of_substring hay needle =
  let n = String.length hay and m = String.length needle in
  let rec go i =
    if i + m > n then None
    else if String.sub hay i m = needle then Some i
    else go (i + 1)
  in
  go 0
;;

(* The wire shape agy 1.5.1 printed on 2026-11-05 when print mode refused a
   read it could not ask about. *)
let refused_read_json = {|[{"action":"read_file","display_name":"ReadFile"}]|}

(* Measured the same day: text written before the refused call survives as
   the SUCCESS response, so the run's leftover sentence must not pass as the
   answer. *)
let test_text_before_a_refused_action_is_not_the_answer () =
  let finished = ref false in
  with_fixture
    [ init ()
    ; step ~state:"ACTIVE" ~text_delta:"Starting the check now." ()
    ; result ~response:"Starting the check now.\n" ~denied_actions_json:refused_read_json () ]
    (fun path ->
       (match run_fixture path ~on_stream_event:(function
           | Runtime_antigravity.Turn_finished _ -> finished := true
           | _ -> ()) with
        | Error (Runtime_antigravity.Actions_denied
            { conversation_id; model; denied; response; num_turns; usage; tool_steps; _ }) ->
          check string "admitted identity" "conversation-1" conversation_id;
          check string "admitted model" "gemini-fixture" model;
          check int "no tool step ran" 0 tool_steps;
          check (list string) "refused actions" [ "read_file" ]
            (Runtime_antigravity.denied_action_names denied);
          check string "partial text kept as evidence" "Starting the check now.\n" response;
          check int "reported turn count" 1 num_turns;
          check int "raw input kept" 100 usage.input_tokens
        | Error error -> fail (Runtime_antigravity.error_to_string error)
        | Ok _ -> fail "a refused run completed with its partial text");
       check bool "no successful turn ending" false !finished)
;;

let test_refusal_without_text_names_the_refusal () =
  with_fixture
    [ init (); result ~response:"" ~denied_actions_json:refused_read_json () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Actions_denied { denied; _ }) ->
         check (list string) "refused actions" [ "read_file" ]
           (Runtime_antigravity.denied_action_names denied)
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "an empty refused run completed")
;;

(* agy writes the run's text only into the result when nothing streamed; a
   refusal keeps it out of the reply stream as well as out of completion. *)
let test_unstreamed_text_before_a_refusal_is_not_replayed () =
  let pieces = ref [] in
  with_fixture
    ~stderr_line:"antigravity: refused read_file"
    [ init (); result ~response:"Starting the check now.\n" ~denied_actions_json:refused_read_json () ]
    (fun path ->
       (match run_fixture path ~on_stream_event:(function
           | Runtime_antigravity.Text_delta { text; _ } -> pieces := text :: !pieces
           | _ -> ()) with
        | Error (Runtime_antigravity.Actions_denied { stderr_tail; _ } as error) ->
          check string "stderr tail kept" "antigravity: refused read_file" stderr_tail;
          let detail = Runtime_antigravity.error_to_string error in
          check bool "detail names the model" true
            (index_of_substring detail "model=gemini-fixture" <> None);
          check bool "detail carries the stderr tail" true
            (index_of_substring detail "antigravity: refused read_file" <> None)
        | Error error -> fail (Runtime_antigravity.error_to_string error)
        | Ok _ -> fail "a refused run completed");
       check (list string) "refused text is not streamed" [] !pieces)
;;

(* agy's closing stderr sentence for a refused read. Its opening is the
   sentence docs/evidence/2026-11-05-antigravity-mcp-tool-budget recorded and
   its last 200 bytes are the tail #50291 quoted from a Keeper turn on
   2026-11-09; the two overlap at "for, so it was auto-denied". *)
let refused_read_stderr =
  "no output produced \xe2\x80\x94 a tool required the \"read_file\" permission that \
   headless mode cannot prompt for, so it was auto-denied. Add an allow-rule under \
   permissions.allow in settings.json (e.g. read_file(<target>)). Alternatively, \
   re-run with --dangerously-skip-permissions to auto-approve all tools."
;;

(* #50291: the refusal detail began at " for, so it was auto-denied", so the
   words that say what was refused never reached the operator. *)
let test_refusal_detail_keeps_the_refusal_sentence_from_its_first_word () =
  assert (String.length refused_read_stderr > 200);
  with_fixture
    ~stderr_line:refused_read_stderr
    [ init (); result ~response:"" ~denied_actions_json:refused_read_json () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Actions_denied { stderr_tail; _ } as error) ->
         check string "whole sentence kept" refused_read_stderr stderr_tail;
         check bool "detail opens the sentence at its first word" true
           (String_util.contains_substring
              (Runtime_antigravity.error_to_string error)
              ("stderr tail: " ^ refused_read_stderr))
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a refused run completed")
;;

(* A stderr longer than the refusal budget keeps what the CLI said first and
   its closing sentence, says how much it left out, and is masked before it is
   cut: the credential sits in the kept head. *)
let test_long_refusal_stderr_keeps_both_ends_and_masks_first () =
  let first_line = "agy: 거부 직전 진단 token=opaque-fixture-value" in
  let middle =
    String.concat "\n" (List.init 200 (fun i -> Printf.sprintf "가운데 줄 %03d" i))
  in
  let stderr = String.concat "\n" [ first_line; middle; refused_read_stderr ] in
  with_fixture
    ~stderr_line:stderr
    [ init (); result ~response:"" ~denied_actions_json:refused_read_json () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Actions_denied { stderr_tail; _ }) ->
         check bool "shorter than what the CLI wrote" true
           (String.length stderr_tail < String.length stderr);
         check bool "first words kept and masked" true
           (String.starts_with ~prefix:"agy: 거부 직전 진단 token=[REDACTED]" stderr_tail);
         check bool "credential value is gone" false
           (String_util.contains_substring stderr_tail "opaque-fixture-value");
         check bool "closing sentence kept whole" true
           (String.ends_with ~suffix:refused_read_stderr stderr_tail);
         check bool "omitted middle is counted" true
           (String_util.contains_substring stderr_tail "bytes omitted");
         check bool "a middle line is left out" false
           (String_util.contains_substring stderr_tail "가운데 줄 100");
         check bool "cut at character boundaries" true (String.is_valid_utf_8 stderr_tail)
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a refused run completed")
;;

(* A refusal ends the run whatever status the CLI reports, so an ERROR with a
   deliverable-looking sentence is not the answer either. *)
let test_error_result_with_refusals_is_actions_denied () =
  with_fixture
    [ init ()
    ; result ~status:"ERROR" ~response:"Here is the full report you asked for."
        ~error:"permission denied" ~denied_actions_json:refused_read_json () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Actions_denied { denied; response; _ }) ->
         check (list string) "refused actions" [ "read_file" ]
           (Runtime_antigravity.denied_action_names denied);
         check string "text kept as evidence" "Here is the full report you asked for." response
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "an ERROR with refusals completed")
;;

let test_refusals_keep_the_cli_order () =
  with_fixture
    [ init ()
    ; result ~response:""
        ~denied_actions_json:{|[{"action":"read_file"},{"action":"run_command","display_name":"RunCommand"}]|} () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Actions_denied { denied; _ }) ->
         check (list string) "both refusals in order" [ "read_file"; "run_command" ]
           (Runtime_antigravity.denied_action_names denied)
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a refused run completed")
;;

let test_absent_refusals_complete_the_turn () =
  List.iter
    (fun denied_actions_json ->
       with_fixture
         [ init (); result ~denied_actions_json () ]
         (fun path ->
            match run_fixture path with
            | Ok _ -> ()
            | Error error ->
              failf "denied_actions %s failed the turn: %s" denied_actions_json
                (Runtime_antigravity.error_to_string error)))
    [ "[]"; "null" ]
;;

(* The CLI's own noncompletion keeps its class; the refusals ride along as
   evidence instead of being dropped. *)
let test_noncompletion_keeps_its_refusals () =
  with_fixture
    [ init ()
    ; result ~status:"INTERRUPTED" ~response:"partial" ~denied_actions_json:refused_read_json () ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_antigravity.Result_not_completed ({ status = Interrupted; denied = Some denied; _ } as evidence)) ->
         check (list string) "refusals retained" [ "read_file" ]
           (Runtime_antigravity.denied_action_names denied);
         (match Runtime_antigravity.noncompletion_result_to_json evidence with
          | `Assoc fields ->
            check bool "evidence names the refusals" true
              (List.assoc_opt "denied_actions" fields = Some (`List [ `String "read_file" ]))
          | _ -> fail "noncompletion evidence is not an object")
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "an interrupted run completed")
;;

let test_malformed_refusal_entry_is_a_protocol_error () =
  List.iter
    (fun denied_actions_json ->
       with_fixture
         [ init (); result ~denied_actions_json () ]
         (fun path ->
            match run_fixture path with
            | Error (Runtime_antigravity.Protocol_error _) -> ()
            | Error error -> fail (Runtime_antigravity.error_to_string error)
            | Ok _ -> failf "denied_actions %s was accepted" denied_actions_json))
    [ {|["read_file"]|}; {|[{"display_name":"ReadFile"}]|}; {|[{"action":""}]|}; {|"read_file"|} ]
;;

(* A Korean stderr line longer than the byte budget must come back cut at a
   character boundary, never with a torn Hangul character at its head
   (#39090 made String_util the SSOT for that rule). *)
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

(* Both detail sinks share the structural masker used by the other log sinks. *)
let test_stderr_tail_redacts_sensitive_lines () =
  let redacted = Runtime_antigravity.redact_stderr_tail in
  check string "empty diagnostic" "" (redacted "");
  check string "Authorization keeps context and masks its value"
    "Authorization: [REDACTED]" (redacted "Authorization: Bearer ya29.aBcDeFgHi");
  check string "lowercase bearer is masked"
    "Authorization: [REDACTED]" (redacted "Authorization: bearer ya29.synthetic");
  check string "opaque token assignment is masked"
    "token=[REDACTED]" (redacted "token=opaque-fixture-value");
  check string "opaque environment API key is masked"
    "VENDOR_API_KEY=[REDACTED]" (redacted "VENDOR_API_KEY=opaque-fixture-value");
  check string "standalone GitHub token is masked"
    "failure: [REDACTED]" (redacted "failure: ghp_syntheticfixture");
  check string "standalone API key is masked"
    "failure: [REDACTED]" (redacted "failure: sk-syntheticfixture");
  check string "ordinary diagnostics remain readable"
    "spawn: /tmp/fixture/agy: no such file"
    (redacted "spawn: /tmp/fixture/agy: no such file");
  check string "other lines are preserved"
    "line1 stays\nAuthorization: [REDACTED]\nline3 stays"
    (redacted "line1 stays\nAuthorization: Bearer sk-fixture\nline3 stays")
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
           (String_util.contains_substring detail "[REDACTED]");
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
           (String_util.contains_substring detail "[REDACTED]");
         check bool "detail never carries the token" true
           (not (String_util.contains_substring detail "ya29"))
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok _ -> fail "a blank result was admitted")
;;

let test_stderr_cut_inside_assignment_omits_the_diagnostic () =
  let marker = "opaque-credential-boundary-canary" in
  let diagnostic = "ordinary diagnostic: model connection closed" in
  (* The fixture's echo adds the last newline. The entire stream is 8198
     bytes, so the old byte-only tail discarded exactly [token=], leaving
     the full opaque value without the context needed to mask it. Its final
     canary is also inside the empty-success sink's 200-byte display tail. *)
  let secret =
    String.make (8192 - String.length diagnostic - 2 - String.length marker) 'x'
    ^ marker
  in
  let stderr_line = "token=" ^ secret ^ "\n" ^ diagnostic in
  check int "cut is immediately after token=" 8198 (String.length stderr_line + 1);
  List.iter
    (fun (exit_code, lines) ->
       with_fixture ~exit_code ~stderr_line lines (fun path ->
         let detail =
           match run_fixture path with
           | Error (Runtime_antigravity.Process_exited detail) when exit_code = 1 -> detail
           | Error (Runtime_antigravity.Turn_failed detail) when exit_code = 0 -> detail
           | Error error -> fail (Runtime_antigravity.error_to_string error)
           | Ok _ -> fail "the failing fixture succeeded"
         in
         check bool "partial credential value never reaches the sink" false
           (String_util.contains_substring detail marker);
         check bool "overflow is explicitly omitted" true
           (String_util.contains_substring detail "[stderr omitted: byte limit]");
         check bool "later lines cannot escape the omitted stream" false
           (String_util.contains_substring detail diagnostic)))
    [ 1, [ init () ]; 0, [ init (); result ~response:"" () ] ]
;;

let test_stderr_chunk_boundaries_preserve_redaction_context () =
  let project chunks =
    let capture = Runtime_official_client_json.Stderr.create ~limit:8192 in
    List.iter (Runtime_official_client_json.Stderr.append capture) chunks;
    Runtime_official_client_json.Stderr.contents capture
  in
  let omitted = "[stderr omitted: byte limit]" in
  let marker = "opaque-chunk-canary" in
  let complete_line = "token=" ^ marker ^ "\nordinary diagnostic" in
  (* Split every byte boundary, including inside the assignment key and the
     opaque value. A read ending without a newline is not a complete line. *)
  for index = 0 to String.length complete_line do
    let chunks =
      [ String.sub complete_line 0 index
      ; String.sub complete_line index (String.length complete_line - index)
      ]
    in
    check string "chunking keeps the same masked diagnostic"
      "token=[REDACTED]\nordinary diagnostic" (project chunks)
  done;
  check string "oversized unterminated line is explicitly omitted" omitted
    (project [ "token="; String.make 8192 'x'; marker ]);
  check string "overflow remains omitted after the next newline" omitted
    (project [ String.make 8193 'x'; "\ntok"; "en="; marker; "\nordinary diagnostic" ]);
  let padding = String.make (8192 - String.length complete_line) '.' in
  check string "a later complete line cannot revive an omitted stream" omitted
    (project [ "dropped\n" ^ complete_line ^ padding ]);
  (* A newline cannot prove a safe masking boundary: an earlier PEM header
     may still govern following lines after the byte bound drops it. *)
  check string "oversized multiline key stays omitted after its header" omitted
    (project [ "-----BEGIN PRIVATE KEY-----\n"; String.make 8192 'x';
               "\n"; marker; "\n-----END PRIVATE KEY-----\nordinary diagnostic" ])
;;

(* #43259: tool phases must bound their CLI spawn slot. Silence there is
   the protocol, so the bound is a 2h backstop far above any plausible
   healthy tool — but it must exist, or a wedged tool holds a slot
   forever. *)
let test_tool_step_phase_carries_idle_backstop () =
  let config = Runtime_antigravity.default_config ~cwd:"/tmp" ~model:"gemini-fixture" in
  check
    (float 0.001)
    "backstop value"
    7200.0
    Runtime_antigravity.tool_step_idle_timeout_s;
  check
    (option (float 0.001))
    "tool phase maps to the backstop"
    (Some Runtime_antigravity.tool_step_idle_timeout_s)
    (Runtime_antigravity.For_testing.tool_step_timeout_s config)
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
       match
         run_fixture
           ~timeout_s:0.75
           ~admission_timeout_s:window_outlasting_process_start_s
           path
       with
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

(* A tool step that outlasts the idle window. The window is short and the gap
   several times longer, so a window that stayed armed through the step would
   fire long before the DONE update. Admission keeps a wide bound because the
   fixture's first line is not what is under test (#28919). *)
let tool_step_idle_window_s = 0.3
let tool_step_gap_s = 1.0
let tool_step_admission_s = window_outlasting_process_start_s

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

(* A closed response can be replayed while a different, real tool step is
   active. The replay says nothing new: it must not replace the active tool
   as the last step and re-arm the model-turn idle window before tool DONE. *)
let test_response_replay_preserves_the_running_tool_phase () =
  let events = ref [] in
  let closed_response = step ~index:1 ~text_delta:"before tool\n" () in
  let expected_tool : Runtime_native_tools.observation =
    { identity =
        Some
          (Runtime_native_tools.Provider_step
             { conversation_id = "conversation-1"; step_index = 2 })
    ; tool_name = Some "run_command"
    ; origin = Runtime_native_tools.Built_in
    }
  in
  with_fixture
    ~line_delays:[ 4, tool_step_gap_s ]
    [ init ()
    ; closed_response
    ; step ~index:2 ~state:"ACTIVE" ~step_type:"tool" ~tool_name:"run_command" ()
    ; closed_response
    ; step ~index:2 ~state:"DONE" ~step_type:"tool" ~tool_name:"run_command" ()
    ; result ~response:"before tool\n" ()
    ]
    (fun path ->
       match
         run_fixture
           ~timeout_s:tool_step_idle_window_s
           ~admission_timeout_s:tool_step_admission_s
           ~on_stream_event:(fun event -> events := event :: !events)
           path
       with
       | Error error -> fail (Runtime_antigravity.error_to_string error)
       | Ok turn ->
         check string "terminal reply survives tool silence" "before tool\n" turn.text;
         check int "only the real tool ACTIVE counts" 1 turn.tool_steps;
         check int "the real tool completed without error" 0 turn.tool_errors;
         match List.rev !events with
         | [ Runtime_antigravity.Turn_started
               { conversation_id = "conversation-1"; model = "gemini-fixture" }
           ; Text_delta { step_index = Some 1; text = "before tool\n" }
           ; Text_completed { step_index = 1; ending = Response_done }
           ; Native_tool_started started
           ; Native_tool_finished
               { observation = finished
               ; completion =
                   { outcome = Runtime_native_tools.Completion_reported; exit_code = None }
               }
           ; Usage_reported
               { conversation_id = "conversation-1"
               ; model = "gemini-fixture"
               ; num_turns = 1
               ; usage =
                   { input_tokens = 100; output_tokens = 7; thinking_tokens = 3
                   ; cache_read_tokens = 50; total_tokens = 107
                   }
               }
           ; Turn_finished { text = "before tool\n" }
           ] ->
           check bool "native start retains the actual tool identity" true
             (started = expected_tool);
           check bool "native completion retains the actual tool identity" true
             (finished = expected_tool)
         | _ -> fail "response replay changed the real ordered stream observations")
;;

(* The same gap after the tool step has ended, whichever way it ended, is
   silence from the model turn again and the idle window ends it. *)
let test_idle_window_rearms_when_the_tool_step_ends () =
  List.iter
    (fun final_state ->
       let gate = Filename.temp_file "masc-antigravity-tool-ended-" ".ready" in
       Sys.remove gate;
       Fun.protect ~finally:(fun () -> if Sys.file_exists gate then Sys.remove gate) @@ fun () ->
       let finished = ref None in
       with_fixture
         (* Start the silence only after the consumer observed the tool end;
            first-event FD sampling cannot consume this producer-side gap. *)
         ~line_gates:[ 3, gate ]
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
                ~on_stream_event:(function
                  | Runtime_antigravity.Native_tool_finished {observation; completion} ->
                    finished := Some (observation.identity, completion.outcome);
                    Out_channel.with_open_bin gate (fun _ -> ())
                  | _ -> ())
                path
            with
            | Error (Runtime_antigravity.Timeout seconds) ->
              let outcome = if final_state = "DONE" then Runtime_native_tools.Completion_reported
                else Runtime_native_tools.Error_reported in
              check bool (final_state ^ ": matching terminal tool update observed") true
                (!finished = Some (Some (Runtime_native_tools.Provider_step
                  {conversation_id="conversation-1";step_index=1}), outcome));
              check bool "the observed tool end released the result's delay" true (Sys.file_exists gate);
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

let test_no_deadline_starts_after_init () =
  let gate = Filename.temp_file "masc-antigravity-init-" ".ready" in
  Sys.remove gate;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists gate then Sys.remove gate)
    (fun () ->
       (* The first-event FD probe precedes the init callback. Start the
          silence only after that callback, so probing cannot consume the
          interval that must outlast admission. Keeping Awaiting_admission
          after init would then time out before the result, even with no
          model-turn deadline. *)
       with_fixture
         ~line_gates:[ 1, gate ]
         ~line_delays:[ 1, window_outlasting_process_start_s +. 0.2 ]
         [ init (); result () ]
         (fun path ->
            match
              run_fixture
                ~admission_timeout_s:window_outlasting_process_start_s
                ~no_turn_deadline:true
                ~on_conversation_ready:(fun ~conversation_id:_ ->
                  let output = open_out_bin gate in
                  close_out output;
                  Ok ())
                path
            with
            | Ok turn ->
              check string "unbounded result" "MASC_ANTIGRAVITY_OK\n" turn.text
            | Error error -> fail (Runtime_antigravity.error_to_string error)))
;;

let test_admission_is_process_free () =
  let config =
    { (Runtime_antigravity.default_config ~cwd:"relative" ~model:"gemini-fixture") with
      cli_path = ""
    }
  in
  let before_spawn_called = ref false in
  let result = Eio_main.run (fun env ->
    Runtime_antigravity.run_turn ~host:(antigravity_host ())
      ~before_spawn:(fun () -> before_spawn_called := true)
      ~mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env)
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
      config ~prompt:"fixture") in
  check bool "invalid configuration does not publish pending ownership" false !before_spawn_called;
  match result with
  | Error (Runtime_antigravity.Invalid_config "cli_path must not be empty") -> ()
  | Error error -> fail (Runtime_antigravity.error_to_string error)
  | Ok _ -> fail "invalid deterministic config passed admission"
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
          Runtime_antigravity.run_turn ~host:(antigravity_host ())
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
      , [ test_case "response content identity and native completion" `Quick test_response_step_ends_preserve_content_identity
        ; test_case "raw current and previous response reconciliation" `Quick
            test_keeper_reconciles_raw_current_and_previous_messages
        ; test_case "complete response closes before tool" `Quick test_done_only_response_closes_before_next_tool
        ; test_case "late response update rejected" `Quick test_late_or_conflicting_response_update_is_rejected
        ; test_case "unassigned ending cannot close named response" `Quick test_unassigned_ends_cannot_close_named_content
        ; test_case "four response steps reconcile final text" `Quick
            test_keeper_reconciles_four_response_steps_and_new_final
        ; test_case "partial steps retain final reply suffix" `Quick
            test_keeper_preserves_final_suffix_after_partial_steps
        ; test_case
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
            "text on other steps is not an answer piece"
            `Quick
            test_text_on_other_steps_is_not_an_answer_piece
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
        ; test_case "repeated native active step retains one chat occurrence" `Quick
            test_repeated_active_native_step_keeps_one_chat_occurrence
        ; test_case
            "resume identity and argv"
            `Quick
            test_resume_requires_exact_identity_and_argv
        ; test_case
            "large prompt uses stdin"
            `Quick
            test_large_prompt_streams_over_stdin
        ; test_case "spawn observer receives the actual child PID" `Quick
            test_spawn_observer_receives_the_actual_child_pid
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
            "agy self-update is off exactly once"
            `Quick
            test_environment_turns_off_agy_auto_update_once
        ; test_case
            "conversation callback"
            `Quick
            test_conversation_callback_precedes_terminal_result
        ; test_case
            "conversation callback failure"
            `Quick
            test_conversation_callback_failure_is_typed
        ; test_case
            "an unexpected exception is unhandled, not a protocol error"
            `Quick
            test_unexpected_exception_is_unhandled
        ; test_case
            "reserved exceptions leave run_turn untyped"
            `Quick
            test_reserved_exceptions_leave_run_turn
        ; test_case
            "callback timeout origin is preserved without deadline"
            `Quick
            test_callback_timeout_origin_is_preserved_without_deadline
        ; test_case "operator interrupt callback keeps typed cause" `Quick
            test_operator_interrupt_callback_keeps_typed_cause
        ; test_case "tool measurements" `Quick test_tool_steps_and_errors_are_measured
        ; test_case "error result" `Quick test_result_error_is_not_success
        ; test_case "documented noncompletion results never complete" `Quick
            test_documented_noncompletion_results_never_complete
        ; test_case "pre-init noncompletion keeps unbound identity" `Quick
            test_pre_init_noncompletion_keeps_unbound_identity
        ; test_case "interrupted partial stream is not a completed reply" `Quick
            test_interrupted_partial_stream_is_not_a_completed_reply
        ; test_case "noncompletion identity mismatch is refused" `Quick
            test_noncompletion_identity_mismatch_is_refused
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
        ; test_case "text before a refused action is not the answer" `Quick
            test_text_before_a_refused_action_is_not_the_answer
        ; test_case "refusal without text names the refusal" `Quick
            test_refusal_without_text_names_the_refusal
        ; test_case "malformed refusal entry is a protocol error" `Quick
            test_malformed_refusal_entry_is_a_protocol_error
        ; test_case "unstreamed text before a refusal is not replayed" `Quick
            test_unstreamed_text_before_a_refusal_is_not_replayed
        ; test_case "refusal detail keeps the refusal sentence from its first word" `Quick
            test_refusal_detail_keeps_the_refusal_sentence_from_its_first_word
        ; test_case "long refusal stderr keeps both ends and masks first" `Quick
            test_long_refusal_stderr_keeps_both_ends_and_masks_first
        ; test_case "ERROR result with refusals is Actions_denied" `Quick
            test_error_result_with_refusals_is_actions_denied
        ; test_case "refusals keep the CLI order" `Quick test_refusals_keep_the_cli_order
        ; test_case "absent refusals complete the turn" `Quick
            test_absent_refusals_complete_the_turn
        ; test_case "noncompletion keeps its refusals" `Quick
            test_noncompletion_keeps_its_refusals
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
            "tool step outlasting the idle window completes"
            `Quick
            test_tool_step_outlasting_the_idle_window_completes
        ; test_case
            "closed response replay preserves the running tool phase"
            `Quick
            test_response_replay_preserves_the_running_tool_phase
        ; test_case
            "idle window re-arms when the tool step ends"
            `Quick
            test_idle_window_rearms_when_the_tool_step_ends
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
        ; test_case
            "stderr cutoff cannot retain an opaque credential without its key"
            `Quick
            test_stderr_cut_inside_assignment_omits_the_diagnostic
        ; test_case
            "stderr read chunks preserve the masking boundary"
            `Quick
            test_stderr_chunk_boundaries_preserve_redaction_context
        ; test_case
            "tool steps carry the 2h idle backstop, not no bound"
            `Quick
            test_tool_step_phase_carries_idle_backstop
        ] )
    ; "live official client", [ test_case "official agy start and resume" `Slow test_live_start_and_resume ]
    ]
;;
