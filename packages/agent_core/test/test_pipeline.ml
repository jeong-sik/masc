(** Pipeline tests — verify the pipeline's type contracts and
    the agent's behavior through mock provider (unit-level).
    Pipeline is internal, so we test correctness through
    Provider_mock.next_response and agent state inspection. *)

open Agent_core
module Internal = Agent_core__
module Internal_agent = Agent_core__Agent_types
module Internal_pipeline = Agent_core__Pipeline
module Internal_runtime = Internal.Execution_runtime
module Internal_codec = Internal.Execution_codec_executor
module Internal_writer = Internal.Execution_lane_writer
module Internal_scope = Internal.Execution_agent_scope
module Internal_binding = Binding_identity
module Internal_settlement = Internal.Execution_tool_settlement

(* Direct pipeline fixtures enter the same boundary as Agent: resolve once
   inside the caller's execution/resume context, then dispatch that frontier.
   Keep resolution errors as results so malformed-resume tests observe them. *)
let run_pipeline_turn ~sw ~api_strategy ?raw_trace_run agent =
  match Internal_pipeline.resolve_turn_frontier agent with
  | Error error -> Error error
  | Ok frontier ->
    Internal_pipeline.run_turn ~sw ~api_strategy ?raw_trace_run ~frontier agent
;;

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
          | Llm_provider.Types.Text s -> Some s
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
          | Llm_provider.Types.ToolUse { name; _ } -> Some name
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
           | Llm_provider.Types.Text s -> Some s
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
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
      Ok { Types.content = "ok"; content_blocks = None; _meta = None })
  in
  let agent =
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
          Ok { Types.content = "a"; content_blocks = None; _meta = None })
      ; Tool.create ~name:"b" ~description:"tool b" ~parameters:[] (fun _ ->
          Ok { Types.content = "b"; content_blocks = None; _meta = None })
      ]
  in
  let messages =
    [ { origin = Llm_provider.Types.Conversation;  Types.role = User
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let prep =
    Agent_turn.prepare_turn ~media_store:(Agent_core.History.Memory_store.create ()) ~tools ~messages ~turn_params:Hooks.default_turn_params ()
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
  ; unreadable_tool_uses = []
  ; stop_reason
  ; content = [ Text "done" ]
  ; usage = None
  ; telemetry
  }
;;

let transport_returning response =
  Llm_provider.Llm_transport.custom ({ Llm_provider.Llm_transport.complete_sync =
      (fun _req ->
        { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _req -> Ok response)
  })
;;

let test_provider_context_retention () =
  List.iter (fun (kind, next_kind, signed, retained, duplicate_context) ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let captured = ref [] in
  let response = pipeline_response Types.EndTurn in
  let capture (request : Llm_provider.Llm_transport.completion_request) =
    captured := request.messages :: !captured;
    if signed then (
      let source = Llm_provider.Reasoning_dialect.reasoning_source_for_provider_config
          request.config |> Result.get_ok in
      Ok { response with
        content = [Llm_provider.Types.Thinking {signature = Some "fixture-signature"; content = "fixture"};
                   Llm_provider.Types.Text "done"];
        telemetry = Some {Types.default_inference_telemetry with reasoning_source = Some source} })
    else Ok response
  in
  let transport =
    Llm_provider.Llm_transport.custom ({ Llm_provider.Llm_transport.complete_sync = (fun request ->
        { Llm_provider.Llm_transport.response = capture request; latency_ms = Some 0 });
      complete_stream = (fun ?on_telemetry:_ ~on_event:_ request -> capture request) })
  in
  let hooks =
    { Hooks.empty with before_turn_params = Some (function
        | Hooks.BeforeTurnParams { turn = 0; current_params; _ } ->
          Hooks.AdjustParams
            { current_params with extra_system_context = Some "first request context" }
        | _ -> Hooks.Continue) }
  in
  let options =
    { Internal_agent.default_options with transport = Some transport; hooks;
      provider_config = Some
        { (Provider_mock.to_provider_config ()) with kind } }
  in
  let media_store = Agent_core.History.Memory_store.create () in
  let projection (messages : Types.message list) =
    let messages =
      match duplicate_context, List.rev messages with
      | true, last :: _ when
          last.origin = Types.System_context ->
        messages @ [last]
      | _ -> messages
    in
    Agent_core.History.to_wire_messages media_store messages
    |> Result.map_error (fun error -> Error.Media error)
  in
  let agent = Internal_agent.create ~media_store ~net:env#net ~model_input_projection:projection
      ~config:{ (Types.default_config ~model:"test-model") with max_tokens = Some 64 } ~options () in
  Internal_agent.set_state agent
    { (Internal_agent.state agent) with messages = [Types.user_msg "first"] };
  let run agent api_strategy =
    match run_pipeline_turn ~sw ~api_strategy agent with
    | Ok _ -> ()
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  run agent Internal_pipeline.Sync;
  let saved = (Internal_agent.state agent).messages in
  let saved = List.map (fun message ->
      Checkpoint.message_to_json message |> Checkpoint.message_of_json |> Result.get_ok) saved in
  let has_historical = List.exists (fun (m : Types.message) ->
    m.origin = Types.Historical_system_context) saved in
  Alcotest.(check bool) "retention follows the producing provider" retained has_historical;
  Alcotest.(check int) "only Anthropic adds durable context"
    (if retained then 3 else 2) (List.length saved);
  let next_options = { options with provider_config = Some
    { (Provider_mock.to_provider_config ()) with kind = next_kind;
      model_capabilities_override = (if signed && kind<>next_kind then
        Some Llm_provider.Capabilities.{openai_compat_chat_capabilities with
          reasoning_replay_override=Force_no_replay}
        else None) } } in
  let resumed = Internal_agent.create ~media_store ~net:env#net
      ~config:{ (Types.default_config ~model:"test-model") with max_tokens = Some 64 }
      ~options:next_options () in
  Internal_agent.set_state resumed
    { (Internal_agent.state agent) with
      config = { (Internal_agent.state agent).config with
        preserve_thinking = (if signed && kind<>next_kind then Some false
          else (Internal_agent.state agent).config.preserve_thinking) };
      messages = saved @ [Types.user_msg "next"] };
  run resumed (Internal_pipeline.Stream { on_event = ignore; on_telemetry = None });
  match !captured with
  | second :: first :: [] ->
    let content messages = List.map (fun (m : Llm_provider.Types.message) -> m.role, m.content) messages in
    if retained then
      Alcotest.(check bool) "Anthropic previous request stays an unchanged prefix" true
        (List.take (List.length first) (content second) = content first)
    else
      Alcotest.(check bool) "other-provider continuation keeps its existing transcript" true
        (Ok second
         = Agent_core.History.to_wire_messages media_store (saved @ [Types.user_msg "next"]))
  | _ -> Alcotest.fail "expected exactly two provider requests")
    Llm_provider.Provider_config.[
      Anthropic, Anthropic, true, true, false;
      Anthropic, Anthropic, false, false, false;
      Anthropic, Anthropic, false, false, true;
      Kimi, Kimi, false, false, true;
      OpenAI_compat, OpenAI_compat, false, false, true;
      Ollama, Ollama, false, false, true;
      Gemini, Gemini, false, false, true;
      Glm, Glm, false, false, true;
      Anthropic, Kimi, true, true, false;
      Anthropic, OpenAI_compat, true, true, false;
      Anthropic, Ollama, true, true, false;
      Anthropic, Gemini, true, true, false;
      Anthropic, Glm, true, true, false]
;;

(* A Keeper hands Agent Core its request view: the carried history after
   [Complete_common.transmitted_history], which on a turn-scoped Anthropic lane
   also runs the context lowering. The carrier collection retains from that
   view becomes history, so it keeps the User role it was created with. The
   next request still opens with the bytes the signed thinking was bound to,
   and that thinking is replayed. *)
let test_turn_scoped_lane_retains_the_canonical_carrier () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let model = "claude-sonnet-5-5" in
  let config =
    Llm_provider.Provider_config.make ~kind:Anthropic ~model_id:model
      ~base_url:"https://api.anthropic.com" ~max_tokens:4096 ~system_prompt:"keeper system"
      ~model_capabilities_override:
        { (Llm_provider.Capabilities.capabilities_of_kind Llm_provider.Provider_config.Anthropic)
          with
          Llm_provider.Capabilities.reasoning_replay_override =
            Llm_provider.Capabilities.Force_turn_scoped_system_context_preserve_always }
      ()
  in
  let captured = ref [] in
  let signed_response (request : Llm_provider.Llm_transport.completion_request) =
    captured := request :: !captured;
    let content =
      [ Llm_provider.Types.Thinking { signature = Some "fixture-signature"; content = "plan" }
      ; Llm_provider.Types.Text "done" ]
    in
    let source =
      Llm_provider.Reasoning_dialect.reasoning_source_for_provider_config request.config
      |> Result.get_ok
    in
    let reasoning_prefix =
      Llm_provider.Backend_anthropic.transmitted_reasoning_prefix ~config:request.config
        ~messages:request.messages ~tools:request.tools ~response_content:content ()
    in
    Ok { (pipeline_response Types.EndTurn) with
         content
       ; telemetry = Some { Types.default_inference_telemetry with
                            reasoning_source = Some source; reasoning_prefix } }
  in
  let transport =
    Llm_provider.Llm_transport.custom
      { Llm_provider.Llm_transport.complete_sync = (fun request ->
          { Llm_provider.Llm_transport.response = signed_response request; latency_ms = Some 0 })
      ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ request -> signed_response request) }
  in
  let hooks =
    { Hooks.empty with before_turn_params = Some (function
        | Hooks.BeforeTurnParams { turn; current_params; _ } ->
          Hooks.AdjustParams
            { current_params with
              extra_system_context = Some (Printf.sprintf "world state %d" turn) }
        | Hooks.BeforeTurn _ | Hooks.AfterTurn _ | Hooks.PreToolUse _ | Hooks.PostToolUse _
        | Hooks.PostToolUseFailure _ | Hooks.OnStop _ | Hooks.OnError _ | Hooks.OnToolError _ ->
          Hooks.Continue) }
  in
  let media_store = Agent_core.History.Memory_store.create () in
  let request_view (messages : Types.message list) =
    match Llm_provider.Complete_common.transmitted_history ~config messages with
    | Error error ->
      Error (Error.Internal (Llm_provider.Reasoning_history_projection.error_to_string error))
    | Ok transmitted ->
      Agent_core.History.to_wire_messages media_store transmitted
      |> Result.map_error (fun error -> Error.Media error)
  in
  let agent =
    Internal_agent.create ~media_store ~net:env#net ~model_input_projection:request_view
      ~config:{ (Types.default_config ~model) with max_tokens = Some 64 }
      ~options:{ Internal_agent.default_options with
                 transport = Some transport; hooks; provider_config = Some config }
      ()
  in
  let run () =
    match run_pipeline_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
    | Ok _ -> ()
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  Internal_agent.set_state agent
    { (Internal_agent.state agent) with messages = [ Types.user_msg "first" ] };
  run ();
  (match
     List.filter (fun (message : Types.message) ->
       message.origin = Types.Historical_system_context)
       (Internal_agent.state agent).messages
   with
   | [ carrier ] ->
     Alcotest.(check bool) "the retained carrier keeps its canonical User role" true
       (carrier.role = Types.User);
     Alcotest.(check string) "the retained carrier holds the transmitted text"
       "[system context] world state 0" (Types.text_of_content carrier.content)
   | carriers ->
     Alcotest.failf "expected one retained carrier, found %d" (List.length carriers));
  Internal_agent.set_state agent
    { (Internal_agent.state agent) with
      messages = (Internal_agent.state agent).messages @ [ Types.user_msg "next" ] };
  run ();
  match !captured with
  | [ second; first ] ->
    let wire (request : Llm_provider.Llm_transport.completion_request) =
      Llm_provider.Backend_anthropic.build_request ~config:request.config
        ~messages:request.messages ~tools:request.tools ()
      |> Yojson.Safe.from_string |> Yojson.Safe.Util.member "messages"
      |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.to_string
    in
    Alcotest.(check (list string)) "the next request opens with the first request's bytes"
      (wire first) (List.take (List.length first.messages) (wire second));
    (match
       Llm_provider.Backend_anthropic.retained_prefix_reasoning_indices ~config:second.config
         ~tools:second.tools second.messages
     with
     | Ok (Some retained) ->
       Alcotest.(check (list int)) "the first turn's signed thinking is replayed" [ 2 ] retained
     | Ok None -> Alcotest.fail "the Anthropic lane binds reasoning to its request"
     | Error error ->
       Alcotest.fail (Llm_provider.Reasoning_history_projection.error_to_string error))
  | requests -> Alcotest.failf "expected two provider requests, found %d" (List.length requests)
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
    Internal_agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
      Ok { Types.content = name; content_blocks = None; _meta = None })
  in
  let tools = [ make_tool "first" "first schema"; make_tool "second" "second schema" ] in
  let expected = List.map Tool.schema_to_json tools in
  let captured = ref None in
  let response = pipeline_response EndTurn in
  let transport : Llm_provider.Llm_transport.t =
    Llm_provider.Llm_transport.custom ({ complete_sync =
        (fun request ->
          captured := Some request.tools;
          { response = Ok response; latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
    })
  in
  let options =
    { Internal_agent.default_options with
      transport = Some transport
    ; provider_config = Some (Provider_mock.to_provider_config ())
    }
  in
  let agent =
    Internal_agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
  (match run_pipeline_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
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

let test_effective_provider_config_drives_lifecycle_without_inferred_cost () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let effective_model = "claude-sonnet-5" in
  let captured_model = ref None in
  let response : Types.api_response =
    { id = "effective-provider-config"
    ; model = ""
    ; unreadable_tool_uses = []
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
    Llm_provider.Llm_transport.custom ({ complete_sync =
        (fun request ->
          captured_model := Some request.config.model_id;
          { response = Ok response; latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
    })
  in
  let carrier =
    (* An explicit [provider_id] selects provider-scoped catalog rows. This
       fixture exercises the native Anthropic wire kind and its bare model
       catalog row, so it must remain an anonymous native config. *)
    Llm_provider.Provider_config.make
      ~kind:Anthropic
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
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
    "display-model fallback does not invent a charge"
    true
    (usage.estimated_cost_usd = 0.0);
  Alcotest.(check bool) "missing reported model preserves the pricing gap" true
    (usage.pricing_gap = Some (Types.Pricing_unavailable effective_model))
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
         Ok { Types.content = "observed"; content_blocks = None; _meta = None })
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
    Llm_provider.Llm_transport.custom ({ complete_sync =
        (fun _request ->
          { Llm_provider.Llm_transport.response = next_response (); latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> next_response ())
    })
  in
  let event_bus = Event_bus.create () in
  let event_config =
    Event_bus.subscription_config ~capacity:32 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let subscription = Event_bus.subscribe ~config:event_config event_bus in
  let agent =
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
            | AgentYielded _
            | AgentInputRequired _
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

(* Every "turn completed" record agent core emitted, as
   (level, turn, stop) in emission order. A record missing either field is a
   contract break, not a filtered row. *)
let turn_completed_records (records : Log.record list) =
  List.filter_map
    (fun (record : Log.record) ->
       if
         String.equal record.module_name "agent"
         && String.equal record.message "turn completed"
       then (
         let turn =
           List.find_map
             (function
               | Log.I ("turn", turn) -> Some turn
               | _ -> None)
             record.fields
         in
         let stop =
           List.find_map
             (function
               | Log.S ("stop", stop) -> Some stop
               | _ -> None)
             record.fields
         in
         match turn, stop with
         | Some turn, Some stop -> Some (Log.level_to_string record.level, turn, stop)
         | None, _ | _, None ->
           Alcotest.fail "turn completed record without a turn or stop field")
       else None)
    records
;;

(* Run [f] with agent-core log records collected at DEBUG; the global level and
   sinks are restored afterwards. Returns [f]'s value and the records. *)
let with_debug_log_records f =
  let sink, get_records = Log.collector_sink () in
  Log.clear_sinks ();
  Log.set_global_level Log.Debug;
  Log.add_sink sink;
  Fun.protect
    ~finally:(fun () ->
      Log.clear_sinks ();
      Log.set_global_level Log.Info)
    (fun () ->
       let value = f () in
       value, get_records ())
;;

(* A tracer that records every span the run opens as (name, turn), in start
   order, so a test can read the ordinal the [agent_turn] span was opened under. *)
let recording_tracer () : Tracing.t * (unit -> (string * int) list) =
  let spans = ref [] in
  let module Recording : Tracing.TRACER with type span = unit = struct
    type span = unit

    let start_span (attrs : Tracing.span_attrs) =
      spans := (attrs.name, attrs.turn) :: !spans
    ;;

    let end_span () ~ok:_ = ()
    let add_event () _ = ()
    let add_attrs () _ = ()
    let add_link () ~trace_id:_ ~span_id:_ = ()
    let trace_id () = None
    let span_id () = None
    let trace_context_headers () = []

    let with_span attrs f =
      start_span attrs;
      f ()
    ;;
  end
  in
  (module Recording : Tracing.TRACER), fun () -> List.rev !spans
;;

let agent_turn_span_ordinals spans =
  List.filter_map
    (fun (name, turn) -> if String.equal name "agent_turn" then Some turn else None)
    spans
;;

let test_turn_completed_log_carries_the_hook_turn_ordinal () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let hook_turns = ref [] in
  let hooks =
    { Hooks.empty with
      after_turn =
        Some
          (function
            | Hooks.AfterTurn { turn; _ } ->
              hook_turns := turn :: !hook_turns;
              Hooks.Continue
            | _ -> Alcotest.fail "expected AfterTurn")
    }
  in
  let tracer, spans = recording_tracer () in
  let (), records =
    with_debug_log_records (fun () ->
      let agent =
        Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
          ~net:(Eio.Stdenv.net env)
          ~config:
            { (Types.default_config ~model:"test-model") with
              name = "turn-ordinal-log-test"
            }
          ~options:
            { Agent.default_options with
              transport = Some (transport_returning (pipeline_response EndTurn))
            ; provider_config = Some (Provider_mock.to_provider_config ())
            ; hooks
            ; tracer
            }
          ()
      in
      match Agent.run ~sw agent "hello" with
      | Ok _ -> ()
      | Error error -> Alcotest.fail (Error.to_string error))
  in
  let turn_records = turn_completed_records records in
  (* One provider turn: the hook saw the zero-based identity. The host's
     AfterTurn hook owns the INFO record of that turn, so agent core emits no
     INFO turn record of its own, and its single DEBUG line names the hook's turn. *)
  Alcotest.(check (list int)) "AfterTurn ordinal" [ 0 ] (List.rev !hook_turns);
  Alcotest.(check (list (triple string int string)))
    "agent core emits exactly one turn record, at DEBUG, on the hook's turn"
    [ "debug", 0, "end_turn" ]
    turn_records;
  Alcotest.(check (list int))
    "agent_turn span opens under the hook's turn"
    (List.rev !hook_turns)
    (agent_turn_span_ordinals (spans ()))
;;

let unwrap_raw_trace = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Error.to_string error)
;;

let test_stream_route_uses_declared_support ~declared_streaming () =
  let trace_path = Filename.temp_file "agent_core-pipeline-capture-id" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> Sys.remove trace_path)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Eio.Switch.run
       @@ fun sw ->
       let captured_id = ref None in
       let sync_calls = ref 0 in
       let stream_calls = ref 0 in
       let response = pipeline_response EndTurn in
       let transport : Llm_provider.Llm_transport.t =
         Llm_provider.Llm_transport.custom ({ complete_sync =
             (fun _req ->
               incr sync_calls;
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream =
             (fun ?on_telemetry:_ ~on_event:_ request ->
               incr stream_calls;
               captured_id := request.Llm_provider.Llm_transport.capture_id;
               Ok response)
         })
       in
       let provider_config = Provider_mock.to_provider_config () in
       let provider_config = if declared_streaming then
         {provider_config with model_capabilities_override=Some
           {Llm_provider.Capabilities.default_capabilities with supports_native_streaming=true}}
         else provider_config in
       let options =
         { Internal_agent.default_options with
           transport = Some transport
         ; provider_config = Some provider_config
         }
       in
       let agent =
         Internal_agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
          run_pipeline_turn
            ~sw
            ~api_strategy:
              (Internal_pipeline.Stream { on_event = ignore; on_telemetry = None })
            ~raw_trace_run:active
            agent
        with
        | Ok (Internal_pipeline.Complete _) -> ()
        | Ok (Internal_pipeline.ToolsExecuted _) ->
          Alcotest.fail "expected a completed turn"
        | Ok (Internal_pipeline.TerminalToolCompleted _) ->
          Alcotest.fail "unexpected terminal tool completion"
        | Error error -> Alcotest.fail (Error.to_string error));
       Alcotest.(check (option string))
         "transport capture identity"
         (if declared_streaming then Some expected else None)
         !captured_id;
       Alcotest.(check int) "native stream follows declared support"
         (if declared_streaming then 1 else 0) !stream_calls;
       Alcotest.(check int) "undeclared transport uses synchronous fallback"
         (if declared_streaming then 0 else 1) !sync_calls;
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
      Ok { Types.content = "ok"; content_blocks = None; _meta = None })
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
    Internal_agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
  match run_pipeline_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
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
  match run_pipeline_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
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
  match run_pipeline_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
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
    match run_pipeline_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
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
  match run_pipeline_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
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
  ; unreadable_tool_uses = []
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
      ; unreadable_tool_uses = []
      ; stop_reason = EndTurn
      ; content = [ Text "provider replanned" ]
      ; usage = None
      ; telemetry = None
      }
    | _ -> Alcotest.fail "unexpected fourth provider call"
  in
  let transport : Llm_provider.Llm_transport.t =
    Llm_provider.Llm_transport.custom ({ complete_sync =
        (fun req ->
          { Llm_provider.Llm_transport.response = Ok (next_response req)
          ; latency_ms = None
          })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ req -> Ok (next_response req))
    })
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
         Ok { Types.content = "should not execute"; content_blocks = None; _meta = None })
  in
  let options =
    { Agent.default_options with
      transport = Some transport
    ; provider_config = Some (Provider_mock.to_provider_config ())
    }
  in
  let agent =
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
          | Llm_provider.Types.Text s -> Some s
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
          | Llm_provider.Types.Text s -> Some s
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
          | Llm_provider.Types.Thinking _ -> true
          | _ -> false)
        resp.content
    in
    let has_text =
      List.exists
        (function
          | Llm_provider.Types.Text _ -> true
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
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~config:(Types.default_config ~model:"test-model") ~net ~tools:[] ()
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
      Ok { Types.content = "a"; content_blocks = None; _meta = None })
  in
  let t2 =
    Tool.create ~name:"tool_b" ~description:"B" ~parameters:[] (fun _ ->
      Ok { Types.content = "b"; content_blocks = None; _meta = None })
  in
  let t3 =
    Tool.create ~name:"tool_c" ~description:"C" ~parameters:[] (fun _ ->
      Ok { Types.content = "c"; content_blocks = None; _meta = None })
  in
  let agent =
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
    [ { origin = Llm_provider.Types.Conversation;  Types.role = User
      ; content = [ Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let prep =
    Agent_turn.prepare_turn ~media_store:(Agent_core.History.Memory_store.create ())
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
    [ { origin = Llm_provider.Types.Conversation;  Types.role = User
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { origin = Llm_provider.Types.Conversation;  Types.role = Assistant
      ; content = [ Text "hi there" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { origin = Llm_provider.Types.Conversation;  Types.role = User
      ; content = [ Text "how are you" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let prep =
    Agent_turn.prepare_turn ~media_store:(Agent_core.History.Memory_store.create ())
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
      ; content_blocks = None
      ; outcome = Tool_succeeded
      }
    ; { invocation = invocation "tu2"
      ; tool_name = "tool-2"
      ; input = `Null
      ; content = "result2"
      ; content_blocks = None
      ; outcome = Tool_succeeded
      }
    ]
  in
  let tool_results = Agent_turn.make_tool_results ~media_store:(Agent_core.History.Memory_store.create ()) results |> Result.get_ok in
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
      ; content_blocks = None
      ; outcome =
          Tool_failed
            { failure_kind = Agent_tools.Recoverable_tool_error; error_class = None }
      }
    ]
  in
  let tool_results = Agent_turn.make_tool_results ~media_store:(Agent_core.History.Memory_store.create ()) results |> Result.get_ok in
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
      ; content_blocks = None
      ; outcome = Tool_succeeded
      }
    ; { invocation = invocation "tu2"
      ; tool_name = "tool-2"
      ; input = `Null
      ; content = "bad"
      ; content_blocks = None
      ; outcome =
          Tool_failed
            { failure_kind = Agent_tools.Recoverable_tool_error; error_class = None }
      }
    ]
  in
  let tool_results = Agent_turn.make_tool_results ~media_store:(Agent_core.History.Memory_store.create ()) results |> Result.get_ok in
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
      ~response_model:None
      ~response_usage:u1
  in
  let after2 =
    Agent_turn.accumulate_usage
      ~current_usage:after1
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
    [ { origin = Llm_provider.Types.Conversation;  Types.role = User
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
    Agent_turn.prepare_turn ~media_store:(Agent_core.History.Memory_store.create ()) ~tools:Tool_set.empty ~messages ~turn_params ()
    |> Result.get_ok
  in
  (* Extra context is appended at the end to preserve prefix for KV cache *)
  Alcotest.(check int)
    "2 messages (original + context)"
    2
    (List.length prep.effective_messages);
  let last = List.nth prep.effective_messages 1 in
  match last.content with
  | [ Llm_provider.Types.Text s ] ->
    Alcotest.(check string)
      "injected context at tail"
      "[system context] You are in debug mode."
      s
  | _ -> Alcotest.fail "expected Text block"
;;

(* ── Error_domain: tag_error ─────────────────────────────── *)

let test_error_domain_of_core_error () =
  let err = Error.Agent (UnrecognizedStopReason { reason = "weird" }) in
  let poly = Error_domain.of_core_error err in
  match poly with
  | `Unrecognized_stop_reason s -> Alcotest.(check string) "reason" "weird" s
  | _ -> Alcotest.fail "expected Unrecognized_stop_reason"
;;

let test_error_domain_roundtrip () =
  let err = Error.Internal "test error" in
  let poly = Error_domain.of_core_error err in
  let back = Error_domain.to_core_error poly in
  Alcotest.(check string) "roundtrip" (Error.to_string err) (Error.to_string back)
;;

let test_error_domain_with_stage () =
  let poly = Error_domain.of_core_error (Error.Internal "fail") in
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
  let errs : Error_domain.core_error_poly list =
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
             | Llm_provider.Types.ToolUse _ -> true
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
  with_execution_test_dir "agent_core-agent-terminal-failure-"
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
    Llm_provider.Llm_transport.custom ({ complete_sync =
        (fun _request ->
          { Llm_provider.Llm_transport.response = next_response (); latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> next_response ())
    })
  in
  let tool =
    Tool.create
      ~name:"durable_tool"
      ~description:"settled before provider failure"
      ~parameters:[]
      (fun _input -> Ok { Types.content = "settled"; content_blocks = None; _meta = None })
  in
  let agent =
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
  with_execution_test_dir "agent_core-agent-terminal-sink-failure-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let callback_count = ref 0 in
  let response = Provider_mock.text_response "done" [] in
  let transport : Llm_provider.Llm_transport.t =
    Llm_provider.Llm_transport.custom ({ complete_sync =
        (fun _request ->
          { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
    })
  in
  let agent =
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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

type trace_diagnostic_fault =
  | Diagnostic_ok
  | Diagnostic_failed
  | Diagnostic_reserved
  | Callback_diagnostic_failed

let test_trace_finalization_preserves_committed_success diagnostic_fault () =
  with_execution_test_dir "agent_core-trace-postcommit-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let trace_path = Filename.temp_file "agent_core-terminal-observer-" ".jsonl" in
  Eio.Switch.on_release sw (fun () ->
    if Sys.is_directory trace_path then Unix.rmdir trace_path else Sys.remove trace_path);
  let trace = unwrap_raw_trace (Raw_trace.create ~path:trace_path ()) in
  let tool_calls = ref 0 in
  let responses = ref
    [ Ok (Provider_mock.tool_use_response ~tool_name:"durable_tool" ~tool_input:(`Assoc []) () [])
    ; Ok (Provider_mock.text_response "committed answer" []) ] in
  let next_response () = match !responses with
    | response :: rest -> responses := rest; response
    | [] -> Alcotest.fail "unexpected provider retry after committed execution" in
  let transport = Llm_provider.Llm_transport.custom
    { complete_sync = (fun _request ->
        { Llm_provider.Llm_transport.response=next_response ();latency_ms=Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> next_response ()) } in
  let tool = Tool.create ~name:"durable_tool" ~description:"committed external effect"
      ~parameters:[] (fun _ -> incr tool_calls;
        Ok {Types.content="settled";content_blocks=None;_meta=None}) in
  let completion = ref None and locator = ref None and before = ref None in
  let agent = Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net:(Eio.Stdenv.net env)
      ~config:{(Types.default_config ~model:"test-model") with name="trace-postcommit"}
      ~tools:[tool]
      ~options:{Agent.default_options with transport=Some transport;
        provider_config=Some (Provider_mock.to_provider_config ());raw_trace=Some trace;
        on_run_complete=Some (fun ok ->
          completion:=Some ok;
          match diagnostic_fault with
          | Callback_diagnostic_failed -> raise (Failure "injected completion observer failure")
          | Diagnostic_ok | Diagnostic_failed | Diagnostic_reserved -> ())} () in
  let open_projection () = match !locator with
    | None -> Alcotest.fail "scope locator missing"
    | Some locator -> match Agent.open_execution_projection ~runtime ~dir locator with
      | Ok projection -> projection
      | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let terminal projection = match Agent.read_execution_terminal projection with
    | Ok (Some terminal) -> terminal
    | Ok None -> Alcotest.fail "canonical terminal missing"
    | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let read_page projection after = match Agent.Execution_projection.read_page projection
      ~after ~limit:512 () with
    | Ok page -> page
    | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let execution_store = Agent.execution_store ~runtime ~dir
      ~on_scope_ready:(fun value -> locator:=Some value;Ok ())
      ~on_terminal_disposition:(fun disposition ->
        Alcotest.(check bool) "canonical success committed before trace fault" true
          (disposition.Agent.outcome=Agent.Terminal_succeeded);
        let projection=open_projection () in
        let page=read_page projection (Agent.Execution_projection.beginning_cursor projection) in
        before:=Some (terminal projection,page);
        Sys.remove trace_path;
        Unix.mkdir trace_path 0o700;
        Ok ()) () in
  let diagnostics=ref 0 and callback_diagnostics=ref 0 in
  Log.clear_sinks ();
  Log.set_global_level Log.Warn;
  Log.add_sink (fun (record : Log.record) ->
    if record.module_name="agent_trace"
       && record.message="raw trace finalization failed after run result" then (
      incr diagnostics;
      match diagnostic_fault with
      | Diagnostic_ok | Callback_diagnostic_failed -> ()
      | Diagnostic_failed -> raise (Failure "injected diagnostic sink failure")
      | Diagnostic_reserved -> raise Sys.Break)
    else if record.module_name="agent_trace" && record.message="on_run_complete callback raised" then (
      incr callback_diagnostics;
      raise (Failure "injected callback diagnostic sink failure")));
  let result=Fun.protect
      ~finally:(fun () -> Log.clear_sinks ();Log.set_global_level Log.Info)
      (fun () -> match Agent.run ~sw ~execution_store agent "settle the effect" with
        | result -> Some result
        | exception Sys.Break -> None) in
  Alcotest.(check int) "external effect executed once" 1 !tool_calls;
  Alcotest.(check bool) "fault occurs after canonical terminal observation" true
    (Option.is_some !before);
  (match diagnostic_fault,result with
   | Diagnostic_reserved,None ->
     Alcotest.(check (option bool)) "reserved diagnostic preempts completion callback" None !completion
   | (Diagnostic_ok | Diagnostic_failed | Callback_diagnostic_failed),Some (Ok response) ->
     Alcotest.(check string) "committed answer survives observer failure"
       "committed answer" (Types.text_of_response response);
     Alcotest.(check (option bool)) "completion callback observes execution success" (Some true) !completion
   | (Diagnostic_ok | Diagnostic_failed | Diagnostic_reserved | Callback_diagnostic_failed),Some (Error error) ->
     Alcotest.failf "observer relabeled committed success: %s" (Error.to_string error)
   | Diagnostic_reserved,Some (Ok _)
   | (Diagnostic_ok | Diagnostic_failed | Callback_diagnostic_failed),None -> Alcotest.fail "diagnostic fault propagation mismatch");
  Alcotest.(check int) "trace failure diagnostic attempted once" 1 !diagnostics;
  Alcotest.(check int) "callback diagnostic only follows a callback failure"
    (match diagnostic_fault with Callback_diagnostic_failed -> 1
     | Diagnostic_ok | Diagnostic_failed | Diagnostic_reserved -> 0) !callback_diagnostics;
  (match Agent.lifecycle agent with
   | Some snapshot -> Alcotest.(check bool) "lifecycle retains committed success" true
       (snapshot.status=Agent.Completed)
   | None -> Alcotest.fail "lifecycle missing");
  let projection=open_projection () in
  match !before with
  | None -> Alcotest.fail "committed prefix missing"
  | Some (expected,page) ->
    Alcotest.(check bool) "fresh reader sees same canonical terminal" true
      (terminal projection=expected);
    let reread=read_page projection (Agent.Execution_projection.beginning_cursor projection) in
    Alcotest.(check bool) "same occurrence identities and sequence after observer failure" true
      (reread.events=page.events && reread.next_cursor=page.next_cursor);
    let tail=read_page projection page.next_cursor in
    Alcotest.(check int) "observer failure appends no compensating execution failure" 0
      (List.length tail.events)
;;

(* Where the optional raw trace stops accepting writes while the run is still
   doing real work.  Each site makes the trace path a directory from inside the
   very callback whose fact the trace records next. *)
type trace_write_fault =
  | Trace_fails_under_provider_response
  | Trace_fails_under_tool_effect
  | Trace_fails_under_allowing_hook
  | Trace_fails_under_blocking_hook

let test_trace_write_failure_keeps_execution fault () =
  with_execution_test_dir "agent_core-trace-midrun-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let trace_path = Filename.temp_file "agent_core-midrun-observer-" ".jsonl" in
  Eio.Switch.on_release sw (fun () ->
    if Sys.is_directory trace_path then Unix.rmdir trace_path else Sys.remove trace_path);
  let trace = unwrap_raw_trace (Raw_trace.create ~path:trace_path ()) in
  let trace_broken = ref false in
  let break_trace () =
    if not !trace_broken
    then (
      trace_broken := true;
      Sys.remove trace_path;
      Unix.mkdir trace_path 0o700)
  in
  let final_text = "answer after the trace stopped" in
  let responses =
    ref
      (match fault with
       | Trace_fails_under_provider_response ->
         [ Provider_mock.text_response ~input_tokens:7 ~output_tokens:3 final_text [] ]
       | Trace_fails_under_tool_effect
       | Trace_fails_under_allowing_hook
       | Trace_fails_under_blocking_hook ->
         [ Provider_mock.tool_use_response
             ~tool_name:"effect_tool"
             ~tool_input:(`Assoc [])
             ()
             []
         ; Provider_mock.text_response ~input_tokens:7 ~output_tokens:3 final_text []
         ])
  in
  let provider_calls = ref 0 in
  let next_response () =
    incr provider_calls;
    (match fault with
     | Trace_fails_under_provider_response -> break_trace ()
     | Trace_fails_under_tool_effect
     | Trace_fails_under_allowing_hook
     | Trace_fails_under_blocking_hook -> ());
    match !responses with
    | response :: rest ->
      responses := rest;
      Ok response
    | [] -> Alcotest.fail "provider was asked again after the final answer"
  in
  let transport =
    Llm_provider.Llm_transport.custom
      { complete_sync =
          (fun _request ->
            { Llm_provider.Llm_transport.response = next_response ()
            ; latency_ms = Some 0
            })
      ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> next_response ())
      }
  in
  let tool_calls = ref 0 in
  let tool =
    Tool.create
      ~name:"effect_tool"
      ~description:"external effect that must happen at most once"
      ~parameters:[]
      (fun _ ->
         incr tool_calls;
         (match fault with
          | Trace_fails_under_tool_effect -> break_trace ()
          | Trace_fails_under_provider_response
          | Trace_fails_under_allowing_hook
          | Trace_fails_under_blocking_hook -> ());
         Ok { Types.content = "effect settled"; content_blocks = None; _meta = None })
  in
  let hooks =
    match fault with
    | Trace_fails_under_provider_response | Trace_fails_under_tool_effect -> Hooks.empty
    | Trace_fails_under_allowing_hook ->
      { Hooks.empty with
        pre_tool_use =
          Some
            (fun _event ->
              break_trace ();
              Hooks.Continue)
      }
    | Trace_fails_under_blocking_hook ->
      { Hooks.empty with
        pre_tool_use =
          Some
            (fun _event ->
              break_trace ();
              Hooks.Block "refused by the hook")
      }
  in
  let completion = ref None in
  let agent =
    Agent.create
      ~media_store:(Agent_core.History.Memory_store.create ())
      ~net:(Eio.Stdenv.net env)
      ~config:{ (Types.default_config ~model:"test-model") with name = "trace-midrun" }
      ~tools:[ tool ]
      ~options:
        { Agent.default_options with
          transport = Some transport
        ; provider_config = Some (Provider_mock.to_provider_config ())
        ; raw_trace = Some trace
        ; hooks
        ; on_run_complete = Some (fun ok -> completion := Some ok)
        }
      ()
  in
  let terminal_outcome = ref None in
  let execution_store =
    Agent.execution_store
      ~runtime
      ~dir
      ~on_scope_ready:(fun _locator -> Ok ())
      ~on_terminal_disposition:(fun disposition ->
        terminal_outcome := Some disposition.Agent.outcome;
        Ok ())
      ()
  in
  let missing_boundaries = ref [] in
  Log.clear_sinks ();
  Log.set_global_level Log.Warn;
  Log.add_sink (fun (record : Log.record) ->
    if record.module_name = "agent_trace"
       && record.message = "raw trace record not written"
    then
      List.iter
        (function
          | Log.S ("trace_boundary", boundary) ->
            missing_boundaries := boundary :: !missing_boundaries
          | Log.S _ | Log.I _ | Log.F _ | Log.B _ | Log.J _ | Log.Secret _ -> ())
        record.fields);
  let result =
    Fun.protect
      ~finally:(fun () ->
        Log.clear_sinks ();
        Log.set_global_level Log.Info)
      (fun () -> Agent.run ~sw ~execution_store agent "do the work")
  in
  Alcotest.(check bool) "the trace was broken during the run" true !trace_broken;
  (match result with
   | Ok response ->
     Alcotest.(check string)
       "accepted provider answer survives the trace failure"
       final_text
       (Types.text_of_response response)
   | Error error ->
     Alcotest.failf "trace write failure became a run failure: %s" (Error.to_string error));
  let expected_provider_calls, expected_tool_calls, expected_boundary =
    match fault with
    | Trace_fails_under_provider_response -> 1, 0, "assistant_block"
    | Trace_fails_under_tool_effect -> 2, 1, "tool_execution_finished"
    | Trace_fails_under_allowing_hook -> 2, 1, "hook_invocation"
    | Trace_fails_under_blocking_hook -> 2, 0, "hook_invocation"
  in
  Alcotest.(check int) "provider is asked exactly as often" expected_provider_calls !provider_calls;
  Alcotest.(check int) "tool effect count follows the hook decision" expected_tool_calls !tool_calls;
  Alcotest.(check bool)
    "the missing record is reported under its own boundary"
    true
    (List.mem expected_boundary !missing_boundaries);
  let state = Agent.state agent in
  Alcotest.(check int) "usage of every accepted response is kept" expected_provider_calls
    state.usage.api_calls;
  Alcotest.(check int) "input tokens are kept" 7 state.usage.total_input_tokens;
  let tool_result_contents =
    List.concat_map
      (fun (message : Types.message) ->
         List.filter_map
           (function
             | Types.ToolResult { content; _ } -> Some content
             | _ -> None)
           message.content)
      state.messages
  in
  (match fault with
   | Trace_fails_under_provider_response ->
     Alcotest.(check (list string)) "no tool ran" [] tool_result_contents
   | Trace_fails_under_tool_effect | Trace_fails_under_allowing_hook ->
     Alcotest.(check (list string))
       "the completed tool result stays in the transcript once"
       [ "effect settled" ]
       tool_result_contents
   | Trace_fails_under_blocking_hook ->
     Alcotest.(check int) "the block is answered once" 1 (List.length tool_result_contents);
     Alcotest.(check bool)
       "the blocked call did not get the tool's own result"
       false
       (List.mem "effect settled" tool_result_contents));
  Alcotest.(check bool)
    "canonical terminal is success"
    true
    (!terminal_outcome = Some Agent.Terminal_succeeded);
  Alcotest.(check (option bool)) "completion callback observes success" (Some true) !completion;
  match Agent.lifecycle agent with
  | Some snapshot ->
    Alcotest.(check bool) "lifecycle is completed" true (snapshot.status = Agent.Completed)
  | None -> Alcotest.fail "lifecycle missing"
;;

exception Checkpoint_authority_refused

let test_durable_turn_bus_uses_canonical_facts
    ?(delivery_fault=false) ?(refuse_checkpoint=false) ~caller_checkpoint () =
  with_execution_test_dir "agent_core-turn-observation-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let bus = Event_bus.create () in
  let subscription = Event_bus.subscribe bus
      ~config:(Result.get_ok (Event_bus.subscription_config
        ~capacity:16 ~overflow:Event_bus.Drop_newest)) in
  let provider_calls = ref 0 and locator = ref None and during_dispatch = ref [] in
  let response =
    { (Provider_mock.text_response "done" []) with
      telemetry = Some {Types.default_inference_telemetry with
        provider_kind = Some Llm_provider.Provider_kind.OpenAI_compat} } in
  let next () =
    during_dispatch := Event_bus.drain subscription;
    incr provider_calls; Ok response in
  let transport = Llm_provider.Llm_transport.custom
    { complete_sync = (fun _ -> {Llm_provider.Llm_transport.response = next (); latency_ms = None})
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> next ()) } in
  let checkpoint_sink = if caller_checkpoint then Some (fun (snapshot:Agent.checkpoint_snapshot) ->
    if refuse_checkpoint && snapshot.stage=After_assistant_collected
    then Error "assistant collection checkpoint refused" else Ok ()) else None in
  let agent = Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
      ~net:(Eio.Stdenv.net env) ?checkpoint_sink
      ~config:{(Types.default_config ~model:"test-model") with name="canonical-turn-bus"}
      ~options:{Agent.default_options with transport=Some transport; event_bus=Some bus;
        provider_config=Some (Provider_mock.to_provider_config ())} () in
  let store = Agent.execution_store ~runtime ~dir
      ~on_scope_ready:(fun value -> locator := Some value; Ok ()) () in
  let outcome = if not delivery_fault then
      Agent.run ~sw ~execution_store:store agent "observe the provider turn"
    else
      let internal_runtime = match Internal_runtime.create ~sw
          ~domain_mgr:env#domain_mgr ~domain_count:1 with
        | Ok runtime -> runtime
        | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error) in
      match Internal_writer.run ~codec:(Internal_codec.of_runtime internal_runtime) ~dir
        (fun ~sw:_ writer ->
          let scope = match Internal_scope.start ~writer ~agent_name:"canonical-turn-bus" with
            | Ok scope -> scope | Error error -> Alcotest.fail (Internal_scope.error_to_string error) in
          locator := Some (match Agent.execution_locator_of_yojson
              (Internal_scope.scope_locator_to_yojson (Internal_scope.scope_locator scope)) with
            | Ok locator -> locator | Error detail -> Alcotest.fail detail);
          let first = ref true in
          let observer = Internal.Agent_bus_observer.create ~publish:(fun bus event ->
            Event_bus.publish bus event;
            match event.Event_bus.payload with
            | TurnReady _ when !first -> first := false; failwith "accepted ready without acknowledgement"
            | TurnStarted _ | TurnReady _ | TurnCompleted _ | InferenceTelemetry _
            | AgentStarted _ | AgentCompleted _ | AgentYielded _ | AgentInputRequired _ | AgentFailed _
            | ToolCalled _ | ToolCompleted _ | HandoffRequested _ | HandoffCompleted _
            | ElicitationCompleted _ | ToolApprovalCompleted _ | Custom _ -> ()) scope in
          observer.register ~run_id:(Internal_scope.scope_locator_run_id
            (Internal_scope.scope_locator scope)) ~event_bus:(Some bus);
          let result = Internal.Execution_context.with_bus_observer observer (fun () ->
            Internal.Execution_context.with_agent_scope scope (fun () ->
              Agent.run ~sw agent "observe the provider turn")) in
          (match Internal_scope.finish scope Internal.Execution_event.Succeeded with
           | Ok () -> () | Error error -> Alcotest.fail (Internal_scope.error_to_string error));
          result) with
      | Ok result -> result
      | Error error -> Alcotest.fail (Internal_writer.scope_failure_to_string error) in
  (match outcome with
   | Error _ when refuse_checkpoint -> ()
   | Ok _ when not refuse_checkpoint -> ()
   | Ok _ -> Alcotest.fail "required checkpoint refusal did not stop continuation"
   | Error error -> Alcotest.fail (Error.to_string error));
  Alcotest.(check int) "provider dispatch once" 1 !provider_calls;
  let deliveries = (!during_dispatch @ Event_bus.drain subscription) |> List.filter (fun (event:Event_bus.event) ->
    match event.payload with
    | TurnStarted _ | TurnReady _ | TurnCompleted _ | InferenceTelemetry _ -> true
    | AgentStarted _ | AgentCompleted _ | AgentYielded _ | AgentInputRequired _ | AgentFailed _
    | ToolCalled _ | ToolCompleted _ | HandoffRequested _ | HandoffCompleted _
    | ElicitationCompleted _ | ToolApprovalCompleted _ | Custom _ -> false) in
  Alcotest.(check int) "only unacknowledged source delivery repeats"
    ((if refuse_checkpoint then 3 else 4) + if delivery_fault then 1 else 0) (List.length deliveries);
  let observations = List.fold_left (fun events (event:Event_bus.event) ->
    if List.exists (fun (seen:Event_bus.event) -> seen.meta.event_id=event.meta.event_id) events
    then events else events @ [event]) [] deliveries in
  Alcotest.(check bool) "ready observation precedes provider dispatch" true
    (List.exists (fun (event:Event_bus.event) -> match event.payload with
      | TurnReady {tool_names=[];turn=0;agent_name="canonical-turn-bus"} -> true
      | _ -> false) !during_dispatch);
  let projection = match Agent.open_execution_projection ~runtime ~dir (Option.get !locator) with
    | Ok projection -> projection
    | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let page = match Agent.Execution_projection.read_page projection
      ~after:(Agent.Execution_projection.beginning_cursor projection) ~limit:1024 () with
    | Ok page -> page
    | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  List.iter (fun (observation:Event_bus.event) ->
    let source = List.find_opt (fun (source:Agent.Execution_projection.event) ->
      String.equal observation.meta.event_id
        (Agent.Execution_projection.Event_id.to_string source.event_id)) page.events in
    match source with
    | None -> Alcotest.fail "durable turn observation has no committed source event"
    | Some source ->
      Alcotest.(check (option int)) "turn observation keeps committed sequence"
        (Some source.seq) observation.meta.seq;
      Alcotest.(check string) "turn observation keeps committed run"
        (Agent.Execution_projection.Run_id.to_string source.run_id) observation.meta.run_id;
      Alcotest.(check string) "turn observation keeps committed correlation"
        (Agent.Execution_projection.Correlation_id.to_string source.correlation_id)
        observation.meta.correlation_id;
      Alcotest.(check (option string)) "turn observation keeps committed parent"
        (Option.map Agent.Execution_projection.Event_id.to_string source.parent_event_id)
        observation.meta.parent_event_id;
      Alcotest.(check bool) "payload derives from its exact committed boundary" true
        (match observation.payload, source.payload with
         | TurnStarted _, Node_opened {kind=Agent_turn {ordinal=0};_} -> true
         | TurnReady {tool_names;_}, Node_updated {update=Turn_ready names;_} -> tool_names=names
         | TurnCompleted _, Node_closed {terminal=Succeeded;_} -> true
         | InferenceTelemetry {model;prompt_ms;decode_ms;decode_tok_s;_},
             Node_updated {update=Provider_response_snapshot response;_} ->
           model=response.model && prompt_ms=None && decode_ms=None && decode_tok_s=None
         | _ -> false)) observations;
  let read projection after limit = match Agent.Execution_projection.read_bus_observations projection
      ~after ~through:page.high_watermark ~limit () with
    | Ok page -> page | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let rec catch_up after acc =
    let next = read projection after 1 in
    let acc = List.rev_append next.observations acc in
    if next.has_more then catch_up next.next_cursor acc else List.rev acc in
  let replay = catch_up (Agent.Execution_projection.beginning_cursor projection) [] in
  Alcotest.(check bool) "cursor catch-up matches deduplicated live observations" true
    (List.map (fun (o:Agent.Execution_projection.bus_observation)->o.event) replay=observations);
  let first = List.hd replay in
  let reopened = match Agent.open_execution_projection ~runtime ~dir (Option.get !locator) with
    | Ok projection -> projection
    | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let retry = read reopened first.through 1024 in
  Alcotest.(check bool) "reopened acknowledgement skips only accepted observation" true
    (List.map (fun (o:Agent.Execution_projection.bus_observation)->o.event) retry.observations
     = List.tl observations);
  Alcotest.(check int) "acknowledged catch-up has no repeat" 0
    (List.length (read reopened retry.next_cursor 1024).observations)
;;

let test_nested_execution_stores_use_their_own_bus_observers () =
  with_execution_test_dir "agent_core-independent-observers-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let root_bus = Event_bus.create () and child_bus = Event_bus.create () in
  let subscribe bus = Event_bus.subscribe bus
      ~config:(Result.get_ok (Event_bus.subscription_config ~capacity:16 ~overflow:Drop_newest)) in
  let root_subscription = subscribe root_bus and child_subscription = subscribe child_bus in
  let root_locator = ref None and child_locator = ref None in
  let root_calls = ref 0 and child_calls = ref 0 in
  let child_dir = Eio.Path.(dir / "independent-child") in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 child_dir;
  let child_store = Agent.execution_store ~runtime ~dir:child_dir
      ~on_scope_ready:(fun value -> child_locator:=Some value; Ok ()) () in
  let make_agent name bus calls hooks =
    let response = {(Provider_mock.text_response "done" []) with
      telemetry=Some {Types.default_inference_telemetry with
        provider_kind=Some Llm_provider.Provider_kind.OpenAI_compat}} in
    let next () = incr calls; Ok response in
    let transport = Llm_provider.Llm_transport.custom
      { complete_sync=(fun _ -> {Llm_provider.Llm_transport.response=next ();latency_ms=None})
      ; complete_stream=(fun ?on_telemetry:_ ~on_event:_ _ -> next ()) } in
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net:env#net
      ~config:{(Types.default_config ~model:"test-model") with name}
      ~options:{Agent.default_options with event_bus=Some bus;transport=Some transport;hooks;
        provider_config=Some (Provider_mock.to_provider_config ())} () in
  let child = make_agent "independent-child" child_bus child_calls Hooks.empty in
  let hooks = {Hooks.empty with after_turn=Some (fun _ ->
    Alcotest.(check bool) "hook child has no shared-journal factory" true
      (Option.is_none (Internal.Execution_context.child_scope_factory ()));
    match Agent.run ~sw ~execution_store:child_store child "child" with
    | Ok _ -> Hooks.Continue
    | Error error -> Alcotest.fail (Error.to_string error))} in
  let root = make_agent "independent-root" root_bus root_calls hooks in
  let root_store = Agent.execution_store ~runtime ~dir
      ~on_scope_ready:(fun value -> root_locator:=Some value; Ok ()) () in
  (match Agent.run ~sw ~execution_store:root_store root "root" with
   | Ok _ -> () | Error error -> Alcotest.fail (Error.to_string error));
  Alcotest.(check int) "parent provider once" 1 !root_calls;
  Alcotest.(check int) "separate child provider once" 1 !child_calls;
  let turn_observations events = List.filter (fun event -> match event.Event_bus.payload with
    | TurnStarted _ | TurnReady _ | TurnCompleted _ | InferenceTelemetry _ -> true
    | AgentStarted _ | AgentCompleted _ | AgentYielded _ | AgentInputRequired _ | AgentFailed _
    | ToolCalled _ | ToolCompleted _ | HandoffRequested _ | HandoffCompleted _
    | ElicitationCompleted _ | ToolApprovalCompleted _ | Custom _ -> false) events in
  List.iter (fun (dir, locator, subscription) ->
    let projection = match Agent.open_execution_projection ~runtime ~dir (Option.get !locator) with
      | Ok projection -> projection
      | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
    let page = match Agent.Execution_projection.read_bus_observations projection
        ~after:(Agent.Execution_projection.beginning_cursor projection) ~limit:1024 () with
      | Ok page -> page | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
    let source = List.map (fun (o:Agent.Execution_projection.bus_observation)->o.event) page.observations in
    Alcotest.(check int) "each journal retains its four turn observations" 4 (List.length source);
    let delivered = turn_observations (Event_bus.drain subscription) in
    Alcotest.(check int) "separate journal has its own live cursor" 4 (List.length delivered);
    Alcotest.(check bool) "each audience observes only its exact journal source" true (delivered=source))
    [dir,root_locator,root_subscription; child_dir,child_locator,child_subscription]
;;

let test_durable_tool_bus_uses_canonical_facts ?(delivery_fault=false) ?checkpoint_failure () =
  with_execution_test_dir "agent_core-tool-observation-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let bus=Event_bus.create () in
  let config=match Event_bus.subscription_config ~capacity:16 ~overflow:Event_bus.Drop_newest with
    | Ok config -> config | Error _ -> Alcotest.fail "invalid fixture subscription" in
  let sub=Event_bus.subscribe ~config ~filter:Event_bus.filter_tools_only bus in
  let during=ref [] and tool_calls=ref 0 and locator=ref None in
  let tool=Tool.create ~name:"canonical_tool" ~description:"observe exact commit identity"
      ~parameters:[] (fun _ ->
        during:=Event_bus.drain sub;incr tool_calls;
        Ok {Types.content="settled";content_blocks=None;_meta=None}) in
  let responses=ref
    [Provider_mock.tool_use_response ~tool_name:"canonical_tool" ~tool_input:(`Assoc []) () [];
     Provider_mock.text_response "done" []] in
  let next ()=match !responses with
    | response::rest -> responses:=rest;Ok response
    | [] -> Alcotest.fail "unexpected provider retry" in
  let transport=Llm_provider.Llm_transport.custom
    {complete_sync=(fun _ -> {Llm_provider.Llm_transport.response=next ();latency_ms=None});
     complete_stream=(fun ?on_telemetry:_ ~on_event:_ _ -> next ())} in
  let checkpoint_sink=Option.map (fun fail (snapshot:Agent.checkpoint_snapshot) ->
    match snapshot.stage with
    | Agent.After_tool_results_appended ->
      let locator=match !locator with Some locator->locator
        | None->Alcotest.fail "checkpoint observer has no canonical locator" in
      let projection=match Agent.open_execution_projection ~runtime ~dir locator with
        | Ok projection->projection
        | Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
      let settled=match Agent.Execution_projection.settled_tool_invocations projection with
        | Ok settled->settled
        | Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
      Alcotest.(check int) "effect committed before checkpoint observer failure" 1 (List.length settled);
      fail ()
    | Agent.After_assistant_collected | Agent.After_context_injection
    | Agent.After_input_wait_changed | Agent.After_rejected_response_dropped -> Ok ()) checkpoint_failure in
  let agent=Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net:(Eio.Stdenv.net env) ~tools:[tool] ?checkpoint_sink
      ~config:{(Types.default_config ~model:"test-model") with name="canonical-bus"}
      ~options:{Agent.default_options with transport=Some transport;event_bus=Some bus;
        provider_config=Some (Provider_mock.to_provider_config ())} () in
  let store=Agent.execution_store ~runtime ~dir
      ~on_scope_ready:(fun value ->locator:=Some value;Ok ()) () in
  let run () =
    if not delivery_fault then Agent.run ~sw ~execution_store:store agent "observe the effect"
    else
      let internal_runtime=match Internal_runtime.create ~sw
          ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~domain_count:1 with
        | Ok runtime->runtime |Error error->Alcotest.fail (Internal_runtime.create_error_to_string error) in
      match Internal_writer.run ~codec:(Internal_codec.of_runtime internal_runtime) ~dir
        (fun ~sw:_ writer ->
          let scope=match Internal_scope.start ~writer ~agent_name:"canonical-bus" with
            | Ok scope->scope |Error error->Alcotest.fail (Internal_scope.error_to_string error) in
          locator:=Some (match Agent.execution_locator_of_yojson
              (Internal_scope.scope_locator_to_yojson (Internal_scope.scope_locator scope)) with
            | Ok locator->locator |Error detail->Alcotest.fail detail);
          let first=ref true in
          let observer=Internal.Agent_bus_observer.create ~publish:(fun bus event ->
            Event_bus.publish bus event;
            match event.Event_bus.payload with
            | ToolCalled _ when !first ->
              first:=false;raise (Failure "accepted delivery without acknowledgement")
            | ToolCalled _ | ToolCompleted _
            | AgentStarted _ | AgentCompleted _ | AgentYielded _ | AgentInputRequired _ | AgentFailed _
            | TurnStarted _ | TurnReady _ | TurnCompleted _ | InferenceTelemetry _
            | HandoffRequested _ | HandoffCompleted _ | ElicitationCompleted _
            | ToolApprovalCompleted _ | Custom _ -> ()) scope in
          observer.register ~run_id:(Internal_scope.scope_locator_run_id (Internal_scope.scope_locator scope))
            ~event_bus:(Some bus);
          let result=Internal.Execution_context.with_bus_observer observer (fun () ->
            Internal.Execution_context.with_agent_scope scope (fun () -> Agent.run ~sw agent "observe the effect")) in
          (match Internal_scope.finish scope Internal.Execution_event.Succeeded with
           | Ok ()->() |Error error->Alcotest.fail (Internal_scope.error_to_string error));
          result) with
      | Ok result->result |Error error->Alcotest.fail (Internal_writer.scope_failure_to_string error) in
  let outcome=try run () with
    | Checkpoint_authority_refused -> Error (Error.Internal "required checkpoint authority raised") in
  match checkpoint_failure with
  | Some _ ->
    Alcotest.(check bool) "required checkpoint authority refusal rejects continuation" true
      (match outcome with Error _->true |Ok _->false);
    Alcotest.(check int) "required checkpoint refusal never repeats committed effect" 1 !tool_calls;
    Alcotest.(check int) "required checkpoint refusal prevents next provider call" 1 (List.length !responses);
    let locator=match !locator with Some locator->locator |None->Alcotest.fail "missing locator" in
    let projection=match Agent.open_execution_projection ~runtime ~dir locator with
      | Ok projection->projection |Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
    Alcotest.(check bool) "caller-owned checkpoints are not dual-written into journal" true
      (match Agent.Execution_projection.latest_checkpoint projection with
       | Ok None->true |Ok (Some _) |Error _->false)
  | None ->
  (match outcome with Ok _ -> () | Error error -> Alcotest.fail (Error.to_string error));
  Alcotest.(check int) "tool effect once" 1 !tool_calls;
  Alcotest.(check int) "called observation arrives before effect" 1 (List.length !during);
  let deliveries= !during @ Event_bus.drain sub in
  Alcotest.(check int) "partial delivery retries only the unacknowledged occurrence"
    (if delivery_fault then 3 else 2) (List.length deliveries);
  let observations=List.fold_left (fun acc (event:Event_bus.event) ->
    if List.exists (fun (existing:Event_bus.event)->existing.meta.event_id=event.meta.event_id) acc
    then acc else acc@[event]) [] deliveries in
  Alcotest.(check int) "one canonical called and completed identity" 2 (List.length observations);
  let locator=match !locator with Some locator->locator |None->Alcotest.fail "missing locator" in
  let projection=match Agent.open_execution_projection ~runtime ~dir locator with
    | Ok projection->projection |Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let page=match Agent.Execution_projection.read_page projection
      ~after:(Agent.Execution_projection.beginning_cursor projection) ~limit:1024 () with
    | Ok page->page |Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let fact is_called=List.find (fun (event:Agent.Execution_projection.event)->
      match event.payload with
      | Node_opened {kind=Tool_attempt;_}->is_called
      | Node_updated {update=Tool_result _;_}->not is_called
      | Node_opened _ | Node_updated _ | Node_closed _->false) page.events in
  List.iter (fun (observation:Event_bus.event)->
    let is_called=match observation.payload with
      | ToolCalled _->true |ToolCompleted _->false
      | AgentStarted _ | AgentCompleted _ | AgentYielded _ | AgentInputRequired _ | AgentFailed _
      | TurnStarted _ | TurnReady _ | TurnCompleted _ | HandoffRequested _ | HandoffCompleted _
      | ElicitationCompleted _ | ToolApprovalCompleted _ | InferenceTelemetry _ | Custom _ ->
        Alcotest.fail "non-tool observation escaped filter" in
    let source=fact is_called in
    Alcotest.(check (option int)) "bus occurrence uses canonical sequence" (Some source.seq) observation.meta.seq;
    Alcotest.(check string) "bus occurrence uses canonical event id"
      (Agent.Execution_projection.Event_id.to_string source.event_id) observation.meta.event_id;
    Alcotest.(check string) "bus occurrence uses canonical run id"
      (Agent.Execution_projection.Run_id.to_string source.run_id) observation.meta.run_id;
    Alcotest.(check string) "bus occurrence uses canonical correlation id"
      (Agent.Execution_projection.Correlation_id.to_string source.correlation_id) observation.meta.correlation_id;
    Alcotest.(check (option string)) "canonical parent event is preserved"
      (Option.map Agent.Execution_projection.Event_id.to_string source.parent_event_id) observation.meta.parent_event_id;
    Alcotest.(check (option string)) "no synthetic lifecycle causation replaces source facts" None observation.meta.caused_by)
    observations;
  let checkpoint_facts=List.filter_map (fun (event:Agent.Execution_projection.event)->
    match event.payload with
    | Node_updated {update=Checkpoint_snapshot snapshot;_}->Some (event,snapshot)
    | Node_opened _ | Node_updated _ | Node_closed _->None) page.events in
  Alcotest.(check bool) "journal checkpoints exist without a caller sink" true
    (List.exists (fun (_,snapshot)->Checkpoint_snapshot.stage snapshot=After_tool_results_appended) checkpoint_facts);
  let latest=match Agent.Execution_projection.latest_checkpoint projection with
    | Ok (Some latest)->latest |Ok None->Alcotest.fail "latest canonical checkpoint absent"
    | Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  Alcotest.(check bool) "latest checkpoint cites exact committed event and cursor" true
    (List.exists (fun ((event:Agent.Execution_projection.event),snapshot)->
      Agent.Execution_projection.Event_id.equal event.event_id latest.event_id &&
      Agent.Execution_projection.cursor_seq latest.through=event.seq &&
      Checkpoint_snapshot.equal snapshot latest.snapshot) checkpoint_facts);
  let restore ()=match Checkpoint_snapshot.checkpoint latest.snapshot with
    | Ok checkpoint->checkpoint |Error error->Alcotest.fail (Checkpoint_snapshot.error_to_string error) in
  let first_copy=restore () in
  Context.set first_copy.context "reader-mutation" (`Bool true);
  Alcotest.(check bool) "each checkpoint reader receives an independent context" true
    (Context.get (restore ()).context "reader-mutation"=None);
  let reopened=match Agent.open_execution_projection ~runtime ~dir locator with
    | Ok projection->projection |Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  Alcotest.(check bool) "reopened reader retains checkpoint identity and cursor" true
    (match Agent.Execution_projection.latest_checkpoint reopened with
     | Ok (Some restored)->Checkpoint_snapshot.equal restored.snapshot latest.snapshot &&
       Agent.Execution_projection.Event_id.equal restored.event_id latest.event_id &&
       restored.through=latest.through
     | Ok None | Error _ ->false);
  let read_tools projection after limit = match Agent.Execution_projection.read_tool_observations projection
      ~after ~through:page.high_watermark ~limit () with
    | Ok page->page |Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let empty_pages=ref 0 in
  let rec catch_up after acc =
    let next=read_tools projection after 1 in
    if next.observations=[] then incr empty_pages;
    let acc=List.rev_append next.observations acc in
    if next.has_more then catch_up next.next_cursor acc else List.rev acc in
  let catch_up=catch_up (Agent.Execution_projection.beginning_cursor projection) [] in
  Alcotest.(check bool) "filtered empty pages still advance source cursor" true (!empty_pages>0);
  Alcotest.(check bool) "public cursor catch-up matches live canonical observations" true
    (List.map (fun (o:Agent.Execution_projection.tool_observation)->o.event) catch_up=observations);
  match catch_up with
  | [first;second] ->
    (* The receiver accepted the first occurrence and failed before accepting
       the second. Persisted source acknowledgement must not skip the second. *)
    let acknowledgement=first.Agent.Execution_projection.through in
    let reopened=match Agent.open_execution_projection ~runtime ~dir locator with
      | Ok projection->projection |Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
    let settled=match Agent.Execution_projection.settled_tool_invocations reopened with
      | Ok records->records
      | Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
    Alcotest.(check bool) "reconstructed settlement retains live canonical occurrence" true
      (match settled,second.event.payload with
       | [record],ToolCompleted {invocation;_}->
         (match Tool_contract.Invocation.occurrence record.invocation,
                Tool_contract.Invocation.occurrence invocation with
          | Some restored,Some live->Tool_contract.Occurrence.equal restored live
          | None,_ | _,None->false)
       | _->false);
    let retry=read_tools reopened acknowledgement 1024 in
    Alcotest.(check bool) "reopened cursor retries the identical undelivered event" true
      (match retry.observations with [observation]->observation.event=second.event
       | [] | _::_::_ ->false);
    let drained=read_tools reopened retry.next_cursor 1024 in
    Alcotest.(check int) "acknowledged catch-up has no repeat" 0 (List.length drained.observations)
  | [] | [_] | _::_::_::_ ->Alcotest.fail "expected two canonical tool observations"
;;

let test_terminal_disposition_observes_cancellation () =
  with_execution_test_dir "agent_core-agent-terminal-cancel-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let terminal_disposition = ref None in
  let cancel () = raise (Eio.Cancel.Cancelled Exit) in
  let transport : Llm_provider.Llm_transport.t =
    Llm_provider.Llm_transport.custom ({ complete_sync = (fun _request -> cancel ())
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> cancel ())
    })
  in
  let agent =
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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

exception Native_parent_interrupt

type native_cancel_source = Parent_switch | Nested_context | Losing_race
type native_cancel_boundary = Before_callback | Provider_wait | Tool_effect

(* Raising Cancelled directly does not cancel the writer's parent context.
   Exercise real cancellation while the provider or a tool is in flight, then
   read the canonical journal after the caller has finished unwinding. *)
let test_native_parent_cancellation ?(resumed = false) source boundary () =
  with_execution_test_dir "agent_core-native-parent-cancel-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let locator = ref None in
  let terminal_dispositions = ref [] in
  let provider_calls = ref 0 in
  let tool_effects = ref 0 in
  let caller_binding = Eio.Fiber.create_key () in
  let interrupt_before_callback = ref None in
  let interrupted_publication_completed = ref false in
  let resume =
    if not resumed then None
    else
      let internal_runtime =
        match Internal_runtime.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env)
            ~domain_count:1 with
        | Ok runtime -> runtime
        | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error)
      in
      let codec = Internal_codec.of_runtime internal_runtime in
      let saved =
        match Internal_writer.run ~codec ~dir (fun ~sw:_ writer ->
          match Internal_scope.start ~writer ~agent_name:"native-parent-cancel" with
          | Ok scope -> Internal_scope.scope_locator_to_yojson
              (Internal_scope.scope_locator scope)
          | Error error -> Alcotest.fail (Internal_scope.error_to_string error)) with
        | Ok locator -> locator
        | Error error -> Alcotest.fail (Internal_writer.scope_failure_to_string error)
      in
      match Agent.execution_locator_of_yojson saved with
      | Ok locator -> Some locator
      | Error detail -> Alcotest.fail detail
  in
  let execution_store =
    Agent.execution_store ~runtime ~dir ?resume
      ~on_scope_ready:(fun value ->
        locator := Some value;
        (match boundary with
         | Before_callback ->
           (match !interrupt_before_callback with
            | Some interrupt ->
              interrupt ();
              interrupted_publication_completed := true
            | None -> Alcotest.fail "pre-callback cancellation is not installed")
         | Provider_wait | Tool_effect -> ());
        Ok ())
      ~on_terminal_disposition:(fun disposition ->
        Eio.Fiber.check ();
        terminal_dispositions := disposition :: !terminal_dispositions;
        Ok ()) ()
  in
  let run ~sw interrupt =
    interrupt_before_callback := Some interrupt;
    let response () =
      incr provider_calls;
      Alcotest.(check bool) "provider retains the caller's fiber binding" true
        (Eio.Fiber.get caller_binding = Some ());
      Alcotest.(check bool) "provider retains its native scope" true
        (Option.is_some (Internal.Execution_context.agent_scope ()));
      match boundary with
      | Before_callback -> Alcotest.fail "pre-callback cancellation dispatched a provider"
      | Provider_wait ->
        interrupt ();
        Alcotest.fail "provider ignored cancellation"
      | Tool_effect ->
        Provider_mock.tool_use_response
          ~tool_name:"interrupted_effect" ~tool_input:(`Assoc []) () []
    in
    let transport : Llm_provider.Llm_transport.t =
      Llm_provider.Llm_transport.custom ({ complete_sync = (fun _ ->
          { Llm_provider.Llm_transport.response=Ok (response ()); latency_ms=Some 0 })
      ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> Ok (response ()))
      })
    in
    let tool = Tool.create ~name:"interrupted_effect"
        ~description:"Effect whose completion is interrupted" ~parameters:[]
        (fun _ ->
          incr tool_effects;
          Alcotest.(check bool) "tool retains the caller's fiber binding" true
            (Eio.Fiber.get caller_binding = Some ());
          Alcotest.(check bool) "tool retains its child execution authority" true
            (Option.is_some (Internal.Execution_context.child_scope_factory ()));
          interrupt ();
          Alcotest.fail "tool ignored cancellation")
    in
    let agent = Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net:(Eio.Stdenv.net env)
        ~config:{(Types.default_config ~model:"test-model") with name="native-parent-cancel"}
        ~tools:[tool]
        ~options:{Agent.default_options with transport=Some transport;
          provider_config=Some (Provider_mock.to_provider_config ())} ()
    in
    if resumed then Agent.set_state agent
        {(Agent.state agent) with messages=[Types.user_msg "wait for cancellation"]};
    match Eio.Fiber.with_binding caller_binding () (fun () ->
      Agent.run ~sw ~execution_store agent "wait for cancellation") with
    | Ok _ | Error _ -> Alcotest.fail "cancelled native call returned normally"
  in
  (match source with
   | Parent_switch ->
     (match Eio.Switch.run (fun call_sw ->
        run ~sw:call_sw (fun () ->
          Eio.Switch.fail call_sw Native_parent_interrupt;
          Eio.Fiber.yield ())) with
      | () -> Alcotest.fail "parent switch cancellation disappeared"
      | exception Native_parent_interrupt -> ())
   | Nested_context ->
     (match Eio.Cancel.sub (fun context ->
        run ~sw (fun () ->
          Eio.Cancel.cancel context Native_parent_interrupt;
          Eio.Fiber.yield ())) with
      | () -> Alcotest.fail "nested cancellation disappeared"
      | exception Eio.Cancel.Cancelled Native_parent_interrupt -> ())
   | Losing_race ->
     let started, notify_started = Eio.Promise.create () in
     Eio.Fiber.first
       (fun () -> run ~sw (fun () ->
          Eio.Promise.resolve notify_started ();
          Eio.Fiber.await_cancel ()))
       (fun () -> Eio.Promise.await started));
  Alcotest.(check int) "terminal callback runs exactly once" 1
    (List.length !terminal_dispositions);
  (match boundary with
   | Before_callback ->
     Alcotest.(check bool) "locator publication finishes before cancelled callback admission"
       true !interrupted_publication_completed
   | Provider_wait | Tool_effect -> ());
  let disposition = match !terminal_dispositions with
    | [disposition] -> disposition
    | _ -> Alcotest.fail "missing or repeated terminal disposition"
  in
  let recovery = match boundary with
    | Before_callback | Provider_wait -> "retire"
    | Tool_effect -> "operator_repair:effect_outcome_unknown"
  in
  check_terminal_disposition ~outcome:"cancelled" ~recovery (Some disposition);
  Alcotest.(check int) "provider dispatch follows admission"
    (match boundary with Before_callback -> 0 | Provider_wait | Tool_effect -> 1)
    !provider_calls;
  Alcotest.(check int) "tool effect is never repeated"
    (match boundary with Before_callback | Provider_wait -> 0 | Tool_effect -> 1) !tool_effects;
  (match resume, !locator with
   | None, Some _ -> ()
   | Some expected, Some actual ->
     Alcotest.(check bool) "resume preserves the admitted locator" true
       (Agent.execution_locator_to_yojson expected = Agent.execution_locator_to_yojson actual)
   | None, None | Some _, None -> Alcotest.fail "native locator was not published");
  let projection = match !locator with
    | None -> Alcotest.fail "native locator was not published"
    | Some locator ->
      (match Agent.open_execution_projection ~runtime ~dir locator with
       | Ok projection -> projection
       | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error))
  in
  let terminal = match Agent.read_execution_terminal projection with
    | Ok (Some terminal) -> terminal
    | Ok None -> Alcotest.fail "parent cancellation left an open native journal"
    | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error)
  in
  Alcotest.(check bool) "callback agrees with canonical terminal evidence" true
    (terminal.disposition = disposition);
  Alcotest.(check bool) "unknown effect keeps its admitted tool attempt"
    (boundary = Tool_effect) terminal.has_tool_attempts;
  Alcotest.(check int) "cancellation invents no settled tool result" 0
    (List.length terminal.settled_tool_results)
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
  let native_path = Filename.temp_file "agent_core-agent-execution-" ".dir" in
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
         Llm_provider.Llm_transport.custom ({ complete_sync =
             (fun _request ->
               { Llm_provider.Llm_transport.response = next_response ()
               ; latency_ms = Some 0
               })
         ; complete_stream =
             (fun ?on_telemetry:_ ~on_event:_ _request -> next_response ())
         })
       in
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
              Ok { Types.content = "tool-result"; content_blocks = None; _meta = None })
       in
       let options =
         { Agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         ; event_bus = Some event_bus
         ; on_run_complete =
             Some
               (fun succeeded ->
                 Alcotest.(check bool) "completion reports success" true succeeded;
                 completion_cursor := Some (committed_cursor ()))
         }
       in
       let agent =
         Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
       let public_tool_events =
         Event_bus.drain event_subscription
         |> List.filter (fun (event : Event_bus.event) ->
           match event.payload with
           | ToolCalled _ | ToolCompleted _ -> true
           | AgentStarted _
           | AgentCompleted _
           | AgentYielded _
           | AgentInputRequired _
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
  ; unreadable_tool_uses = []
  ; stop_reason = Types.StopToolUse
  ; content =
      List.map (fun (id, name, input) -> Llm_provider.Types.ToolUse { id; name; input }) tool_uses
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
  let native_path = Filename.temp_file "agent_core-agent-resume-" ".dir" in
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
         Llm_provider.Llm_transport.custom ({ complete_sync =
             (fun _request ->
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
         })
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
              Ok { Types.content = "duplicate"; content_blocks = None; _meta = None })
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
         Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net:(Eio.Stdenv.net env) ~config ~tools:[ tool ] ~options ()
       in
       Agent.set_state
         agent
         { provider_binding = None; config
         ; messages =
             [ { origin = Llm_provider.Types.Conversation;  Types.role = User
               ; content = [ Text "run the tool" ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { origin = Llm_provider.Types.Conversation;  Types.role = Assistant
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
  let native_path = Filename.temp_file "agent_core-legacy-tool-approval-" ".dir" in
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
                  Ok { Types.content = "unexpected-effect"; content_blocks = None; _meta = None })
           in
           let hooks =
             { Hooks.empty with
               pre_tool_use =
                 Some
                   (fun _ ->
                     Hooks.ElicitToolApproval
                       { Hooks.question = "Approve legacy durable call?"
                       ; Hooks.because = "policy: unknown tool surface"
                       })
             }
           in
           let agent =
             Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
                 [ Llm_provider.Types.ToolUse
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
      [ { origin = Llm_provider.Types.Conversation;  Types.role = User
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
      [ { origin = Llm_provider.Types.Conversation;  Types.role = User
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
  let native_path = Filename.temp_file "agent_core-agent-settled-" ".dir" in
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
         Llm_provider.Llm_transport.custom ({ complete_sync =
             (fun _request ->
               incr provider_call_count;
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream =
             (fun ?on_telemetry:_ ~on_event:_ _request ->
               incr provider_call_count;
               Ok response)
         })
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
              Ok { Types.content = "duplicate"; content_blocks = None; _meta = None })
       in
       let bus = Event_bus.create () in
       let subscription = Event_bus.subscribe bus
           ~config:(Result.get_ok (Event_bus.subscription_config ~capacity:32 ~overflow:Drop_newest)) in
       let options =
         { Agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         ; event_bus = Some bus
         }
       in
       let agent =
         Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
         { provider_binding = None; config
         ; messages =
             [ { origin = Llm_provider.Types.Conversation;  Types.role = User
               ; content = [ Text "run the tool" ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { origin = Llm_provider.Types.Conversation;  Types.role = Assistant
               ; content =
                   [ ToolUse
                       { id = tool_use_id; name = "durable_tool"; input = tool_input }
                   ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { origin = Llm_provider.Types.Conversation;  Types.role = Tool
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
       let projection = match Agent.open_execution_projection ~runtime ~dir locator with
         | Ok projection -> projection
         | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
       let observations = match Agent.Execution_projection.read_bus_observations projection
           ~after:(Agent.Execution_projection.beginning_cursor projection) ~limit:1024 () with
         | Ok page -> page.observations
         | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
       let completed_zero event = match event.Event_bus.payload with
         | TurnCompleted {turn=0;_} -> true | _ -> false in
       let durable = List.filter (fun (o:Agent.Execution_projection.bus_observation)->completed_zero o.event)
           observations in
       Alcotest.(check int) "resumed completed turn has one canonical close observation"
         (match window with Window_turn_failed -> 0 | Window_provider_closed | Window_turn_closed -> 1)
         (List.length durable);
       let live = List.filter completed_zero (Event_bus.drain subscription) in
       Alcotest.(check int) "live subscription emits only newly committed resume close"
         (match window with Window_provider_closed -> 1 | Window_turn_closed | Window_turn_failed -> 0)
         (List.length live);
       List.iter (fun event -> Alcotest.(check bool) "resume completion keeps canonical source identity" true
         (List.exists (fun (o:Agent.Execution_projection.bus_observation) -> o.event=event) durable)) live;
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

(* The same durable crash window as the tool fixture above, with no ToolUse
   turn: the provider answer and turn are closed, but the root is Running.
   Replay must retain the persisted frontier, not depend on a new AfterTurn. *)
type settled_terminal_expectation =
  | Exact_terminal_replay
  | Refused_terminal_content
  | Refused_terminal_base64
  | Refused_terminal_missing_media

let check_advanced_settled_terminal_replay
      ?(content = [Llm_provider.Types.Text "persisted terminal answer"])
      ?restored_content
      ?(forget_media = false)
      ?(expected = Exact_terminal_replay)
      ()
  =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun runtime_sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime = match Agent.create_execution_runtime ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok value -> value | Error error -> Alcotest.fail (Error.to_string error) in
  let writer_runtime = match Internal_runtime.create ~sw:runtime_sw ~domain_mgr ~domain_count:1 with
    | Ok value -> value | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error) in
  let codec = Internal_codec.of_runtime writer_runtime in
  let native_path = Filename.temp_file "agent-core-settled-terminal-ordinal-" ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
  Fun.protect ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir) (fun () ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    let config = {(Types.default_config ~model:"test-model") with name="settled-terminal-ordinal"} in
    let provider_config = Provider_mock.to_provider_config () in
    let binding = match Internal_binding.of_provider_config ~transport:Internal_binding.Injected provider_config with
      | Ok value -> value | Error detail -> Alcotest.fail detail in
    let persisted = {(Provider_mock.text_response "persisted terminal answer" []) with
      Types.id="persisted-turn-seven";
      content;
      usage=Some {Types.input_tokens=17;output_tokens=23;cache_creation_input_tokens=5;
        cache_read_input_tokens=7;cost_usd=Some 0.125}} in
    let locator_json = ref None in
    let scope_ok = function
      | Ok value -> value | Error error -> Alcotest.fail (Internal_scope.error_to_string error) in
    (match Internal_writer.run ~codec ~dir (fun ~sw:_ writer ->
       let scope = scope_ok (Internal_scope.start ~writer ~agent_name:config.name) in
       locator_json := Some (Internal_scope.scope_locator_to_yojson (Internal_scope.scope_locator scope));
       let turn = scope_ok (Internal_scope.open_turn scope ~ordinal:7) in
       let provider = scope_ok (Internal_scope.open_provider_attempt turn ~ordinal:0 binding) in
       record_durable_provider_response provider persisted;
       scope_ok (Internal_scope.close_provider_attempt provider Internal.Execution_event.Succeeded);
       scope_ok (Internal_scope.close_turn turn Internal.Execution_event.Succeeded)) with
     | Ok () -> () | Error failure -> Alcotest.fail (Internal_writer.scope_failure_to_string failure));
    let locator = match !locator_json with
      | None -> Alcotest.fail "fixture did not retain durable root"
      | Some json -> (match Agent.execution_locator_of_yojson json with
        | Ok value -> value | Error detail -> Alcotest.fail detail) in
    let provider_calls = ref 0 in
    let transport : Llm_provider.Llm_transport.t =
      Llm_provider.Llm_transport.custom ({complete_sync=(fun _ -> incr provider_calls;
         {Llm_provider.Llm_transport.response=Ok (Provider_mock.text_response "unexpected new answer" []);latency_ms=Some 0});
       complete_stream=(fun ?on_telemetry:_ ~on_event:_ _ -> incr provider_calls;
         Ok (Provider_mock.text_response "unexpected new answer" []))}) in
    let after_turns = ref 0 in
    let hooks = {Hooks.empty with after_turn=Some (fun _ -> incr after_turns; Hooks.Continue)} in
    let options = {Agent.default_options with transport=Some transport;
      provider_config=Some provider_config;hooks} in
    let retained_media_store = Agent_core.History.Memory_store.create () in
    let persisted_content =
      Agent_core.History.of_wire_blocks retained_media_store
        (Option.value restored_content ~default:content) |> Result.get_ok in
    let media_store = if forget_media then Agent_core.History.Memory_store.create ()
      else retained_media_store in
    let agent = Agent.create ~media_store ~net:(Eio.Stdenv.net env) ~config ~tools:[] ~options () in
    Agent.set_state agent { provider_binding = None;config;messages=[Types.user_msg "finish this request";
      Types.make_message ~role:Types.Assistant persisted_content];turn_count=8;usage=Types.empty_usage};
    let execution_store = Agent.execution_store ~runtime ~dir ~resume:locator () in
    (match expected, Agent.Advanced.run_blocks ~sw:runtime_sw ~execution_store ~api_strategy:Agent.Sync
       ~on_tool_boundary:(fun _ -> Alcotest.fail "terminal replay reached a tool boundary")
       agent [Types.Text "finish this request"] with
     | Exact_terminal_replay, Ok (Agent.Advanced.Completed completed) ->
       Alcotest.(check int) "replay returns the original nonzero provider ordinal" 7 completed.provider_turn_ordinal;
       Alcotest.(check bool) "persisted response identity, content and usage remain exact" true
         (completed.response=persisted)
     | Refused_terminal_content, Error (Error.Internal _)
     | Refused_terminal_base64, Error (Error.Media (Agent_core.History.Invalid_base64 _))
     | Refused_terminal_missing_media, Error (Error.Media (Agent_core.History.Missing_bytes _)) -> ()
     | (Refused_terminal_content | Refused_terminal_base64 | Refused_terminal_missing_media),
       Ok (Agent.Advanced.Completed _) -> Alcotest.fail "inconsistent terminal replay succeeded"
     | _, Ok (Agent.Advanced.Yielded _ | Agent.Advanced.Terminal_tool_completed _) ->
       Alcotest.fail "terminal replay changed the terminal outcome kind"
     | _, Error error -> Alcotest.fail (Error.to_string error));
    Alcotest.(check int) "settled terminal replay makes no provider call" 0 !provider_calls;
    Alcotest.(check int) "settled terminal replay invokes no new AfterTurn" 0 !after_turns;
    Alcotest.(check int) "restored turn count stays distinct and is not advanced again" 8
      (Agent.state agent).turn_count)
;;

let test_advanced_replays_nonzero_settled_terminal_ordinal () =
  check_advanced_settled_terminal_replay ()
;;

let settled_terminal_media_content encoded =
  [ Llm_provider.Types.Text "persisted terminal answer"
  ; Llm_provider.Types.Image {media_type="image/png";source=Llm_provider.Types.Base64 encoded}
  ; Llm_provider.Types.Document {media_type="application/pdf";source=Llm_provider.Types.Base64 encoded}
  ; Llm_provider.Types.Audio {media_type="audio/wav";source=Llm_provider.Types.Base64 encoded}
  ]
;;

let test_settled_terminal_replay_compares_media_bytes () =
  List.iter (fun encoded ->
    check_advanced_settled_terminal_replay ~content:(settled_terminal_media_content encoded) ())
    ["AA==";"AB=="]
;;

let test_settled_terminal_replay_keeps_content_exact () =
  let content = settled_terminal_media_content "AB==" in
  List.iter (fun restored_content ->
    check_advanced_settled_terminal_replay ~content ~restored_content
      ~expected:Refused_terminal_content ())
    [ settled_terminal_media_content "AQ=="
    ; Llm_provider.Types.Text "different answer" :: List.tl content
    ; List.rev content
    ; [ Llm_provider.Types.Text "persisted terminal answer"
      ; Llm_provider.Types.Image {media_type="image/jpeg";source=Llm_provider.Types.Base64 "AA=="}
      ; Llm_provider.Types.Document {media_type="application/pdf";source=Llm_provider.Types.Base64 "AA=="}
      ; Llm_provider.Types.Audio {media_type="audio/wav";source=Llm_provider.Types.Base64 "AA=="}
      ]
    ]
;;

let test_settled_terminal_replay_refuses_invalid_or_missing_media () =
  check_advanced_settled_terminal_replay
    ~content:(settled_terminal_media_content "abc")
    ~restored_content:(settled_terminal_media_content "AA==")
    ~expected:Refused_terminal_base64 ();
  check_advanced_settled_terminal_replay ~content:(settled_terminal_media_content "AA==")
    ~forget_media:true ~expected:Refused_terminal_missing_media ()
;;

type terminal_resume_entry = Resume_regular | Resume_streaming | Resume_advanced

type terminal_resume_case =
  | Exact_terminal
  | Invalid_terminal_stop of Types.stop_reason
  | Accepted_stop_hook
  | Raising_stop_hook
  | Illegal_stop_hook
  | Replayed_stop_hook
  | Provider_closed_stop_hook
  | Stale_terminal_counter
  | Different_terminal_content
  | Unexpected_terminal_invocation

let test_active_terminal_resumes_committed_checkpoint
    ?(case=Exact_terminal) entry () =
  with_execution_test_dir "agent-core-active-terminal-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let scope_ok = function
    | Ok value -> value | Error error -> Alcotest.fail (Internal_scope.error_to_string error) in
  let config = {(Types.default_config ~model:"test-model") with name="active-terminal"} in
  let provider_config = Provider_mock.to_provider_config () in
  let binding = match Internal_binding.of_provider_config ~transport:Internal_binding.Injected provider_config with
    | Ok value -> value | Error detail -> Alcotest.fail detail in
  let response = {(Provider_mock.text_response "committed final answer" []) with
    Types.id="active-terminal-seven";
    stop_reason=(match case with Invalid_terminal_stop reason->reason | _->Types.EndTurn);
    usage=Some {Types.input_tokens=17;output_tokens=23;cache_creation_input_tokens=5;
      cache_read_input_tokens=7;cost_usd=Some 0.125}} in
  let provider_calls = ref 0 and after_turns = ref 0 and on_stops = ref 0 in
  let on_stop = match case with
    | Accepted_stop_hook | Replayed_stop_hook -> Some (fun _->incr on_stops;Hooks.Continue)
    | Raising_stop_hook | Provider_closed_stop_hook ->
      Some (fun _->incr on_stops;failwith "stop hook failed")
    | Illegal_stop_hook -> Some (fun _->incr on_stops;Hooks.Block "illegal stop decision")
    | Exact_terminal | Invalid_terminal_stop _ | Stale_terminal_counter
    | Different_terminal_content | Unexpected_terminal_invocation -> None in
  let next () = incr provider_calls; Ok (Provider_mock.text_response "unexpected redispatch" []) in
  let transport = Llm_provider.Llm_transport.custom
    {complete_sync=(fun _->{Llm_provider.Llm_transport.response=next ();latency_ms=None});
     complete_stream=(fun ?on_telemetry:_ ~on_event:_ _->next ())} in
  let bus = Event_bus.create () in
  let subscription = Event_bus.subscribe bus
      ~config:(Result.get_ok (Event_bus.subscription_config ~capacity:16 ~overflow:Drop_newest)) in
  let options = {Agent.default_options with transport=Some transport;provider_config=Some provider_config;
    event_bus=Some bus;hooks={Hooks.empty with on_stop;
      after_turn=Some (fun _->incr after_turns;Hooks.Continue)}} in
  let media_store = Agent_core.History.Memory_store.create () in
  let original = Agent.create ~media_store ~net:env#net ~config ~options () in
  let checkpoint_content = match case with
    | Different_terminal_content -> [Llm_provider.Types.Text "another response"]
    | Exact_terminal | Invalid_terminal_stop _ | Accepted_stop_hook | Raising_stop_hook
    | Illegal_stop_hook | Replayed_stop_hook | Provider_closed_stop_hook
    | Stale_terminal_counter | Unexpected_terminal_invocation -> response.content in
  let content = History.of_wire_blocks media_store checkpoint_content |> Result.get_ok in
  let usage = Types.add_usage Types.empty_usage (Option.get response.usage) in
  let collected_turn_count = match case with Stale_terminal_counter->9 | _->8 in
  Agent.set_state original {provider_binding=None;config;turn_count=collected_turn_count;usage;
    messages=[Types.user_msg "finish this request";Types.make_message ~role:Types.Assistant content]};
  let checkpoint = Agent.checkpoint original in
  let writer_runtime = match Internal_runtime.create ~sw ~domain_mgr:env#domain_mgr ~domain_count:1 with
    | Ok value -> value | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error) in
  let locator_json = ref None in
  (match Internal_writer.run ~codec:(Internal_codec.of_runtime writer_runtime) ~dir (fun ~sw:_ writer ->
    let scope = scope_ok (Internal_scope.start ~writer ~agent_name:config.name) in
    locator_json:=Some (Internal_scope.scope_locator_to_yojson (Internal_scope.scope_locator scope));
    let turn = scope_ok (Internal_scope.open_turn scope ~ordinal:7) in
    let provider = scope_ok (Internal_scope.open_provider_attempt turn ~ordinal:0 binding) in
    record_durable_provider_response provider response;
    let fact = match Checkpoint_snapshot.create ~stage:After_assistant_collected checkpoint with
      | Ok value -> value | Error error -> Alcotest.fail (Checkpoint_snapshot.error_to_string error) in
    scope_ok (Internal_scope.record_checkpoint scope fact);
    (match case with
     | Replayed_stop_hook ->
       (* Model a callback that returned before interruption, with its provider
          still open: recovery must not silently assume its success. *)
       (match Hooks.invoke_validated on_stop (Hooks.OnStop {reason=response.stop_reason;response}) with
        | Hooks.Continue -> ()
        | _ -> Alcotest.fail "replay fixture's first stop decision failed")
     | Provider_closed_stop_hook ->
       scope_ok (Internal_scope.close_provider_attempt provider Internal.Execution_event.Succeeded)
     | Unexpected_terminal_invocation ->
       let schedule : Tool_contract.schedule = {planned_index=0;batch_index=0;batch_size=1;
         execution_mode=Tool_contract.Serial} in
       let invocation = Tool_contract.Invocation.create ~tool_use_id:"unexpected-tool"
           ~turn:7 ~schedule ~completion:Tool_contract.Continue_after_success in
       ignore (scope_ok (Internal_scope.open_invocation provider ~invocation
         ~tool_name:"unexpected-tool" ~input:(`Assoc [])))
     | Exact_terminal | Invalid_terminal_stop _ | Accepted_stop_hook | Raising_stop_hook
     | Illegal_stop_hook | Stale_terminal_counter | Different_terminal_content -> ())) with
   | Ok () -> () | Error error -> Alcotest.fail (Internal_writer.scope_failure_to_string error));
  let locator = match Agent.execution_locator_of_yojson (Option.get !locator_json) with
    | Ok value -> value | Error detail -> Alcotest.fail detail in
  let open_projection () = match Agent.open_execution_projection ~runtime ~dir locator with
    | Ok value -> value | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let snapshot = match Agent.Execution_projection.latest_checkpoint (open_projection ()) with
    | Ok (Some value) -> value.snapshot
    | Ok None -> Alcotest.fail "committed assistant checkpoint missing"
    | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let checkpoint = match Checkpoint_snapshot.checkpoint snapshot with
    | Ok value -> value | Error error -> Alcotest.fail (Checkpoint_snapshot.error_to_string error) in
  let agent = match Agent.resume ~media_store ~net:env#net ~checkpoint ~config ~options () with
    | Ok value -> value | Error error -> Alcotest.fail (Agent_checkpoint.resume_error_to_string error) in
  let store = Agent.execution_store ~runtime ~dir ~resume:locator () in
  let result = match entry with
    | Resume_regular -> Agent.run ~sw ~execution_store:store agent "finish this request"
    | Resume_streaming -> Agent.run_stream ~sw ~execution_store:store ~on_event:(fun _->
        Alcotest.fail "recovery invented a new provider stream") agent "finish this request"
    | Resume_advanced ->
      (match Agent.Advanced.run_blocks ~sw ~execution_store:store ~api_strategy:Agent.Sync
          ~on_tool_boundary:(fun _->Alcotest.fail "terminal recovery reached a tool boundary")
          agent [Types.Text "finish this request"] with
       | Ok (Agent.Advanced.Completed completed) ->
         Alcotest.(check int) "terminal recovery keeps canonical nonzero ordinal" 7 completed.provider_turn_ordinal;
         Ok completed.response
       | Ok (Agent.Advanced.Yielded _ | Agent.Advanced.Terminal_tool_completed _) ->
         Alcotest.fail "terminal recovery changed outcome kind"
       | Error error -> Error error) in
  Alcotest.(check int) "terminal recovery does not redispatch provider" 0 !provider_calls;
  Alcotest.(check int) "terminal recovery does not repeat AfterTurn" 0 !after_turns;
  let expect_success = match case with
    | Exact_terminal | Accepted_stop_hook | Replayed_stop_hook | Provider_closed_stop_hook -> true
    | Invalid_terminal_stop _ | Raising_stop_hook | Illegal_stop_hook
    | Stale_terminal_counter | Different_terminal_content | Unexpected_terminal_invocation -> false in
  (match case, result with
   | (Exact_terminal | Accepted_stop_hook | Replayed_stop_hook | Provider_closed_stop_hook), Ok restored ->
     Alcotest.(check bool) "response identity, content, model and usage are exact" true (restored=response)
   | Invalid_terminal_stop _, Error (Error.Agent (UnrecognizedStopReason _)) -> ()
   | (Raising_stop_hook | Illegal_stop_hook), Error (Error.Agent
       (HookExecutionFailed {hook_name;stage;_})) ->
     Alcotest.(check string) "stop hook identity" "on_stop" hook_name;
     Alcotest.(check string) "stop hook stage" "on_stop" stage
   | (Stale_terminal_counter | Different_terminal_content | Unexpected_terminal_invocation),
     Error (Error.Internal _) -> ()
   | _, Error error -> Alcotest.fail (Error.to_string error)
   | _, Ok _ -> Alcotest.fail "invalid terminal frontier was accepted");
  Alcotest.(check int) "stop callback follows the pending output contract"
    (match case with Replayed_stop_hook->2 | Accepted_stop_hook | Raising_stop_hook | Illegal_stop_hook->1
     | Exact_terminal | Invalid_terminal_stop _ | Provider_closed_stop_hook
     | Stale_terminal_counter | Different_terminal_content | Unexpected_terminal_invocation->0)
    !on_stops;
  Alcotest.(check int) "collected checkpoint counter is not advanced again" collected_turn_count (Agent.state agent).turn_count;
  Alcotest.(check bool) "collected checkpoint usage is not charged twice" true ((Agent.state agent).usage=usage);
  let projection = open_projection () in
  (match Agent.read_execution_terminal projection with
   | Ok (Some terminal) -> Alcotest.(check bool) "resumed root matches validated outcome" expect_success
       (terminal.disposition.outcome=Agent.Terminal_succeeded)
   | Ok None -> Alcotest.fail "terminal recovery left root running"
   | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error));
  let completed = Event_bus.drain subscription |> List.filter (fun event ->
    match event.Event_bus.payload with TurnCompleted {turn=7;_}->true | _->false) in
  let page = match Agent.Execution_projection.read_bus_observations projection
      ~after:(Agent.Execution_projection.beginning_cursor projection) ~limit:1024 () with
    | Ok value -> value | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  Alcotest.(check int) "only accepted output emits successful turn close"
    (if expect_success then 1 else 0) (List.length completed);
  List.iter (fun event -> Alcotest.(check bool) "completion keeps committed source envelope" true
    (List.exists (fun (source:Agent.Execution_projection.bus_observation)->source.event=event) page.observations)) completed
;;

type terminal_stop_window = Stop_provider_open | Stop_provider_closed | Stop_turn_closed

type terminal_surface_change =
  | Keep_terminal_surface
  | Remove_terminal_surface
  | Extend_terminal_surface

let test_terminal_stop_reason_owns_tool_content
      ?(only_unregistered_tools=false)
      ?(canonical_only=false)
      ?(surface_change=Keep_terminal_surface)
      ~stop_reason ~window entry () =
  with_execution_test_dir "agent-core-terminal-tool-content-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let scope_ok = function
    | Ok value -> value | Error error -> Alcotest.fail (Internal_scope.error_to_string error) in
  let accepted = match stop_reason with
    | Types.Unknown _ | Types.UnmatchedToolCalls -> false
    | Types.StopToolUse -> Alcotest.fail "this fixture needs a terminal or invalid stop reason"
    | Types.EndTurn | Types.MaxTokens | Types.StopSequence | Types.Refusal | Types.ContentFilter
    | Types.RepetitionTruncation | Types.PauseTurn | Types.Compaction
    | Types.ContextWindowExceeded -> true in
  let effect_count = ref 0 and provider_calls = ref 0 and after_turns = ref 0 and on_stops = ref 0 in
  let on_stop_responses = ref [] in
  let after_turn_responses = ref [] in
  let tool = Tool.create ~name:"must_not_execute" ~description:"Observe an unintended terminal effect"
      ~parameters:[] (fun _ -> incr effect_count;
        Ok {Types.content="unintended effect";content_blocks=None;_meta=None}) in
  let tools = [tool] in
  let config = {(Types.default_config ~model:"test-model") with name="terminal-tool-content"} in
  let provider_config = Provider_mock.to_provider_config () in
  let binding = match Internal_binding.of_provider_config ~transport:Internal_binding.Injected provider_config with
    | Ok value -> value | Error detail -> Alcotest.fail detail in
  let raw_content, admitted_content =
    if canonical_only then
      let content = [Llm_provider.Types.Text "terminal with tool content";
        ToolUse {id="not-a-tool-turn";name="must_not_execute";input=`Assoc []}] in
      content, content
    else if only_unregistered_tools then
      [Llm_provider.Types.Text "terminal with tool content";
        ToolUse {id="dropped-unknown-tool";name="unregistered_terminal_tool";input=`Assoc []}],
      [Llm_provider.Types.Text "terminal with tool content"]
    else
      [Llm_provider.Types.Text "terminal with tool content";
        ToolUse {id="not-a-tool-turn";name="must_not_execute1";input=`Assoc []};
        ToolUse {id="dropped-unknown-tool";name="unregistered_terminal_tool";input=`Assoc []}],
      [Llm_provider.Types.Text "terminal with tool content";
        ToolUse {id="not-a-tool-turn";name="must_not_execute";input=`Assoc []}] in
  let response = {(Provider_mock.text_response "terminal with tool content" []) with
    Types.id="terminal-tool-content-seven";stop_reason;
    content=raw_content;
    usage=Some {Types.input_tokens=17;output_tokens=23;cache_creation_input_tokens=5;
      cache_read_input_tokens=7;cost_usd=Some 0.125}} in
  let next () = incr provider_calls; Ok response in
  let transport = Llm_provider.Llm_transport.custom
    {complete_sync=(fun _->{Llm_provider.Llm_transport.response=next ();latency_ms=None});
     complete_stream=(fun ?on_telemetry:_ ~on_event:_ _->next ())} in
  let active_agent = ref None in
  let extra_tools = List.map (fun name ->
      Tool.create ~name ~description:"Added after response admission" ~parameters:[]
        (fun _ -> incr effect_count;
          Ok {Types.content="unintended added effect";content_blocks=None;_meta=None}))
      ["must_not_execute1";"unregistered_terminal_tool"] in
  let options = {Agent.default_options with transport=Some transport;provider_config=Some provider_config;
    hooks={Hooks.empty with
      on_stop=Some (function
        | Hooks.OnStop {response=stop_response;_} ->
          incr on_stops; on_stop_responses := stop_response :: !on_stop_responses; Hooks.Continue
        | _ -> Hooks.Continue);
      after_turn=Some (function
        | Hooks.AfterTurn {response=actual;_} ->
          incr after_turns;
          after_turn_responses := actual :: !after_turn_responses;
          (match surface_change, !active_agent with
           | Extend_terminal_surface, Some agent -> Agent.extend_tools agent extra_tools
           | Extend_terminal_surface, None -> Alcotest.fail "AfterTurn lost its agent"
           | (Keep_terminal_surface | Remove_terminal_surface), (Some _ | None) -> ());
          Hooks.Continue
        | _ -> Hooks.Continue)}} in
  let media_store = Agent_core.History.Memory_store.create () in
  let create () =
    let agent = Agent.create ~media_store ~net:env#net ~tools ~config ~options () in
    active_agent := Some agent;
    agent in
  (* Establish the fresh public pipeline behavior before constructing a crash. *)
  let fresh = create () in
  let fresh_dir = Eio.Path.(dir / "fresh") in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 fresh_dir;
  let fresh_locator = ref None in
  let fresh_store = Agent.execution_store ~runtime ~dir:fresh_dir
      ~on_scope_ready:(fun value -> fresh_locator:=Some value;Ok ()) () in
  let fresh_result = Agent.run ~sw ~execution_store:fresh_store fresh "finish this request" in
  let admitted_response = match !after_turn_responses with
    | [actual] -> actual
    | _ -> Alcotest.fail "fresh execution did not observe one collected response" in
  (* Public completion adds telemetry to the transport result. Independently
     check the expected admission, then keep that actual complete response as
     the exact authority for hooks, persistence and restart. *)
  Alcotest.(check string) "fresh collection preserves response identity" response.id admitted_response.id;
  Alcotest.(check bool) "fresh collection preserves stop reason" true
    (admitted_response.stop_reason=stop_reason);
  Alcotest.(check bool) "fresh collection applies the expected name admission" true
    (admitted_response.content=admitted_content);
  Alcotest.(check bool) "fresh collection preserves reported usage" true
    (admitted_response.usage=response.usage);
  (match fresh_result with
   | Ok actual when accepted ->
     Alcotest.(check bool) "fresh output keeps terminal stop and admitted tool content" true
       (actual=admitted_response);
     Alcotest.(check bool) "fresh OnStop receives admitted response" true
       (!on_stop_responses=[admitted_response])
   | Error (Error.Agent (UnrecognizedStopReason _)) when not accepted -> ()
   | Error error -> Alcotest.fail (Error.to_string error)
   | Ok _ -> Alcotest.fail "fresh output treated terminal content as a tool turn");
  Alcotest.(check int) "fresh control dispatches exactly one provider call" 1 !provider_calls;
  Alcotest.(check int) "fresh terminal content never invokes the registered tool" 0 !effect_count;
  Alcotest.(check int) "fresh output invokes OnStop only for accepted terminal reasons"
    (if accepted then 1 else 0) !on_stops;
  if accepted then (
    let projection = Agent.open_execution_projection ~runtime ~dir:fresh_dir
        (Option.get !fresh_locator) |> Result.get_ok in
    let page = Agent.Execution_projection.read_page projection
        ~after:(Agent.Execution_projection.beginning_cursor projection) ~limit:1024 ()
      |> Result.get_ok in
    let responses = List.filter_map (fun (event:Agent.Execution_projection.event) ->
        match event.payload with
        | Node_updated {update=Provider_response_snapshot stored;_} -> Some (event.seq,stored)
        | _ -> None) page.events in
    match responses with
    | [(response_seq,stored)] ->
      Alcotest.(check bool) "durable response freezes the actual admission result" true
        (stored=admitted_response);
      Alcotest.(check bool) "response authority precedes the collected checkpoint" true
        (List.exists (fun (event:Agent.Execution_projection.event) -> match event.payload with
           | Node_updated {update=Checkpoint_snapshot snapshot;_} ->
             Checkpoint_snapshot.stage snapshot=After_assistant_collected && response_seq<event.seq
           | _ -> false) page.events)
    | _ -> Alcotest.fail "fresh execution did not persist one provider response");
  provider_calls:=0;after_turns:=0;on_stops:=0;on_stop_responses:=[];after_turn_responses:=[];
  let collected_state = Agent.state fresh in
  let usage = collected_state.usage in
  Agent.set_state fresh {collected_state with turn_count=8};
  let checkpoint = Agent.checkpoint fresh in
  let writer_runtime = match Internal_runtime.create ~sw ~domain_mgr:env#domain_mgr ~domain_count:1 with
    | Ok value -> value | Error error -> Alcotest.fail (Internal_runtime.create_error_to_string error) in
  let locator_json = ref None in
  (match Internal_writer.run ~codec:(Internal_codec.of_runtime writer_runtime) ~dir (fun ~sw:_ writer ->
    let scope = scope_ok (Internal_scope.start ~writer ~agent_name:config.name) in
    locator_json:=Some (Internal_scope.scope_locator_to_yojson (Internal_scope.scope_locator scope));
    let turn = scope_ok (Internal_scope.open_turn scope ~ordinal:7) in
    let provider = scope_ok (Internal_scope.open_provider_attempt turn ~ordinal:0 binding) in
    record_durable_provider_response provider admitted_response;
    let fact = match Checkpoint_snapshot.create ~stage:After_assistant_collected checkpoint with
      | Ok value -> value | Error error -> Alcotest.fail (Checkpoint_snapshot.error_to_string error) in
    scope_ok (Internal_scope.record_checkpoint scope fact);
    match window with
    | Stop_provider_open -> ()
    | Stop_provider_closed | Stop_turn_closed ->
      scope_ok (Internal_scope.close_provider_attempt provider Internal.Execution_event.Succeeded);
      (match window with
       | Stop_turn_closed -> scope_ok (Internal_scope.close_turn turn Internal.Execution_event.Succeeded)
       | Stop_provider_open | Stop_provider_closed -> ())) with
   | Ok () -> () | Error error -> Alcotest.fail (Internal_writer.scope_failure_to_string error));
  let locator = Agent.execution_locator_of_yojson (Option.get !locator_json) |> Result.get_ok in
  let resume_tools = match surface_change with
    | Remove_terminal_surface -> []
    | Keep_terminal_surface -> tools
    | Extend_terminal_surface -> tools @ extra_tools in
  let agent = match Agent.resume ~media_store ~net:env#net ~tools:resume_tools ~checkpoint ~config ~options () with
    | Ok value -> value | Error error -> Alcotest.fail (Agent_checkpoint.resume_error_to_string error) in
  let store = Agent.execution_store ~runtime ~dir ~resume:locator () in
  let result = match entry with
    | Resume_regular -> Agent.run ~sw ~execution_store:store agent "finish this request"
    | Resume_streaming -> Agent.run_stream ~sw ~execution_store:store ~on_event:(fun _->
        Alcotest.fail "terminal recovery invented a provider stream") agent "finish this request"
    | Resume_advanced ->
      (match Agent.Advanced.run_blocks ~sw ~execution_store:store ~api_strategy:Agent.Sync
          ~on_tool_boundary:(fun _->Alcotest.fail "terminal recovery reached a tool boundary")
          agent [Types.Text "finish this request"] with
       | Ok (Agent.Advanced.Completed completed) ->
         Alcotest.(check int) "restored terminal keeps its nonzero ordinal" 7 completed.provider_turn_ordinal;
         Ok completed.response
       | Ok _ -> Alcotest.fail "terminal recovery changed the outcome kind"
       | Error error -> Error error) in
  (match result with
   | Ok actual when accepted -> Alcotest.(check bool) "recovery returns the admitted persisted response"
       true (actual=admitted_response)
   | Error (Error.Agent (UnrecognizedStopReason _)) when not accepted -> ()
   | Error error -> Alcotest.fail (Error.to_string error)
   | Ok _ -> Alcotest.fail "invalid terminal stop was accepted");
  Alcotest.(check int) "recovery never invokes the registered tool" 0 !effect_count;
  Alcotest.(check int) "recovery never redispatches provider" 0 !provider_calls;
  Alcotest.(check int) "recovery never repeats AfterTurn" 0 !after_turns;
  Alcotest.(check int) "only an active accepted provider runs pending OnStop"
    (match accepted,window with true,Stop_provider_open->1 | _->0) !on_stops;
  Alcotest.(check bool) "active recovery passes admitted response to OnStop" true
    (match accepted,window with true,Stop_provider_open-> !on_stop_responses=[admitted_response] | _-> !on_stop_responses=[]);
  Alcotest.(check int) "collected counter is unchanged" 8 (Agent.state agent).turn_count;
  Alcotest.(check bool) "collected usage is not charged twice" true ((Agent.state agent).usage=usage);
  let projection = Agent.open_execution_projection ~runtime ~dir locator |> Result.get_ok in
  let page = Agent.Execution_projection.read_tool_observations projection
      ~after:(Agent.Execution_projection.beginning_cursor projection) ~limit:1024 () |> Result.get_ok in
  Alcotest.(check int) "terminal content creates no canonical tool observation" 0 (List.length page.observations);
  match Agent.read_execution_terminal projection with
  | Ok (Some terminal) -> Alcotest.(check bool) "root outcome follows the persisted stop reason" accepted
      (terminal.disposition.outcome=Agent.Terminal_succeeded)
  | Ok None -> Alcotest.fail "terminal recovery left the root running"
  | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error)
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
  let native_path = Filename.temp_file "agent_core-terminal-durability-" ".dir" in
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
         | [ Llm_provider.Types.ToolUse { id; _ } ] -> id
         | _ -> Alcotest.fail "terminal fixture did not produce one exact ToolUse"
       in
       let transport : Llm_provider.Llm_transport.t =
         Llm_provider.Llm_transport.custom ({ complete_sync =
             (fun _request ->
               incr provider_calls;
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream =
             (fun ?on_telemetry:_ ~on_event:_ _request ->
               incr provider_calls;
               Ok response)
         })
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
                  Ok { Types.content = "effect committed"; content_blocks = None; _meta = None })
           in
           let agent =
             Internal_agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
                run_pipeline_turn ~sw ~api_strategy:Internal_pipeline.Sync agent)
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
      Filename.temp_file ("agent_core-agent-malformed-terminal-" ^ label) ".dir"
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
                      Ok { Types.content = "unexpected-effect"; content_blocks = None; _meta = None })
               in
               let assistant_content =
                 List.map
                   (fun (id, name, input) -> Types.ToolUse { id; name; input })
                   restored
               in
               let messages =
                 let assistant =
                   { origin = Llm_provider.Types.Conversation;  Types.role = Assistant
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
                   ; { origin = Llm_provider.Types.Conversation;  Types.role = Tool
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
                 Internal_agent.create ~media_store:(Agent_core.History.Memory_store.create ())
                   ~net:(Eio.Stdenv.net env)
                   ~config
                   ~tools:[ tool ]
                   ~options
                   ()
               in
               Internal_agent.set_state
                 agent
                 { provider_binding = None; config; messages; turn_count = 1; usage = Types.empty_usage };
               let outcome =
                 Internal.Execution_context.with_agent_scope scope (fun () ->
                   Internal.Execution_context.with_resume_once (fun () ->
                     run_pipeline_turn
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
                 Internal_agent.create ~media_store:(Agent_core.History.Memory_store.create ())
                   ~net:(Eio.Stdenv.net env)
                   ~config
                   ~tools:[]
                   ~options
                   ()
               in
               Internal_agent.set_state
                 agent
                 { provider_binding = None; config
                 ; messages =
                     [ Types.user_msg "run malformed authority"
                     ; { origin = Llm_provider.Types.Conversation;  Types.role = Assistant
                       ; content = assistant_content
                       ; name = None
                       ; tool_call_id = None
                       ; metadata = []
                       }
                     ; { origin = Llm_provider.Types.Conversation;  Types.role = Tool
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
                      run_pipeline_turn
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

let test_agent_run_replays_stale_checkpoint_terminal_settlement () =
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
    let native_path = Filename.temp_file ("agent_core-agent-precheckpoint-" ^ label) ".dir" in
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
           Llm_provider.Llm_transport.custom ({ complete_sync =
               (fun _request ->
                 { Llm_provider.Llm_transport.response = Ok (next_response ())
                 ; latency_ms = Some 0
                 })
           ; complete_stream =
               (fun ?on_telemetry:_ ~on_event:_ _request -> Ok (next_response ()))
           })
         in
         let options =
           { Agent.default_options with
             transport = Some transport
           ; provider_config = Some (Provider_mock.to_provider_config ())
           ; context_injector =
               Some
                 (fun ~tool_name:_ ~input:_ ~output:_ ->
                    Some { Hooks.context_updates = []; extra_messages = [] })
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
                Ok { Types.content = "settled-before-checkpoint"; content_blocks = None; _meta = None })
         in
         let saved_checkpoint = ref None in
         let initial_agent =
           Internal_agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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
                 raise Sys.Break
               | Agent.After_context_injection ->
                 Alcotest.fail "fixture unexpectedly reached context injection"
               | Agent.After_input_wait_changed
               | Agent.After_rejected_response_dropped ->
                 Alcotest.fail "the pipeline never writes the dropped-response stage")
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
                  run_pipeline_turn
                    ~sw
                    ~api_strategy:Internal_pipeline.Sync
                    initial_agent)
              with
              | exception Sys.Break -> ()
              | Error error -> Alcotest.fail (Error.to_string error)
              | Ok _ -> Alcotest.fail "reserved checkpoint delivery interruption did not escape")
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
                    Ok { Types.content = "duplicate"; content_blocks = None; _meta = None })
             ]
         in
         let resumed_stages = ref [] in
         let resumed_agent =
           (Agent.resume ~media_store:(Agent_core.History.Memory_store.create ())
             ~net:(Eio.Stdenv.net env)
             ~checkpoint
             ~tools:resumed_tools
             ~options
             ~config
             ~checkpoint_sink:(fun snapshot ->
               resumed_stages := snapshot.Agent.stage :: !resumed_stages;
               Ok ())
             () |> Result.get_ok)
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
         Alcotest.(check bool)
           (label ^ " empty injection preserves the tool-result recovery boundary")
           true
           (List.rev !resumed_stages = [ Agent.After_tool_results_appended ]);
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
  let native_path = Filename.temp_file "agent_core-agent-all-blocked-" ".dir" in
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
         Llm_provider.Llm_transport.custom ({ complete_sync =
             (fun _request ->
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
         })
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
              Ok { Types.content = "duplicate"; content_blocks = None; _meta = None })
       in
       let options =
         { Agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         }
       in
       let agent =
         Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net:(Eio.Stdenv.net env) ~config ~tools:[ tool ] ~options ()
       in
       (* Restored checkpoint: the blocked ToolResult is present (a blocked call
          still emits a model-visible ToolResult) even though no Tool_invocation
          node exists. Only the tool_use_id drives the resume classification. *)
       Agent.set_state
         agent
         { provider_binding = None; config
         ; messages =
             [ { origin = Llm_provider.Types.Conversation;  Types.role = User
               ; content = [ Text "run the tool" ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { origin = Llm_provider.Types.Conversation;  Types.role = Assistant
               ; content =
                   [ ToolUse
                       { id = tool_use_id; name = "durable_tool"; input = tool_input }
                   ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { origin = Llm_provider.Types.Conversation;  Types.role = Tool
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
  let native_path = Filename.temp_file "agent_core-agent-resume-yield-" ".dir" in
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
         Llm_provider.Llm_transport.custom ({ complete_sync =
             (fun _request ->
               { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
         ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
         })
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
              Ok { Types.content = "executed"; content_blocks = None; _meta = None })
       in
       let tracer, spans = recording_tracer () in
       let options =
         { Agent.default_options with
           transport = Some transport
         ; provider_config = Some (Provider_mock.to_provider_config ())
         ; tracer
         }
       in
       let agent =
         Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net:(Eio.Stdenv.net env) ~config ~tools:[ tool ] ~options ()
       in
       (* Restored checkpoint: the ToolUse is collected, but no ToolResults exist
          yet, so resume re-executes the tools and must fire [on_yield] before the
          first tool implementation runs. *)
       Agent.set_state
         agent
         { provider_binding = None; config
         ; messages =
             [ { origin = Llm_provider.Types.Conversation;  Types.role = User
               ; content = [ Text "run the tool" ]
               ; name = None
               ; tool_call_id = None
               ; metadata = []
               }
             ; { origin = Llm_provider.Types.Conversation;  Types.role = Assistant
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
       let (), records =
         with_debug_log_records (fun () ->
           match
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
           | Error error ->
             Alcotest.failf "resume run failed: %s" (Error.to_string error))
       in
       Alcotest.(check int) "tool executes once on resume" 1 !effect_count;
       Alcotest.(check int)
         "on_yield fires on the resume turn (fresh/resume parity)"
         1
         !yield_count;
       (* The restored counter is 1 while the journal replays durable turn 0.
          The replayed tool turn and the fresh turn that follows must be logged
          and traced as 0 then 1: the ordinal comes from the resolved frontier,
          not from [turn_count], which would name both as 1. *)
       Alcotest.(check (list (triple string int string)))
         "replayed turn 0 then fresh turn 1 in the turn log"
         [ "debug", 0, "tools_executed"; "debug", 1, "end_turn" ]
         (turn_completed_records records);
       Alcotest.(check (list int))
         "agent_turn spans open under the replayed then fresh ordinal"
         [ 0; 1 ]
         (agent_turn_span_ordinals (spans ())))
;;

(* ── Runner ──────────────────────────────────────────────── *)

let test_text_response_persists_actual_provider_binding () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let snapshots = ref [] in
  let agent = make_pipeline_test_agent ~net:(Eio.Stdenv.net env)
    ~response:(pipeline_response EndTurn) in
  let agent = {agent with Internal_agent.checkpoint_sink=Some(fun snapshot ->
    snapshots := snapshot::!snapshots; Ok ())} in
  Alcotest.(check bool) "unexecuted agent has no invented source" true
    (agent.state.provider_binding=None);
  match run_pipeline_turn ~sw ~api_strategy:Internal_pipeline.Sync agent with
  | Error error -> Alcotest.fail (Error.to_string error)
  | Ok (Internal_pipeline.ToolsExecuted _ | Internal_pipeline.TerminalToolCompleted _) ->
    Alcotest.fail "expected plain completed response"
  | Ok (Internal_pipeline.Complete response) ->
    let module Source = Llm_provider.Types.Reasoning_source in
    let source = match Option.bind response.telemetry (fun t -> t.Types.reasoning_source) with
      | Some source -> source | None -> Alcotest.fail "actual response source missing" in
    let same = function Some actual -> Source.equal source actual | None -> false in
    Alcotest.(check bool) "text-only state records actual collected source" true (same agent.state.provider_binding);
    let checkpoint = Agent_checkpoint.build_checkpoint ~pending_input:agent.pending_input
      ~state:agent.state ~tools:agent.tools ~context:agent.context
      () in
    let restored = Checkpoint.of_json (Checkpoint.to_json checkpoint) |> Result.get_ok in
    Alcotest.(check bool) "checkpoint retains actual source" true (same restored.provider_binding);
    let clone = Internal_agent.clone agent in
    Alcotest.(check bool) "clone retains producer" true (same clone.state.provider_binding);
    Alcotest.(check bool) "turn sink sees producer" true
      (List.exists(fun snapshot -> same (snapshot : Agent.checkpoint_snapshot).checkpoint.provider_binding) !snapshots)
;;

type nested_tool_audience = Shared_tool_bus | Distinct_tool_bus | No_child_tool_bus

let test_nested_tool_observation_audiences audience ~concurrent () =
  with_execution_test_dir "agent_core-tool-audiences-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let root_bus=Event_bus.create () and child_bus=Event_bus.create () in
  let subscribe bus=let config=match Event_bus.subscription_config ~capacity:32 ~overflow:Event_bus.Drop_newest with
    | Ok config->config |Error _->Alcotest.fail "invalid audience fixture" in
    Event_bus.subscribe ~config ~filter:Event_bus.filter_tools_only bus in
  let root_sub=subscribe root_bus and child_sub=subscribe child_bus in
  let subscribe_all bus = Event_bus.subscribe bus
      ~config:(Result.get_ok (Event_bus.subscription_config ~capacity:128 ~overflow:Drop_newest)) in
  let root_all = subscribe_all root_bus and child_all = subscribe_all child_bus in
  let child_target=match audience with Shared_tool_bus->Some root_bus
    | Distinct_tool_bus->Some child_bus |No_child_tool_bus->None in
  let parent_calls=ref 0 and child_calls=ref 0 in
  let both_started,release_both=Eio.Promise.create () in
  let local_agent name bus tools responses =
    let responses=ref responses in
    let next ()=match !responses with response::rest->responses:=rest;Ok response
      | []->Alcotest.fail "nested provider retried completed work" in
    let transport=Llm_provider.Llm_transport.custom
      {complete_sync=(fun _->{Llm_provider.Llm_transport.response=next ();latency_ms=None});
       complete_stream=(fun ?on_telemetry:_ ~on_event:_ _->next ())} in
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net:(Eio.Stdenv.net env) ~tools
      ~config:{(Types.default_config ~model:"test-model") with name}
      ~options:{Agent.default_options with transport=Some transport;event_bus=bus;
        provider_config=Some (Provider_mock.to_provider_config ())} () in
  let parent_tool=Tool.create
      ~descriptor:(Tool.ordinary_descriptor (if concurrent then Concurrent else Serial))
      ~name:"same_tool" ~description:"recursively invoke child with its own audience" ~parameters:[]
      (fun _ ->
        incr parent_calls;
        let child_tool=Tool.create ~name:"same_tool" ~description:"child effect" ~parameters:[]
            (fun _ ->
              incr child_calls;
              if concurrent then (
                if !child_calls=2 then Eio.Promise.resolve release_both ();
                Eio.Promise.await both_started);
              Ok {Types.content="child settled";content_blocks=None;_meta=None}) in
        (* Provider tool-use IDs, names and schedules deliberately overlap
           across recursive Agent runs. Only canonical run/node authority joins. *)
        let child=local_agent "child-audience" child_target [child_tool]
            [durable_tool_response ["same-provider-id","same_tool",`Assoc []];
             Provider_mock.text_response "child done" []] in
        match Agent.run ~sw child "child" with
        | Ok _->Ok {Types.content="parent settled";content_blocks=None;_meta=None}
        | Error error->Alcotest.fail (Error.to_string error)) in
  let roots=if concurrent then ["same-provider-id";"second-parent-id"] else ["same-provider-id"] in
  let root=local_agent "root-audience" (Some root_bus) [parent_tool]
      [durable_tool_response (List.map (fun id->id,"same_tool",`Assoc []) roots);
       Provider_mock.text_response "root done" []] in
  let locator=ref None in
  let store=Agent.execution_store ~runtime ~dir
      ~on_scope_ready:(fun value->locator:=Some value;Ok ()) () in
  (match Agent.run ~sw ~execution_store:store root "root" with
   | Ok _->() |Error error->Alcotest.fail (Error.to_string error));
  let count=List.length roots in
  Alcotest.(check int) "each parent effect runs once" count !parent_calls;
  Alcotest.(check int) "each recursive child effect runs once" count !child_calls;
  let root_events=Event_bus.drain root_sub and child_events=Event_bus.drain child_sub in
  let agent_name (event:Event_bus.event)=match event.payload with
    | ToolCalled {agent_name;_} | ToolCompleted {agent_name;_}->agent_name
    | AgentStarted _ | AgentCompleted _ | AgentYielded _ | AgentInputRequired _ | AgentFailed _
    | TurnStarted _ | TurnReady _ | TurnCompleted _ | HandoffRequested _ | HandoffCompleted _
    | ElicitationCompleted _ | ToolApprovalCompleted _ | InferenceTelemetry _ | Custom _ ->
      Alcotest.fail "non-tool event escaped audience filter" in
  let expected_root=match audience with Shared_tool_bus->4*count
    | Distinct_tool_bus | No_child_tool_bus->2*count in
  let expected_child=match audience with Distinct_tool_bus->2*count
    | Shared_tool_bus | No_child_tool_bus->0 in
  Alcotest.(check int) "root bus keeps explicit audience" expected_root (List.length root_events);
  Alcotest.(check int) "child bus keeps explicit audience" expected_child (List.length child_events);
  (match audience with
   | Shared_tool_bus->()
   | Distinct_tool_bus | No_child_tool_bus->
     Alcotest.(check bool) "child observations never leak to root audience" true
       (List.for_all (fun event->agent_name event="root-audience") root_events));
  let ordered events =
    let rec loop previous = function
      | []->true
      | (event:Event_bus.event)::rest->match event.meta.seq with
        | Some seq when seq>previous->loop seq rest
        | None | Some _->false in loop 0 events in
  Alcotest.(check bool) "shared audience preserves global canonical order" true (ordered root_events);
  Alcotest.(check bool) "distinct audience preserves canonical order" true (ordered child_events);
  let locator=match !locator with Some locator->locator |None->Alcotest.fail "nested locator missing" in
  let projection=match Agent.open_execution_projection ~runtime ~dir locator with
    | Ok projection->projection |Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let page=match Agent.Execution_projection.read_tool_observations projection
      ~after:(Agent.Execution_projection.beginning_cursor projection) ~limit:1024 () with
    | Ok page->page |Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  Alcotest.(check int) "canonical source retains every child regardless of audience" (4*count)
    (List.length page.observations);
  let delivered=root_events@child_events in
  List.iter (fun (event:Event_bus.event)->
    Alcotest.(check bool) "audience event is the exact committed source observation" true
      (List.exists (fun (source:Agent.Execution_projection.tool_observation)->source.event=event) page.observations)) delivered;
  let canonical event = match event.Event_bus.payload with
    | TurnStarted _ | TurnReady _ | TurnCompleted _ | InferenceTelemetry _ | ToolCalled _ | ToolCompleted _ -> true
    | AgentStarted _ | AgentCompleted _ | AgentYielded _ | AgentInputRequired _ | AgentFailed _
    | HandoffRequested _ | HandoffCompleted _ | ElicitationCompleted _ | ToolApprovalCompleted _ | Custom _ -> false in
  let name event = match event.Event_bus.payload with
    | TurnStarted {agent_name;_} | TurnReady {agent_name;_} | TurnCompleted {agent_name;_}
    | InferenceTelemetry {agent_name;_} | ToolCalled {agent_name;_} | ToolCompleted {agent_name;_} -> agent_name
    | _ -> Alcotest.fail "expected canonical bus projection" in
  let all = match Agent.Execution_projection.read_bus_observations projection
      ~after:(Agent.Execution_projection.beginning_cursor projection) ~limit:1024 () with
    | Ok page -> List.map (fun (source:Agent.Execution_projection.bus_observation) -> source.event) page.observations
    | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  let root_all = List.filter canonical (Event_bus.drain root_all)
  and child_all = List.filter canonical (Event_bus.drain child_all) in
  let expected_root = match audience with
    | Shared_tool_bus -> all
    | Distinct_tool_bus | No_child_tool_bus -> List.filter (fun event -> name event="root-audience") all in
  let expected_child = match audience with
    | Distinct_tool_bus -> List.filter (fun event -> name event="child-audience") all
    | Shared_tool_bus | No_child_tool_bus -> [] in
  Alcotest.(check bool) "turn and tool observations share ordered root audience" true
    (root_all=expected_root && ordered root_all);
  Alcotest.(check bool) "turn and tool observations preserve explicit child audience" true
    (child_all=expected_child && ordered child_all)
;;

let test_unattempted_tool_has_no_bus_execution_observation () =
  with_execution_test_dir "agent_core-tool-blocked-observation-"
  @@ fun ~env ~sw ~runtime ~dir ->
  let bus=Event_bus.create () in
  let subscription=Event_bus.subscribe ~filter:Event_bus.filter_tools_only
      ~config:(Result.get_ok (Event_bus.subscription_config ~capacity:16 ~overflow:Drop_newest)) bus in
  let effects=ref 0 and locator=ref None in
  let tool=Tool.create ~name:"blocked_tool" ~description:"must not run" ~parameters:[]
      (fun _->incr effects;Ok {Types.content="wrong";content_blocks=None;_meta=None}) in
  let responses=ref [durable_tool_response ["blocked","blocked_tool",`Assoc []];Provider_mock.text_response "blocked" []] in
  let next ()=match !responses with response::rest->responses:=rest;Ok response
    | []->Alcotest.fail "blocked provider fixture exhausted" in
  let transport=Llm_provider.Llm_transport.custom
    {complete_sync=(fun _->{Llm_provider.Llm_transport.response=next ();latency_ms=None});
     complete_stream=(fun ?on_telemetry:_ ~on_event:_ _->next ())} in
  let agent=Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net:(Eio.Stdenv.net env) ~tools:[tool]
      ~config:{(Types.default_config ~model:"test-model") with name="blocked-observation"}
      ~options:{Agent.default_options with transport=Some transport;event_bus=Some bus;
        provider_config=Some (Provider_mock.to_provider_config ());
        hooks={Hooks.empty with pre_tool_use=Some (fun _->Block "not admitted")}} () in
  let store=Agent.execution_store ~runtime ~dir ~on_scope_ready:(fun value->locator:=Some value;Ok ()) () in
  (match Agent.run ~sw ~execution_store:store agent "blocked" with
   | Ok _->() |Error error->Alcotest.fail (Error.to_string error));
  Alcotest.(check int) "blocked effect is never invoked" 0 !effects;
  Alcotest.(check int) "blocked effect invents no execution bus event" 0 (List.length (Event_bus.drain subscription));
  let projection=match Agent.open_execution_projection ~runtime ~dir (Option.get !locator) with
    | Ok projection->projection |Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error) in
  match Agent.Execution_projection.read_tool_observations projection
      ~after:(Agent.Execution_projection.beginning_cursor projection) ~limit:1024 () with
  | Ok page->Alcotest.(check int) "public reader invents no unattempted execution" 0 (List.length page.observations)
  | Error error->Alcotest.fail (Agent.Execution_projection.error_to_string error)
;;

let () =
  Alcotest.run
    "Pipeline"
    [ ( "terminal stop authority",
        List.map (fun (name, stop_reason, window, entry) ->
          Alcotest.test_case name `Quick
            (test_terminal_stop_reason_owns_tool_content ~stop_reason ~window entry))
          ["active MaxTokens with tool content completes without effects", Types.MaxTokens, Stop_provider_open, Resume_regular;
           "active Refusal with tool content completes without effects", Refusal, Stop_provider_open, Resume_regular;
           "active injected EndTurn with tool content completes without effects", EndTurn, Stop_provider_open, Resume_regular;
           "provider-closed MaxTokens with tool content replays without hooks", MaxTokens, Stop_provider_closed, Resume_regular;
           "provider-closed Refusal with tool content replays without hooks", Refusal, Stop_provider_closed, Resume_regular;
           "provider-closed injected EndTurn with tool content replays without hooks", EndTurn, Stop_provider_closed, Resume_regular;
           "turn-closed MaxTokens with tool content replays without hooks", MaxTokens, Stop_turn_closed, Resume_regular;
           "turn-closed Refusal with tool content replays without hooks", Refusal, Stop_turn_closed, Resume_regular;
           "turn-closed injected EndTurn with tool content replays without hooks", EndTurn, Stop_turn_closed, Resume_regular;
           "streaming active MaxTokens with tool content completes without effects", MaxTokens, Stop_provider_open, Resume_streaming;
           "Advanced active MaxTokens with tool content completes without effects", MaxTokens, Stop_provider_open, Resume_advanced;
           "unknown stop with tool content remains rejected", Unknown "unknown-stop", Stop_provider_open, Resume_regular;
           "unmatched tool calls remain rejected with tool content", UnmatchedToolCalls, Stop_provider_open, Resume_regular]
        @ [ Alcotest.test_case
              "active Refusal with only unregistered tool content completes after admission"
              `Quick
              (test_terminal_stop_reason_owns_tool_content
                 ~only_unregistered_tools:true
                 ~stop_reason:Refusal
                 ~window:Stop_provider_open
                 Resume_regular)
          ; Alcotest.test_case
              "turn-closed Refusal with only unregistered tool content replays after admission"
              `Quick
              (test_terminal_stop_reason_owns_tool_content
                 ~only_unregistered_tools:true
                 ~stop_reason:Refusal
                 ~window:Stop_turn_closed
                 Resume_regular)
          ]
        @ List.concat_map (fun (label,window) ->
            [ Alcotest.test_case (label ^ " canonical terminal survives tool removal") `Quick
                (test_terminal_stop_reason_owns_tool_content
                   ~canonical_only:true ~surface_change:Remove_terminal_surface
                   ~stop_reason:Refusal ~window Resume_regular)
            ; Alcotest.test_case (label ^ " admission survives AfterTurn tool additions") `Quick
                (test_terminal_stop_reason_owns_tool_content
                   ~surface_change:Extend_terminal_surface
                   ~stop_reason:MaxTokens ~window Resume_regular)
            ])
            ["active",Stop_provider_open;
             "provider-closed",Stop_provider_closed;
             "turn-closed",Stop_turn_closed])
    ; ( "mock_responses"
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
      , [ Alcotest.test_case "text-only actual provider binding" `Quick test_text_response_persists_actual_provider_binding
        ; Alcotest.test_case "initial state" `Quick test_agent_initial_state
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
            "provider context retention survives sync, checkpoint and stream"
            `Quick
            test_provider_context_retention
        ; Alcotest.test_case
            "turn-scoped lane retains the canonical carrier"
            `Quick
            test_turn_scoped_lane_retains_the_canonical_carrier
        ; Alcotest.test_case
            "effective provider config drives lifecycle without inferred cost"
            `Quick
            test_effective_provider_config_drives_lifecycle_without_inferred_cost
        ; Alcotest.test_case
            "provider turn identity spans multiturn tool loop"
            `Quick
            test_provider_turn_identity_is_shared_across_multiturn_tool_loop
        ; Alcotest.test_case
            "one turn: no INFO turn record from agent core, DEBUG line and span carry the \
             AfterTurn ordinal (audit R1)"
            `Quick
            test_turn_completed_log_carries_the_hook_turn_ordinal
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
            "undeclared native stream uses synchronous fallback"
            `Quick
            (test_stream_route_uses_declared_support ~declared_streaming:false)
        ; Alcotest.test_case
            "declared native stream carries exact raw trace run id"
            `Quick
            (test_stream_route_uses_declared_support ~declared_streaming:true)
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
      , [ Alcotest.test_case "of_core_error" `Quick test_error_domain_of_core_error
        ; Alcotest.test_case "roundtrip" `Quick test_error_domain_roundtrip
        ; Alcotest.test_case "with_stage" `Quick test_error_domain_with_stage
        ; Alcotest.test_case "is_retryable" `Quick test_error_domain_is_retryable
        ; Alcotest.test_case "provider errors" `Quick test_error_domain_provider_errors

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
            "Advanced settled terminal replay retains nonzero ordinal without provider or AfterTurn"
            `Quick
            test_advanced_replays_nonzero_settled_terminal_ordinal
        ; Alcotest.test_case
            "settled terminal replay compares media bytes across base64 spellings"
            `Quick
            test_settled_terminal_replay_compares_media_bytes
        ; Alcotest.test_case
            "settled terminal replay keeps bytes text order and MIME exact"
            `Quick
            test_settled_terminal_replay_keeps_content_exact
        ; Alcotest.test_case
            "settled terminal replay refuses malformed and unavailable media"
            `Quick
            test_settled_terminal_replay_refuses_invalid_or_missing_media
        ; Alcotest.test_case
            "regular resumes collected terminal before provider close" `Quick
            (test_active_terminal_resumes_committed_checkpoint Resume_regular)
        ; Alcotest.test_case
            "streaming resumes collected terminal before provider close" `Quick
            (test_active_terminal_resumes_committed_checkpoint Resume_streaming)
        ; Alcotest.test_case
            "Advanced resumes collected terminal before provider close" `Quick
            (test_active_terminal_resumes_committed_checkpoint Resume_advanced)
        ; Alcotest.test_case "terminal resume rejects unknown stop" `Quick
            (test_active_terminal_resumes_committed_checkpoint
              ~case:(Invalid_terminal_stop (Types.Unknown "unknown-stop")) Resume_regular)
        ; Alcotest.test_case "terminal resume rejects unmatched tool calls" `Quick
            (test_active_terminal_resumes_committed_checkpoint
              ~case:(Invalid_terminal_stop Types.UnmatchedToolCalls) Resume_regular)
        ; Alcotest.test_case "terminal resume rejects empty tool stop" `Quick
            (test_active_terminal_resumes_committed_checkpoint
              ~case:(Invalid_terminal_stop Types.StopToolUse) Resume_regular)
        ; Alcotest.test_case "terminal resume runs pending OnStop" `Quick
            (test_active_terminal_resumes_committed_checkpoint ~case:Accepted_stop_hook Resume_regular)
        ; Alcotest.test_case "terminal resume propagates OnStop exception" `Quick
            (test_active_terminal_resumes_committed_checkpoint ~case:Raising_stop_hook Resume_regular)
        ; Alcotest.test_case "terminal resume rejects illegal OnStop decision" `Quick
            (test_active_terminal_resumes_committed_checkpoint ~case:Illegal_stop_hook Resume_regular)
        ; Alcotest.test_case "open provider repeats OnStop after interruption" `Quick
            (test_active_terminal_resumes_committed_checkpoint ~case:Replayed_stop_hook Resume_regular)
        ; Alcotest.test_case "closed provider reuses output decision without OnStop" `Quick
            (test_active_terminal_resumes_committed_checkpoint ~case:Provider_closed_stop_hook Resume_regular)
        ; Alcotest.test_case "terminal resume rejects stale collected counter" `Quick
            (test_active_terminal_resumes_committed_checkpoint ~case:Stale_terminal_counter Resume_regular)
        ; Alcotest.test_case "terminal resume rejects different collected content" `Quick
            (test_active_terminal_resumes_committed_checkpoint ~case:Different_terminal_content Resume_regular)
        ; Alcotest.test_case "terminal resume rejects persisted tool invocation" `Quick
            (test_active_terminal_resumes_committed_checkpoint ~case:Unexpected_terminal_invocation Resume_regular)
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
            "stale checkpoint terminal settlement survives removal and drift"
            `Quick
            test_agent_run_replays_stale_checkpoint_terminal_settlement
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
            "trace failure preserves committed execution success"
            `Quick
            (test_trace_finalization_preserves_committed_success Diagnostic_ok)
        ; Alcotest.test_case
            "throwing trace diagnostic preserves committed success"
            `Quick
            (test_trace_finalization_preserves_committed_success Diagnostic_failed)
        ; Alcotest.test_case
            "reserved trace diagnostic finalizes committed lifecycle"
            `Quick
            (test_trace_finalization_preserves_committed_success Diagnostic_reserved)
        ; Alcotest.test_case
            "completion callback diagnostic preserves committed success"
            `Quick
            (test_trace_finalization_preserves_committed_success Callback_diagnostic_failed)
        ; Alcotest.test_case
            "trace write failure keeps an accepted provider response"
            `Quick
            (test_trace_write_failure_keeps_execution Trace_fails_under_provider_response)
        ; Alcotest.test_case
            "trace write failure keeps a completed tool result"
            `Quick
            (test_trace_write_failure_keeps_execution Trace_fails_under_tool_effect)
        ; Alcotest.test_case
            "trace write failure keeps an allowing hook decision"
            `Quick
            (test_trace_write_failure_keeps_execution Trace_fails_under_allowing_hook)
        ; Alcotest.test_case
            "trace write failure keeps a blocking hook decision"
            `Quick
            (test_trace_write_failure_keeps_execution Trace_fails_under_blocking_hook)
        ; Alcotest.test_case "durable turn observations keep committed identity" `Quick
            (test_durable_turn_bus_uses_canonical_facts ~caller_checkpoint:false)
        ; Alcotest.test_case "caller-owned checkpoint preserves canonical turn observations" `Quick
            (test_durable_turn_bus_uses_canonical_facts ~caller_checkpoint:true)
        ; Alcotest.test_case "turn publication failure retries source without provider redispatch" `Quick
            (test_durable_turn_bus_uses_canonical_facts ~delivery_fault:true ~caller_checkpoint:false)
        ; Alcotest.test_case "checkpoint refusal does not publish assistant collection" `Quick
            (test_durable_turn_bus_uses_canonical_facts ~refuse_checkpoint:true ~caller_checkpoint:true)
        ; Alcotest.test_case "nested independent stores own separate live observers" `Quick
            test_nested_execution_stores_use_their_own_bus_observers
        ; Alcotest.test_case
            "durable tool bus uses canonical committed facts"
            `Quick
            (test_durable_tool_bus_uses_canonical_facts ~delivery_fault:false)
        ; Alcotest.test_case "required checkpoint sink Error refuses continuation" `Quick
            (test_durable_tool_bus_uses_canonical_facts
              ~checkpoint_failure:(fun () -> Error "checkpoint delivery refused"))
        ; Alcotest.test_case "required checkpoint sink exception refuses continuation" `Quick
            (test_durable_tool_bus_uses_canonical_facts
              ~checkpoint_failure:(fun () -> raise Checkpoint_authority_refused))
        ; Alcotest.test_case
            "durable tool partial delivery retains source cursor"
            `Quick
            (test_durable_tool_bus_uses_canonical_facts ~delivery_fault:true)
        ; Alcotest.test_case "nested tool observations use shared audience" `Quick
            (test_nested_tool_observation_audiences Shared_tool_bus ~concurrent:false)
        ; Alcotest.test_case "nested tool observations use distinct audiences" `Quick
            (test_nested_tool_observation_audiences Distinct_tool_bus ~concurrent:false)
        ; Alcotest.test_case "nested tool observations preserve absent audience" `Quick
            (test_nested_tool_observation_audiences No_child_tool_bus ~concurrent:false)
        ; Alcotest.test_case "concurrent recursive tool observations keep journal order" `Quick
            (test_nested_tool_observation_audiences Shared_tool_bus ~concurrent:true)
        ; Alcotest.test_case "unattempted tools have no bus execution observation" `Quick
            test_unattempted_tool_has_no_bus_execution_observation
        ; Alcotest.test_case
            "terminal disposition observes cancellation"
            `Quick
            test_terminal_disposition_observes_cancellation
        ; Alcotest.test_case
            "parent switch cancellation commits native terminal"
            `Quick
            (test_native_parent_cancellation Parent_switch Provider_wait)
        ; Alcotest.test_case
            "cancellation before fresh callback commits native terminal"
            `Quick
            (test_native_parent_cancellation Parent_switch Before_callback)
        ; Alcotest.test_case
            "cancellation before resumed callback commits native terminal"
            `Quick
            (test_native_parent_cancellation ~resumed:true Parent_switch Before_callback)
        ; Alcotest.test_case
            "nested cancellation retains the caller context"
            `Quick
            (test_native_parent_cancellation Nested_context Provider_wait)
        ; Alcotest.test_case
            "losing provider race commits native terminal"
            `Quick
            (test_native_parent_cancellation Losing_race Provider_wait)
        ; Alcotest.test_case
            "parent cancellation preserves unknown tool effects"
            `Quick
            (test_native_parent_cancellation Parent_switch Tool_effect)
        ] )
    ]
;;
