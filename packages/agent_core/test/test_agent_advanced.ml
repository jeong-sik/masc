(** Typed cooperative tool-boundary execution tests. *)

open Agent_sdk

let mock_provider =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~provider_id:"test"
    ~api_key:""
    ~headers:[ "Content-Type", "application/json" ]
    ~request_path:"/v1/chat/completions"
    ~base_url:"http://mock.local"
    ~model_id:"mock-model"
    ()
;;

let text_response text : Types.api_response =
  { id = "advanced-text"
  ; model = "mock-model"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text text ]
  ; usage = None
  ; telemetry = None
  }
;;

let tool_use_response : Types.api_response =
  { id = "advanced-tool"
  ; model = "mock-model"
  ; stop_reason = Types.StopToolUse
  ; content =
      [ Types.ToolUse
          { id = "call_1"
          ; name = "get_time"
          ; input = `Assoc [ "timezone", `String "UTC" ]
          }
      ]
  ; usage = None
  ; telemetry = None
  }
;;

let sequence_transport ?(on_call = ignore) responses =
  let remaining = ref responses in
  let call_count = ref 0 in
  let next () =
    on_call ();
    incr call_count;
    match !remaining with
    | response :: rest ->
      remaining := rest;
      response
    | [] -> Alcotest.fail "mock transport exhausted"
  in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun _request ->
          { Llm_provider.Llm_transport.response = Ok (next ()); latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok (next ()))
    }
  in
  transport, call_count
;;

let make_agent
      ~net
      ~transport
      ~raw_trace
      ~checkpoint_sink
      ~context_injector
      ~on_run_complete
      ~tool
  =
  let options =
    { Agent.default_options with
      provider_config = Some mock_provider
    ; transport = Some transport
    ; raw_trace = Some raw_trace
    ; context_injector
    ; on_run_complete
    }
  in
  let config =
    { (Types.default_config ~model:"mock-model") with
      name = "advanced-boundary-test"
    ; yield_on_tool = true
    }
  in
  Agent.create ~net ~config ~tools:[ tool ] ~options ~checkpoint_sink ()
;;

let time_tool ?descriptor ?result on_execute =
  Tool.create
    ?descriptor
    ~name:"get_time"
    ~description:"Get current time"
    ~parameters:
      [ { Types.name = "timezone"
        ; param_type = Types.String
        ; description = "timezone"
        ; required = true
        }
      ]
    (fun _input ->
       on_execute ();
       match result with
       | Some result -> result
       | None -> Ok { Types.content = "12:00 UTC"; _meta = None })
;;

let messages_contain_text expected messages =
  List.exists
    (fun (message : Types.message) ->
       List.exists
         (function
           | Types.Text text -> String.equal expected text
           | Types.Thinking _
           | Types.ReasoningDetails _
           | Types.RedactedThinking _
           | Types.ToolUse _
           | Types.ToolResult _
           | Types.Image _
           | Types.Document _
           | Types.Audio _ -> false)
         message.content)
    messages
;;

let last_record path =
  match Raw_trace.read_all ~path () with
  | Error error -> Alcotest.fail (Error.to_string error)
  | Ok records ->
    (match List.rev records with
     | record :: _ -> record
     | [] -> Alcotest.fail "raw trace is empty")
;;

let with_temp_trace f =
  let path = Filename.temp_file "oas-agent-advanced" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)
;;

let test_yield_after_context_checkpoint () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let persisted = ref [] in
  let checkpoint_sink snapshot =
    persisted := snapshot :: !persisted;
    Ok ()
  in
  let tool_executed = ref false in
  let context_injected = ref false in
  let context_injector ~tool_name:_ ~input:_ ~output:_ =
    context_injected := true;
    Some
      { Hooks.context_updates = []
      ; extra_messages =
          [ Types.make_message ~role:Types.User [ Types.Text "projected context" ] ]
      }
  in
  let completions = ref [] in
  let lease_events = ref [] in
  let transport, call_count =
    sequence_transport
      ~on_call:(fun () -> lease_events := "provider" :: !lease_events)
      [ tool_use_response ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink
      ~context_injector:(Some context_injector)
      ~on_run_complete:(Some (fun completed -> completions := completed :: !completions))
      ~tool:
        (time_tool (fun () ->
           tool_executed := true;
           lease_events := "tool" :: !lease_events))
  in
  let callback_count = ref 0 in
  let on_tool_boundary (boundary : Agent.Advanced.tool_boundary) =
    lease_events := "boundary" :: !lease_events;
    incr callback_count;
    Alcotest.(check bool) "tool completed before callback" true !tool_executed;
    Alcotest.(check bool) "context injected before callback" true !context_injected;
    (match !persisted with
     | latest :: _ ->
       Alcotest.(check bool)
         "context checkpoint persisted before callback"
         true
         (latest.Agent.stage = Agent.After_context_injection)
     | [] -> Alcotest.fail "callback ran without a successful checkpoint");
    Alcotest.(check int) "boundary turn" 1 boundary.turn;
    Alcotest.(check bool)
      "boundary stage"
      true
      (boundary.checkpoint_stage = Agent.After_context_injection);
    Agent.Advanced.Yield
  in
  let on_yield () =
    Alcotest.(check bool) "tool not started at lease release" false !tool_executed;
    (match !persisted with
     | latest :: _ ->
       Alcotest.(check bool)
         "assistant checkpoint persisted before provider lease release"
         true
         (latest.Agent.stage = Agent.After_assistant_collected)
     | [] -> Alcotest.fail "lease released before assistant checkpoint");
    lease_events := "yield" :: !lease_events
  in
  (match
     Agent.Advanced.run_blocks
       ~sw
       ~on_yield
       ~on_resume:(fun () -> lease_events := "resume" :: !lease_events)
       ~api_strategy:Agent.Sync
       ~on_tool_boundary
       agent
       [ Types.Text "what time is it?" ]
   with
   | Error error -> Alcotest.fail (Error.to_string error)
   | Ok (Agent.Advanced.Completed _) -> Alcotest.fail "expected cooperative yield"
   | Ok (Agent.Advanced.Terminal_tool_completed _) ->
     Alcotest.fail "expected cooperative yield"
   | Ok (Agent.Advanced.Yielded yielded) ->
     Alcotest.(check int) "yielded turn" 1 yielded.turn;
     Alcotest.(check int) "checkpoint turn" 1 yielded.checkpoint.turn_count;
     Alcotest.(check bool)
       "yielded checkpoint stage"
       true
       (yielded.checkpoint_stage = Agent.After_context_injection);
     Alcotest.(check bool)
       "yielded checkpoint includes projected context"
       true
       (messages_contain_text "projected context" yielded.checkpoint.messages));
  Alcotest.(check int) "callback count" 1 !callback_count;
  Alcotest.(check (list string))
    "yield releases before boundary and does not resume"
    [ "provider"; "yield"; "tool"; "boundary" ]
    (List.rev !lease_events);
  Alcotest.(check int) "provider call count" 1 !call_count;
  Alcotest.(check (list bool)) "not terminal-complete" [] !completions;
  (match Agent.lifecycle agent with
   | Some snapshot ->
     Alcotest.(check bool) "lifecycle ready" true (snapshot.status = Agent.Ready);
     Alcotest.(check (option string)) "no lifecycle error" None snapshot.last_error
   | None -> Alcotest.fail "missing lifecycle snapshot");
  let record = last_record trace_path in
  Alcotest.(check bool) "trace finished" true (record.record_type = Raw_trace.Run_finished);
  Alcotest.(check (option string)) "trace error" None record.error;
  Alcotest.(check (option string))
    "trace yield outcome"
    (Some "cooperative_tool_boundary_yield")
    record.stop_reason
;;

let test_continue_reaches_terminal_completion () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let checkpoint_sink _snapshot = Ok () in
  let completions = ref [] in
  let lease_events = ref [] in
  let transport, call_count =
    sequence_transport
      ~on_call:(fun () -> lease_events := "provider" :: !lease_events)
      [ tool_use_response; text_response "done" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink
      ~context_injector:None
      ~on_run_complete:(Some (fun completed -> completions := completed :: !completions))
      ~tool:(time_tool (fun () -> lease_events := "tool" :: !lease_events))
  in
  let callback_count = ref 0 in
  let on_tool_boundary (boundary : Agent.Advanced.tool_boundary) =
    lease_events := "boundary" :: !lease_events;
    incr callback_count;
    Alcotest.(check bool)
      "base tool-result checkpoint boundary"
      true
      (boundary.checkpoint_stage = Agent.After_tool_results_appended);
    Agent.Advanced.Continue
  in
  (match
     Agent.Advanced.run_blocks
       ~sw
       ~on_yield:(fun () -> lease_events := "yield" :: !lease_events)
       ~on_resume:(fun () -> lease_events := "resume" :: !lease_events)
       ~api_strategy:Agent.Sync
       ~on_tool_boundary
       agent
       [ Types.Text "what time is it?" ]
   with
   | Error error -> Alcotest.fail (Error.to_string error)
   | Ok (Agent.Advanced.Yielded _) -> Alcotest.fail "expected terminal completion"
   | Ok (Agent.Advanced.Terminal_tool_completed _) ->
     Alcotest.fail "expected provider terminal completion"
   | Ok (Agent.Advanced.Completed response) ->
     Alcotest.(check string)
       "visible response"
       "done"
       (Types.visible_text_of_response response));
  Alcotest.(check int) "callback count" 1 !callback_count;
  Alcotest.(check (list string))
    "continue release-boundary-resume ordering"
    [ "provider"; "yield"; "tool"; "boundary"; "resume"; "provider" ]
    (List.rev !lease_events);
  Alcotest.(check int) "provider call count" 2 !call_count;
  Alcotest.(check (list bool)) "terminal callback" [ true ] !completions;
  (match Agent.lifecycle agent with
   | Some snapshot ->
     Alcotest.(check bool) "lifecycle completed" true (snapshot.status = Agent.Completed)
   | None -> Alcotest.fail "missing lifecycle snapshot");
  let record = last_record trace_path in
  Alcotest.(check (option string)) "trace error" None record.error;
  Alcotest.(check (option string))
    "terminal stop reason"
    (Some (Types.show_stop_reason Types.EndTurn))
    record.stop_reason
;;

let test_context_checkpoint_failure_prevents_boundary_and_resume () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let checkpoint_sink (snapshot : Agent.checkpoint_snapshot) =
    match snapshot.stage with
    | Agent.After_context_injection -> Error "durable sink rejected boundary"
    | Agent.After_assistant_collected | Agent.After_tool_results_appended -> Ok ()
  in
  let context_injector ~tool_name:_ ~input:_ ~output:_ =
    Some { Hooks.context_updates = []; extra_messages = [] }
  in
  let lease_events = ref [] in
  let tool_executed = ref false in
  let transport, _call_count =
    sequence_transport
      ~on_call:(fun () -> lease_events := "provider" :: !lease_events)
      [ tool_use_response ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink
      ~context_injector:(Some context_injector)
      ~on_run_complete:None
      ~tool:
        (time_tool (fun () ->
           tool_executed := true;
           lease_events := "tool" :: !lease_events))
  in
  let callback_count = ref 0 in
  let outcome =
    Agent.Advanced.run_blocks
      ~sw
      ~on_yield:(fun () -> lease_events := "yield" :: !lease_events)
      ~on_resume:(fun () -> lease_events := "resume" :: !lease_events)
      ~api_strategy:Agent.Sync
      ~on_tool_boundary:(fun _boundary ->
        incr callback_count;
        Agent.Advanced.Yield)
      agent
      [ Types.Text "what time is it?" ]
  in
  (match outcome with
   | Error (Error.Internal _) -> ()
   | Error error -> Alcotest.fail ("unexpected error: " ^ Error.to_string error)
   | Ok _ -> Alcotest.fail "expected checkpoint failure");
  Alcotest.(check int) "callback suppressed" 0 !callback_count;
  Alcotest.(check bool) "tool ran after lease release" true !tool_executed;
  Alcotest.(check (list string))
    "context checkpoint failure does not reacquire provider lease"
    [ "provider"; "yield"; "tool" ]
    (List.rev !lease_events);
  (match Agent.lifecycle agent with
   | Some snapshot ->
     Alcotest.(check bool) "lifecycle failed" true (snapshot.status = Agent.Failed)
   | None -> Alcotest.fail "missing lifecycle snapshot");
  let record = last_record trace_path in
  Alcotest.(check bool)
    "trace has typed failure detail"
    true
    (Option.is_some record.error);
  Alcotest.(check (option string)) "no yield stop reason" None record.stop_reason
;;

let test_assistant_checkpoint_failure_suppresses_release_and_tool () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let checkpoint_sink (snapshot : Agent.checkpoint_snapshot) =
    match snapshot.stage with
    | Agent.After_assistant_collected -> Error "assistant checkpoint rejected"
    | Agent.After_tool_results_appended | Agent.After_context_injection -> Ok ()
  in
  let lease_events = ref [] in
  let tool_executed = ref false in
  let transport, call_count =
    sequence_transport
      ~on_call:(fun () -> lease_events := "provider" :: !lease_events)
      [ tool_use_response ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink
      ~context_injector:None
      ~on_run_complete:None
      ~tool:(time_tool (fun () -> tool_executed := true))
  in
  let boundary_count = ref 0 in
  let outcome =
    Agent.Advanced.run_blocks
      ~sw
      ~on_yield:(fun () -> lease_events := "yield" :: !lease_events)
      ~on_resume:(fun () -> lease_events := "resume" :: !lease_events)
      ~api_strategy:Agent.Sync
      ~on_tool_boundary:(fun _boundary ->
        incr boundary_count;
        Agent.Advanced.Continue)
      agent
      [ Types.Text "what time is it?" ]
  in
  (match outcome with
   | Error (Error.Internal _) -> ()
   | Error error -> Alcotest.fail ("unexpected error: " ^ Error.to_string error)
   | Ok _ -> Alcotest.fail "expected assistant checkpoint failure");
  Alcotest.(check int) "one provider call" 1 !call_count;
  Alcotest.(check int) "boundary suppressed" 0 !boundary_count;
  Alcotest.(check bool) "tool suppressed" false !tool_executed;
  Alcotest.(check (list string))
    "lease release suppressed"
    [ "provider" ]
    (List.rev !lease_events)
;;

let test_release_callback_failure_prevents_tool_execution () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let tool_executed = ref false in
  let boundary_count = ref 0 in
  let resume_count = ref 0 in
  let transport, _call_count = sequence_transport [ tool_use_response ] in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _snapshot -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:(time_tool (fun () -> tool_executed := true))
  in
  let callback_failed =
    match
      Agent.Advanced.run_blocks
        ~sw
        ~on_yield:(fun () -> raise (Failure "provider lease release failed"))
        ~on_resume:(fun () -> incr resume_count)
        ~api_strategy:Agent.Sync
        ~on_tool_boundary:(fun _boundary ->
          incr boundary_count;
          Agent.Advanced.Continue)
        agent
        [ Types.Text "what time is it?" ]
    with
    | Ok _ | Error _ -> false
    | exception Failure _ -> true
  in
  Alcotest.(check bool) "release callback failure propagated" true callback_failed;
  Alcotest.(check bool) "tool did not start" false !tool_executed;
  Alcotest.(check int) "boundary did not run" 0 !boundary_count;
  Alcotest.(check int) "lease was not reacquired" 0 !resume_count;
  match Agent.lifecycle agent with
  | Some snapshot ->
    Alcotest.(check bool) "lifecycle failed" true (snapshot.status = Agent.Failed)
  | None -> Alcotest.fail "missing lifecycle snapshot"
;;

let test_regular_run_releases_before_tool_execution () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let lease_events = ref [] in
  let tool_executed = ref false in
  let transport, call_count =
    sequence_transport
      ~on_call:(fun () -> lease_events := "provider" :: !lease_events)
      [ tool_use_response; text_response "done" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _snapshot -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:
        (time_tool (fun () ->
           tool_executed := true;
           lease_events := "tool" :: !lease_events))
  in
  (match
     Agent.run_blocks
       ~sw
       ~on_yield:(fun () ->
         Alcotest.(check bool) "tool not started" false !tool_executed;
         lease_events := "yield" :: !lease_events)
       ~on_resume:(fun () -> lease_events := "resume" :: !lease_events)
       agent
       [ Types.Text "what time is it?" ]
   with
   | Error error -> Alcotest.fail (Error.to_string error)
   | Ok response ->
     Alcotest.(check string)
       "visible response"
       "done"
       (Types.visible_text_of_response response));
  Alcotest.(check int) "two provider calls" 2 !call_count;
  Alcotest.(check (list string))
    "regular run release-tool-resume ordering"
    [ "provider"; "yield"; "tool"; "resume"; "provider" ]
    (List.rev !lease_events)
;;

let test_unpaired_lease_callback_is_rejected () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let transport, call_count = sequence_transport [ text_response "unused" ] in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _snapshot -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:(time_tool ignore)
  in
  (match
     Agent.Advanced.run_blocks
       ~sw
       ~on_yield:ignore
       ~api_strategy:Agent.Sync
       ~on_tool_boundary:(fun _boundary -> Agent.Advanced.Continue)
       agent
       [ Types.Text "must not reach provider" ]
   with
   | Error (Error.Config (Error.InvalidConfig { field; _ })) ->
     Alcotest.(check string) "callback pair field" "on_yield/on_resume" field
   | Error error -> Alcotest.fail ("unexpected error: " ^ Error.to_string error)
   | Ok _ -> Alcotest.fail "expected unpaired callback validation error");
  Alcotest.(check int) "provider not called" 0 !call_count
;;

let test_malformed_terminal_admission_keeps_provider_lease_held () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let malformed_response =
    match tool_use_response.content with
    | [ ToolUse { name; input; _ } ] ->
      { tool_use_response with
        content =
          [ ToolUse { id = "malformed-terminal-1"; name; input }
          ; ToolUse { id = "malformed-terminal-2"; name; input }
          ]
      }
    | _ -> Alcotest.fail "terminal fixture lost its singleton ToolUse"
  in
  let lease_events = ref [] in
  let handler_count = ref 0 in
  let transport, call_count =
    sequence_transport
      ~on_call:(fun () -> lease_events := "provider" :: !lease_events)
      [ malformed_response; text_response "corrected" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _ -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:
        (time_tool
           ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
           (fun () -> incr handler_count))
  in
  (match
     Agent.run_blocks
       ~sw
       ~on_yield:(fun () -> lease_events := "yield" :: !lease_events)
       ~on_resume:(fun () -> lease_events := "resume" :: !lease_events)
       agent
       [ Types.Text "reject malformed terminal turn" ]
   with
   | Error error -> Alcotest.fail (Error.to_string error)
   | Ok response ->
     Alcotest.(check string)
       "provider corrected the malformed turn"
       "corrected"
       (Types.visible_text_of_response response));
  Alcotest.(check int) "malformed turn ran no terminal handlers" 0 !handler_count;
  Alcotest.(check int) "provider corrected on its second turn" 2 !call_count;
  Alcotest.(check (list string))
    "no resume callback without a preceding yield"
    [ "provider"; "provider" ]
    (List.rev !lease_events)
;;

let test_terminal_success_stops_advanced_before_next_provider () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let handler_count = ref 0 in
  let transport, call_count =
    sequence_transport [ tool_use_response; text_response "must-not-run" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _ -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:
        (time_tool
           ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
           (fun () -> incr handler_count))
  in
  (match
     Agent.Advanced.run_blocks
       ~sw
       ~api_strategy:Agent.Sync
       ~on_tool_boundary:(fun _ ->
         Alcotest.fail "terminal completion reached cooperative boundary")
       agent
       [ Types.Text "finish" ]
   with
   | Error error -> Alcotest.fail (Error.to_string error)
   | Ok (Agent.Advanced.Completed _) ->
     Alcotest.fail "expected typed terminal tool completion"
   | Ok (Agent.Advanced.Yielded _) ->
     Alcotest.fail "terminal tool completion must not yield"
   | Ok (Agent.Advanced.Terminal_tool_completed completion) ->
     Alcotest.(check string)
       "exact invocation"
       "call_1"
       (Tool_contract.Invocation.tool_use_id completion.receipt.invocation);
     Alcotest.(check bool)
       "checkpoint stage"
       true
       (completion.receipt.checkpoint_stage = Agent.After_tool_results_appended);
     Alcotest.(check int) "checkpoint turn" 1 completion.checkpoint.turn_count);
  Alcotest.(check int) "one handler" 1 !handler_count;
  Alcotest.(check int) "one provider call" 1 !call_count
;;

let test_terminal_typed_error_allows_correction () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let typed_error =
    Error
      { Types.message = "correct input"
      ; recoverable = true
      ; error_class = Some Types.Deterministic
      }
  in
  let transport, call_count =
    sequence_transport [ tool_use_response; text_response "corrected" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _ -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:
        (time_tool
           ~descriptor:(Tool.terminal_descriptor Tool_contract.Proven_pre_effect)
           ~result:typed_error
           ignore)
  in
  (match Agent.run_blocks ~sw agent [ Types.Text "finish" ] with
   | Error error -> Alcotest.fail (Error.to_string error)
   | Ok response ->
     Alcotest.(check string)
       "corrected provider response"
       "corrected"
       (Types.visible_text_of_response response));
  Alcotest.(check int) "correction used second provider turn" 2 !call_count
;;

let test_terminal_post_effect_error_stops_before_next_provider () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let effect_count = ref 0 in
  let typed_error =
    Error
      { Types.message = "effect committed before receipt failure"
      ; recoverable = true
      ; error_class = Some Types.Unknown
      }
  in
  let transport, call_count =
    sequence_transport [ tool_use_response; text_response "must-not-run" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _ -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:
        (time_tool
           ~descriptor:(Tool.terminal_descriptor Tool_contract.Proven_post_effect)
           ~result:typed_error
           (fun () -> incr effect_count))
  in
  (match Agent.run_blocks ~sw agent [ Types.Text "finish" ] with
   | Error
       (Error.Agent
          (Error.TerminalToolEffectFailed { tool_use_id; effect_disposition; detail })) ->
     Alcotest.(check string) "typed terminal occurrence" "call_1" tool_use_id;
     Alcotest.(check bool)
       "typed post-effect disposition"
       true
       (Error.terminal_effect_disposition effect_disposition
        = Tool_contract.Proven_post_effect);
     Alcotest.(check string)
       "typed terminal failure detail"
       "effect committed before receipt failure"
       detail
   | Error error -> Alcotest.fail ("unexpected error: " ^ Error.to_string error)
   | Ok _ -> Alcotest.fail "post-effect terminal failure must stop");
  Alcotest.(check int) "effect ran once" 1 !effect_count;
  Alcotest.(check int) "post-effect failure stopped provider" 1 !call_count
;;

let test_terminal_unknown_effect_error_is_typed () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let typed_error =
    Error
      { Types.message = "effect outcome cannot be proven"
      ; recoverable = true
      ; error_class = Some Types.Unknown
      }
  in
  let transport, call_count =
    sequence_transport [ tool_use_response; text_response "must-not-run" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _ -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:
        (time_tool
           ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
           ~result:typed_error
           ignore)
  in
  (match Agent.run_blocks ~sw agent [ Types.Text "finish" ] with
   | Error
       (Error.Agent
          (Error.TerminalToolEffectFailed { tool_use_id; effect_disposition; detail })) ->
     Alcotest.(check string) "typed terminal occurrence" "call_1" tool_use_id;
     Alcotest.(check bool)
       "typed unknown-effect disposition"
       true
       (Error.terminal_effect_disposition effect_disposition
        = Tool_contract.Effect_outcome_unknown);
     Alcotest.(check string)
       "typed unknown-effect detail"
       "effect outcome cannot be proven"
       detail
   | Error error -> Alcotest.fail ("unexpected error: " ^ Error.to_string error)
   | Ok _ -> Alcotest.fail "unknown-effect terminal failure must stop");
  Alcotest.(check int) "unknown-effect failure stopped provider" 1 !call_count
;;

let test_terminal_stream_detail_preserves_canonical_response () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let expected_usage : Types.api_usage =
    { input_tokens = 11
    ; output_tokens = 7
    ; cache_creation_input_tokens = 3
    ; cache_read_input_tokens = 2
    ; cost_usd = None
    }
  in
  let expected_response =
    { tool_use_response with
      id = "terminal-provider-response"
    ; model = "terminal-provider-model"
    ; usage = Some expected_usage
    }
  in
  let transport, call_count =
    sequence_transport [ expected_response; text_response "must-not-run" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _ -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:
        (time_tool
           ~descriptor:(Tool.terminal_descriptor Tool_contract.Proven_post_effect)
           ignore)
  in
  Agent.set_state
    agent
    { (Agent.state agent) with messages = [ Types.user_msg "finish" ] };
  (match Agent.run_turn_stream_detailed ~sw ~on_event:ignore agent with
   | Ok (`TerminalToolCompleted completion) ->
     Alcotest.(check string)
       "canonical response id"
       expected_response.id
       completion.response.id;
     Alcotest.(check string)
       "canonical response model"
       expected_response.model
       completion.response.model;
     Alcotest.(check bool)
       "canonical stop reason"
       true
       (completion.response.stop_reason = expected_response.stop_reason);
     Alcotest.(check bool)
       "canonical response content"
       true
       (completion.response.content = expected_response.content);
     (match completion.response.usage with
      | None -> Alcotest.fail "canonical response lost token usage"
      | Some usage ->
        Alcotest.(check int)
          "canonical input tokens"
          expected_usage.input_tokens
          usage.input_tokens;
        Alcotest.(check int)
          "canonical output tokens"
          expected_usage.output_tokens
          usage.output_tokens;
        Alcotest.(check int)
          "canonical cache creation tokens"
          expected_usage.cache_creation_input_tokens
          usage.cache_creation_input_tokens;
        Alcotest.(check int)
          "canonical cache read tokens"
          expected_usage.cache_read_input_tokens
          usage.cache_read_input_tokens;
        Alcotest.(check bool)
          "cost enrichment is an optional finite observation"
          true
          (Option.fold
             ~none:true
             ~some:(fun cost -> Float.is_finite cost && cost >= 0.0)
             usage.cost_usd));
     (match completion.response.telemetry with
      | None -> Alcotest.fail "canonical response lost completion telemetry"
      | Some telemetry ->
        Alcotest.(check bool)
          "provider telemetry is observed"
          true
          (Option.is_some telemetry.provider_kind);
        Alcotest.(check (option string))
          "canonical model telemetry is observed"
          (Some "mock-model")
          telemetry.canonical_model_id;
        Alcotest.(check bool)
          "completion latency is observed"
          true
          (Option.is_some telemetry.request_latency_ms));
     Alcotest.(check bool)
       "checkpoint stage"
       true
       (completion.checkpoint_stage = Agent.After_tool_results_appended)
   | Ok (`Complete _) -> Alcotest.fail "terminal tool unexpectedly completed as text"
   | Ok `ToolsExecuted ->
     Alcotest.fail "terminal tool unexpectedly requested another turn"
   | Error error -> Alcotest.fail (Error.to_string error.error));
  Alcotest.(check int) "terminal detail used one provider call" 1 !call_count
;;

exception Terminal_cancel_token

let test_terminal_cancellation_preserves_token_and_stops_provider () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let transport, call_count =
    sequence_transport [ tool_use_response; text_response "must-not-run" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _ -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:
        (time_tool
           ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
           (fun () -> raise (Eio.Cancel.Cancelled Terminal_cancel_token)))
  in
  (match Agent.run_blocks ~sw agent [ Types.Text "finish" ] with
   | _ -> Alcotest.fail "terminal cancellation must propagate"
   | exception Eio.Cancel.Cancelled Terminal_cancel_token -> ()
   | exception exn -> raise exn);
  Alcotest.(check int) "cancellation stops before next provider" 1 !call_count
;;

let test_terminal_exception_stops_before_next_provider () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let transport, call_count =
    sequence_transport [ tool_use_response; text_response "must-not-run" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _ -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:
        (time_tool
           ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
           (fun () -> failwith "terminal boom"))
  in
  (match Agent.run_blocks ~sw agent [ Types.Text "finish" ] with
   | _ -> Alcotest.fail "terminal exception must propagate"
   | exception Failure message ->
     Alcotest.(check string) "original exception" "terminal boom" message
   | exception exn -> raise exn);
  Alcotest.(check int) "exception stops before next provider call" 1 !call_count
;;

let test_terminal_success_stops_stream_before_next_provider () =
  with_temp_trace
  @@ fun trace_path ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let trace = Raw_trace.create ~path:trace_path () |> Result.get_ok in
  let transport, call_count =
    sequence_transport [ tool_use_response; text_response "must-not-run" ]
  in
  let agent =
    make_agent
      ~net:env#net
      ~transport
      ~raw_trace:trace
      ~checkpoint_sink:(fun _ -> Ok ())
      ~context_injector:None
      ~on_run_complete:None
      ~tool:
        (time_tool
           ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
           ignore)
  in
  (match Agent.run_stream_blocks ~sw ~on_event:ignore agent [ Types.Text "finish" ] with
   | Error error -> Alcotest.fail (Error.to_string error)
   | Ok response ->
     Alcotest.(check bool)
       "terminal response remains tool-use response"
       true
       (response.stop_reason = Types.StopToolUse));
  Alcotest.(check int) "stream stops after one provider call" 1 !call_count
;;

let () =
  Alcotest.run
    "Agent advanced cooperative execution"
    [ ( "tool boundary"
      , [ Alcotest.test_case
            "yield after context checkpoint"
            `Quick
            test_yield_after_context_checkpoint
        ; Alcotest.test_case
            "continue reaches terminal completion"
            `Quick
            test_continue_reaches_terminal_completion
        ; Alcotest.test_case
            "context checkpoint failure prevents boundary and resume"
            `Quick
            test_context_checkpoint_failure_prevents_boundary_and_resume
        ; Alcotest.test_case
            "assistant checkpoint failure suppresses release and tool"
            `Quick
            test_assistant_checkpoint_failure_suppresses_release_and_tool
        ; Alcotest.test_case
            "release callback failure prevents tool execution"
            `Quick
            test_release_callback_failure_prevents_tool_execution
        ; Alcotest.test_case
            "regular run releases before tool execution"
            `Quick
            test_regular_run_releases_before_tool_execution
        ; Alcotest.test_case
            "unpaired provider lease callback is rejected"
            `Quick
            test_unpaired_lease_callback_is_rejected
        ; Alcotest.test_case
            "malformed terminal admission keeps provider lease held"
            `Quick
            test_malformed_terminal_admission_keeps_provider_lease_held
        ; Alcotest.test_case
            "terminal success stops Advanced"
            `Quick
            test_terminal_success_stops_advanced_before_next_provider
        ; Alcotest.test_case
            "terminal typed error allows correction"
            `Quick
            test_terminal_typed_error_allows_correction
        ; Alcotest.test_case
            "terminal post-effect error stops provider"
            `Quick
            test_terminal_post_effect_error_stops_before_next_provider
        ; Alcotest.test_case
            "terminal unknown-effect error is typed"
            `Quick
            test_terminal_unknown_effect_error_is_typed
        ; Alcotest.test_case
            "terminal stream detail preserves provider response"
            `Quick
            test_terminal_stream_detail_preserves_canonical_response
        ; Alcotest.test_case
            "terminal cancellation preserves token"
            `Quick
            test_terminal_cancellation_preserves_token_and_stops_provider
        ; Alcotest.test_case
            "terminal exception stops before next provider"
            `Quick
            test_terminal_exception_stops_before_next_provider
        ; Alcotest.test_case
            "terminal success stops stream"
            `Quick
            test_terminal_success_stops_stream_before_next_provider
        ] )
    ]
;;
