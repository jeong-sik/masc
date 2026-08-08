(** Integration test: Pipeline.run_turn emits Telemetry_event.t via mock transport.

    Verifies that the streaming path through Pipeline → Complete → Transport
    forwards telemetry events to the on_telemetry callback, which Agent.run_stream
    wires to Telemetry_bus when an event_bus is configured. *)

open Agent_sdk

let local_provider_config ~base_url ~model_id =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~provider_id:"test"
    ~model_id
    ~base_url
    ~api_key:""
    ~headers:[ "Content-Type", "application/json" ]
    ~request_path:"/v1/chat/completions"
    ()
;;

let contains_substring ~sub text =
  let sub_len = String.length sub in
  let text_len = String.length text in
  let rec loop index =
    if sub_len = 0
    then true
    else if index + sub_len > text_len
    then false
    else if String.sub text index sub_len = sub
    then true
    else loop (index + 1)
  in
  loop 0
;;

let make_mock_transport () : Llm_provider.Llm_transport.t =
  let response : Types.api_response =
    { id = "telemetry-pipeline-mock"
    ; model = "mock-model"
    ; stop_reason = Types.EndTurn
    ; content = [ Types.Text "ok" ]
    ; usage = None
    ; telemetry = None
    }
  in
  { complete_sync =
      (fun _req ->
        { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
  ; complete_stream =
      (fun ?on_telemetry
        ~on_event
        (_req : Llm_provider.Llm_transport.completion_request) ->
        on_event
          (Types.MessageStart { id = "mock-1"; model = "mock-model"; usage = None });
        on_event (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "ok" });
        on_event Types.MessageStop;
        (match on_telemetry with
         | Some emit ->
           emit
             (Llm_provider.Telemetry_event.Streaming_first_chunk
                { provider = "mock-provider"
                ; model = "mock-model"
                ; ttfrc_ms = Some 1.0
                ; requested_at = 0.0
                })
         | None -> ());
        Ok response)
  }
;;

let text_response ?(id = "checkpoint-text") text : Types.api_response =
  { id
  ; model = "mock-model"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text text ]
  ; usage = None
  ; telemetry = None
  }
;;

let tool_use_response () : Types.api_response =
  { id = "checkpoint-tool-use"
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

let make_sequence_transport responses : Llm_provider.Llm_transport.t =
  let remaining = ref responses in
  let next_response () =
    match !remaining with
    | response :: rest ->
      remaining := rest;
      response
    | [] -> Alcotest.fail "mock transport exhausted"
  in
  { complete_sync =
      (fun _req ->
        { Llm_provider.Llm_transport.response = Ok (next_response ())
        ; latency_ms = Some 0
        })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _req -> Ok (next_response ()))
  }
;;

let make_agent ~net ~transport () =
  let event_bus = Event_bus.create () in
  let options =
    { Agent.default_options with
      transport = Some transport
    ; event_bus = Some event_bus
    ; provider_config =
        Some (local_provider_config ~base_url:"http://mock.local" ~model_id:"mock-model")
    }
  in
  let config =
    { (Types.default_config ~model:"test-model") with
      name = "telemetry-pipeline-test"
    ; model = "mock-model"
    }
  in
  let agent = Agent.create ~net ~config ~options () in
  agent, event_bus
;;

let make_checkpoint_agent
      ?event_bus
      ?journal
      ?(hooks = Hooks.empty)
      ?context_injector
      ~net
      ~transport
      ~checkpoint_sink
      ~tools
      ()
  =
  let options =
    { Agent.default_options with
      transport = Some transport
    ; event_bus
    ; journal
    ; hooks
    ; context_injector
    ; provider_config =
        Some (local_provider_config ~base_url:"http://mock.local" ~model_id:"mock-model")
    }
  in
  let config =
    { (Types.default_config ~model:"test-model") with
      name = "turn-checkpoint-test"
    ; model = "mock-model"
    }
  in
  Agent.create ~net ~config ~tools ~options ~checkpoint_sink ()
;;

let messages_contain_tool_result ~tool_use_id ~content messages =
  List.exists
    (fun (message : Types.message) ->
       List.exists
         (function
           | Types.ToolResult
               { tool_use_id = actual_tool_use_id; content = actual_content; _ } ->
             String.equal actual_tool_use_id tool_use_id
             && String.equal actual_content content
           | _ -> false)
         message.content)
    messages
;;

let require_decoded_telemetry = function
  | Ok event -> event
  | Error (failure : Telemetry_bus.decode_failure) ->
    Alcotest.fail ("unexpected telemetry decode failure: " ^ failure.detail)
;;

let test_run_stream_emits_telemetry_via_pipeline () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let transport = make_mock_transport () in
  let agent, event_bus = make_agent ~net ~transport () in
  let telemetry_bus = Telemetry_bus.of_event_bus event_bus in
  let config =
    Event_bus.subscription_config ~capacity:16 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Telemetry_bus.subscribe ~config telemetry_bus in
  (match Agent.run_stream ~sw ~on_event:(fun _ -> ()) agent "trigger streaming turn" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected stream success: " ^ Error.to_string err));
  let events = Telemetry_bus.drain sub |> List.map require_decoded_telemetry in
  Alcotest.(check int) "telemetry events received" 1 (List.length events);
  (match
     List.find_opt
       (function
         | Llm_provider.Telemetry_event.Streaming_first_chunk _ -> true
         | _ -> false)
       events
   with
   | Some (Llm_provider.Telemetry_event.Streaming_first_chunk { provider; model; _ }) ->
     Alcotest.(check string) "provider" "mock-provider" provider;
     Alcotest.(check string) "model" "mock-model" model
   | _ -> Alcotest.fail "expected Streaming_first_chunk event");
  Telemetry_bus.unsubscribe telemetry_bus sub
;;

let test_run_stream_without_event_bus_skips_telemetry () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let transport = make_mock_transport () in
  let options =
    { Agent.default_options with
      transport = Some transport
    ; provider_config =
        Some (local_provider_config ~base_url:"http://mock.local" ~model_id:"mock-model")
    }
  in
  let config =
    { (Types.default_config ~model:"test-model") with
      name = "telemetry-pipeline-no-bus"
    ; model = "mock-model"
    }
  in
  (* No event_bus configured → on_telemetry passed to transport should be None. *)
  let on_telemetry_received = Atomic.make false in
  let transport_with_probe =
    { transport with
      complete_stream =
        (fun ?on_telemetry ~on_event req ->
          (match on_telemetry with
           | Some _ -> Atomic.set on_telemetry_received true
           | None -> ());
          transport.complete_stream ?on_telemetry ~on_event req)
    }
  in
  let options = { options with transport = Some transport_with_probe } in
  let agent = Agent.create ~net ~config ~options () in
  (match Agent.run_stream ~sw ~on_event:(fun _ -> ()) agent "trigger streaming turn" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected stream success: " ^ Error.to_string err));
  Alcotest.(check bool)
    "on_telemetry is None when no event_bus"
    false
    (Atomic.get on_telemetry_received)
;;

let test_checkpoint_sink_after_assistant_collect () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let snapshots = ref [] in
  let checkpoint_sink snapshot =
    snapshots := snapshot :: !snapshots;
    Ok ()
  in
  let transport = make_sequence_transport [ text_response "ok" ] in
  let agent =
    make_checkpoint_agent ~net:env#net ~transport ~checkpoint_sink ~tools:[] ()
  in
  (match Agent.run ~sw agent "capture this turn" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected run success: " ^ Error.to_string err));
  let snapshots = List.rev !snapshots in
  Alcotest.(check int) "one checkpoint" 1 (List.length snapshots);
  match snapshots with
  | [ snapshot ] ->
    Alcotest.(check bool) "stage" true (snapshot.stage = Agent.After_assistant_collected);
    Alcotest.(check int) "turn" 1 snapshot.turn;
    Alcotest.(check int) "checkpoint turn" 1 snapshot.checkpoint.turn_count;
    Alcotest.(check bool)
      "assistant persisted"
      true
      (List.exists
         (fun (msg : Types.message) ->
            msg.role = Types.Assistant
            && List.exists
                 (function
                   | Types.Text "ok" -> true
                   | _ -> false)
                 msg.content)
         snapshot.checkpoint.messages)
  | _ -> Alcotest.fail "expected one snapshot"
;;

let test_checkpoint_sink_after_tool_feedback () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let snapshots = ref [] in
  let checkpoint_sink snapshot =
    snapshots := snapshot :: !snapshots;
    Ok ()
  in
  let transport =
    make_sequence_transport [ tool_use_response (); text_response "tool complete" ]
  in
  let time_tool =
    Tool.create
      ~name:"get_time"
      ~description:"Get current time"
      ~parameters:
        [ { name = "timezone"
          ; param_type = Types.String
          ; description = "tz"
          ; required = true
          }
        ]
      (fun _input -> Ok { Types.content = "12:00 UTC"; _meta = None })
  in
  let context_injector ~tool_name:_ ~input:_ ~output:_ =
    Some
      { Hooks.context_updates = []
      ; extra_messages =
          [ Types.make_message ~role:Types.User [ Types.Text "projected" ] ]
      }
  in
  let agent =
    make_checkpoint_agent
      ~context_injector
      ~net:env#net
      ~transport
      ~checkpoint_sink
      ~tools:[ time_tool ]
      ()
  in
  (match Agent.run ~sw agent "what time is it?" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected run success: " ^ Error.to_string err));
  let snapshots = List.rev !snapshots in
  let stages =
    List.map (fun (snapshot : Agent.checkpoint_snapshot) -> snapshot.stage) snapshots
  in
  let turns =
    List.map (fun (snapshot : Agent.checkpoint_snapshot) -> snapshot.turn) snapshots
  in
  Alcotest.(check int) "four checkpoints" 4 (List.length snapshots);
  Alcotest.(check bool)
    "stage sequence"
    true
    (stages
     = [ Agent.After_assistant_collected
       ; Agent.After_tool_results_appended
       ; Agent.After_context_injection
       ; Agent.After_assistant_collected
       ]);
  Alcotest.(check (list int)) "turn sequence" [ 1; 1; 1; 2 ] turns;
  let tool_feedback_snapshot = List.nth snapshots 1 in
  let injection_snapshot = List.nth snapshots 2 in
  Alcotest.(check bool)
    "tool result persisted"
    true
    (List.exists
       (fun (msg : Types.message) ->
          List.exists
            (function
              | Types.ToolResult { tool_use_id = "call_1"; content = "12:00 UTC"; _ } ->
                true
              | _ -> false)
            msg.content)
       tool_feedback_snapshot.checkpoint.messages);
  Alcotest.(check bool)
    "context injection has a distinct durable state"
    true
    (List.exists
       (fun (message : Types.message) ->
          List.exists
            (function
              | Types.Text "projected" -> true
              | _ -> false)
            message.content)
       injection_snapshot.checkpoint.messages)
;;

let test_checkpoint_sink_failure_fails_turn () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let event_bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:16 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let event_sub = Event_bus.subscribe ~config event_bus in
  let journal = Durable_event.create () in
  let checkpoint_sink _snapshot = Error "disk full" in
  let transport = make_sequence_transport [ text_response "ok" ] in
  let agent =
    make_checkpoint_agent
      ~event_bus
      ~journal
      ~net:env#net
      ~transport
      ~checkpoint_sink
      ~tools:[]
      ()
  in
  match Agent.run ~sw agent "capture this turn" with
  | Ok _ -> Alcotest.fail "expected checkpoint sink failure"
  | Error err ->
    Alcotest.(check bool)
      "error mentions checkpoint sink"
      true
      (contains_substring ~sub:"checkpoint sink failed" (Error.to_string err));
    let event_payloads =
      Event_bus.drain event_sub |> List.map (fun event -> event.Event_bus.payload)
    in
    Alcotest.(check bool)
      "no TurnCompleted event after checkpoint failure"
      false
      (List.exists
         (function
           | Event_bus.TurnCompleted _ -> true
           | _ -> false)
         event_payloads);
    let journal_events = Durable_event.events journal in
    Alcotest.(check bool)
      "no turn_complete journal transition after checkpoint failure"
      false
      (List.exists
         (function
           | Durable_event.State_transition { to_state = "turn_complete"; _ } -> true
           | _ -> false)
         journal_events)
;;

let test_checkpoint_sink_does_not_clobber_intervening_state () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let agent_ref = ref None in
  let marker_message =
    { Types.role = Types.System
    ; content = [ Types.Text "sink-side-effect" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let checkpoint_sink _snapshot =
    (match !agent_ref with
     | Some agent ->
       Agent.update_state agent (fun state ->
         { state with messages = state.messages @ [ marker_message ] })
     | None -> ());
    Ok ()
  in
  let transport = make_sequence_transport [ text_response "ok" ] in
  let agent =
    make_checkpoint_agent ~net:env#net ~transport ~checkpoint_sink ~tools:[] ()
  in
  agent_ref := Some agent;
  (match Agent.run ~sw agent "capture this turn" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected run success: " ^ Error.to_string err));
  let messages = (Agent.state agent).messages in
  Alcotest.(check bool)
    "sink state mutation preserved"
    true
    (List.exists
       (fun (msg : Types.message) ->
          msg.role = Types.System
          && List.exists
               (function
                 | Types.Text "sink-side-effect" -> true
                 | _ -> false)
               msg.content)
       messages);
  Alcotest.(check bool)
    "assistant state mutation preserved"
    true
    (List.exists
       (fun (msg : Types.message) ->
          msg.role = Types.Assistant
          && List.exists
               (function
                 | Types.Text "ok" -> true
                 | _ -> false)
               msg.content)
       messages)
;;

let test_post_hook_failure_commits_tool_result_before_surface () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let snapshots = ref [] in
  let tool_runs = ref 0 in
  let checkpoint_sink snapshot =
    snapshots := snapshot :: !snapshots;
    Ok ()
  in
  let transport =
    make_sequence_transport [ tool_use_response (); text_response "done" ]
  in
  let time_tool =
    Tool.create
      ~name:"get_time"
      ~description:"Get current time"
      ~parameters:
        [ { Types.name = "timezone"
          ; param_type = Types.String
          ; description = "tz"
          ; required = true
          }
        ]
      (fun _input ->
         incr tool_runs;
         Ok { Types.content = "12:00 UTC"; _meta = None })
  in
  let hooks =
    { Hooks.empty with post_tool_use = Some (fun _ -> failwith "post hook failed") }
  in
  let agent =
    make_checkpoint_agent
      ~hooks
      ~net:env#net
      ~transport
      ~checkpoint_sink
      ~tools:[ time_tool ]
      ()
  in
  (match Agent.run ~sw agent "what time is it?" with
   | Error
       (Error.Agent
          (Error.HookExecutionFailed
             { hook_name = "post_tool_use"
             ; stage = "post_tool_use"
             ; tool_name = Some "get_time"
             ; tool_use_id = Some "call_1"
             ; detail
             })) ->
     Alcotest.(check bool)
       "hook detail retained"
       true
       (contains_substring ~sub:"post hook failed" detail)
   | Ok _ -> Alcotest.fail "expected typed post-hook failure"
   | Error error -> Alcotest.fail ("unexpected post-hook error: " ^ Error.to_string error));
  Alcotest.(check int) "tool ran once before hook failure" 1 !tool_runs;
  Alcotest.(check bool)
    "in-memory state retained completed ToolResult"
    true
    (messages_contain_tool_result
       ~tool_use_id:"call_1"
       ~content:"12:00 UTC"
       (Agent.state agent).messages);
  let durable_tool_result =
    List.exists
      (fun (snapshot : Agent.checkpoint_snapshot) ->
         snapshot.stage = Agent.After_tool_results_appended
         && messages_contain_tool_result
              ~tool_use_id:"call_1"
              ~content:"12:00 UTC"
              snapshot.checkpoint.messages)
      !snapshots
  in
  Alcotest.(check bool)
    "checkpoint retained completed ToolResult before failure"
    true
    durable_tool_result;
  (match Agent.run ~sw agent "continue from the recorded result" with
   | Ok response ->
     Alcotest.(check bool)
       "next provider turn completed"
       true
       (List.exists
          (function
            | Types.Text "done" -> true
            | _ -> false)
          response.content)
   | Error error ->
     Alcotest.fail ("expected continuation success: " ^ Error.to_string error));
  Alcotest.(check int) "completed tool was not replayed" 1 !tool_runs
;;

let test_context_injection_failure_keeps_base_tool_result () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let snapshots = ref [] in
  let checkpoint_sink snapshot =
    snapshots := snapshot :: !snapshots;
    Ok ()
  in
  let transport = make_sequence_transport [ tool_use_response () ] in
  let time_tool =
    Tool.create
      ~name:"get_time"
      ~description:"Get current time"
      ~parameters:
        [ { Types.name = "timezone"
          ; param_type = Types.String
          ; description = "tz"
          ; required = true
          }
        ]
      (fun _input -> Ok { Types.content = "12:00 UTC"; _meta = None })
  in
  let context_injector ~tool_name:_ ~input:_ ~output:_ =
    failwith "context projection failed"
  in
  let agent =
    make_checkpoint_agent
      ~context_injector
      ~net:env#net
      ~transport
      ~checkpoint_sink
      ~tools:[ time_tool ]
      ()
  in
  (match Agent.run ~sw agent "what time is it?" with
   | Error (Error.Internal detail) ->
     Alcotest.(check bool)
       "context error retained"
       true
       (contains_substring ~sub:"context projection failed" detail)
   | Ok _ -> Alcotest.fail "expected context injection failure"
   | Error error ->
     Alcotest.fail ("unexpected context injection error: " ^ Error.to_string error));
  Alcotest.(check bool)
    "in-memory base ToolResult survives injector failure"
    true
    (messages_contain_tool_result
       ~tool_use_id:"call_1"
       ~content:"12:00 UTC"
       (Agent.state agent).messages);
  Alcotest.(check bool)
    "durable base ToolResult precedes injector failure"
    true
    (List.exists
       (fun (snapshot : Agent.checkpoint_snapshot) ->
          snapshot.stage = Agent.After_tool_results_appended
          && messages_contain_tool_result
               ~tool_use_id:"call_1"
               ~content:"12:00 UTC"
               snapshot.checkpoint.messages)
       !snapshots)
;;

let test_journal_observer_failure_rethrows_after_tool_result_checkpoint () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let snapshots = ref [] in
  let checkpoint_sink snapshot =
    snapshots := snapshot :: !snapshots;
    Ok ()
  in
  let journal =
    Durable_event.create
      ~on_append:(function
        | Durable_event.Tool_completed _ -> failwith "journal projection failed"
        | _ -> ())
      ()
  in
  let transport = make_sequence_transport [ tool_use_response () ] in
  let time_tool =
    Tool.create
      ~name:"get_time"
      ~description:"Get current time"
      ~parameters:
        [ { Types.name = "timezone"
          ; param_type = Types.String
          ; description = "tz"
          ; required = true
          }
        ]
      (fun _input -> Ok { Types.content = "12:00 UTC"; _meta = None })
  in
  let agent =
    make_checkpoint_agent
      ~journal
      ~net:env#net
      ~transport
      ~checkpoint_sink
      ~tools:[ time_tool ]
      ()
  in
  (match Agent.run ~sw agent "what time is it?" with
   | Ok _ | Error _ -> Alcotest.fail "expected journal observer exception"
   | exception Failure detail ->
     Alcotest.(check string)
       "original observer exception"
       "journal projection failed"
       detail
   | exception exception_ ->
     Alcotest.fail ("unexpected observer exception: " ^ Printexc.to_string exception_));
  Alcotest.(check bool)
    "in-memory ToolResult precedes observer rethrow"
    true
    (messages_contain_tool_result
       ~tool_use_id:"call_1"
       ~content:"12:00 UTC"
       (Agent.state agent).messages);
  Alcotest.(check bool)
    "checkpoint ToolResult precedes observer rethrow"
    true
    (List.exists
       (fun (snapshot : Agent.checkpoint_snapshot) ->
          snapshot.stage = Agent.After_tool_results_appended
          && messages_contain_tool_result
               ~tool_use_id:"call_1"
               ~content:"12:00 UTC"
               snapshot.checkpoint.messages)
       !snapshots);
  Alcotest.(check int)
    "journal kept Tool_completed before reporting callback failure"
    1
    (Durable_event.events journal
     |> List.filter (function
       | Durable_event.Tool_completed _ -> true
       | _ -> false)
     |> List.length)
;;

let () =
  Alcotest.run
    "Telemetry pipeline integration"
    [ ( "emit"
      , [ Alcotest.test_case
            "run_stream emits telemetry via pipeline"
            `Quick
            test_run_stream_emits_telemetry_via_pipeline
        ; Alcotest.test_case
            "run_stream skips telemetry without event_bus"
            `Quick
            test_run_stream_without_event_bus_skips_telemetry
        ; Alcotest.test_case
            "checkpoint after assistant collect"
            `Quick
            test_checkpoint_sink_after_assistant_collect
        ; Alcotest.test_case
            "checkpoint after tool feedback"
            `Quick
            test_checkpoint_sink_after_tool_feedback
        ; Alcotest.test_case
            "checkpoint sink failure fails turn"
            `Quick
            test_checkpoint_sink_failure_fails_turn
        ; Alcotest.test_case
            "checkpoint sink preserves intervening state"
            `Quick
            test_checkpoint_sink_does_not_clobber_intervening_state
        ; Alcotest.test_case
            "post-hook failure commits tool result before surfacing"
            `Quick
            test_post_hook_failure_commits_tool_result_before_surface
        ; Alcotest.test_case
            "context injection failure keeps base tool result"
            `Quick
            test_context_injection_failure_keeps_base_tool_result
        ; Alcotest.test_case
            "journal observer rethrows after tool result checkpoint"
            `Quick
            test_journal_observer_failure_rethrows_after_tool_result_checkpoint
        ] )
    ]
;;
