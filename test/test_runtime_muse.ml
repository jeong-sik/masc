open Alcotest

(* Recorded from `muse exec --provider echo --json`: the envelope shape is
   verbatim, only the ids are shortened. *)
let accepted =
  {|{"schema_version":1,"stream":{"kind":"session","id":"sess-1"},"sequence":1,"payload_type":"runtime.command.accepted","payload":{"kind":"command_accepted","command_id":"cmd-1"}}|}
;;

let user_input =
  {|{"schema_version":1,"stream":{"kind":"session","id":"sess-1"},"sequence":4,"payload_type":"turn.input.user","payload":{"kind":"turn_input_user","run_stream":{"kind":"run","id":"run-1"},"prompt":"say hi"}}|}
;;

let task_noise =
  {|{"schema_version":1,"stream":{"kind":"session","id":"sess-1"},"sequence":9,"payload_type":"task.lifecycle.scheduled","payload":{"kind":"task_lifecycle","run_stream":{"kind":"run","id":"run-1"},"event":{"kind":"scheduled"}}}|}
;;

let delta =
  {|{"schema_version":1,"stream":{"kind":"session","id":"sess-1"},"sequence":18,"payload_type":"run.output.delta","payload":{"kind":"run_output_delta","run_stream":{"kind":"run","id":"run-1"},"text":"echo: say hi"}}|}
;;

let terminal_completed =
  {|{"schema_version":1,"stream":{"kind":"session","id":"sess-1"},"sequence":28,"payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","run_stream":{"kind":"run","id":"run-1"},"terminal":"completed","text":"echo: say hi","reason":null}}|}
;;

let terminal_completed_with_usage =
  {|{"schema_version":1,"stream":{"kind":"session","id":"sess-1"},"sequence":28,"payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","run_stream":{"kind":"run","id":"run-1"},"terminal":"completed","text":"done","reason":null,"usage":{"inputTokens":10,"outputTokens":3,"reasoningTokens":1,"cachedTokens":2}}}|}
;;

let terminal_completed_partial_usage =
  {|{"schema_version":1,"stream":{"kind":"session","id":"sess-1"},"sequence":28,"payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","run_stream":{"kind":"run","id":"run-1"},"terminal":"completed","text":"done","reason":null,"usage":{"outputTokens":3}}}|}
;;

let terminal_failed =
  {|{"schema_version":1,"stream":{"kind":"session","id":"sess-1"},"sequence":28,"payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","run_stream":{"kind":"run","id":"run-1"},"terminal":"failed","reason":"boom","usage":{"inputTokens":10,"outputTokens":3,"reasoningTokens":0,"cachedTokens":0}}}|}
;;

let terminal_unknown =
  {|{"schema_version":1,"stream":{"kind":"session","id":"sess-1"},"sequence":28,"payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","run_stream":{"kind":"run","id":"run-1"},"terminal":"stalled","reason":null}}|}
;;

let missing_kind =
  {|{"schema_version":1,"stream":{"kind":"session","id":"sess-1"},"sequence":1,"payload_type":"runtime.command.accepted","payload":{"command_id":"cmd-1"}}|}
;;

let parse line = Yojson.Safe.from_string line

let fold lines =
  List.fold_left
    (fun acc line ->
      match acc with
      | Error _ as err -> err
      | Ok (progress, events) ->
        (match Runtime_muse.apply_record progress (parse line) with
         | Error _ as err -> err
         | Ok (progress, fresh) -> Ok (progress, events @ fresh)))
    (Ok (Runtime_muse.empty_progress, []))
    lines
;;

let test_completed_turn_reports_terminal_text_once () =
  match fold [ accepted; user_input; task_noise; delta; terminal_completed ] with
  | Error err -> fail ("fold failed: " ^ Runtime_muse.error_to_string err)
  | Ok (progress, events) ->
    (match events with
     | [ Runtime_muse.Turn_started { session_id; turn_id }
       ; Runtime_muse.Text_delta text
       ; Runtime_muse.Turn_finished { text = answer }
       ] ->
       check string "session" "sess-1" session_id;
       (* The first record carries no run id; the run id arrives later
          and updates the fold state without a second start event. *)
       check (option string) "turn at start" None turn_id;
       check (option string) "turn at end" (Some "run-1") progress.Runtime_muse.turn_id;
       check string "delta" "echo: say hi" text;
       (* The terminal text is the answer; the delta is display-only. *)
       check string "answer" "echo: say hi" answer
     | _ -> fail "unexpected event sequence")
;;

let test_unknown_payloads_are_ignored () =
  match fold [ task_noise; task_noise ] with
  | Error err -> fail ("fold failed: " ^ Runtime_muse.error_to_string err)
  | Ok (_, events) ->
    (match events with
     | [ Runtime_muse.Turn_started _ ] -> ()
     | _ -> fail "noise must start the turn and nothing else")
;;

let test_complete_usage_is_reported_before_finish () =
  match fold [ accepted; terminal_completed_with_usage ] with
  | Error err -> fail ("fold failed: " ^ Runtime_muse.error_to_string err)
  | Ok (_, events) ->
    (match events with
     | [ Runtime_muse.Turn_started _
       ; Runtime_muse.Usage_reported { session_id; usage }
       ; Runtime_muse.Turn_finished _
       ] ->
       check string "session" "sess-1" session_id;
       check int "input" 10 usage.Runtime_muse.input_tokens;
       check int "output" 3 usage.Runtime_muse.output_tokens;
       check int "reasoning" 1 usage.Runtime_muse.reasoning_tokens;
       check int "cached" 2 usage.Runtime_muse.cached_tokens
     | _ -> fail "usage must precede finish")
;;

let test_partial_usage_reports_nothing () =
  match fold [ accepted; terminal_completed_partial_usage ] with
  | Error err -> fail ("fold failed: " ^ Runtime_muse.error_to_string err)
  | Ok (_, events) ->
    (match events with
     | [ Runtime_muse.Turn_started _; Runtime_muse.Turn_finished _ ] -> ()
     | _ -> fail "partial usage must not zero-fill an event")
;;

let test_failed_terminal_carries_reason_and_usage () =
  match fold [ accepted; terminal_failed ] with
  | Ok _ -> fail "a failed terminal must end the fold"
  | Error (Runtime_muse.Turn_failed { terminal; reason; usage }) ->
    check string "terminal" "failed" terminal;
    check (option string) "reason" (Some "boom") reason;
    (match usage with
     | None -> fail "complete usage on a failed turn must be carried"
     | Some usage -> check int "output" 3 usage.Runtime_muse.output_tokens)
  | Error err -> fail ("wrong error: " ^ Runtime_muse.error_to_string err)
;;

let test_unknown_terminal_word_is_protocol_error () =
  match fold [ accepted; terminal_unknown ] with
  | Error (Runtime_muse.Protocol_error _) -> ()
  | Ok _ -> fail "an unknown terminal word must not succeed"
  | Error err -> fail ("wrong error: " ^ Runtime_muse.error_to_string err)
;;

let test_missing_kind_is_protocol_error () =
  match Runtime_muse.apply_record Runtime_muse.empty_progress (parse missing_kind) with
  | Error (Runtime_muse.Protocol_error _) -> ()
  | Ok _ -> fail "a kindless record must not fold"
  | Error err -> fail ("wrong error: " ^ Runtime_muse.error_to_string err)
;;

let test_non_object_is_protocol_error () =
  match Runtime_muse.apply_record Runtime_muse.empty_progress (`String "nope") with
  | Error (Runtime_muse.Protocol_error _) -> ()
  | Ok _ -> fail "a non-object must not fold"
  | Error err -> fail ("wrong error: " ^ Runtime_muse.error_to_string err)
;;

let default_config () = Runtime_muse.default_config ~cwd:"/tmp/base"

let test_command_pins_default_argv () =
  let config = default_config () in
  match
    Runtime_muse.command ~prompt_file:"/tmp/p.txt" ~schema_file:None ~images:[]
      ~session_mode:Runtime_muse.Start config
  with
  | Error err -> fail (Runtime_muse.error_to_string err)
  | Ok argv ->
    check (list string)
      "argv"
      [ "muse"; "exec"; "--json"; "--prompt-file"; "/tmp/p.txt"; "--workspace"; "/tmp/base"
      ; "--approval-mode"; "on-request"
      ]
      argv
;;

let test_command_pins_full_argv () =
  let config =
    Runtime_muse.
      { (default_config ~cwd:"/tmp/base") with
        model = Some "muse-spark-1.3"
      ; reasoning_effort = Some Effort_high
      ; approval_mode = Never
      }
  in
  let images = [ Runtime_muse.{ path = "/tmp/a.png" } ] in
  match
    Runtime_muse.command ~prompt_file:"/tmp/p.txt" ~schema_file:(Some "/tmp/s.json") ~images
      ~session_mode:Runtime_muse.Start config
  with
  | Error err -> fail (Runtime_muse.error_to_string err)
  | Ok argv ->
    check (list string)
      "argv"
      [ "muse"; "exec"; "--json"; "--prompt-file"; "/tmp/p.txt"; "--workspace"; "/tmp/base"
      ; "--approval-mode"; "never"; "--model"; "muse-spark-1.3"; "--reasoning-effort"; "high"
      ; "--image"; "/tmp/a.png"; "--output-schema"; "/tmp/s.json"
      ]
      argv
;;

let test_blank_model_is_rejected () =
  let config = Runtime_muse.{ (default_config ~cwd:"/tmp/base") with model = Some "  " } in
  match
    Runtime_muse.command ~prompt_file:"/tmp/p.txt" ~schema_file:None ~images:[]
      ~session_mode:Runtime_muse.Start config
  with
  | Error (Runtime_muse.Invalid_config _) -> ()
  | Ok _ -> fail "a blank model must not spell the CLI default"
  | Error err -> fail ("wrong error: " ^ Runtime_muse.error_to_string err)
;;

let test_command_pins_resume_argv () =
  let config = default_config () in
  match
    Runtime_muse.command ~prompt_file:"/tmp/p.txt" ~schema_file:None ~images:[]
      ~session_mode:(Runtime_muse.Resume { session_id = "sess-9" })
      config
  with
  | Error err -> fail (Runtime_muse.error_to_string err)
  | Ok argv ->
    check (list string)
      "argv"
      [ "muse"; "exec"; "--json"; "--prompt-file"; "/tmp/p.txt"; "--workspace"; "/tmp/base"
      ; "--approval-mode"; "on-request"; "--session-id"; "sess-9"
      ]
      argv
;;

(* The fixture answers like the recorded CLI: two envelope lines, then a
   clean exit. It ignores argv, so these tests pin the client's reading of
   the stream, not the flags it was spawned with (pinned above). *)
let with_fixture_script lines f =
  let path = Filename.temp_file "masc-muse-fixture-" ".sh" in
  let channel = open_out_bin path in
  output_string channel "#!/bin/sh\n";
  List.iter (fun line -> Printf.fprintf channel "printf '%%s\\n' '%s'\n" line) lines;
  close_out channel;
  Unix.chmod path 0o755;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let run_fixture ?(timeout_s = 5.0) ~on_stream_event ?on_prompt_sent ?on_session_ready path =
  Eio_main.run (fun env ->
    let config =
      Runtime_muse.
        { (default_config ~cwd:"/tmp") with
          cli_path = path
        ; admission_timeout_s = timeout_s
        ; timeout_s = Some timeout_s
        }
    in
    Runtime_muse.run_turn
      ~mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env)
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
      ?on_prompt_sent
      ?on_session_ready
      ~on_stream_event config ~prompt:"say hi" ~images:[])
;;

let test_run_turn_fires_prompt_sent_and_session_ready () =
  with_fixture_script [ accepted; terminal_completed ] (fun path ->
    let sent = ref false in
    let ready = ref None in
    let result =
      run_fixture
        ~on_stream_event:(fun _ -> ())
        ~on_prompt_sent:(fun () -> sent := true)
        ~on_session_ready:(fun ~session_id ~turn_id -> ready := Some (session_id, turn_id))
        path
    in
    (match result with
     | Error err -> fail ("run_turn failed: " ^ Runtime_muse.error_to_string err)
     | Ok _ -> ());
    check bool "prompt sent" true !sent;
    check
      (option (pair string (option string)))
      "session ready"
      (Some ("sess-1", None))
      !ready)
;;

let with_serve_fixture ~usage_result f =
  let path = Filename.temp_file "masc-muse-serve-" ".sh" in
  let channel = open_out_bin path in
  output_string channel "#!/bin/sh\nread _; read _; read _\n";
  Printf.fprintf channel
    "printf '%%s\\n' '%s'\n"
    {|{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"muse","version":"9.9.9"}}}|};
  Printf.fprintf channel "printf '%%s\\n' '%s'\n" usage_result;
  close_out channel;
  Unix.chmod path 0o755;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let serve_fixture ?(timeout_s = 5.0) path =
  Eio_main.run (fun env ->
    let config =
      Runtime_muse.
        { (default_config ~cwd:"/tmp") with
          cli_path = path
        ; admission_timeout_s = timeout_s
        ; timeout_s = Some timeout_s
        }
    in
    Runtime_muse.serve_usage
      ~mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env)
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
      config)
;;

let test_serve_usage_returns_raw_usage () =
  with_serve_fixture
    ~usage_result:
      {|{"jsonrpc":"2.0","id":2,"result":{"usage":{"window":{"usedPercent":67,"resetsAtMs":1780500000000,"windowDurationMins":300}}}}|}
    (fun path ->
      match serve_fixture path with
      | Error err -> fail ("serve_usage failed: " ^ Runtime_muse.error_to_string err)
      | Ok None -> fail "the host stated usage"
      | Ok (Some json) ->
        (match json with
         | `Assoc fields ->
           (match List.assoc_opt "window" fields with
            | Some (`Assoc window) ->
              check
                (option (testable Yojson.Safe.pp Yojson.Safe.equal))
                "percent"
                (Some (`Int 67))
                (List.assoc_opt "usedPercent" window)
            | _ -> fail "usage.window missing")
         | _ -> fail "usage is not an object"))
;;

let test_serve_usage_empty_result_is_absence () =
  with_serve_fixture ~usage_result:{|{"jsonrpc":"2.0","id":2,"result":{}}|} (fun path ->
    match serve_fixture path with
    | Error err -> fail ("serve_usage failed: " ^ Runtime_muse.error_to_string err)
    | Ok None -> ()
    | Ok (Some _) -> fail "a bare result must read as absence")
;;

let test_serve_usage_rpc_error_is_protocol_error () =
  with_serve_fixture
    ~usage_result:
      {|{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Not initialized"}}|}
    (fun path ->
      match serve_fixture path with
      | Error (Runtime_muse.Protocol_error { detail; _ }) ->
        check string "code and message carried" "request 2: code -32600: Not initialized" detail
      | Ok _ -> fail "a refused request must not read as usage"
      | Error err -> fail ("wrong error: " ^ Runtime_muse.error_to_string err))
;;

let test_effort_mapping_is_total () =
  let open Llm_provider.Reasoning_effort in
  let cases =
    [ None_, "none"
    ; Minimal, "minimal"
    ; Low, "low"
    ; Medium, "medium"
    ; High, "high"
    ; XHigh, "xhigh"
    ; Max, "max"
    ]
  in
  List.iter
    (fun (effort, expected) ->
      check string "spelling" expected
        (Runtime_muse.effort_to_string (Runtime_muse.effort_of_reasoning_effort effort)))
    cases
;;

let test_run_turn_serves_recorded_stream () =
  with_fixture_script [ accepted; terminal_completed ] (fun path ->
    let events = ref [] in
    let result = run_fixture ~on_stream_event:(fun event -> events := event :: !events) path in
    match result with
    | Error err -> fail ("run_turn failed: " ^ Runtime_muse.error_to_string err)
    | Ok turn ->
      check string "session" "sess-1" turn.Runtime_muse.session_id;
      check string "answer" "echo: say hi" turn.Runtime_muse.text;
      check bool "resumed" false turn.Runtime_muse.resumed;
      check int "events" 2 (List.length !events))
;;

let test_run_turn_reports_failed_terminal () =
  with_fixture_script [ accepted; terminal_failed ] (fun path ->
    let events = ref [] in
    let result = run_fixture ~on_stream_event:(fun event -> events := event :: !events) path in
    match result with
    | Ok _ -> fail "a failed terminal must fail the turn"
    | Error (Runtime_muse.Turn_failed { terminal; reason; usage }) ->
      check string "terminal" "failed" terminal;
      check (option string) "reason" (Some "boom") reason;
      check bool "usage carried" true (Option.is_some usage);
      (* The spend is still observed before the failure lands. *)
      check int "events" 2 (List.length !events)
    | Error err -> fail ("wrong error: " ^ Runtime_muse.error_to_string err))
;;

let test_run_turn_rejects_empty_prompt_without_spawning () =
  let result =
    Eio_main.run (fun env ->
      let config =
        Runtime_muse.{ (default_config ~cwd:"/tmp") with cli_path = "/nonexistent/muse" }
      in
      Runtime_muse.run_turn
        ~mgr:(Eio.Stdenv.process_mgr env)
        ~clock:(Eio.Stdenv.clock env)
        ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
        config ~prompt:"  " ~images:[])
  in
  match result with
  | Error (Runtime_muse.Invalid_config _) -> ()
  | Ok _ -> fail "an empty prompt must not spawn"
  | Error err -> fail ("wrong error: " ^ Runtime_muse.error_to_string err)
;;

let () =
  run
    "runtime_muse"
    [ ( "msp fold"
      , [ test_case "completed turn reports terminal text once" `Quick
            test_completed_turn_reports_terminal_text_once
        ; test_case "unknown payloads are ignored" `Quick test_unknown_payloads_are_ignored
        ; test_case "complete usage is reported before finish" `Quick
            test_complete_usage_is_reported_before_finish
        ; test_case "partial usage reports nothing" `Quick test_partial_usage_reports_nothing
        ; test_case "failed terminal carries reason and usage" `Quick
            test_failed_terminal_carries_reason_and_usage
        ; test_case "unknown terminal word is protocol error" `Quick
            test_unknown_terminal_word_is_protocol_error
        ; test_case "missing kind is protocol error" `Quick test_missing_kind_is_protocol_error
        ; test_case "non-object is protocol error" `Quick test_non_object_is_protocol_error
        ]
      )
    ; ( "argv"
      , [ test_case "default argv pinned" `Quick test_command_pins_default_argv
        ; test_case "full argv pinned" `Quick test_command_pins_full_argv
        ; test_case "blank model rejected" `Quick test_blank_model_is_rejected
        ; test_case "resume argv pinned" `Quick test_command_pins_resume_argv
        ]
      )
    ; ( "spawn"
      , [ test_case "serves recorded stream" `Quick test_run_turn_serves_recorded_stream
        ; test_case "reports failed terminal" `Quick test_run_turn_reports_failed_terminal
        ; test_case "rejects empty prompt without spawning" `Quick
            test_run_turn_rejects_empty_prompt_without_spawning
        ; test_case "fires prompt sent and session ready" `Quick
            test_run_turn_fires_prompt_sent_and_session_ready
        ]
      )
    ; ("effort", [ test_case "mapping is total" `Quick test_effort_mapping_is_total ])
    ; ( "serve"
      , [ test_case "returns raw usage" `Quick test_serve_usage_returns_raw_usage
        ; test_case "empty result is absence" `Quick test_serve_usage_empty_result_is_absence
        ; test_case "rpc error is protocol error" `Quick test_serve_usage_rpc_error_is_protocol_error
        ]
      )
    ]
;;
