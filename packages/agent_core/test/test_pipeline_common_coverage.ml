open Agent_sdk
module Internal_agent = Agent_sdk__Agent_types
module Pipeline_common = Agent_sdk__Pipeline_common

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)
let check_opt_string = Alcotest.(check (option string))

let openai_config =
  Provider_mock.local_provider_config
    ~base_url:"http://127.0.0.1:65535"
    ~model_id:"openai_chat"
    ~request_path:"/v1/chat/completions"
    ()
;;

let card_interfaces =
  Agent_card.create_supported_interface
    ~url:"https://coverage-agent.example/a2a"
    ~protocol_binding:"JSONRPC"
    ~protocol_version:"1.0"
    ()
  |> Result.get_ok
  |> fun interface -> Agent_card.supported_interfaces interface []
;;

let echo_tool =
  Tool.create
    ~name:"echo"
    ~description:"Echo input"
    ~parameters:
      [ { Types.name = "message"
        ; description = "Message"
        ; param_type = Types.String
        ; required = true
        }
      ]
    (fun input ->
       let open Yojson.Safe.Util in
       Ok { Types.content = input |> member "message" |> to_string; _meta = None })
;;

let text_response ?(content = [ Types.Text "ok" ]) () : Types.api_response =
  { id = "resp-1"
  ; model = "openai_chat"
  ; stop_reason = EndTurn
  ; content
  ; usage = None
  ; telemetry = None
  }
;;

let with_agent
      ?(config = Types.default_config ~model:"test-model")
      ?(options = Internal_agent.default_options)
      f
  =
  Eio_main.run
  @@ fun env ->
  let agent = Internal_agent.create ~net:env#net ~config ~options () in
  f agent
;;

let test_strategy_and_outcome_constructors () =
  let events = ref 0 in
  let strategy =
    Pipeline_common.Stream
      { on_event = (fun _ -> incr events); on_telemetry = Some (fun _ -> incr events) }
  in
  (match strategy with
   | Pipeline_common.Stream { on_event; on_telemetry = Some _ } ->
     on_event MessageStop;
     check_int "event callback" 1 !events
   | _ -> Alcotest.fail "expected stream strategy");
  (match Pipeline_common.Sync with
   | Pipeline_common.Sync -> ()
   | _ -> Alcotest.fail "expected sync strategy");
  let complete = Pipeline_common.Complete (text_response ()) in
  (match complete with
   | Pipeline_common.Complete response -> check_string "response id" "resp-1" response.id
   | _ -> Alcotest.fail "expected complete outcome");
  match Pipeline_common.ToolsExecuted with
  | Pipeline_common.ToolsExecuted -> ()
  | _ -> Alcotest.fail "expected tools outcome"
;;

let test_agent_type_checkpoint_stage_labels () =
  check_string
    "assistant collected"
    "after_assistant_collected"
    (Internal_agent.checkpoint_stage_to_string After_assistant_collected);
  check_string
    "tool results appended"
    "after_tool_results_appended"
    (Internal_agent.checkpoint_stage_to_string After_tool_results_appended);
  check_string
    "context injection"
    "after_context_injection"
    (Internal_agent.checkpoint_stage_to_string After_context_injection)
;;

let test_agent_type_accessors_card_and_state_mutators () =
  let config =
    { (Types.default_config ~model:"test-model") with
      name = "coverage-agent"
    ; model = "openai_chat"
    }
  in
  let options =
    { Internal_agent.default_options with
      description = Some "Coverage agent"
    ; provider_config = Some openai_config
    }
  in
  Eio_main.run
  @@ fun env ->
  let agent =
    Internal_agent.create ~net:env#net ~config ~tools:[ echo_tool ] ~options ()
  in
  check_string "config name" "coverage-agent" (Internal_agent.state agent).config.name;
  check_bool "same net accessor" true (Internal_agent.net agent == env#net);
  check_bool "tool present" true (Tool_set.mem "echo" (Internal_agent.tools agent));
  check_bool
    "context initially empty"
    true
    (Context.keys (Internal_agent.context agent) = []);
  check_opt_string
    "description"
    (Some "Coverage agent")
    (Internal_agent.description agent);
  check_bool
    "provider config option"
    true
    (Option.is_some (Internal_agent.options agent).provider_config);
  let card = Internal_agent.card ~supported_interfaces:card_interfaces agent in
  check_string "card name" "coverage-agent" card.name;
  check_opt_string "card description" (Some "Coverage agent") card.description;
  check_int "card tools" 1 (List.length card.tools);
  Internal_agent.set_state agent { (Internal_agent.state agent) with turn_count = 2 };
  check_int "set_state" 2 (Internal_agent.state agent).turn_count;
  Internal_agent.update_state agent (fun state ->
    { state with turn_count = state.turn_count + 3 });
  check_int "update_state" 5 (Internal_agent.state agent).turn_count
;;

let test_agent_type_lifecycle_status_show () =
  List.iter
    (fun status ->
       check_bool
         "show status"
         true
         (String.length (Internal_agent.show_lifecycle_status status) > 0))
    [ Accepted; Ready; Running; Completed; Failed ]
;;

let test_agent_type_create_merges_mcp_tools () =
  Eio_main.run
  @@ fun env ->
  let managed : Mcp.managed =
    { tools = [ echo_tool ]
    ; name = "coverage-mcp"
    ; transport =
        Mcp.Http
          { close_fn = (fun () -> ()); base_url = "http://127.0.0.1"; headers = [] }
    }
  in
  let options = { Internal_agent.default_options with mcp_clients = [ managed ] } in
  let config = Types.default_config ~model:"test-model" in
  let agent = Internal_agent.create ~net:env#net ~config ~options () in
  check_bool "mcp tool merged" true (Tool_set.mem "echo" (Internal_agent.tools agent))
;;

let test_agent_type_lifecycle_rejects_invalid_transition () =
  Eio_main.run
  @@ fun env ->
  let config = Types.default_config ~model:"test-model" in
  let agent = Internal_agent.create ~net:env#net ~config () in
  Internal_agent.set_lifecycle agent ~accepted_at:1.0 Accepted;
  Internal_agent.set_lifecycle agent ~ready_at:2.0 Ready;
  Internal_agent.set_lifecycle agent ~current_run_id:"run-1" ~started_at:3.0 Running;
  Internal_agent.set_lifecycle agent ~finished_at:4.0 Completed;
  (match Internal_agent.lifecycle agent with
   | Some snapshot ->
     check_bool "completed" true (snapshot.status = Completed);
     check_opt_string "run id" (Some "run-1") snapshot.current_run_id
   | None -> Alcotest.fail "expected lifecycle snapshot");
  Internal_agent.set_lifecycle agent Running;
  match Internal_agent.lifecycle agent with
  | Some snapshot ->
    check_bool "invalid transition rejected" true (snapshot.status = Completed)
  | None -> Alcotest.fail "expected lifecycle snapshot"
;;

let test_agent_type_clone_variants () =
  let config =
    { (Types.default_config ~model:"test-model") with name = "clone-source" }
  in
  Eio_main.run
  @@ fun env ->
  let context = Context.create_sync () in
  Context.set context "marker" (`String "copied");
  let agent =
    Internal_agent.create ~net:env#net ~config ~context ~tools:[ echo_tool ] ()
  in
  Internal_agent.set_state
    agent
    { (Internal_agent.state agent) with
      turn_count = 7
    ; messages = [ Types.user_msg "hello" ]
    };
  Internal_agent.set_lifecycle agent Accepted;
  let fresh = Internal_agent.clone agent in
  check_int "fresh state copied" 7 (Internal_agent.state fresh).turn_count;
  check_int "fresh messages copied" 1 (List.length (Internal_agent.state fresh).messages);
  check_bool "fresh context empty" true (Context.keys (Internal_agent.context fresh) = []);
  check_bool "tools shared" true (Tool_set.mem "echo" (Internal_agent.tools fresh));
  let copied = Internal_agent.clone ~copy_context:true agent in
  check_bool
    "context copied"
    true
    (Context.get (Internal_agent.context copied) "marker" = Some (`String "copied"));
  Context.set (Internal_agent.context copied) "marker" (`String "changed");
  check_bool
    "source context independent"
    true
    (Context.get (Internal_agent.context agent) "marker" = Some (`String "copied"))
;;

let test_event_envelope_falls_back_without_trace () =
  with_agent (fun agent ->
    let envelope = Pipeline_common.event_envelope agent in
    check_bool "correlation id" true (String.length envelope.correlation_id > 0);
    check_bool "run id" true (String.length envelope.run_id > 0))
;;

let test_event_envelope_uses_trace_and_lifecycle () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "oas-pipeline-common-%d" (Unix.getpid ()))
  in
  Unix.mkdir root 0o755;
  let trace_path = Filename.concat root "trace.jsonl" in
  let trace =
    match Raw_trace.create ~session_id:"session-123" ~path:trace_path () with
    | Ok trace -> trace
    | Error err -> Alcotest.fail (Error.to_string err)
  in
  let options = { Internal_agent.default_options with raw_trace = Some trace } in
  with_agent ~options (fun agent ->
    Internal_agent.set_lifecycle agent ~current_run_id:"run-123" Agent.Running;
    let envelope = Pipeline_common.event_envelope agent in
    check_string "trace session" "session-123" envelope.correlation_id;
    check_string "lifecycle run" "run-123" envelope.run_id);
  (try Sys.remove trace_path with
   | Sys_error _ -> ());
  try Unix.rmdir root with
  | Unix.Unix_error _ -> ()
;;

let () =
  Alcotest.run
    "Pipeline_common_coverage"
    [ ( "types"
      , [ Alcotest.test_case
            "strategy and outcome constructors"
            `Quick
            test_strategy_and_outcome_constructors
        ; Alcotest.test_case
            "agent checkpoint labels"
            `Quick
            test_agent_type_checkpoint_stage_labels
        ; Alcotest.test_case
            "agent accessors card and state mutators"
            `Quick
            test_agent_type_accessors_card_and_state_mutators
        ; Alcotest.test_case
            "agent lifecycle status show"
            `Quick
            test_agent_type_lifecycle_status_show
        ; Alcotest.test_case
            "agent create merges mcp tools"
            `Quick
            test_agent_type_create_merges_mcp_tools
        ; Alcotest.test_case
            "agent lifecycle rejects invalid transition"
            `Quick
            test_agent_type_lifecycle_rejects_invalid_transition
        ; Alcotest.test_case "agent clone variants" `Quick test_agent_type_clone_variants
        ] )
    ; ( "envelope"
      , [ Alcotest.test_case
            "fallback ids"
            `Quick
            test_event_envelope_falls_back_without_trace
        ; Alcotest.test_case
            "trace and lifecycle ids"
            `Quick
            test_event_envelope_uses_trace_and_lifecycle
        ] )
    ]
;;
