(** Extended Builder coverage tests — targets uncovered paths in builder.ml,
    agent.ml, and agent_tools.ml.

    Focuses on:
    - Builder chainable API: with_* methods not yet covered
    - build_safe validation: invalid max_tokens and thinking_budget
    - Agent accessors: state, tools, context, options, description
    - Agent.default_options fields
    - Agent.clone *)

open Agent_sdk

let card_interfaces =
  Agent_card.create_supported_interface
    ~url:"https://test-agent.example/a2a"
    ~protocol_binding:"JSONRPC"
    ~protocol_version:"1.0"
    ()
  |> Result.get_ok
  |> fun interface -> Agent_card.supported_interfaces interface []
;;

(* ── Builder chain methods ────────────────────────────────── *)

let test_builder_chain () =
  Eio_main.run
  @@ fun env ->
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_name "test-chain"
    |> Builder.with_system_prompt "You are a test agent"
    |> Builder.with_max_tokens 200
    |> Builder.with_temperature 0.5
    |> Builder.with_top_p 0.9
    |> Builder.with_top_k 40
    |> Builder.with_min_p 0.1
    |> Builder.with_description "A test builder"
  in
  match Builder.build_safe b with
  | Ok agent ->
    let st = Agent.state agent in
    Alcotest.(check string) "name" "test-chain" st.config.name;
    Alcotest.(check (option int)) "max_tokens" (Some 200) st.config.max_tokens;
    (match Agent.description agent with
     | Some d -> Alcotest.(check string) "desc" "A test builder" d
     | None -> Alcotest.fail "expected description")
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_builder_thinking () =
  Eio_main.run
  @@ fun env ->
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_enable_thinking true
    |> Builder.with_thinking_budget 1000
    |> Builder.with_reasoning_effort Llm_provider.Reasoning_effort.Max
  in
  match Builder.build_safe b with
  | Ok agent ->
    let config = (Agent.state agent).config in
    Alcotest.(check (option int)) "numeric budget" (Some 1000) config.thinking_budget;
    Alcotest.(check (option string))
      "categorical effort"
      (Some "max")
      (Option.map Llm_provider.Reasoning_effort.to_string config.reasoning_effort)
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_builder_response_format () =
  Eio_main.run
  @@ fun env ->
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_response_format Types.JsonMode
    |> Builder.with_cache_system_prompt true
    |> Builder.with_disable_parallel_tool_use true
  in
  match Builder.build_safe b with
  | Ok agent ->
    let st = Agent.state agent in
    Alcotest.(check bool) "json mode" true (st.config.response_format = Types.JsonMode);
    Alcotest.(check bool) "cache prompt" true st.config.cache_system_prompt;
    Alcotest.(check bool) "disable parallel" true st.config.disable_parallel_tool_use
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_builder_tool_choice () =
  Eio_main.run
  @@ fun env ->
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_tool_choice Types.Auto
  in
  match Builder.build_safe b with
  | Ok _agent -> ()
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_builder_initial_messages () =
  Eio_main.run
  @@ fun env ->
  let msgs = [ Types.user_msg "initial context" ] in
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_initial_messages msgs
  in
  match Builder.build_safe b with
  | Ok _agent -> ()
  | Error e -> Alcotest.fail (Error.to_string e)
;;

(* ── build_safe validation ────────────────────────────────── *)

let test_build_safe_invalid_max_tokens () =
  Eio_main.run
  @@ fun env ->
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_max_tokens 0
  in
  match Builder.build_safe b with
  | Error (Error.Config (Error.InvalidConfig { field; _ })) ->
    Alcotest.(check string) "field" "max_tokens" field
  | Error _ -> Alcotest.fail "expected InvalidConfig for max_tokens"
  | Ok _ -> Alcotest.fail "expected Error for max_tokens <= 0"
;;

let test_build_safe_preserves_independent_thinking_budget () =
  Eio_main.run
  @@ fun env ->
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_thinking_budget 500
  in
  match Builder.build_safe b with
  | Ok agent ->
    let config = (Agent.state agent).config in
    Alcotest.(check (option bool)) "enable_thinking omitted" None config.enable_thinking;
    Alcotest.(check (option int)) "budget preserved" (Some 500) config.thinking_budget
  | Error error -> Alcotest.fail (Error.to_string error)
;;

(* ── Agent accessors ──────────────────────────────────────── *)

let test_agent_accessors () =
  Eio_main.run
  @@ fun env ->
  let tool =
    Tool.create ~name:"test_tool" ~description:"desc" ~parameters:[] (fun _input ->
      Ok { Types.content = "result"; _meta = None })
  in
  let ctx = Context.create_sync () in
  Context.set ctx "key" (`String "value");
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_name "accessor-test"
    |> Builder.with_tools [ tool ]
    |> Builder.with_context ctx
    |> Builder.with_description "test desc"
  in
  match Builder.build_safe b with
  | Ok agent ->
    (* state *)
    let st = Agent.state agent in
    Alcotest.(check string) "name" "accessor-test" st.config.name;
    (* tools *)
    let ts = Agent.tools agent in
    Alcotest.(check int) "tool count" 1 (Tool_set.size ts);
    (* context *)
    let c = Agent.context agent in
    Alcotest.(check bool) "ctx value" true (Context.get c "key" = Some (`String "value"));
    (* description *)
    Alcotest.(check (option string)) "desc" (Some "test desc") (Agent.description agent);
    (* net *)
    let _net = Agent.net agent in
    ();
    (* lifecycle *)
    let _lc = Agent.lifecycle agent in
    ()
  | Error e -> Alcotest.fail (Error.to_string e)
;;

(* ── Agent.default_options ────────────────────────────────── *)

let test_agent_default_options () =
  let opts = Agent.default_options in
  Alcotest.(check bool) "no provider config" true (opts.provider_config = None);
  Alcotest.(check bool) "no event_bus" true (opts.event_bus = None);
  Alcotest.(check bool) "no skill_registry" true (opts.skill_registry = None);
  Alcotest.(check int) "empty mcp" 0 (List.length opts.mcp_clients)
;;

(* ── Agent.clone ──────────────────────────────────────────── *)

let test_agent_clone () =
  Eio_main.run
  @@ fun env ->
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_name "original"
    |> Builder.with_description "orig desc"
  in
  match Builder.build_safe b with
  | Ok agent ->
    let cloned = Agent.clone agent in
    let st = Agent.state cloned in
    Alcotest.(check string) "name preserved" "original" st.config.name;
    Alcotest.(check (option string))
      "desc preserved"
      (Some "orig desc")
      (Agent.description cloned)
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_agent_clone_copy_context () =
  Eio_main.run
  @@ fun env ->
  let ctx = Context.create_sync () in
  Context.set ctx "test_key" (`String "test_val");
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_context ctx
  in
  match Builder.build_safe b with
  | Ok agent ->
    let cloned = Agent.clone ~copy_context:true agent in
    let c = Agent.context cloned in
    Alcotest.(check bool)
      "context copied"
      true
      (Context.get c "test_key" = Some (`String "test_val"))
  | Error e -> Alcotest.fail (Error.to_string e)
;;

(* ── Agent.sdk_version ────────────────────────────────────── *)

let test_sdk_version () =
  let v = Agent.sdk_version in
  Alcotest.(check bool) "non-empty" true (String.length v > 0)
;;

(* ── Agent.card ───────────────────────────────────────────── *)

let test_agent_card () =
  Eio_main.run
  @@ fun env ->
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_name "card-test"
    |> Builder.with_description "Card desc"
  in
  match Builder.build_safe b with
  | Ok agent ->
    let card = Agent.card ~supported_interfaces:card_interfaces agent in
    Alcotest.(check string) "card name" "card-test" card.name
  | Error e -> Alcotest.fail (Error.to_string e)
;;

(* ── Builder with_event_bus ───────────────────────────────── *)

let test_builder_with_event_bus () =
  Eio_main.run
  @@ fun env ->
  let bus = Event_bus.create () in
  let b =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.with_event_bus bus
  in
  match Builder.build_safe b with
  | Ok agent ->
    let opts = Agent.options agent in
    Alcotest.(check bool) "has event_bus" true (opts.event_bus <> None)
  | Error e -> Alcotest.fail (Error.to_string e)
;;

(* ── Suite ────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Builder_coverage"
    [ ( "builder_chain"
      , [ Alcotest.test_case "full chain" `Quick test_builder_chain
        ; Alcotest.test_case "thinking" `Quick test_builder_thinking
        ; Alcotest.test_case "response format" `Quick test_builder_response_format
        ; Alcotest.test_case "tool choice" `Quick test_builder_tool_choice
        ; Alcotest.test_case "initial messages" `Quick test_builder_initial_messages
        ; Alcotest.test_case "with event_bus" `Quick test_builder_with_event_bus
        ] )
    ; ( "build_safe_validation"
      , [ Alcotest.test_case
            "invalid max_tokens"
            `Quick
            test_build_safe_invalid_max_tokens
        ; Alcotest.test_case
            "independent thinking budget"
            `Quick
            test_build_safe_preserves_independent_thinking_budget
        ] )
    ; ( "agent_accessors"
      , [ Alcotest.test_case "state/tools/context/desc" `Quick test_agent_accessors
        ; Alcotest.test_case "default_options" `Quick test_agent_default_options
        ; Alcotest.test_case "sdk_version" `Quick test_sdk_version
        ; Alcotest.test_case "agent card" `Quick test_agent_card
        ] )
    ; ( "clone"
      , [ Alcotest.test_case "basic clone" `Quick test_agent_clone
        ; Alcotest.test_case "clone with context" `Quick test_agent_clone_copy_context
        ] )
    ]
;;
