(** Pipeline tests — verify the pipeline's type contracts and
    the agent's behavior through mock provider (unit-level).
    Pipeline is internal, so we test correctness through
    Provider_mock.next_response and agent state inspection. *)

open Agent_sdk
module Internal = Agent_sdk__
module Internal_agent = Agent_sdk__Agent_types
module Internal_pipeline = Agent_sdk__Pipeline
module Internal_runtime = Internal.Execution_runtime
module Internal_codec = Internal.Execution_codec_executor
module Internal_writer = Internal.Execution_lane_writer
module Internal_scope = Internal.Execution_agent_scope
module Internal_binding = Binding_identity
module Internal_settlement = Internal.Execution_tool_settlement

let invocation tool_use_id =
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  Tool_contract.Invocation.create
    ~tool_use_id
    ~turn:0
    ~schedule
    ~completion:Tool_contract.Continue_after_success
;;

let terminal_outcome_name = function
  | Agent.Terminal_succeeded -> "succeeded"
  | Agent.Terminal_failed -> "failed"
  | Agent.Terminal_cancelled -> "cancelled"
;;

let recovery_action_name = function
  | Agent.Retire -> "retire"
  | Agent.Operator_repair_required Agent.Effect_outcome_unknown ->
    "operator_repair:effect_outcome_unknown"
;;

let check_terminal_disposition ~outcome ~recovery = function
  | None -> Alcotest.fail "terminal disposition callback was not invoked"
  | Some disposition ->
    Alcotest.(check string)
      "terminal outcome"
      outcome
      (terminal_outcome_name disposition.Agent.outcome);
    Alcotest.(check string)
      "terminal recovery action"
      recovery
      (recovery_action_name disposition.Agent.recovery)
;;

(* ── Provider mock: verify pipeline stages via mock responses ── *)

let test_mock_text_response () =
  let mock =
    Provider_mock.create
      ~responses:[ Provider_mock.text_response "hello from pipeline" ]
      ()
  in
  match Provider_mock.next_response mock [] with
  | Ok resp ->
    Alcotest.(check string)
      "stop_reason"
      "end_turn"
      (match resp.stop_reason with
       | EndTurn -> "end_turn"
       | _ -> "other");
    let text =
      List.filter_map
        (function
          | Types.Text s -> Some s
          | _ -> None)
        resp.content
      |> String.concat ""
    in
    Alcotest.(check string) "text content" "hello from pipeline" text
  | Error e -> Alcotest.failf "unexpected: %s" (Error.to_string e)
;;

let test_mock_tool_use_response () =
  let mock =
    Provider_mock.create
      ~responses:
        [ Provider_mock.tool_use_response
            ~tool_name:"search"
            ~tool_input:(`Assoc [ "q", `String "test" ])
            ()
        ]
      ()
  in
  match Provider_mock.next_response mock [] with
  | Ok resp ->
    Alcotest.(check string)
      "stop_reason"
      "tool_use"
      (match resp.stop_reason with
       | StopToolUse -> "tool_use"
       | _ -> "other");
    let tool_names =
      List.filter_map
        (function
          | Types.ToolUse { name; _ } -> Some name
          | _ -> None)
        resp.content
    in
    Alcotest.(check (list string)) "tool names" [ "search" ] tool_names
  | Error e -> Alcotest.failf "unexpected: %s" (Error.to_string e)
;;

let test_mock_tool_then_text_sequence () =
  let responses =
    Provider_mock.tool_then_text
      ~tool_name:"calc"
      ~tool_input:(`Assoc [])
      ~final_text:"42"
      ()
  in
  let mock = Provider_mock.create ~responses () in
  (* First call: tool use *)
  (match Provider_mock.next_response mock [] with
   | Ok resp ->
     Alcotest.(check string)
       "first is tool_use"
       "tool_use"
       (match resp.stop_reason with
        | StopToolUse -> "tool_use"
        | _ -> "other")
   | Error _ -> Alcotest.fail "expected first response");
  (* Second call: text *)
  (match Provider_mock.next_response mock [] with
   | Ok resp ->
     let text =
       List.filter_map
         (function
           | Types.Text s -> Some s
           | _ -> None)
         resp.content
       |> String.concat ""
     in
     Alcotest.(check string) "final text" "42" text
   | Error _ -> Alcotest.fail "expected second response");
  Alcotest.(check int) "call count" 2 (Provider_mock.call_count mock)
;;

(* ── Agent state: verify pipeline modifies state correctly ─── *)

let test_agent_initial_state () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let agent =
    Agent.create
      ~net
      ~config:{ (Types.default_config ~model:"test-model") with name = "state-test" }
      ()
  in
  let state = Agent.state agent in
  Alcotest.(check int) "initial turn_count" 0 state.turn_count;
  Alcotest.(check int) "initial api_calls" 0 state.usage.api_calls;
  Alcotest.(check (list string))
    "initial messages"
    []
    (List.map
       (fun (m : Types.message) ->
          match m.content with
          | [ Types.Text s ] -> s
          | _ -> "<complex>")
       state.messages)
;;

let test_agent_tools_registered () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let tool =
    Tool.create ~name:"my_tool" ~description:"test" ~parameters:[] (fun _ ->
      Ok { Types.content = "ok"; _meta = None })
  in
  let agent =
    Agent.create
      ~config:(Types.default_config ~model:"test-model")
      ~net
      ~tools:[ tool ]
      ()
  in
  let tools = Agent.tools agent in
  Alcotest.(check int) "tool count" 1 (Tool_set.size tools);
  Alcotest.(check string)
    "tool name"
    "my_tool"
    (List.hd (Tool_set.to_list tools)).schema.name
;;

(* ── Pipeline type contracts ─────────────────────────────── *)

let test_agent_turn_preparation () =
  (* Verify Agent_turn.prepare_turn produces valid preparation *)
  let tools =
    Tool_set.of_list
      [ Tool.create ~name:"a" ~description:"tool a" ~parameters:[] (fun _ ->
          Ok { Types.content = "a"; _meta = None })
      ; Tool.create ~name:"b" ~description:"tool b" ~parameters:[] (fun _ ->
          Ok { Types.content = "b"; _meta = None })
      ]
  in
  let messages =
    [ { Types.role = User
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let prep =
    Agent_turn.prepare_turn ~tools ~messages ~turn_params:Hooks.default_turn_params ()
    |> Result.get_ok
  in
  (* tools_json should be Some with 2 tools *)
  (match prep.tools_json with
   | Some tools_json -> Alcotest.(check int) "2 tools in json" 2 (List.length tools_json)
   | None -> Alcotest.fail "expected tools_json");
  (* effective_messages should contain our user message *)
  Alcotest.(check int) "1 message" 1 (List.length prep.effective_messages);
  (* visible_tool_names mirrors tools_json — exact list LLM sees *)
  Alcotest.(check (list string))
    "visible_tool_names matches"
    [ "a"; "b" ]
    prep.visible_tool_names
;;

let pipeline_response ?telemetry stop_reason : Types.api_response =
  { id = "pipeline-reset-test"
  ; model = "mock-model"
  ; stop_reason
  ; content = [ Text "done" ]
  ; usage = None
  ; telemetry
  }
;;

let transport_returning response =
  { Llm_provider.Llm_transport.complete_sync =
      (fun _req ->
        { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _req -> Ok response)
  }
;;

let make_pipeline_test_agent ~net ~response =
  let transport = transport_returning response in
  let options =
    { Internal_agent.default_options with
      transport = Some transport
    ; provider_config = Some (Provider_mock.to_provider_config ())
    }
  in
  let agent =
    Internal_agent.create
      ~net
      ~config:
        { (Types.default_config ~model:"test-model") with
          name = "pipeline-idle-reset-test"
        }
      ~options
      ()
  in
  Internal_agent.set_state
    agent
    { (Internal_agent.state agent) with messages = [ Types.user_msg "hello" ] };
  agent
;;

let test_pipeline_sends_exact_supplied_tools () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let make_tool name description =
    Tool.create ~name ~description ~parameters:[] (fun _ ->
      Ok { Types.content = name; _meta = None })
  in
  let tools = [ make_tool "first" "first schema"; make_tool "second" "second schema" ] in
  let expected = List.map Tool.schema_to_json tools in
  let captured = ref None in
  let response = pipeline_response EndTurn in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun request ->
          captured := Some request.tools;
          { response = Ok response; latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
    }
  in
  let options =
    { Internal_agent.default_options with
      transport = Some transport
    ; provider_config = Some (Provider_mock.to_provider_config ())
    }
  in
  let agent =
    Internal_agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:
        { (Types.default_config ~model:"test-model") with name = "exact-tools-test" }
      ~tools
      ~options
      ()
  in
  Internal_agent.set_state
    agent
    { (Internal_agent.state agent) with messages = [ Types.user_msg "hello" ] };
  (match Internal_pipeline.run_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
   | Ok (Internal_pipeline.Complete _) -> ()
   | Ok (Internal_pipeline.ToolsExecuted _) -> Alcotest.fail "expected terminal response"
   | Ok (Internal_pipeline.TerminalToolCompleted _) ->
     Alcotest.fail "unexpected terminal tool completion"
   | Error error -> Alcotest.fail (Error.to_string error));
  Alcotest.(check bool)
    "provider receives exact caller tool schemas"
    true
    (Option.equal (List.equal Yojson.Safe.equal) (Some expected) !captured)
;;

let test_effective_provider_config_drives_lifecycle_and_pricing () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let effective_model = "claude-sonnet-4-6" in
  let captured_model = ref None in
  let response : Types.api_response =
    { id = "effective-provider-config"
    ; model = ""
    ; stop_reason = EndTurn
    ; content = [ Text "done" ]
    ; usage =
        Some
          { input_tokens = 100
          ; output_tokens = 50
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    ; telemetry = None
    }
  in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun request ->
          captured_model := Some request.config.model_id;
          { response = Ok response; latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
    }
  in
  let carrier =
    Llm_provider.Provider_config.make
      ~kind:Anthropic
      ~provider_id:"anthropic"
      ~model_id:"carrier-model-without-pricing"
      ~base_url:"https://api.anthropic.com"
      ~request_path:"/v1/messages"
      ()
  in
  let options =
    { Agent.default_options with
      provider_config = Some carrier
    ; transport = Some transport
    }
  in
  let agent =
    Agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:
        { (Types.default_config ~model:effective_model) with
          name = "effective-provider-config-test"
        }
      ~options
      ()
  in
  (match Agent.run ~sw agent "hello" with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Error.to_string error));
  Alcotest.(check (option string)) "wire model" (Some effective_model) !captured_model;
  (match Agent.lifecycle agent with
   | Some snapshot ->
     Alcotest.(check (option string))
       "lifecycle resolved model"
       (Some effective_model)
       snapshot.resolved_model
   | None -> Alcotest.fail "completed agent has no lifecycle snapshot");
  let usage = (Agent.state agent).usage in
  Alcotest.(check bool)
    "effective model pricing applied"
    true
    (usage.estimated_cost_usd > 0.0);
  Alcotest.(check bool) "no pricing gap" true (Option.is_none usage.pricing_gap)
;;

let test_provider_turn_identity_is_shared_across_multiturn_tool_loop () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let before_turns = ref [] in
  let after_turns = ref [] in
  let pre_tool_turns = ref [] in
  let handler_turns = ref [] in
  let hooks =
    { Hooks.empty with
      before_turn =
        Some
          (function
            | Hooks.BeforeTurn { turn; _ } ->
              before_turns := turn :: !before_turns;
              Hooks.Continue
            | _ -> Alcotest.fail "expected BeforeTurn")
    ; after_turn =
        Some
          (function
            | Hooks.AfterTurn { turn; _ } ->
              after_turns := turn :: !after_turns;
              Hooks.Continue
            | _ -> Alcotest.fail "expected AfterTurn")
    ; pre_tool_use =
        Some
          (function
            | Hooks.PreToolUse { invocation; _ } ->
              pre_tool_turns
              := Tool_contract.Invocation.turn invocation :: !pre_tool_turns;
              Hooks.Continue
            | _ -> Alcotest.fail "expected PreToolUse")
    }
  in
  let tool =
    Tool.of_schema
      (Types.tool_schema_of_params
         ~name:"identity_tool"
         ~description:"observe the canonical provider turn"
         ~parameters:[]
         ())
      (fun execution_env _input ->
         (match Tool.Execution_env.invocation execution_env with
          | None -> Alcotest.fail "tool handler received no invocation"
          | Some invocation ->
            handler_turns := Tool_contract.Invocation.turn invocation :: !handler_turns);
         Ok { Types.content = "observed"; _meta = None })
  in
  let responses =
    ref
      [ { (pipeline_response StopToolUse) with
          id = "provider-turn-0"
        ; content =
            [ ToolUse
                { id = "provider-tool-0"; name = "identity_tool"; input = `Assoc [] }
            ]
        }
      ; { (pipeline_response EndTurn) with id = "provider-turn-1" }
      ]
  in
  let next_response () =
    match !responses with
    | response :: rest ->
      responses := rest;
      Ok response
    | [] ->
      Error
        (Llm_provider.Http_client.AcceptRejected
           { reason = "provider-turn identity fixture exhausted responses" })
  in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun _request ->
          { Llm_provider.Llm_transport.response = next_response (); latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> next_response ())
    }
  in
  let event_bus = Event_bus.create () in
  let event_config =
    Event_bus.subscription_config ~capacity:32 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let subscription = Event_bus.subscribe ~config:event_config event_bus in
  let agent =
    Agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:
        { (Types.default_config ~model:"test-model") with
          name = "provider-turn-identity-test"
        }
      ~tools:[ tool ]
      ~options:
        { Agent.default_options with
          transport = Some transport
        ; provider_config = Some (Provider_mock.to_provider_config ())
        ; hooks
        ; event_bus = Some event_bus
        }
      ()
  in
  (match Agent.run ~sw agent "run identity_tool" with
   | Ok response ->
     Alcotest.(check string) "terminal response" "done" (Types.text_of_response response)
   | Error error -> Alcotest.fail (Error.to_string error));
  let turn_started, turn_ready, turn_completed, tool_events =
    Event_bus.drain subscription
    |> List.fold_left
         (fun (started, ready, completed, tools) (event : Event_bus.event) ->
            match event.payload with
            | TurnStarted { turn; _ } -> turn :: started, ready, completed, tools
            | TurnReady { turn; _ } -> started, turn :: ready, completed, tools
            | TurnCompleted { turn; _ } -> started, ready, turn :: completed, tools
            | ToolCalled { invocation; _ } | ToolCompleted { invocation; _ } ->
              started, ready, completed, Tool_contract.Invocation.turn invocation :: tools
            | AgentStarted _
            | AgentCompleted _
            | AgentFailed _
            | HandoffRequested _
            | HandoffCompleted _
            | ElicitationCompleted _
            | ToolApprovalCompleted _
            | InferenceTelemetry _
            | Custom _ -> started, ready, completed, tools)
         ([], [], [], [])
  in
  let check_turns label expected actual =
    Alcotest.(check (list int)) label expected (List.rev actual)
  in
  check_turns "BeforeTurn identity" [ 0; 1 ] !before_turns;
  check_turns "AfterTurn identity" [ 0; 1 ] !after_turns;
  check_turns "TurnStarted identity" [ 0; 1 ] turn_started;
  check_turns "TurnReady identity" [ 0; 1 ] turn_ready;
  check_turns "TurnCompleted identity" [ 0; 1 ] turn_completed;
  check_turns "PreToolUse identity" [ 0 ] !pre_tool_turns;
  check_turns "tool handler identity" [ 0 ] !handler_turns;
  check_turns "public tool event identity" [ 0; 0 ] tool_events;
  Alcotest.(check int)
    "state advances after two provider turns"
    2
    (Agent.state agent).turn_count
;;

let unwrap_raw_trace = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Error.to_string error)
;;

let test_stream_route_carries_exact_raw_trace_run_id () =
  let trace_path = Filename.temp_file "oas-pipeline-capture-id" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> Sys.remove trace_path)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Eio.Switch.run
       @@ fun sw ->
       let captured_id = ref None in
       let response = pipeline_response EndTurn in
       let transport : Llm_provider.Llm_transport.t =
         { complete_sync =
             (fun _req ->
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream =
             (fun ?on_telemetry:_ ~on_event:_ request ->
               captured_id := request.Llm_provider.Llm_transport.capture_id;
               Ok response)
         }
       in
       let options =
         { Internal_agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         }
       in
       let agent =
         Internal_agent.create
           ~net:(Eio.Stdenv.net env)
           ~config:
             { (Types.default_config ~model:"test-model") with
               name = "pipeline-capture-id-test"
             }
           ~options
           ()
       in
       Internal_agent.set_state
         agent
         { (Internal_agent.state agent) with messages = [ Types.user_msg "hello" ] };
       let trace = unwrap_raw_trace (Raw_trace.create ~path:trace_path ()) in
       let active =
         unwrap_raw_trace
           (Raw_trace.start_run
              trace
              ~agent_name:"pipeline-capture-id-test"
              ~prompt:"hello"
              ())
       in
       let expected = Raw_trace.active_run_id active in
       (match
          Internal_pipeline.run_turn
            ~sw
            ~api_strategy:
              (Internal_pipeline.Stream { on_event = ignore; on_telemetry = None })
            ~raw_trace_run:active
            agent
        with
        | Ok (Internal_pipeline.Complete _) -> ()
        | Ok (Internal_pipeline.ToolsExecuted _) ->
          Alcotest.fail "expected a completed streaming turn"
        | Ok (Internal_pipeline.TerminalToolCompleted _) ->
          Alcotest.fail "unexpected terminal tool completion"
        | Error error -> Alcotest.fail (Error.to_string error));
       Alcotest.(check (option string))
         "transport capture identity"
         (Some expected)
         !captured_id;
       ignore
         (unwrap_raw_trace
            (Raw_trace.finish_run
               active
               ~final_text:(Some "done")
               ~stop_reason:(Some "EndTurn")
               ~error:None)))
;;

let text_tool_intent_response () =
  { (pipeline_response EndTurn) with
    id = "pipeline-tool-recovery-test"
  ; content = [ Text "{\"name\":\"my_tool\",\"input\":{\"x\":1}}" ]
  }
;;

let make_text_tool_intent_test_agent
      ~net
      ~(provider_config : Llm_provider.Provider_config.t)
  =
  let tool =
    Tool.create ~name:"my_tool" ~description:"test" ~parameters:[] (fun _ ->
      Ok { Types.content = "ok"; _meta = None })
  in
  let response = text_tool_intent_response () in
  let transport = transport_returning response in
  let options =
    { Internal_agent.default_options with
      transport = Some transport
    ; provider_config = Some provider_config
    }
  in
  let agent =
    Internal_agent.create
      ~net
      ~tools:[ tool ]
      ~config:
        { (Types.default_config ~model:"test-model") with
          name = "pipeline-tool-recovery-test"
        }
      ~options
      ()
  in
  Internal_agent.set_state
    agent
    { (Internal_agent.state agent) with messages = [ Types.user_msg "hello" ] };
  agent
;;

let test_pipeline_output_completes_on_end_turn () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let agent = make_pipeline_test_agent ~net ~response:(pipeline_response EndTurn) in
  match Internal_pipeline.run_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
  | Ok (Internal_pipeline.Complete response) ->
    Alcotest.(check bool) "completed" true (response.stop_reason = EndTurn)
  | Ok (Internal_pipeline.ToolsExecuted _) ->
    Alcotest.fail "expected Complete, got ToolsExecuted"
  | Ok (Internal_pipeline.TerminalToolCompleted _) ->
    Alcotest.fail "expected Complete, got TerminalToolCompleted"
  | Error err -> Alcotest.failf "unexpected run error: %s" (Error.to_string err)
;;

let test_pipeline_output_rejects_unknown_terminal () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let agent =
    make_pipeline_test_agent ~net ~response:(pipeline_response (Unknown "mystery-stop"))
  in
  match Internal_pipeline.run_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
  | Error (Error.Agent (UnrecognizedStopReason { reason })) ->
    Alcotest.(check string) "unknown reason" "mystery-stop" reason
  | Error err -> Alcotest.failf "unexpected run error: %s" (Error.to_string err)
  | Ok _ -> Alcotest.fail "expected unknown stop reason rejection"
;;

let test_pipeline_output_completes_repetition_truncation () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let agent =
    make_pipeline_test_agent ~net ~response:(pipeline_response RepetitionTruncation)
  in
  match Internal_pipeline.run_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
  | Ok (Internal_pipeline.Complete response) ->
    Alcotest.(check bool)
      "documented provider terminal reason is preserved"
      true
      (response.stop_reason = RepetitionTruncation)
  | Ok (Internal_pipeline.ToolsExecuted _) ->
    Alcotest.fail "expected Complete, got ToolsExecuted"
  | Ok (Internal_pipeline.TerminalToolCompleted _) ->
    Alcotest.fail "expected Complete, got TerminalToolCompleted"
  | Error err -> Alcotest.failf "unexpected run error: %s" (Error.to_string err)
;;

let test_pipeline_output_rejects_tool_stop_without_block () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let reject stop_reason expected =
    let agent = make_pipeline_test_agent ~net ~response:(pipeline_response stop_reason) in
    match Internal_pipeline.run_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
    | Error (Error.Agent (UnrecognizedStopReason { reason })) ->
      Alcotest.(check string) "tool stop rejection" expected reason
    | Error err -> Alcotest.failf "unexpected run error: %s" (Error.to_string err)
    | Ok _ -> Alcotest.fail "expected malformed tool-stop rejection"
  in
  reject UnmatchedToolCalls "unmatched_tool_calls";
  reject StopToolUse "StopToolUse turn carried no tool block"
;;

let test_pipeline_text_tool_intent_remains_text () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let provider = Provider_mock.to_provider_config () in
  let agent = make_text_tool_intent_test_agent ~net ~provider_config:provider in
  match Internal_pipeline.run_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
  | Ok (Internal_pipeline.Complete response) ->
    (match response.content with
     | [ Text _ ] -> ()
     | _ -> Alcotest.fail "expected text to remain unpromoted")
  | Ok (Internal_pipeline.ToolsExecuted _) ->
    Alcotest.fail "text content must not be promoted into a tool call"
  | Ok (Internal_pipeline.TerminalToolCompleted _) ->
    Alcotest.fail "text content must not produce terminal completion"
  | Error err -> Alcotest.failf "unexpected run error: %s" (Error.to_string err)
;;

let repeated_invalid_tool_response id : Types.api_response =
  { id
  ; model = "mock-model"
  ; stop_reason = StopToolUse
  ; content = [ ToolUse { id; name = "my_tool"; input = `Assoc [] } ]
  ; usage = None
  ; telemetry = None
  }
;;

let test_repeated_validation_error_without_judge_continues_to_provider () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let provider_calls = ref 0 in
  let next_response (_req : Llm_provider.Llm_transport.completion_request) =
    incr provider_calls;
    match !provider_calls with
    | 1 | 2 ->
      repeated_invalid_tool_response (Printf.sprintf "invalid-%d" !provider_calls)
    | 3 ->
      { Types.id = "validation-replanned"
      ; model = "mock-model"
      ; stop_reason = EndTurn
      ; content = [ Text "provider replanned" ]
      ; usage = None
      ; telemetry = None
      }
    | _ -> Alcotest.fail "unexpected fourth provider call"
  in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun req ->
          { Llm_provider.Llm_transport.response = Ok (next_response req)
          ; latency_ms = None
          })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ req -> Ok (next_response req))
    }
  in
  let executed = ref 0 in
  let tool =
    Tool.create
      ~name:"my_tool"
      ~description:"requires x"
      ~parameters:
        [ { Types.name = "x"
          ; description = "required input"
          ; param_type = Types.String
          ; required = true
          }
        ]
      (fun _ ->
         incr executed;
         Ok { Types.content = "should not execute"; _meta = None })
  in
  let options =
    { Agent.default_options with
      transport = Some transport
    ; provider_config = Some (Provider_mock.to_provider_config ())
    }
  in
  let agent =
    Agent.create
      ~net
      ~tools:[ tool ]
      ~config:
        { (Types.default_config ~model:"test-model") with
          name = "validation-loop-block-test"
        }
      ~options
      ()
  in
  match Agent.run ~sw agent "call my_tool" with
  | Ok response ->
    Alcotest.(check int) "provider calls" 3 !provider_calls;
    Alcotest.(check int) "tool handler not executed" 0 !executed;
    Alcotest.(check string)
      "provider controls terminal response"
      "validation-replanned"
      response.id;
    Alcotest.(check string)
      "provider final text"
      "provider replanned"
      (Types.text_of_response response)
  | Error err -> Alcotest.failf "unexpected run error: %s" (Error.to_string err)
;;

(* ── Provider_mock: additional coverage ─────────────────── *)

let test_mock_reset () =
  let mock =
    Provider_mock.create
      ~responses:[ Provider_mock.text_response "a"; Provider_mock.text_response "b" ]
      ()
  in
  let _r1 = Provider_mock.next_response mock [] in
  Alcotest.(check int) "count after 1" 1 (Provider_mock.call_count mock);
  Provider_mock.reset mock;
  Alcotest.(check int) "count after reset" 0 (Provider_mock.call_count mock);
  (* First response again *)
  match Provider_mock.next_response mock [] with
  | Ok resp ->
    let text =
      List.filter_map
        (function
          | Types.Text s -> Some s
          | _ -> None)
        resp.content
      |> String.concat ""
    in
    Alcotest.(check string) "reset replays from start" "a" text
  | Error _ -> Alcotest.fail "unexpected error after reset"
;;

let test_mock_cycle_wraps () =
  let mock = Provider_mock.create ~responses:[ Provider_mock.text_response "only" ] () in
  let _r1 = Provider_mock.next_response mock [] in
  let _r2 = Provider_mock.next_response mock [] in
  let _r3 = Provider_mock.next_response mock [] in
  Alcotest.(check int) "count after 3 calls" 3 (Provider_mock.call_count mock);
  (* All 3 calls succeed because of wrap-around *)
  match _r3 with
  | Ok resp ->
    let text =
      List.filter_map
        (function
          | Types.Text s -> Some s
          | _ -> None)
        resp.content
      |> String.concat ""
    in
    Alcotest.(check string) "wrapped" "only" text
  | Error _ -> Alcotest.fail "wrap-around failed"
;;

let test_mock_empty_responses () =
  let mock = Provider_mock.create ~responses:[] () in
  match Provider_mock.next_response mock [] with
  | Error (Error.Internal msg) ->
    Alcotest.(check bool) "mentions empty" true (String.length msg > 0)
  | Error _ -> Alcotest.fail "wrong error type"
  | Ok _ -> Alcotest.fail "expected error for empty responses"
;;

let test_mock_thinking_response () =
  let mock =
    Provider_mock.create
      ~responses:
        [ Provider_mock.thinking_response
            ~thinking:"Let me think..."
            ~text:"The answer is 42"
            ()
        ]
      ()
  in
  match Provider_mock.next_response mock [] with
  | Ok resp ->
    let has_thinking =
      List.exists
        (function
          | Types.Thinking _ -> true
          | _ -> false)
        resp.content
    in
    let has_text =
      List.exists
        (function
          | Types.Text _ -> true
          | _ -> false)
        resp.content
    in
    Alcotest.(check bool) "has thinking" true has_thinking;
    Alcotest.(check bool) "has text" true has_text
  | Error e -> Alcotest.failf "unexpected: %s" (Error.to_string e)
;;

let test_mock_to_provider_config () =
  let cfg = Provider_mock.to_provider_config () in
  Alcotest.(check string) "model_id" "test-model" cfg.model_id;
  Alcotest.(check (option string)) "provider_id" (Some "test") cfg.provider_id;
  Alcotest.(check string) "base_url" "http://test.invalid" cfg.base_url;
  Alcotest.(check string) "request_path" "/v1/chat/completions" cfg.request_path
;;

(* ── Agent state: more detail ──────────────────────────── *)

let test_agent_initial_usage () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let agent =
    Agent.create
      ~net
      ~config:{ (Types.default_config ~model:"test-model") with name = "usage-test" }
      ()
  in
  let state = Agent.state agent in
  Alcotest.(check int) "total_input_tokens 0" 0 state.usage.total_input_tokens;
  Alcotest.(check int) "total_output_tokens 0" 0 state.usage.total_output_tokens;
  Alcotest.(check int) "api_calls 0" 0 state.usage.api_calls
;;

let test_agent_empty_tools () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let agent =
    Agent.create ~config:(Types.default_config ~model:"test-model") ~net ~tools:[] ()
  in
  let tools = Agent.tools agent in
  Alcotest.(check int) "0 tools" 0 (Tool_set.size tools)
;;

let test_agent_multiple_tools () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let t1 =
    Tool.create ~name:"tool_a" ~description:"A" ~parameters:[] (fun _ ->
      Ok { Types.content = "a"; _meta = None })
  in
  let t2 =
    Tool.create ~name:"tool_b" ~description:"B" ~parameters:[] (fun _ ->
      Ok { Types.content = "b"; _meta = None })
  in
  let t3 =
    Tool.create ~name:"tool_c" ~description:"C" ~parameters:[] (fun _ ->
      Ok { Types.content = "c"; _meta = None })
  in
  let agent =
    Agent.create
      ~config:(Types.default_config ~model:"test-model")
      ~net
      ~tools:[ t1; t2; t3 ]
      ()
  in
  Alcotest.(check int) "3 tools" 3 (Tool_set.size (Agent.tools agent))
;;

(* ── Agent_turn: prepare_turn edge cases ──────────────── *)

let test_prepare_turn_no_tools () =
  let messages =
    [ { Types.role = User
      ; content = [ Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let prep =
    Agent_turn.prepare_turn
      ~tools:Tool_set.empty
      ~messages
      ~turn_params:Hooks.default_turn_params
      ()
    |> Result.get_ok
  in
  (match prep.tools_json with
   | None -> ()
   | Some _ -> Alcotest.fail "expected no tools_json for empty tool set");
  Alcotest.(check int) "1 message" 1 (List.length prep.effective_messages);
  (* visible_tool_names is empty when the caller supplies no tools. *)
  Alcotest.(check (list string)) "empty visible_tool_names" [] prep.visible_tool_names
;;

let test_prepare_turn_preserves_messages () =
  let messages =
    [ { Types.role = User
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { Types.role = Assistant
      ; content = [ Text "hi there" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { Types.role = User
      ; content = [ Text "how are you" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let prep =
    Agent_turn.prepare_turn
      ~tools:Tool_set.empty
      ~messages
      ~turn_params:Hooks.default_turn_params
      ()
    |> Result.get_ok
  in
  Alcotest.(check int) "3 messages" 3 (List.length prep.effective_messages)
;;

(* ── Agent_turn.make_tool_results ───────────────────── *)

let test_make_tool_results_ok () =
  let results =
    [ { Agent_tools.invocation = invocation "tu1"
      ; tool_name = "tool-1"
      ; input = `Null
      ; content = "result1"
      ; outcome = Tool_succeeded
      }
    ; { invocation = invocation "tu2"
      ; tool_name = "tool-2"
      ; input = `Null
      ; content = "result2"
      ; outcome = Tool_succeeded
      }
    ]
  in
  let tool_results = Agent_turn.make_tool_results results in
  Alcotest.(check int) "2 tool results" 2 (List.length tool_results);
  List.iter
    (fun block ->
       match block with
       | Types.ToolResult { outcome; _ } ->
         Alcotest.(check bool)
           "not error"
           false
           (Types.tool_result_outcome_is_error outcome)
       | _ -> Alcotest.fail "expected ToolResult")
    tool_results
;;

let test_make_tool_results_error () =
  let results =
    [ { Agent_tools.invocation = invocation "tu1"
      ; tool_name = "tool-1"
      ; input = `Null
      ; content = "failed"
      ; outcome =
          Tool_failed
            { failure_kind = Agent_tools.Recoverable_tool_error; error_class = None }
      }
    ]
  in
  let tool_results = Agent_turn.make_tool_results results in
  Alcotest.(check int) "1 tool result" 1 (List.length tool_results);
  match List.hd tool_results with
  | Types.ToolResult { outcome = Tool_failed _; content; _ } ->
    Alcotest.(check bool) "error content" true (String.length content > 0)
  | _ -> Alcotest.fail "expected error ToolResult"
;;

let test_make_tool_results_mixed () =
  let results =
    [ { Agent_tools.invocation = invocation "tu1"
      ; tool_name = "tool-1"
      ; input = `Null
      ; content = "good"
      ; outcome = Tool_succeeded
      }
    ; { invocation = invocation "tu2"
      ; tool_name = "tool-2"
      ; input = `Null
      ; content = "bad"
      ; outcome =
          Tool_failed
            { failure_kind = Agent_tools.Recoverable_tool_error; error_class = None }
      }
    ]
  in
  let tool_results = Agent_turn.make_tool_results results in
  Alcotest.(check int) "2 results" 2 (List.length tool_results)
;;

(* ── accumulate_usage ────────────────────────────────────── *)

let test_accumulate_usage_with_response () =
  let current = Types.empty_usage in
  let resp_usage =
    Some
      { Types.input_tokens = 100
      ; output_tokens = 50
      ; cache_creation_input_tokens = 20
      ; cache_read_input_tokens = 10
      ; cost_usd = None
      }
  in
  let result =
    Agent_turn.accumulate_usage
      ~current_usage:current
      ~provider_config:None
      ~response_model:None
      ~response_usage:resp_usage
  in
  Alcotest.(check int) "input tokens" 100 result.total_input_tokens;
  Alcotest.(check int) "output tokens" 50 result.total_output_tokens;
  Alcotest.(check int) "api_calls" 1 result.api_calls
;;

let test_accumulate_usage_no_response () =
  let current =
    { Types.empty_usage with
      api_calls = 2
    ; total_input_tokens = 500
    ; total_output_tokens = 200
    }
  in
  let result =
    Agent_turn.accumulate_usage
      ~current_usage:current
      ~provider_config:None
      ~response_model:None
      ~response_usage:None
  in
  Alcotest.(check int) "api_calls incremented" 3 result.api_calls;
  Alcotest.(check int) "input tokens preserved" 500 result.total_input_tokens;
  Alcotest.(check int) "output tokens preserved" 200 result.total_output_tokens
;;

let test_accumulate_usage_cumulative () =
  let u1 =
    Some
      { Types.input_tokens = 50
      ; output_tokens = 20
      ; cache_creation_input_tokens = 0
      ; cache_read_input_tokens = 0
      ; cost_usd = None
      }
  in
  let u2 =
    Some
      { Types.input_tokens = 30
      ; output_tokens = 10
      ; cache_creation_input_tokens = 0
      ; cache_read_input_tokens = 0
      ; cost_usd = None
      }
  in
  let after1 =
    Agent_turn.accumulate_usage
      ~current_usage:Types.empty_usage
      ~provider_config:None
      ~response_model:None
      ~response_usage:u1
  in
  let after2 =
    Agent_turn.accumulate_usage
      ~current_usage:after1
      ~provider_config:None
      ~response_model:None
      ~response_usage:u2
  in
  Alcotest.(check int) "cumulative input" 80 after2.total_input_tokens;
  Alcotest.(check int) "cumulative output" 30 after2.total_output_tokens;
  Alcotest.(check int) "cumulative calls" 2 after2.api_calls
;;

(* ── prepare_turn: extra_system_context ──────────────────── *)

let test_prepare_turn_extra_context () =
  let messages =
    [ { Types.role = User
      ; content = [ Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let turn_params =
    { Hooks.default_turn_params with
      extra_system_context = Some "You are in debug mode."
    }
  in
  let prep =
    Agent_turn.prepare_turn ~tools:Tool_set.empty ~messages ~turn_params ()
    |> Result.get_ok
  in
  (* Extra context is appended at the end to preserve prefix for KV cache *)
  Alcotest.(check int)
    "2 messages (original + context)"
    2
    (List.length prep.effective_messages);
  let last = List.nth prep.effective_messages 1 in
  match last.content with
  | [ Types.Text s ] ->
    Alcotest.(check string)
      "injected context at tail"
      "[system context] You are in debug mode."
      s
  | _ -> Alcotest.fail "expected Text block"
;;

(* ── Error_domain: tag_error ─────────────────────────────── *)

let test_error_domain_of_sdk_error () =
  let err = Error.Agent (UnrecognizedStopReason { reason = "weird" }) in
  let poly = Error_domain.of_sdk_error err in
  match poly with
  | `Unrecognized_stop_reason s -> Alcotest.(check string) "reason" "weird" s
  | _ -> Alcotest.fail "expected Unrecognized_stop_reason"
;;

let test_error_domain_roundtrip () =
  let err = Error.Internal "test error" in
  let poly = Error_domain.of_sdk_error err in
  let back = Error_domain.to_sdk_error poly in
  Alcotest.(check string) "roundtrip" (Error.to_string err) (Error.to_string back)
;;

let test_error_domain_with_stage () =
  let poly = Error_domain.of_sdk_error (Error.Internal "fail") in
  let ctx = Error_domain.with_stage "route" poly in
  let s = Error_domain.ctx_to_string ctx in
  Alcotest.(check bool) "contains stage" true (String.length s > 0);
  Alcotest.(check bool)
    "has route prefix"
    true
    (let prefix = "[route]" in
     String.length s >= String.length prefix
     && String.sub s 0 (String.length prefix) = prefix)
;;

let test_error_domain_is_retryable () =
  Alcotest.(check bool)
    "rate limited is retryable"
    true
    (Error_domain.is_retryable (`Rate_limited (Some 1.0, "slow down")));
  Alcotest.(check bool)
    "internal not retryable"
    false
    (Error_domain.is_retryable (`Internal "nope"));
  Alcotest.(check bool)
    "network error retryable"
    true
    (Error_domain.is_retryable (`Network_error "timeout"))
;;

let test_error_domain_provider_errors () =
  let errs : Error_domain.sdk_error_poly list =
    [ `Auth_error "bad key"
    ; `Server_error (500, "internal")
    ; `Overloaded
    ; `Provider_timeout (None, "slow")
    ; `Invalid_request (Llm_provider.Retry.Unknown_invalid_request, "bad")
    ]
  in
  List.iter
    (fun e ->
       let s = Error_domain.to_string e in
       Alcotest.(check bool) "has string" true (String.length s > 0))
    errs
;;

(* Pipeline.error_domain_of stamps the durable [Error_occurred] event's
   [error_domain] from the actual error's typed category, not a hardcoded
   "Api". A durable journal/store-write failure surfaces as [Error.Internal]
   (see Pipeline_execution_scope.sdk_error), so it must be labeled "Internal",
   not misattributed to the provider "Api" domain. The Internal->Internal
   assertion fails if the hardcoded [error_domain = "Api"] is restored. *)
let test_error_domain_of_persistence_not_api () =
  Alcotest.(check string)
    "persistence/store failure -> Internal"
    "Internal"
    (Internal_pipeline.error_domain_of (Error.Internal "journal write failed: disk full"));
  Alcotest.(check bool)
    "persistence failure is not misattributed to Api"
    true
    (Internal_pipeline.error_domain_of (Error.Internal "x") <> "Api");
  (* Genuine provider errors stay "Api" so existing provider logs are stable. *)
  Alcotest.(check string)
    "genuine provider error -> Api"
    "Api"
    (Internal_pipeline.error_domain_of
       (Error.Api (Error.Retry.AuthError { message = "bad key" })));
  (* A third variant confirms the label is derived, not constant. *)
  Alcotest.(check string)
    "config error -> Config"
    "Config"
    (Internal_pipeline.error_domain_of
       (Error.Config (Error.MissingEnvVar { var_name = "API_KEY" })))
;;

(* ── Provider_mock: multi-tool response ───────────────────── *)

let test_mock_multi_tool_response () =
  let mock =
    Provider_mock.create
      ~responses:
        [ Provider_mock.tool_use_response ~tool_name:"t1" ~tool_input:(`Assoc []) () ]
      ()
  in
  match Provider_mock.next_response mock [] with
  | Ok resp ->
    let tool_count =
      List.length
        (List.filter
           (function
             | Types.ToolUse _ -> true
             | _ -> false)
           resp.content)
    in
    Alcotest.(check bool) "has tool use" true (tool_count > 0)
  | Error _ -> Alcotest.fail "expected ok"
;;

let with_execution_test_dir prefix f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let runtime =
    match
      Agent.create_execution_runtime
        ~sw
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domain_count:1
    with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  let native_path = Filename.temp_file prefix ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
  Eio.Switch.on_release sw (fun () -> Eio.Path.rmtree ~missing_ok:true dir);
  f ~env ~sw ~runtime ~dir
;;

let test_terminal_disposition_retires_settled_provider_failure () =
  with_execution_test_dir "oas-agent-terminal-failure-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let checkpoint_count = ref 0 in
  let locator_persisted = ref false in
  let terminal_disposition = ref None in
  let responses =
    ref
      [ Ok
          (Provider_mock.tool_use_response
             ~tool_name:"durable_tool"
             ~tool_input:(`Assoc [])
             ()
             [])
      ; Error
          (Llm_provider.Http_client.AcceptRejected
             { reason = "provider failed after persisted checkpoint" })
      ]
  in
  let next_response () =
    match !responses with
    | response :: rest ->
      responses := rest;
      response
    | [] -> Alcotest.fail "provider failure fixture exhausted responses"
  in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun _request ->
          { Llm_provider.Llm_transport.response = next_response (); latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> next_response ())
    }
  in
  let tool =
    Tool.create
      ~name:"durable_tool"
      ~description:"settled before provider failure"
      ~parameters:[]
      (fun _input -> Ok { Types.content = "settled"; _meta = None })
  in
  let agent =
    Agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:
        { (Types.default_config ~model:"test-model") with
          name = "terminal-provider-failure-test"
        }
      ~tools:[ tool ]
      ~options:
        { Agent.default_options with
          transport = Some transport
        ; provider_config = Some (Provider_mock.to_provider_config ())
        }
      ~checkpoint_sink:(fun _snapshot ->
        incr checkpoint_count;
        Ok ())
      ()
  in
  let execution_store =
    Agent.execution_store
      ~runtime
      ~dir
      ~on_scope_ready:(fun _locator ->
        locator_persisted := true;
        Ok ())
      ~on_terminal_disposition:(fun disposition ->
        terminal_disposition := Some disposition;
        Ok ())
      ()
  in
  (match Agent.run ~sw ~execution_store agent "run the tool" with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "provider failure unexpectedly completed");
  Alcotest.(check bool) "locator persisted" true !locator_persisted;
  Alcotest.(check bool) "checkpoint persisted" true (!checkpoint_count > 0);
  check_terminal_disposition ~outcome:"failed" ~recovery:"retire" !terminal_disposition
;;

let test_terminal_disposition_sink_failure_fails_call () =
  with_execution_test_dir "oas-agent-terminal-sink-failure-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let callback_count = ref 0 in
  let response = Provider_mock.text_response "done" [] in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun _request ->
          { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
    }
  in
  let agent =
    Agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:
        { (Types.default_config ~model:"test-model") with
          name = "terminal-sink-failure-test"
        }
      ~options:
        { Agent.default_options with
          transport = Some transport
        ; provider_config = Some (Provider_mock.to_provider_config ())
        }
      ()
  in
  let execution_store =
    Agent.execution_store
      ~runtime
      ~dir
      ~on_terminal_disposition:(fun _disposition ->
        incr callback_count;
        Error "injected persistence failure")
      ()
  in
  (match Agent.run ~sw ~execution_store agent "complete" with
   | Error (Error.Internal _) -> ()
   | Error error ->
     Alcotest.failf "terminal sink failure changed category: %s" (Error.to_string error)
   | Ok _ -> Alcotest.fail "terminal sink failure unexpectedly completed");
  Alcotest.(check int) "terminal sink called once" 1 !callback_count;
  Alcotest.(check bool)
    "terminal journal committed before sink failure"
    true
    (Eio.Path.is_file Eio.Path.(dir / "events.v1.commit"))
;;

let test_terminal_disposition_observes_cancellation () =
  with_execution_test_dir "oas-agent-terminal-cancel-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let terminal_disposition = ref None in
  let cancel () = raise (Eio.Cancel.Cancelled Exit) in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync = (fun _request -> cancel ())
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> cancel ())
    }
  in
  let agent =
    Agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:
        { (Types.default_config ~model:"test-model") with
          name = "terminal-cancellation-test"
        }
      ~options:
        { Agent.default_options with
          transport = Some transport
        ; provider_config = Some (Provider_mock.to_provider_config ())
        }
      ()
  in
  let execution_store =
    Agent.execution_store
      ~runtime
      ~dir
      ~on_terminal_disposition:(fun disposition ->
        terminal_disposition := Some disposition;
        Ok ())
      ()
  in
  (match Agent.run ~sw ~execution_store agent "cancel" with
   | exception Eio.Cancel.Cancelled Exit -> ()
   | exception exn ->
     Alcotest.failf "unexpected cancellation exception: %s" (Printexc.to_string exn)
   | Ok _ | Error _ -> Alcotest.fail "cancellation did not propagate");
  check_terminal_disposition ~outcome:"cancelled" ~recovery:"retire" !terminal_disposition
;;

let test_agent_run_uses_durable_tool_authority () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun runtime_sw ->
  let runtime =
    match
      Agent.create_execution_runtime
        ~sw:runtime_sw
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domain_count:1
    with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  let native_path = Filename.temp_file "oas-agent-execution-" ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
  Fun.protect
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
    (fun () ->
       Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
       let locator_persisted = ref false in
       let effect_after_locator = ref false in
       let effect_count = ref 0 in
       let completion_cursor = ref None in
       let terminal_disposition = ref None in
       let committed_cursor () =
         let authority =
           Eio.Path.load Eio.Path.(dir / "events.v1.commit") |> Yojson.Safe.from_string
         in
         match authority with
         | `Assoc outer ->
           (match List.assoc_opt "authority" outer with
            | Some (`Assoc fields) ->
              (match List.assoc_opt "last_seq" fields with
               | Some (`Int value) -> value
               | _ -> Alcotest.fail "execution authority has no integer last_seq")
            | _ -> Alcotest.fail "execution commit has no authority object")
         | _ -> Alcotest.fail "execution commit authority is not an object"
       in
       let responses =
         ref
           (Provider_mock.tool_then_text
              ~tool_name:"durable_tool"
              ~tool_input:(`Assoc [ "value", `Int 7 ])
              ~final_text:"done"
              ()
            |> List.map (fun response -> response []))
       in
       let next_response () =
         match !responses with
         | response :: rest ->
           responses := rest;
           Ok response
         | [] ->
           Error
             (Llm_provider.Http_client.AcceptRejected
                { reason = "durable execution test exhausted responses" })
       in
       let transport : Llm_provider.Llm_transport.t =
         { complete_sync =
             (fun _request ->
               { Llm_provider.Llm_transport.response = next_response ()
               ; latency_ms = Some 0
               })
         ; complete_stream =
             (fun ?on_telemetry:_ ~on_event:_ _request -> next_response ())
         }
       in
       let journal = Durable_event.create () in
       let event_bus = Event_bus.create () in
       let event_config =
         Event_bus.subscription_config ~capacity:32 ~overflow:Event_bus.Drop_newest
         |> Result.get_ok
       in
       let event_subscription = Event_bus.subscribe ~config:event_config event_bus in
       let tool =
         Tool.create
           ~name:"durable_tool"
           ~description:"durable execution test"
           ~parameters:[]
           (fun _input ->
              incr effect_count;
              effect_after_locator := !locator_persisted;
              Ok { Types.content = "tool-result"; _meta = None })
       in
       let options =
         { Agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         ; journal = Some journal
         ; event_bus = Some event_bus
         ; on_run_complete =
             Some
               (fun succeeded ->
                 Alcotest.(check bool) "completion reports success" true succeeded;
                 completion_cursor := Some (committed_cursor ()))
         }
       in
       let agent =
         Agent.create
           ~net:(Eio.Stdenv.net env)
           ~config:
             { (Types.default_config ~model:"test-model") with
               name = "durable-agent-run-test"
             }
           ~tools:[ tool ]
           ~options
           ()
       in
       let execution_store =
         Agent.execution_store
           ~runtime
           ~dir
           ~on_scope_ready:(fun locator ->
             (match Agent.execution_locator_to_yojson locator with
              | `Assoc fields ->
                Alcotest.(check bool)
                  "locator contains durable run identity"
                  true
                  (List.mem_assoc "run_id" fields)
              | _ -> Alcotest.fail "execution locator is not an object");
             locator_persisted := true;
             Ok ())
           ~on_terminal_disposition:(fun disposition ->
             ignore (committed_cursor ());
             terminal_disposition := Some disposition;
             Ok ())
           ()
       in
       (match Agent.run ~sw:runtime_sw ~execution_store agent "run the tool" with
        | Ok response ->
          Alcotest.(check string)
            "terminal response"
            "done"
            (Types.text_of_response response)
        | Error error -> Alcotest.fail (Error.to_string error));
       Alcotest.(check int) "tool effect executes once" 1 !effect_count;
       Alcotest.(check bool)
         "locator is durable before tool effect"
         true
         !effect_after_locator;
       check_terminal_disposition
         ~outcome:"succeeded"
         ~recovery:"retire"
         !terminal_disposition;
       Alcotest.(check (option int))
         "completion observes the final durable cursor"
         (Some (committed_cursor ()))
         !completion_cursor;
       let legacy_tool_events =
         Durable_event.events journal
         |> List.filter (function
           | Durable_event.Tool_called _ | Durable_event.Tool_completed _ -> true
           | _ -> false)
       in
       Alcotest.(check int)
         "legacy journal does not duplicate tool authority"
         0
         (List.length legacy_tool_events);
       let public_tool_events =
         Event_bus.drain event_subscription
         |> List.filter (fun (event : Event_bus.event) ->
           match event.payload with
           | ToolCalled _ | ToolCompleted _ -> true
           | AgentStarted _
           | AgentCompleted _
           | AgentFailed _
           | TurnStarted _
           | TurnReady _
           | TurnCompleted _
           | HandoffRequested _
           | HandoffCompleted _
           | ElicitationCompleted _
           | ToolApprovalCompleted _
           | InferenceTelemetry _
           | Custom _ -> false)
       in
       Alcotest.(check int)
         "durable authority preserves public ToolCalled and ToolCompleted"
         2
         (List.length public_tool_events))
;;

let durable_tool_response
      ?(id = "durable-provider-response")
      ?(model = "persisted-provider-model")
      ?(usage = None)
      tool_uses
  =
  { Types.id
  ; model
  ; stop_reason = Types.StopToolUse
  ; content =
      List.map (fun (id, name, input) -> Types.ToolUse { id; name; input }) tool_uses
  ; usage
  ; telemetry = None
  }
;;

let record_durable_provider_response provider response =
  match Internal_scope.record_provider_response provider response with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
;;

let test_agent_run_resumes_tool_without_duplicate_effects
      ?(extra_restored_messages = [])
      ?(resume_prompt = "run the tool")
      ?(expect_reject = false)
      ~settled
      ()
  =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun runtime_sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    match Agent.create_execution_runtime ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  let internal_runtime =
    match Internal_runtime.create ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error)
  in
  let codec = Internal_codec.of_runtime internal_runtime in
  let native_path = Filename.temp_file "oas-agent-resume-" ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
  Fun.protect
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
    (fun () ->
       Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
       let config =
         { (Types.default_config ~model:"test-model") with
           name = "durable-agent-resume-test"
         }
       in
       let tool_input = `Assoc [ "value", `Int 7 ] in
       let tool_use_id = "restart-tool-use" in
       let schedule : Tool_contract.schedule =
         { planned_index = 0
         ; batch_index = 0
         ; batch_size = 1
         ; execution_mode = Tool_contract.Serial
         }
       in
       let locator_json = ref None in
       let exception Effect_interrupted_after_attempt in
       let provider_config =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~model_id:"test-model"
           ~base_url:"http://resume.invalid"
           ~api_key:""
           ~request_path:"/v1/chat/completions"
           ()
       in
       let binding =
         match
           Internal_binding.of_provider_config
             ~transport:Internal_binding.Injected
             provider_config
         with
         | Ok binding -> binding
         | Error detail -> Alcotest.fail detail
       in
       (match
          Internal_writer.run ~codec ~dir (fun ~sw:_ writer ->
            let scope =
              match
                Internal_scope.start ~writer ~agent_name:"durable-agent-resume-test"
              with
              | Ok scope -> scope
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            locator_json
            := Some
                 (Internal_scope.scope_locator_to_yojson
                    (Internal_scope.scope_locator scope));
            let turn =
              match Internal_scope.open_turn scope ~ordinal:0 with
              | Ok turn -> turn
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            let provider =
              match Internal_scope.open_provider_attempt turn ~ordinal:0 binding with
              | Ok provider -> provider
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            record_durable_provider_response
              provider
              (durable_tool_response [ tool_use_id, "durable_tool", tool_input ]);
            let invocation =
              Tool_contract.Invocation.create
                ~tool_use_id
                ~turn:0
                ~schedule
                ~completion:Tool_contract.Continue_after_success
            in
            let durable =
              match
                Internal_scope.open_invocation
                  provider
                  ~invocation
                  ~tool_name:"durable_tool"
                  ~input:tool_input
              with
              | Ok durable -> durable
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            match
              Internal_scope.execute
                durable
                ~invoke:(fun ~start_child:_ ~tool_name:_ ~input:_ ->
                  if settled
                  then "settled-before-restart", Types.Tool_succeeded
                  else raise Effect_interrupted_after_attempt)
            with
            | Ok (Internal_scope.Executed _) when settled -> ()
            | Ok (Internal_scope.Executed _) ->
              Alcotest.fail "unknown-effect fixture unexpectedly settled"
            | Ok (Internal_scope.Replayed _) ->
              Alcotest.fail "fixture unexpectedly replayed its first tool effect"
            | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            | exception Effect_interrupted_after_attempt when not settled -> ()
            | exception Effect_interrupted_after_attempt ->
              Alcotest.fail "settled fixture interrupted its tool effect")
        with
        | Ok () -> ()
        | Error failure -> Alcotest.fail (Internal_writer.scope_failure_to_string failure));
       let locator =
         match Option.get !locator_json |> Agent.execution_locator_of_yojson with
         | Ok locator -> locator
         | Error detail -> Alcotest.fail detail
       in
       let response = Provider_mock.text_response "done-after-restart" [] in
       let transport : Llm_provider.Llm_transport.t =
         { complete_sync =
             (fun _request ->
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
         }
       in
       let effect_count = ref 0 in
       let pre_hook_count = ref 0 in
       let post_hook_count = ref 0 in
       let terminal_disposition = ref None in
       let tool =
         Tool.create
           ~name:"durable_tool"
           ~description:"must not rerun after restart"
           ~parameters:[]
           (fun _input ->
              incr effect_count;
              Ok { Types.content = "duplicate"; _meta = None })
       in
       let hooks =
         { Hooks.empty with
           pre_tool_use =
             Some
               (fun _event ->
                 incr pre_hook_count;
                 Hooks.Continue)
         ; post_tool_use =
             Some
               (fun _event ->
                 incr post_hook_count;
                 Hooks.Continue)
         }
       in
       let options =
         { Agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         ; hooks
         }
       in
       let agent =
         Agent.create ~net:(Eio.Stdenv.net env) ~config ~tools:[ tool ] ~options ()
       in
       Agent.set_state
         agent
         { config
         ; messages =
             [ { Types.role = User
               ; content = [ Text "run the tool" ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { Types.role = Assistant
               ; content =
                   [ ToolUse
                       { id = tool_use_id; name = "durable_tool"; input = tool_input }
                   ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ]
             @ extra_restored_messages
         ; turn_count = 1
         ; usage = Types.empty_usage
         };
       let execution_store =
         Agent.execution_store
           ~runtime
           ~dir
           ~on_terminal_disposition:(fun disposition ->
             terminal_disposition := Some disposition;
             Ok ())
           ~resume:locator
           ()
       in
       let run_result = Agent.run ~sw:runtime_sw ~execution_store agent resume_prompt in
       if expect_reject
       then (
         (* Fail-closed: a resume prompt that does not match the run's original
            prompt is rejected before the durable scope reopens. The rejection
            short-circuits [resume_user_input] ahead of any journal I/O, so the
            settled tool effect is never rerun. *)
         (match run_result with
          | Error
              (Error.Config (Error.InvalidConfig { field = "execution_store.resume"; _ }))
            -> ()
          | Error error ->
            Alcotest.failf
              "expected resume-input rejection, got: %s"
              (Error.to_string error)
          | Ok _ -> Alcotest.fail "expected resume-input rejection, but resume succeeded");
         Alcotest.(check int) "rejected resume does not run tool handler" 0 !effect_count)
       else (
         (match settled, run_result with
          | true, Ok response ->
            Alcotest.(check string)
              "terminal response"
              "done-after-restart"
              (Types.text_of_response response)
          | true, Error error -> Alcotest.fail (Error.to_string error)
          | false, Error (Error.Internal _) -> ()
          | false, Error error ->
            Alcotest.failf
              "unknown effect changed error category: %s"
              (Error.to_string error)
          | false, Ok _ -> Alcotest.fail "unknown effect unexpectedly completed");
         Alcotest.(check int) "settled tool handler is not rerun" 0 !effect_count;
         Alcotest.(check int) "settled pre-tool hook is not rerun" 0 !pre_hook_count;
         Alcotest.(check int) "settled post-tool hook is not rerun" 0 !post_hook_count;
         if settled
         then
           check_terminal_disposition
             ~outcome:"succeeded"
             ~recovery:"retire"
             !terminal_disposition
         else
           check_terminal_disposition
             ~outcome:"failed"
             ~recovery:"operator_repair:effect_outcome_unknown"
             !terminal_disposition))
;;

let test_agent_run_resumes_settled_tool_without_duplicate_effects () =
  test_agent_run_resumes_tool_without_duplicate_effects ~settled:true ()
;;

let test_agent_run_reports_unknown_effect_for_operator_repair () =
  test_agent_run_resumes_tool_without_duplicate_effects ~settled:false ()
;;

(* A legacy journal could contain an invocation opened after an untyped
   [Answer (`Bool false)] and crash before committing the effect attempt. The
   invocation node alone is not current typed approval authority: resume must
   run the current gate again, and a denial must keep the effect closed. *)
let test_unattempted_legacy_invocation_requires_typed_readmission () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun runtime_sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    match Internal_runtime.create ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error)
  in
  let codec = Internal_codec.of_runtime runtime in
  let native_path = Filename.temp_file "oas-legacy-tool-approval-" ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
  Fun.protect
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
    (fun () ->
       Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
       match
         Internal_writer.run ~codec ~dir (fun ~sw:_ writer ->
           let scope =
             match Internal_scope.start ~writer ~agent_name:"legacy-approval-test" with
             | Ok scope -> scope
             | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
           in
           let turn =
             match Internal_scope.open_turn scope ~ordinal:0 with
             | Ok turn -> turn
             | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
           in
           let binding =
             let provider_config =
               Llm_provider.Provider_config.make
                 ~kind:Llm_provider.Provider_config.OpenAI_compat
                 ~model_id:"test-model"
                 ~base_url:"http://legacy-approval.invalid"
                 ~api_key:""
                 ~request_path:"/v1/chat/completions"
                 ()
             in
             match
               Internal_binding.of_provider_config
                 ~transport:Internal_binding.Injected
                 provider_config
             with
             | Ok binding -> binding
             | Error detail -> Alcotest.fail detail
           in
           let provider =
             match Internal_scope.open_provider_attempt turn ~ordinal:0 binding with
             | Ok provider -> provider
             | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
           in
           let tool_input = `Assoc [ "value", `Int 7 ] in
           let tool_use_id = "legacy-unattempted-tool-use" in
           record_durable_provider_response
             provider
             (durable_tool_response [ tool_use_id, "durable_tool", tool_input ]);
           let durable_invocation = invocation tool_use_id in
           (match
              Internal_scope.open_invocation
                provider
                ~invocation:durable_invocation
                ~tool_name:"durable_tool"
                ~input:tool_input
            with
            | Ok _ -> ()
            | Error error -> Alcotest.fail (Internal_scope.error_to_string error));
           let before_denial =
             match Internal_writer.current_cursor writer with
             | Ok cursor -> cursor
             | Error error -> Alcotest.fail (Internal_writer.read_error_to_string error)
           in
           let effect_count = ref 0 in
           let approval_count = ref 0 in
           let tool =
             Tool.create
               ~name:"durable_tool"
               ~description:"must remain closed after typed denial"
               ~parameters:[]
               (fun _ ->
                  incr effect_count;
                  Ok { Types.content = "unexpected-effect"; _meta = None })
           in
           let hooks =
             { Hooks.empty with
               pre_tool_use =
                 Some
                   (fun _ ->
                     Hooks.ElicitToolApproval
                       { Hooks.question = "Approve legacy durable call?" })
             }
           in
           let agent =
             Agent.create
               ~net:(Eio.Stdenv.net env)
               ~config:(Types.default_config ~model:"test-model")
               ~tools:[ tool ]
               ~options:
                 { Agent.default_options with
                   hooks
                 ; tool_approval =
                     Some
                       (fun _ ->
                         incr approval_count;
                         Hooks.Denied)
                 }
               ()
           in
           let options = Agent.options agent in
           let report =
             Internal.Execution_context.with_provider_attempt provider (fun () ->
               Agent_tools.execute_tools
                 ~context:(Agent.context agent)
                 ~tools:(Tool_set.to_list (Agent.tools agent))
                 ~hooks:options.hooks
                 ?tool_approval:options.tool_approval
                 ~event_bus:options.event_bus
                 ~tracer:options.tracer
                 ~agent_name:(Agent.state agent).config.name
                 ~turn_count:0
                 ~usage:Types.empty_usage
                 [ Types.ToolUse
                     { id = tool_use_id; name = "durable_tool"; input = tool_input }
                 ])
           in
           Alcotest.(check int) "typed approval runs once" 1 !approval_count;
           Alcotest.(check int) "denied legacy effect stays closed" 0 !effect_count;
           (match report with
            | Ok
                { Agent_tools.completed_results = [ { outcome = Types.Tool_failed _; _ } ]
                ; _
                } -> ()
            | Ok _ -> Alcotest.fail "typed denial did not produce a blocked ToolResult"
            | Error _ -> Alcotest.fail "typed denial returned an execution error");
           (match Internal_scope.provider_invocations_settled provider with
            | Ok true -> ()
            | Ok false -> Alcotest.fail "denied legacy invocation stayed open"
            | Error error -> Alcotest.fail (Internal_scope.error_to_string error));
           let denial_events =
             match Internal_writer.read_page writer ~after:before_denial ~limit:8 () with
             | Ok page -> page.events
             | Error error -> Alcotest.fail (Internal_writer.read_error_to_string error)
           in
           Alcotest.(check int)
             "typed denial opens no durable effect attempt"
             0
             (List.fold_left
                (fun count event ->
                   match Internal.Execution_event.payload event with
                   | Internal.Execution_event.Node_opened node ->
                     (match Internal.Execution_event.node_kind node with
                      | Internal.Execution_event.Tool_attempt -> count + 1
                      | Internal.Execution_event.Agent_run _
                      | Internal.Execution_event.Agent_turn _
                      | Internal.Execution_event.Provider_attempt _
                      | Internal.Execution_event.Output_block _
                      | Internal.Execution_event.Tool_invocation _ -> count)
                   | Internal.Execution_event.Node_updated _
                   | Internal.Execution_event.Node_closed _ -> count)
                0
                denial_events);
           List.iter
             (fun close ->
                match close () with
                | Ok () -> ()
                | Error error -> Alcotest.fail (Internal_scope.error_to_string error))
             [ (fun () ->
                 Internal_scope.close_provider_attempt
                   provider
                   Internal.Execution_event.Succeeded)
             ; (fun () ->
                 Internal_scope.close_turn turn Internal.Execution_event.Succeeded)
             ; (fun () -> Internal_scope.finish scope Internal.Execution_event.Succeeded)
             ])
       with
       | Ok () -> ()
       | Error failure -> Alcotest.fail (Internal_writer.scope_failure_to_string failure))
;;

(* A context injector appends User-role messages during a turn (see
   [Agent_turn.apply_context_injection]); after such a turn the latest User
   message in the restored checkpoint is the injected one, not the run's
   original prompt. Resume must match the original prompt (at the base-messages
   boundary), so it succeeds even though a later injected User message differs.
   Reverting [resume_user_input] to a latest-User-message scan makes this fail:
   the injected message no longer equals the resume prompt. *)
let test_agent_run_resume_ignores_injected_user_context_message () =
  test_agent_run_resumes_tool_without_duplicate_effects
    ~settled:true
    ~extra_restored_messages:
      [ { Types.role = User
        ; content = [ Text "[system] git status: clean" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ]
    ()
;;

(* Fail-closed preserved: a genuinely different resume prompt is still
   rejected, even with an injected User message present. *)
let test_agent_run_resume_rejects_mismatched_prompt () =
  test_agent_run_resumes_tool_without_duplicate_effects
    ~settled:true
    ~extra_restored_messages:
      [ { Types.role = User
        ; content = [ Text "[system] git status: clean" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ]
    ~resume_prompt:"a completely different prompt"
    ~expect_reject:true
    ()
;;

(* Regression for #2683: a fully-settled turn interrupted between the provider
   close, the turn close, and the root finish must resume through the public
   [Agent.run ~resume] surface instead of aborting the root as Failed.
   [close_success] commits the provider close and turn close as two journal
   transactions and the root [finish] is a third, so a crash leaves either
   [Window_provider_closed] (provider Closed Succeeded, turn Open) or
   [Window_turn_closed] (turn Closed Succeeded). Both are idempotent completed
   boundaries: the tool effect is durably settled and must be replayed, not
   re-run, and the run must complete Succeeded. [Window_turn_failed] pins the
   fail-closed contract: a Closed [Failed] turn stays an error, never a bogus
   success. *)
type settled_window =
  | Window_provider_closed
  | Window_turn_closed
  | Window_turn_failed

let test_agent_run_resumes_settled_closed_turn
      ?(persisted_completion = Tool_contract.Continue_after_success)
      ?(resume_tool_present = true)
      ?(expect_terminal = false)
      ~window
      ()
  =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun runtime_sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    match Agent.create_execution_runtime ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  let internal_runtime =
    match Internal_runtime.create ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error)
  in
  let codec = Internal_codec.of_runtime internal_runtime in
  let native_path = Filename.temp_file "oas-agent-settled-" ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
  Fun.protect
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
    (fun () ->
       Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
       let config =
         { (Types.default_config ~model:"test-model") with
           name = "durable-agent-settled-test"
         }
       in
       let tool_input = `Assoc [ "value", `Int 7 ] in
       let tool_use_id = "settled-tool-use" in
       let persisted_response =
         durable_tool_response
           ~id:"persisted-terminal-response-id"
           ~model:"persisted-provider-model"
           ~usage:
             (Some
                { Types.input_tokens = 17
                ; output_tokens = 23
                ; cache_creation_input_tokens = 5
                ; cache_read_input_tokens = 7
                ; cost_usd = Some 0.125
                })
           [ tool_use_id, "durable_tool", tool_input ]
       in
       let schedule : Tool_contract.schedule =
         { planned_index = 0
         ; batch_index = 0
         ; batch_size = 1
         ; execution_mode = Tool_contract.Serial
         }
       in
       let locator_json = ref None in
       let provider_config =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~model_id:"test-model"
           ~base_url:"http://resume.invalid"
           ~api_key:""
           ~request_path:"/v1/chat/completions"
           ()
       in
       let binding =
         match
           Internal_binding.of_provider_config
             ~transport:Internal_binding.Injected
             provider_config
         with
         | Ok binding -> binding
         | Error detail -> Alcotest.fail detail
       in
       (* Build the durable journal to the exact crash-window topology: a settled
          tool invocation whose provider (and, for [Window_turn_closed], turn) is
          Closed Succeeded, with the run root deliberately left Running (no
          [finish]). *)
       (match
          Internal_writer.run ~codec ~dir (fun ~sw:_ writer ->
            let scope =
              match
                Internal_scope.start ~writer ~agent_name:"durable-agent-settled-test"
              with
              | Ok scope -> scope
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            locator_json
            := Some
                 (Internal_scope.scope_locator_to_yojson
                    (Internal_scope.scope_locator scope));
            let turn =
              match Internal_scope.open_turn scope ~ordinal:0 with
              | Ok turn -> turn
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            let provider =
              match Internal_scope.open_provider_attempt turn ~ordinal:0 binding with
              | Ok provider -> provider
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            record_durable_provider_response provider persisted_response;
            let invocation =
              Tool_contract.Invocation.create
                ~tool_use_id
                ~turn:0
                ~schedule
                ~completion:persisted_completion
            in
            let durable =
              match
                Internal_scope.open_invocation
                  provider
                  ~invocation
                  ~tool_name:"durable_tool"
                  ~input:tool_input
              with
              | Ok durable -> durable
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            (match
               Internal_scope.execute
                 durable
                 ~invoke:(fun ~start_child:_ ~tool_name:_ ~input:_ ->
                   "settled-before-restart", Types.Tool_succeeded)
             with
             | Ok (Internal_scope.Executed _) -> ()
             | Ok (Internal_scope.Replayed _) ->
               Alcotest.fail "fixture unexpectedly replayed its first tool effect"
             | Error error -> Alcotest.fail (Internal_scope.error_to_string error));
            (match
               Internal_scope.close_provider_attempt
                 provider
                 Internal.Execution_event.Succeeded
             with
             | Ok () -> ()
             | Error error -> Alcotest.fail (Internal_scope.error_to_string error));
            match window with
            | Window_provider_closed -> ()
            | Window_turn_closed ->
              (match
                 Internal_scope.close_turn turn Internal.Execution_event.Succeeded
               with
               | Ok () -> ()
               | Error error -> Alcotest.fail (Internal_scope.error_to_string error))
            | Window_turn_failed ->
              (match
                 Internal_scope.close_turn
                   turn
                   (Internal.Execution_event.Failed
                      { kind = Internal.Execution_event.Internal_failure
                      ; detail = "injected settled-turn failure"
                      ; data = None
                      })
               with
               | Ok () -> ()
               | Error error -> Alcotest.fail (Internal_scope.error_to_string error)))
        with
        | Ok () -> ()
        | Error failure -> Alcotest.fail (Internal_writer.scope_failure_to_string failure));
       let locator =
         match Option.get !locator_json |> Agent.execution_locator_of_yojson with
         | Ok locator -> locator
         | Error detail -> Alcotest.fail detail
       in
       let response = Provider_mock.text_response "done-after-restart" [] in
       let provider_call_count = ref 0 in
       let transport : Llm_provider.Llm_transport.t =
         { complete_sync =
             (fun _request ->
               incr provider_call_count;
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream =
             (fun ?on_telemetry:_ ~on_event:_ _request ->
               incr provider_call_count;
               Ok response)
         }
       in
       let effect_count = ref 0 in
       let terminal_disposition = ref None in
       let tool =
         Tool.create
           ~name:"durable_tool"
           ~description:"must not rerun after restart"
           ~parameters:[]
           (fun _input ->
              incr effect_count;
              Ok { Types.content = "duplicate"; _meta = None })
       in
       let options =
         { Agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         }
       in
       let agent =
         Agent.create
           ~net:(Eio.Stdenv.net env)
           ~config
           ~tools:(if resume_tool_present then [ tool ] else [])
           ~options
           ()
       in
       (* The settled tool turn's checkpoint (After_tool_results_appended) is
          restored: the ToolUse and its recovered ToolResult are already present,
          so resume replays the settled result without re-running the effect. *)
       Agent.set_state
         agent
         { config
         ; messages =
             [ { Types.role = User
               ; content = [ Text "run the tool" ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { Types.role = Assistant
               ; content =
                   [ ToolUse
                       { id = tool_use_id; name = "durable_tool"; input = tool_input }
                   ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { Types.role = Tool
               ; content =
                   [ ToolResult
                       { tool_use_id
                       ; content = "settled-before-restart"
                       ; outcome = Types.Tool_succeeded
                       ; json = None
                       ; content_blocks = None
                       }
                   ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ]
         ; turn_count = 1
         ; usage = Types.empty_usage
         };
       let execution_store =
         Agent.execution_store
           ~runtime
           ~dir
           ~on_terminal_disposition:(fun disposition ->
             terminal_disposition := Some disposition;
             Ok ())
           ~resume:locator
           ()
       in
       (match window, Agent.run ~sw:runtime_sw ~execution_store agent "run the tool" with
        | (Window_provider_closed | Window_turn_closed), Ok response when expect_terminal
          ->
          Alcotest.(check bool)
            "persisted terminal response provenance is exact"
            true
            (response = persisted_response)
        | (Window_provider_closed | Window_turn_closed), Ok response ->
          Alcotest.(check string)
            "settled turn resumes and completes"
            "done-after-restart"
            (Types.text_of_response response)
        | (Window_provider_closed | Window_turn_closed), Error error ->
          Alcotest.failf
            "settled turn resume aborted instead of completing: %s"
            (Error.to_string error)
        | Window_turn_failed, Error _ -> ()
        | Window_turn_failed, Ok _ ->
          Alcotest.fail "closed-Failed turn must not resume as a bogus success");
       Alcotest.(check int) "settled tool handler is not rerun" 0 !effect_count;
       Alcotest.(check int)
         "provider count follows persisted completion"
         (match window with
          | Window_turn_failed -> 0
          | Window_provider_closed | Window_turn_closed ->
            if expect_terminal then 0 else 1)
         !provider_call_count;
       match window with
       | Window_provider_closed | Window_turn_closed ->
         check_terminal_disposition
           ~outcome:"succeeded"
           ~recovery:"retire"
           !terminal_disposition
       | Window_turn_failed -> ())
;;

let test_agent_run_resumes_settled_provider_closed_turn =
  test_agent_run_resumes_settled_closed_turn ~window:Window_provider_closed
;;

let test_agent_run_resumes_settled_closed_turn_boundary =
  test_agent_run_resumes_settled_closed_turn ~window:Window_turn_closed
;;

let test_agent_run_resumes_terminal_after_descriptor_drift () =
  test_agent_run_resumes_settled_closed_turn
    ~persisted_completion:
      (Tool_contract.Terminal_after_success Tool_contract.Effect_outcome_unknown)
    ~resume_tool_present:true
    ~expect_terminal:true
    ~window:Window_turn_closed
    ()
;;

let test_agent_run_resumes_terminal_after_tool_removal () =
  test_agent_run_resumes_settled_closed_turn
    ~persisted_completion:
      (Tool_contract.Terminal_after_success Tool_contract.Effect_outcome_unknown)
    ~resume_tool_present:false
    ~expect_terminal:true
    ~window:Window_turn_closed
    ()
;;

let test_terminal_durability_failure_is_typed_non_retryable () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun runtime_sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    match Internal_runtime.create ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error)
  in
  let codec = Internal_codec.of_runtime runtime in
  let native_path = Filename.temp_file "oas-terminal-durability-" ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
  Fun.protect
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
    (fun () ->
       Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
       let provider_calls = ref 0 in
       let effect_count = ref 0 in
       let tool_input = `Assoc [ "value", `Int 1 ] in
       let response =
         Provider_mock.tool_use_response ~tool_name:"terminal_tool" ~tool_input () []
       in
       let persisted_tool_use_id =
         match response.content with
         | [ Types.ToolUse { id; _ } ] -> id
         | _ -> Alcotest.fail "terminal fixture did not produce one exact ToolUse"
       in
       let transport : Llm_provider.Llm_transport.t =
         { complete_sync =
             (fun _request ->
               incr provider_calls;
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream =
             (fun ?on_telemetry:_ ~on_event:_ _request ->
               incr provider_calls;
               Ok response)
         }
       in
       let config =
         { (Types.default_config ~model:"test-model") with
           name = "terminal-durability-production-path"
         }
       in
       let options =
         { Agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         }
       in
       match
         Internal_writer.run ~codec ~dir (fun ~sw writer ->
           let scope =
             match Internal_scope.start ~writer ~agent_name:config.name with
             | Ok scope -> scope
             | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
           in
           let tool =
             Tool.create
               ~descriptor:(Tool.terminal_descriptor Tool_contract.Proven_post_effect)
               ~name:"terminal_tool"
               ~description:"closes durable writer after the effect"
               ~parameters:[]
               (fun _input ->
                  incr effect_count;
                  Internal_writer.close writer;
                  Ok { Types.content = "effect committed"; _meta = None })
           in
           let agent =
             Internal_agent.create
               ~net:(Eio.Stdenv.net env)
               ~config
               ~tools:[ tool ]
               ~options
               ()
           in
           Internal_agent.set_state
             agent
             { (Internal_agent.state agent) with
               messages = [ Types.user_msg "finish exactly once" ]
             };
           let expected_detail =
             Internal_scope.error_to_string
               (Internal_scope.Settlement_failed
                  (Internal_settlement.Receipt_admission_outcome_unknown
                     Internal_writer.Admission_closed))
           in
           (match
              Internal.Execution_context.with_agent_scope scope (fun () ->
                Internal_pipeline.run_turn ~sw ~api_strategy:Internal_pipeline.Sync agent)
            with
            | Error
                (Error.Agent
                   (Error.TerminalToolDurabilityFailed
                      { invocation; effect_disposition; detail }) as error) ->
              let schedule = Tool_contract.Invocation.schedule invocation in
              Alcotest.(check string)
                "exact invocation"
                persisted_tool_use_id
                (Tool_contract.Invocation.tool_use_id invocation);
              Alcotest.(check int)
                "exact invocation turn"
                0
                (Tool_contract.Invocation.turn invocation);
              Alcotest.(check int) "exact planned index" 0 schedule.planned_index;
              Alcotest.(check int) "exact batch index" 0 schedule.batch_index;
              Alcotest.(check int) "exact batch size" 1 schedule.batch_size;
              Alcotest.(check bool)
                "exact serial schedule"
                true
                (schedule.execution_mode = Tool_contract.Serial);
              Alcotest.(check bool)
                "exact closed effect disposition"
                true
                (Error.terminal_effect_disposition effect_disposition
                 = Tool_contract.Proven_post_effect);
              Alcotest.(check string) "exact durability detail" expected_detail detail;
              Alcotest.(check bool)
                "terminal durability failure is not retryable"
                false
                (Error.is_retryable error)
            | Error error -> Alcotest.fail ("unexpected error: " ^ Error.to_string error)
            | Ok _ -> Alcotest.fail "terminal durability failure unexpectedly succeeded");
           Alcotest.(check int) "provider called once" 1 !provider_calls;
           Alcotest.(check int) "terminal effect ran once" 1 !effect_count)
       with
       | Ok () -> ()
       | Error failure -> Alcotest.fail (Internal_writer.scope_failure_to_string failure))
;;

let test_settled_malformed_terminal_topology_does_not_finalize_turn () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun runtime_sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    match Internal_runtime.create ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error)
  in
  let codec = Internal_codec.of_runtime runtime in
  let terminal_input = `Assoc [ "value", `Int 1 ] in
  let valid_terminal_schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  let run_case label case =
    let native_path =
      Filename.temp_file ("oas-agent-malformed-terminal-" ^ label) ".dir"
    in
    Sys.remove native_path;
    let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
    Fun.protect
      ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
      (fun () ->
         Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
         let config =
           { (Types.default_config ~model:"test-model") with
             name = "durable-malformed-terminal-" ^ label
           }
         in
         let provider_config =
           Llm_provider.Provider_config.make
             ~kind:Llm_provider.Provider_config.OpenAI_compat
             ~model_id:"test-model"
             ~base_url:"http://resume.invalid"
             ~api_key:""
             ~request_path:"/v1/chat/completions"
             ()
         in
         let binding =
           match
             Internal_binding.of_provider_config
               ~transport:Internal_binding.Injected
               provider_config
           with
           | Ok binding -> binding
           | Error detail -> Alcotest.fail detail
         in
         match
           Internal_writer.run ~codec ~dir (fun ~sw writer ->
             let scope =
               match Internal_scope.start ~writer ~agent_name:config.name with
               | Ok scope -> scope
               | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
             in
             let turn =
               match Internal_scope.open_turn scope ~ordinal:0 with
               | Ok turn -> turn
               | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
             in
             let provider =
               match Internal_scope.open_provider_attempt turn ~ordinal:0 binding with
               | Ok provider -> provider
               | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
             in
             let assert_turn_open () =
               match Internal_scope.resume_current_turn scope with
               | Ok (Internal_scope.Resume_turn_open _) -> ()
               | Ok Internal_scope.Resume_turn_absent ->
                 Alcotest.failf "%s: malformed case removed its durable turn" label
               | Ok (Internal_scope.Resume_turn_settled _) ->
                 Alcotest.failf "%s: malformed case finalized its turn" label
               | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
             in
             let invocation ~tool_use_id ~schedule ~completion =
               Tool_contract.Invocation.create ~tool_use_id ~turn:0 ~schedule ~completion
             in
             let persist (tool_use_id, tool_name, input, schedule, completion) =
               let invocation = invocation ~tool_use_id ~schedule ~completion in
               let durable =
                 match
                   Internal_scope.open_invocation provider ~invocation ~tool_name ~input
                 with
                 | Ok durable -> durable
                 | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
               in
               match
                 Internal_scope.execute
                   durable
                   ~invoke:(fun ~start_child:_ ~tool_name:_ ~input:_ ->
                     tool_name ^ "-settled", Types.Tool_succeeded)
               with
               | Ok (Internal_scope.Executed _) -> ()
               | Ok (Internal_scope.Replayed _) ->
                 Alcotest.fail "fixture unexpectedly replayed a fresh invocation"
               | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
             in
             match case with
             | `Invalid_contract (schedule, completion) ->
               let invalid =
                 invocation ~tool_use_id:"terminal-call" ~schedule ~completion
               in
               (match
                  Internal_scope.open_invocation
                    provider
                    ~invocation:invalid
                    ~tool_name:"terminal_tool"
                    ~input:terminal_input
                with
                | Error
                    (Internal_scope.Mutation_failed
                       (Internal_writer.Transaction_rejected
                          (Internal.Execution_journal.Invalid_argument _))) -> ()
                | Error error ->
                  Alcotest.failf
                    "%s: wrong typed contract error: %s"
                    label
                    (Internal_scope.error_to_string error)
                | Ok _ -> Alcotest.failf "%s: invalid terminal contract persisted" label);
               assert_turn_open ()
             | `Response_mismatch settled ->
               let restored =
                 [ "restored-zero-call", "zero_invocation_tool", terminal_input ]
               in
               record_durable_provider_response
                 provider
                 (durable_tool_response
                    [ "persisted-zero-call", "zero_invocation_tool", terminal_input ]);
               if settled
               then (
                 match
                   Internal_scope.close_provider_attempt
                     provider
                     Internal.Execution_event.Succeeded
                 with
                 | Ok () -> ()
                 | Error error -> Alcotest.fail (Internal_scope.error_to_string error));
               let effect_count = ref 0 in
               let tool =
                 Tool.create
                   ~name:"zero_invocation_tool"
                   ~description:"must not execute before response topology validation"
                   ~parameters:[]
                   (fun _input ->
                      incr effect_count;
                      Ok { Types.content = "unexpected-effect"; _meta = None })
               in
               let assistant_content =
                 List.map
                   (fun (id, name, input) -> Types.ToolUse { id; name; input })
                   restored
               in
               let messages =
                 let assistant =
                   { Types.role = Assistant
                   ; content = assistant_content
                   ; name = None
                   ; tool_call_id = None
                   ; metadata = []
                   }
                 in
                 if settled
                 then
                   [ Types.user_msg "run mismatched zero-invocation authority"
                   ; assistant
                   ; { Types.role = Tool
                     ; content =
                         [ Types.ToolResult
                             { tool_use_id = "restored-zero-call"
                             ; content = "blocked before invocation admission"
                             ; outcome = Types.Tool_succeeded
                             ; json = None
                             ; content_blocks = None
                             }
                         ]
                     ; name = None
                     ; tool_call_id = None
                     ; metadata = []
                     }
                   ]
                 else
                   [ Types.user_msg "run mismatched zero-invocation authority"
                   ; assistant
                   ]
               in
               let options =
                 { Agent.default_options with
                   provider_config = Some (Provider_mock.to_provider_config ())
                 }
               in
               let agent =
                 Internal_agent.create
                   ~net:(Eio.Stdenv.net env)
                   ~config
                   ~tools:[ tool ]
                   ~options
                   ()
               in
               Internal_agent.set_state
                 agent
                 { config; messages; turn_count = 1; usage = Types.empty_usage };
               let outcome =
                 Internal.Execution_context.with_agent_scope scope (fun () ->
                   Internal.Execution_context.with_resume_once (fun () ->
                     Internal_pipeline.run_turn
                       ~sw
                       ~api_strategy:Internal_pipeline.Sync
                       agent))
               in
               Alcotest.(check int)
                 (label ^ ": mismatch executes no tool effect")
                 0
                 !effect_count;
               assert_turn_open ();
               (match outcome with
                | Error (Error.Internal _) -> ()
                | Error error ->
                  Alcotest.failf
                    "%s: wrong typed response mismatch error: %s"
                    label
                    (Error.to_string error)
                | Ok _ ->
                  Alcotest.failf "%s: mismatched response topology was accepted" label)
             | `Resume (turn_count, persisted, restored) ->
               record_durable_provider_response provider (durable_tool_response restored);
               List.iter persist persisted;
               (match
                  Internal_scope.close_provider_attempt
                    provider
                    Internal.Execution_event.Succeeded
                with
                | Ok () -> ()
                | Error error -> Alcotest.fail (Internal_scope.error_to_string error));
               let assistant_content =
                 List.map
                   (fun (id, name, input) -> Types.ToolUse { id; name; input })
                   restored
               in
               let result_content =
                 List.map
                   (fun (tool_use_id, name, _input) ->
                      Types.ToolResult
                        { tool_use_id
                        ; content = name ^ "-settled"
                        ; outcome = Types.Tool_succeeded
                        ; json = None
                        ; content_blocks = None
                        })
                   restored
               in
               let options =
                 { Agent.default_options with
                   provider_config = Some (Provider_mock.to_provider_config ())
                 }
               in
               let agent =
                 Internal_agent.create
                   ~net:(Eio.Stdenv.net env)
                   ~config
                   ~tools:[]
                   ~options
                   ()
               in
               Internal_agent.set_state
                 agent
                 { config
                 ; messages =
                     [ Types.user_msg "run malformed authority"
                     ; { Types.role = Assistant
                       ; content = assistant_content
                       ; name = None
                       ; tool_call_id = None
                       ; metadata = []
                       }
                     ; { Types.role = Tool
                       ; content = result_content
                       ; name = None
                       ; tool_call_id = None
                       ; metadata = []
                       }
                     ]
                 ; turn_count
                 ; usage = Types.empty_usage
                 };
               (match
                  Internal.Execution_context.with_agent_scope scope (fun () ->
                    Internal.Execution_context.with_resume_once (fun () ->
                      Internal_pipeline.run_turn
                        ~sw
                        ~api_strategy:Internal_pipeline.Sync
                        agent))
                with
                | Error (Error.Internal _) -> ()
                | Error error ->
                  Alcotest.failf
                    "%s: wrong typed resume error: %s"
                    label
                    (Error.to_string error)
                | Ok _ ->
                  Alcotest.failf "%s: malformed persisted topology was accepted" label);
               assert_turn_open ())
         with
         | Ok () -> ()
         | Error failure ->
           Alcotest.fail (Internal_writer.scope_failure_to_string failure))
  in
  let terminal_completion =
    Tool_contract.Terminal_after_success Tool_contract.Effect_outcome_unknown
  in
  let terminal_persisted =
    [ ( "terminal-call"
      , "terminal_tool"
      , terminal_input
      , valid_terminal_schedule
      , terminal_completion )
    ]
  in
  let terminal_restored = [ "terminal-call", "terminal_tool", terminal_input ] in
  let resume ?(turn_count = 1) ?(persisted = terminal_persisted) restored =
    `Resume (turn_count, persisted, restored)
  in
  let serial_schedule planned_index : Tool_contract.schedule =
    { planned_index
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  run_case
    "id-drift"
    (resume [ "drifted-terminal-call", "terminal_tool", terminal_input ]);
  let first = "first-call", "first_tool", `Assoc [ "ordinal", `Int 0 ] in
  let second = "second-call", "second_tool", `Assoc [ "ordinal", `Int 1 ] in
  let ordered_persisted =
    [ ( "first-call"
      , "first_tool"
      , `Assoc [ "ordinal", `Int 0 ]
      , serial_schedule 0
      , Tool_contract.Continue_after_success )
    ; ( "second-call"
      , "second_tool"
      , `Assoc [ "ordinal", `Int 1 ]
      , serial_schedule 1
      , Tool_contract.Continue_after_success )
    ]
  in
  run_case "order-drift" (resume ~persisted:ordered_persisted [ second; first ]);
  run_case "turn-drift" (resume ~turn_count:2 terminal_restored);
  run_case
    "name-drift"
    (resume [ "terminal-call", "renamed_terminal_tool", terminal_input ]);
  run_case
    "input-drift"
    (resume [ "terminal-call", "terminal_tool", `Assoc [ "value", `Int 2 ] ]);
  run_case "active-zero-invocation-response-drift" (`Response_mismatch false);
  run_case "settled-zero-invocation-response-drift" (`Response_mismatch true);
  let planned_index_persisted =
    [ ( "ordinary-call"
      , "ordinary_tool"
      , terminal_input
      , serial_schedule 1
      , Tool_contract.Continue_after_success )
    ]
  in
  run_case
    "planned-index-drift"
    (resume
       ~persisted:planned_index_persisted
       [ "ordinary-call", "ordinary_tool", terminal_input ]);
  run_case
    "schedule-planned-index-drift"
    (`Invalid_contract
        ( { valid_terminal_schedule with planned_index = 1 }
        , Tool_contract.Terminal_after_success Tool_contract.Effect_outcome_unknown ));
  run_case
    "schedule-batch-index-drift"
    (`Invalid_contract
        ( { valid_terminal_schedule with batch_index = 1 }
        , Tool_contract.Terminal_after_success Tool_contract.Effect_outcome_unknown ));
  run_case
    "schedule-batch-size-drift"
    (`Invalid_contract
        ( { valid_terminal_schedule with batch_size = 2 }
        , Tool_contract.Terminal_after_success Tool_contract.Effect_outcome_unknown ));
  run_case
    "schedule-execution-mode-drift"
    (`Invalid_contract
        ( { valid_terminal_schedule with execution_mode = Tool_contract.Concurrent }
        , Tool_contract.Terminal_after_success Tool_contract.Effect_outcome_unknown ))
;;

let test_agent_run_replays_precheckpoint_terminal_settlement () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun runtime_sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    match Agent.create_execution_runtime ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  let internal_runtime =
    match Internal_runtime.create ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error)
  in
  let codec = Internal_codec.of_runtime internal_runtime in
  let run_case label resume_mode =
    let native_path = Filename.temp_file ("oas-agent-precheckpoint-" ^ label) ".dir" in
    Sys.remove native_path;
    let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
    Fun.protect
      ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
      (fun () ->
         Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
         let config =
           { (Types.default_config ~model:"test-model") with
             name = "durable-agent-precheckpoint-" ^ label
           }
         in
         let tool_input = `Assoc [ "value", `Int 7 ] in
         let response =
           Provider_mock.tool_use_response ~tool_name:"durable_tool" ~tool_input () []
         in
         let provider_calls = ref 0 in
         let transport : Llm_provider.Llm_transport.t =
           let next_response () =
             incr provider_calls;
             if !provider_calls = 1
             then response
             else Provider_mock.text_response "unexpected-provider-resume" []
           in
           { complete_sync =
               (fun _request ->
                 { Llm_provider.Llm_transport.response = Ok (next_response ())
                 ; latency_ms = Some 0
                 })
           ; complete_stream =
               (fun ?on_telemetry:_ ~on_event:_ _request -> Ok (next_response ()))
           }
         in
         let options =
           { Agent.default_options with
             transport = Some transport
           ; provider_config = Some (Provider_mock.to_provider_config ())
           }
         in
         let effect_count = ref 0 in
         let initial_tool =
           Tool.create
             ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
             ~name:"durable_tool"
             ~description:"settles before the Agent checkpoint"
             ~parameters:[]
             (fun _ ->
                incr effect_count;
                Ok { Types.content = "settled-before-checkpoint"; _meta = None })
         in
         let saved_checkpoint = ref None in
         let initial_agent =
           Internal_agent.create
             ~net:(Eio.Stdenv.net env)
             ~config
             ~tools:[ initial_tool ]
             ~options
             ~checkpoint_sink:(fun snapshot ->
               match snapshot.Agent.stage with
               | Agent.After_assistant_collected ->
                 saved_checkpoint := Some snapshot.checkpoint;
                 Ok ()
               | Agent.After_tool_results_appended ->
                 Error "simulated crash before Agent tool-result checkpoint"
               | Agent.After_context_injection ->
                 Alcotest.fail "fixture unexpectedly reached context injection")
             ()
         in
         Internal_agent.set_state
           initial_agent
           { (Internal_agent.state initial_agent) with
             messages = [ Types.user_msg "run the durable tool" ]
           };
         let locator_json = ref None in
         (match
            Internal_writer.run ~codec ~dir (fun ~sw writer ->
              let scope =
                match Internal_scope.start ~writer ~agent_name:config.name with
                | Ok scope -> scope
                | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
              in
              locator_json
              := Some
                   (Internal_scope.scope_locator_to_yojson
                      (Internal_scope.scope_locator scope));
              match
                Internal.Execution_context.with_agent_scope scope (fun () ->
                  Internal_pipeline.run_turn
                    ~sw
                    ~api_strategy:Internal_pipeline.Sync
                    initial_agent)
              with
              | Error _ -> ()
              | Ok _ ->
                Alcotest.fail
                  "simulated crash boundary completed instead of rejecting its checkpoint")
          with
          | Ok () -> ()
          | Error failure ->
            Alcotest.fail (Internal_writer.scope_failure_to_string failure));
         Alcotest.(check int) "initial provider call" 1 !provider_calls;
         Alcotest.(check int) "initial effect settled once" 1 !effect_count;
         let checkpoint =
           match !saved_checkpoint with
           | Some checkpoint -> checkpoint
           | None -> Alcotest.fail "assistant checkpoint was not captured"
         in
         let locator =
           match Option.get !locator_json |> Agent.execution_locator_of_yojson with
           | Ok locator -> locator
           | Error detail -> Alcotest.fail detail
         in
         let resumed_handler_count = ref 0 in
         let resumed_tools =
           match resume_mode with
           | `Removed -> []
           | `Drifted ->
             [ Tool.create
                 ~descriptor:(Tool.ordinary_descriptor Tool_contract.Concurrent)
                 ~name:"durable_tool"
                 ~description:"current descriptor must not control resume"
                 ~parameters:[]
                 (fun _ ->
                    incr resumed_handler_count;
                    Ok { Types.content = "duplicate"; _meta = None })
             ]
         in
         let resumed_agent =
           Agent.resume
             ~net:(Eio.Stdenv.net env)
             ~checkpoint
             ~tools:resumed_tools
             ~options
             ~config
             ()
         in
         let execution_store = Agent.execution_store ~runtime ~dir ~resume:locator () in
         (match
            Agent.run ~sw:runtime_sw ~execution_store resumed_agent "run the durable tool"
          with
          | Error error ->
            Alcotest.failf
              "%s resume ignored persisted settlement authority: %s"
              label
              (Error.to_string error)
          | Ok response ->
            Alcotest.(check bool)
              (label ^ " retains persisted terminal completion")
              true
              (response.stop_reason = Types.StopToolUse));
         Alcotest.(check int) (label ^ " total provider calls") 1 !provider_calls;
         Alcotest.(check int)
           (label ^ " current handler never runs")
           0
           !resumed_handler_count)
  in
  run_case "removed" `Removed;
  run_case "drifted" `Drifted
;;

let test_agent_run_rejects_settled_failed_turn =
  test_agent_run_resumes_settled_closed_turn ~window:Window_turn_failed
;;

(* Regression for #2713 follow-up (Site 2, all-blocked vacuous-truth): a resumed
   turn whose ToolUses were all PreToolUse-blocked has its blocked ToolResults in
   the restored checkpoint but ZERO durable Tool_invocation nodes — a blocked call
   emits a model-visible ToolResult but never reaches [open_invocation] (that is
   Continue-only in agent_tools.ml). The journal turn and provider are still Open
   (the run crashed with results collected but the scope not yet closed), so
   resume takes the Active path, asserts result_ids == expected_ids, then checks
   journal settlement. An empty invocation set must count as fully-settled
   (vacuous truth), not "settlement incomplete"; otherwise the root is aborted
   Failed and the run becomes un-resumable. Reverting [provider_invocations_settled]'s
   empty arm to [Ok false] makes this go red (resume Error -> root Failed). *)
let test_agent_run_resumes_all_blocked_settled_turn () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun runtime_sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    match Agent.create_execution_runtime ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  let internal_runtime =
    match Internal_runtime.create ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error)
  in
  let codec = Internal_codec.of_runtime internal_runtime in
  let native_path = Filename.temp_file "oas-agent-all-blocked-" ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
  Fun.protect
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
    (fun () ->
       Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
       let config =
         { (Types.default_config ~model:"test-model") with
           name = "durable-agent-all-blocked-test"
         }
       in
       let tool_input = `Assoc [ "value", `Int 7 ] in
       let tool_use_id = "all-blocked-tool-use" in
       let locator_json = ref None in
       let provider_config =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~model_id:"test-model"
           ~base_url:"http://resume.invalid"
           ~api_key:""
           ~request_path:"/v1/chat/completions"
           ()
       in
       let binding =
         match
           Internal_binding.of_provider_config
             ~transport:Internal_binding.Injected
             provider_config
         with
         | Ok binding -> binding
         | Error detail -> Alcotest.fail detail
       in
       (* Build the durable journal to the all-blocked crash topology: an Open turn
          with an Open provider attempt and NO invocation node, the run root left
          Running (no [finish]). *)
       (match
          Internal_writer.run ~codec ~dir (fun ~sw:_ writer ->
            let scope =
              match
                Internal_scope.start ~writer ~agent_name:"durable-agent-all-blocked-test"
              with
              | Ok scope -> scope
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            locator_json
            := Some
                 (Internal_scope.scope_locator_to_yojson
                    (Internal_scope.scope_locator scope));
            let turn =
              match Internal_scope.open_turn scope ~ordinal:0 with
              | Ok turn -> turn
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            match Internal_scope.open_provider_attempt turn ~ordinal:0 binding with
            | Ok provider ->
              record_durable_provider_response
                provider
                (durable_tool_response [ tool_use_id, "durable_tool", tool_input ])
            | Error error -> Alcotest.fail (Internal_scope.error_to_string error))
        with
        | Ok () -> ()
        | Error failure -> Alcotest.fail (Internal_writer.scope_failure_to_string failure));
       let locator =
         match Option.get !locator_json |> Agent.execution_locator_of_yojson with
         | Ok locator -> locator
         | Error detail -> Alcotest.fail detail
       in
       let response = Provider_mock.text_response "done-after-restart" [] in
       let transport : Llm_provider.Llm_transport.t =
         { complete_sync =
             (fun _request ->
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
         }
       in
       let effect_count = ref 0 in
       let terminal_disposition = ref None in
       let tool =
         Tool.create
           ~name:"durable_tool"
           ~description:"must not rerun after restart"
           ~parameters:[]
           (fun _input ->
              incr effect_count;
              Ok { Types.content = "duplicate"; _meta = None })
       in
       let options =
         { Agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         }
       in
       let agent =
         Agent.create ~net:(Eio.Stdenv.net env) ~config ~tools:[ tool ] ~options ()
       in
       (* Restored checkpoint: the blocked ToolResult is present (a blocked call
          still emits a model-visible ToolResult) even though no Tool_invocation
          node exists. Only the tool_use_id drives the resume classification. *)
       Agent.set_state
         agent
         { config
         ; messages =
             [ { Types.role = User
               ; content = [ Text "run the tool" ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { Types.role = Assistant
               ; content =
                   [ ToolUse
                       { id = tool_use_id; name = "durable_tool"; input = tool_input }
                   ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { Types.role = Tool
               ; content =
                   [ ToolResult
                       { tool_use_id
                       ; content = "blocked by pre_tool_use hook"
                       ; outcome =
                           Tool_failed
                             { failure_kind = Non_retryable_tool_error
                             ; error_class = Some Deterministic
                             }
                       ; json = None
                       ; content_blocks = None
                       }
                   ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ]
         ; turn_count = 1
         ; usage = Types.empty_usage
         };
       let execution_store =
         Agent.execution_store
           ~runtime
           ~dir
           ~on_terminal_disposition:(fun disposition ->
             terminal_disposition := Some disposition;
             Ok ())
           ~resume:locator
           ()
       in
       (match Agent.run ~sw:runtime_sw ~execution_store agent "run the tool" with
        | Ok response ->
          Alcotest.(check string)
            "all-blocked settled turn resumes and completes"
            "done-after-restart"
            (Types.text_of_response response)
        | Error error ->
          Alcotest.failf
            "all-blocked settled turn resume aborted instead of completing: %s"
            (Error.to_string error));
       Alcotest.(check int) "blocked turn runs no tool effect on resume" 0 !effect_count;
       check_terminal_disposition
         ~outcome:"succeeded"
         ~recovery:"retire"
         !terminal_disposition)
;;

(* Regression for #2713 follow-up (Site 1, on_yield parity): with [yield_on_tool]
   and a durable execution_store, a crash after the ToolUse was collected but
   before any ToolResults were produced leaves the turn/provider Open with no
   invocation node. Resume re-executes the tools through the resume [~execute]
   closure, which must thread [before_tool_execution] (the provider-lease
   [on_yield] release) exactly as the fresh path threads it into [run_new_turn].
   Otherwise [on_yield] never fires on the resume turn while the lease still
   advances Held->Released and re-acquires next turn, leaving an acquire with no
   matching release. Reverting the resume [~execute] closure to drop
   [?before_tool_execution] makes this go red ([yield_count] stays 0). *)
let test_agent_run_resume_fires_on_yield () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun runtime_sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    match Agent.create_execution_runtime ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  let internal_runtime =
    match Internal_runtime.create ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error)
  in
  let codec = Internal_codec.of_runtime internal_runtime in
  let native_path = Filename.temp_file "oas-agent-resume-yield-" ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
  Fun.protect
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
    (fun () ->
       Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
       let config =
         { (Types.default_config ~model:"test-model") with
           name = "durable-agent-resume-yield-test"
         ; yield_on_tool = true
         }
       in
       let tool_input = `Assoc [ "value", `Int 7 ] in
       let tool_use_id = "resume-yield-tool-use" in
       let locator_json = ref None in
       let provider_config =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~model_id:"test-model"
           ~base_url:"http://resume.invalid"
           ~api_key:""
           ~request_path:"/v1/chat/completions"
           ()
       in
       let binding =
         match
           Internal_binding.of_provider_config
             ~transport:Internal_binding.Injected
             provider_config
         with
         | Ok binding -> binding
         | Error detail -> Alcotest.fail detail
       in
       (* Build the durable journal to the pre-execution crash topology: an Open
          turn with an Open provider attempt, no invocation node and no results,
          the run root left Running. *)
       (match
          Internal_writer.run ~codec ~dir (fun ~sw:_ writer ->
            let scope =
              match
                Internal_scope.start ~writer ~agent_name:"durable-agent-resume-yield-test"
              with
              | Ok scope -> scope
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            locator_json
            := Some
                 (Internal_scope.scope_locator_to_yojson
                    (Internal_scope.scope_locator scope));
            let turn =
              match Internal_scope.open_turn scope ~ordinal:0 with
              | Ok turn -> turn
              | Error error -> Alcotest.fail (Internal_scope.error_to_string error)
            in
            match Internal_scope.open_provider_attempt turn ~ordinal:0 binding with
            | Ok provider ->
              record_durable_provider_response
                provider
                (durable_tool_response [ tool_use_id, "durable_tool", tool_input ])
            | Error error -> Alcotest.fail (Internal_scope.error_to_string error))
        with
        | Ok () -> ()
        | Error failure -> Alcotest.fail (Internal_writer.scope_failure_to_string failure));
       let locator =
         match Option.get !locator_json |> Agent.execution_locator_of_yojson with
         | Ok locator -> locator
         | Error detail -> Alcotest.fail detail
       in
       let response = Provider_mock.text_response "done-after-restart" [] in
       let transport : Llm_provider.Llm_transport.t =
         { complete_sync =
             (fun _request ->
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
         }
       in
       let effect_count = ref 0 in
       let yield_count = ref 0 in
       let resume_count = ref 0 in
       let tool =
         Tool.create
           ~name:"durable_tool"
           ~description:"executes once on resume"
           ~parameters:[]
           (fun _input ->
              incr effect_count;
              Ok { Types.content = "executed"; _meta = None })
       in
       let options =
         { Agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         }
       in
       let agent =
         Agent.create ~net:(Eio.Stdenv.net env) ~config ~tools:[ tool ] ~options ()
       in
       (* Restored checkpoint: the ToolUse is collected, but no ToolResults exist
          yet, so resume re-executes the tools and must fire [on_yield] before the
          first tool implementation runs. *)
       Agent.set_state
         agent
         { config
         ; messages =
             [ { Types.role = User
               ; content = [ Text "run the tool" ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { Types.role = Assistant
               ; content =
                   [ ToolUse
                       { id = tool_use_id; name = "durable_tool"; input = tool_input }
                   ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ]
         ; turn_count = 1
         ; usage = Types.empty_usage
         };
       let execution_store = Agent.execution_store ~runtime ~dir ~resume:locator () in
       (match
          Agent.run
            ~sw:runtime_sw
            ~on_yield:(fun () -> incr yield_count)
            ~on_resume:(fun () -> incr resume_count)
            ~execution_store
            agent
            "run the tool"
        with
        | Ok response ->
          Alcotest.(check string)
            "resume completes"
            "done-after-restart"
            (Types.text_of_response response)
        | Error error -> Alcotest.failf "resume run failed: %s" (Error.to_string error));
       Alcotest.(check int) "tool executes once on resume" 1 !effect_count;
       Alcotest.(check int)
         "on_yield fires on the resume turn (fresh/resume parity)"
         1
         !yield_count)
;;

(* ── Runner ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Pipeline"
    [ ( "mock_responses"
      , [ Alcotest.test_case "text response" `Quick test_mock_text_response
        ; Alcotest.test_case "tool use response" `Quick test_mock_tool_use_response
        ; Alcotest.test_case "tool then text" `Quick test_mock_tool_then_text_sequence
        ; Alcotest.test_case "reset" `Quick test_mock_reset
        ; Alcotest.test_case "cycle wraps" `Quick test_mock_cycle_wraps
        ; Alcotest.test_case "empty responses" `Quick test_mock_empty_responses
        ; Alcotest.test_case "thinking response" `Quick test_mock_thinking_response
        ; Alcotest.test_case "to_provider_config" `Quick test_mock_to_provider_config
        ] )
    ; ( "agent_state"
      , [ Alcotest.test_case "initial state" `Quick test_agent_initial_state
        ; Alcotest.test_case "tools registered" `Quick test_agent_tools_registered
        ; Alcotest.test_case "initial usage" `Quick test_agent_initial_usage
        ; Alcotest.test_case "empty tools" `Quick test_agent_empty_tools
        ; Alcotest.test_case "multiple tools" `Quick test_agent_multiple_tools
        ] )
    ; ( "turn_mechanics"
      , [ Alcotest.test_case "turn preparation" `Quick test_agent_turn_preparation
        ; Alcotest.test_case "no tools prep" `Quick test_prepare_turn_no_tools
        ; Alcotest.test_case
            "preserves messages"
            `Quick
            test_prepare_turn_preserves_messages
        ; Alcotest.test_case
            "output completes on end turn"
            `Quick
            test_pipeline_output_completes_on_end_turn
        ; Alcotest.test_case
            "provider receives exact supplied tools"
            `Quick
            test_pipeline_sends_exact_supplied_tools
        ; Alcotest.test_case
            "effective provider config drives lifecycle and pricing"
            `Quick
            test_effective_provider_config_drives_lifecycle_and_pricing
        ; Alcotest.test_case
            "provider turn identity spans multiturn tool loop"
            `Quick
            test_provider_turn_identity_is_shared_across_multiturn_tool_loop
        ; Alcotest.test_case
            "output rejects unknown terminal"
            `Quick
            test_pipeline_output_rejects_unknown_terminal
        ; Alcotest.test_case
            "output completes repetition truncation"
            `Quick
            test_pipeline_output_completes_repetition_truncation
        ; Alcotest.test_case
            "output rejects tool stop without block"
            `Quick
            test_pipeline_output_rejects_tool_stop_without_block
        ; Alcotest.test_case
            "text tool intent remains text"
            `Quick
            test_pipeline_text_tool_intent_remains_text
        ; Alcotest.test_case
            "repeated validation error without judge continues"
            `Quick
            test_repeated_validation_error_without_judge_continues_to_provider
        ; Alcotest.test_case
            "stream route carries exact raw trace run id"
            `Quick
            test_stream_route_carries_exact_raw_trace_run_id
        ; Alcotest.test_case "extra system context" `Quick test_prepare_turn_extra_context
        ] )
    ; ( "tool_results"
      , [ Alcotest.test_case "make ok" `Quick test_make_tool_results_ok
        ; Alcotest.test_case "make error" `Quick test_make_tool_results_error
        ; Alcotest.test_case "make mixed" `Quick test_make_tool_results_mixed
        ] )
    ; ( "accumulate_usage"
      , [ Alcotest.test_case "with response" `Quick test_accumulate_usage_with_response
        ; Alcotest.test_case "no response" `Quick test_accumulate_usage_no_response
        ; Alcotest.test_case "cumulative" `Quick test_accumulate_usage_cumulative
        ] )
    ; ( "error_domain"
      , [ Alcotest.test_case "of_sdk_error" `Quick test_error_domain_of_sdk_error
        ; Alcotest.test_case "roundtrip" `Quick test_error_domain_roundtrip
        ; Alcotest.test_case "with_stage" `Quick test_error_domain_with_stage
        ; Alcotest.test_case "is_retryable" `Quick test_error_domain_is_retryable
        ; Alcotest.test_case "provider errors" `Quick test_error_domain_provider_errors
        ; Alcotest.test_case
            "durable event: persistence not Api"
            `Quick
            test_error_domain_of_persistence_not_api
        ] )
    ; ( "provider_mock_extra"
      , [ Alcotest.test_case "multi tool response" `Quick test_mock_multi_tool_response
        ; Alcotest.test_case
            "Agent.run uses durable tool authority"
            `Quick
            test_agent_run_uses_durable_tool_authority
        ; Alcotest.test_case
            "Agent.run resumes settled tool without duplicate effects"
            `Quick
            test_agent_run_resumes_settled_tool_without_duplicate_effects
        ; Alcotest.test_case
            "unattempted legacy invocation requires typed readmission"
            `Quick
            test_unattempted_legacy_invocation_requires_typed_readmission
        ; Alcotest.test_case
            "Agent.run resume matches original prompt not injected User message"
            `Quick
            test_agent_run_resume_ignores_injected_user_context_message
        ; Alcotest.test_case
            "Agent.run resume rejects mismatched prompt (fail-closed)"
            `Quick
            test_agent_run_resume_rejects_mismatched_prompt
        ; Alcotest.test_case
            "Agent.run resumes settled turn after provider-close crash (#2683)"
            `Quick
            test_agent_run_resumes_settled_provider_closed_turn
        ; Alcotest.test_case
            "Agent.run resumes settled turn after turn-close crash (#2683)"
            `Quick
            test_agent_run_resumes_settled_closed_turn_boundary
        ; Alcotest.test_case
            "terminal resume ignores current descriptor drift"
            `Quick
            test_agent_run_resumes_terminal_after_descriptor_drift
        ; Alcotest.test_case
            "terminal resume survives current tool removal"
            `Quick
            test_agent_run_resumes_terminal_after_tool_removal
        ; Alcotest.test_case
            "malformed terminal resume does not finalize its turn"
            `Quick
            test_settled_malformed_terminal_topology_does_not_finalize_turn
        ; Alcotest.test_case
            "terminal durability failure is typed and non-retryable"
            `Quick
            test_terminal_durability_failure_is_typed_non_retryable
        ; Alcotest.test_case
            "terminal pre-checkpoint settlement survives removal and drift"
            `Quick
            test_agent_run_replays_precheckpoint_terminal_settlement
        ; Alcotest.test_case
            "Agent.run rejects a closed-Failed turn on resume (#2683)"
            `Quick
            test_agent_run_rejects_settled_failed_turn
        ; Alcotest.test_case
            "Agent.run resumes an all-blocked settled turn (#2713 Site 2)"
            `Quick
            test_agent_run_resumes_all_blocked_settled_turn
        ; Alcotest.test_case
            "Agent.run fires on_yield on the resume turn (#2713 Site 1)"
            `Quick
            test_agent_run_resume_fires_on_yield
        ; Alcotest.test_case
            "terminal disposition retires settled provider failure"
            `Quick
            test_terminal_disposition_retires_settled_provider_failure
        ; Alcotest.test_case
            "terminal disposition requires operator repair for unknown effect"
            `Quick
            test_agent_run_reports_unknown_effect_for_operator_repair
        ; Alcotest.test_case
            "terminal disposition sink failure fails call"
            `Quick
            test_terminal_disposition_sink_failure_fails_call
        ; Alcotest.test_case
            "terminal disposition observes cancellation"
            `Quick
            test_terminal_disposition_observes_cancellation
        ] )
    ]
;;
