(** Tests for Builder module — chainable agent construction API. *)

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

(** Run a function inside Eio with network access. *)
let with_net f =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  f net
;;

(** Helper: create a simple echo tool. *)
let make_tool name =
  Tool.create ~name ~description:("tool:" ^ name) ~parameters:[] (fun input ->
    Ok { Types.content = Yojson.Safe.to_string input; _meta = None })
;;

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0
    then true
    else if idx + needle_len > haystack_len
    then false
    else if String.sub haystack idx needle_len = needle
    then true
    else loop (idx + 1)
  in
  loop 0
;;

(** Helper: compare model fields via string. *)
let check_model msg expected actual = Alcotest.(check string) msg expected actual

(* --- 1. create sets model --- *)

let test_create_sets_model () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-haiku-4-5" |> Builder.build_safe |> Result.get_ok
  in
  check_model "model" "claude-haiku-4-5" (Agent.state agent).config.model
;;

(* --- 2. with_system_prompt --- *)

let test_with_system_prompt () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_system_prompt "You are helpful."
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check (option string))
    "system_prompt"
    (Some "You are helpful.")
    (Agent.state agent).config.system_prompt
;;

(* --- 3. with_name --- *)

let test_with_name () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_name "test-agent"
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check string) "name" "test-agent" (Agent.state agent).config.name
;;

(* --- 4. with_max_tokens --- *)

let test_with_max_tokens () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_max_tokens 8192
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check (option int))
    "max_tokens"
    (Some 8192)
    (Agent.state agent).config.max_tokens
;;

(* --- 6. with_temperature --- *)

let test_with_temperature () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_temperature 0.7
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check (option (float 0.001)))
    "temperature"
    (Some 0.7)
    (Agent.state agent).config.temperature
;;

let test_with_provider_m_sampling () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"dashscope-3.5-35b-a3b-ud-q8-xl"
    |> Builder.with_top_p 0.95
    |> Builder.with_top_k 20
    |> Builder.with_min_p 0.01
    |> Builder.with_enable_thinking false
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check (option (float 0.001)))
    "top_p"
    (Some 0.95)
    (Agent.state agent).config.top_p;
  Alcotest.(check (option int)) "top_k" (Some 20) (Agent.state agent).config.top_k;
  Alcotest.(check (option (float 0.001)))
    "min_p"
    (Some 0.01)
    (Agent.state agent).config.min_p;
  Alcotest.(check (option bool))
    "enable_thinking"
    (Some false)
    (Agent.state agent).config.enable_thinking
;;

(* --- 7. with_tools replaces --- *)

let test_with_tools_replaces () =
  with_net
  @@ fun net ->
  let t1 = make_tool "a" in
  let t2 = make_tool "b" in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_tool t1
    |> Builder.with_tools [ t2 ]
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check int) "tool count" 1 (Tool_set.size (Agent.tools agent));
  Alcotest.(check string)
    "tool name"
    "b"
    (List.hd (Tool_set.to_list (Agent.tools agent))).schema.name
;;

(* --- 8. with_tool appends --- *)

let test_with_tool_appends () =
  with_net
  @@ fun net ->
  let t1 = make_tool "first" in
  let t2 = make_tool "second" in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_tool t1
    |> Builder.with_tool t2
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check int) "tool count" 2 (Tool_set.size (Agent.tools agent));
  let tools_list = Tool_set.to_list (Agent.tools agent) in
  Alcotest.(check string) "first tool" "first" (List.nth tools_list 0).schema.name;
  Alcotest.(check string) "second tool" "second" (List.nth tools_list 1).schema.name
;;

(* --- 9. with_hooks --- *)

let test_with_hooks () =
  with_net
  @@ fun net ->
  let hook _event = Hooks.Continue in
  let hooks = { Hooks.empty with before_turn = Some hook } in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_hooks hooks
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check bool)
    "before_turn set"
    true
    (Option.is_some (Agent.options agent).hooks.before_turn)
;;

(* --- 10. with_tracer --- *)

let test_with_tracer () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_tracer Tracing.fmt
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check bool)
    "tracer not null"
    true
    ((Agent.options agent).tracer != Tracing.null)
;;

(* --- 13d. with_transport --- *)

let test_with_transport () =
  with_net
  @@ fun net ->
  let mock_transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun _req ->
          { response =
              Error
                (Llm_provider.Http_client.NetworkError
                   { message = "mock"; kind = Unknown })
          ; latency_ms = Some 0
          })
    ; complete_stream =
        (fun ?on_telemetry:_ ~on_event:_ _req ->
          Error
            (Llm_provider.Http_client.NetworkError { message = "mock"; kind = Unknown }))
    }
  in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_transport mock_transport
    |> Builder.build_safe
    |> Result.get_ok
  in
  let opts = Agent.options agent in
  Alcotest.(check bool) "transport set" true (Option.is_some opts.transport)
;;

(* --- 13. with_context --- *)

let test_with_context () =
  with_net
  @@ fun net ->
  let ctx = Context.create_sync () in
  Context.set ctx "key" (`String "value");
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_context ctx
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check (option string))
    "context key"
    (Some "value")
    (match Context.get (Agent.context agent) "key" with
     | Some (`String s) -> Some s
     | _ -> None)
;;

(* --- 14. exact provider config --- *)

let exact_provider_config () =
  let schema = `Assoc [ "type", `String "object" ] in
  let capabilities =
    { Llm_provider.Capabilities.openai_compat_chat_capabilities with
      supports_tools = true
    ; supports_structured_output = true
    }
  in
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Ollama
    ~provider_id:"ollama"
    ~model_id:"builder-exact-model"
    ~base_url:"https://builder-exact.invalid/api"
    ~api_key:"builder-exact-secret"
    ~headers:[ "Content-Type", "application/json"; "x-builder-tenant", "exact" ]
    ~request_path:"/exact/chat"
    ~max_tokens:111
    ~max_context:65536
    ~temperature:0.75
    ~top_p:0.8
    ~top_k:32
    ~min_p:0.05
    ~system_prompt:"exact provider prompt"
    ~enable_thinking:true
    ~preserve_thinking:true
    ~thinking_budget:4096
    ~clear_thinking:false
    ~tool_stream:true
    ~tool_choice:Types.Auto
    ~response_format:(Types.JsonSchema schema)
    ~cache_system_prompt:true
    ~supports_tool_choice_override:true
    ~supports_structured_output_override:true
    ~model_capabilities_override:capabilities
    ~keep_alive:"-1"
    ~num_ctx:32768
    ~seed:2590
    ~previous_response_id:"response-before-builder"
    ~connect_timeout_s:12.5
    ()
;;

let test_with_provider_config_reaches_dispatch_losslessly () =
  with_net
  @@ fun net ->
  let observed = ref None in
  let response : Types.api_response =
    { id = "builder-exact-response"
    ; model = "builder-exact-model"
    ; stop_reason = Types.EndTurn
    ; content = [ Types.Text "ok" ]
    ; usage = None
    ; telemetry = None
    }
  in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun request ->
          observed := Some request.Llm_provider.Llm_transport.config;
          { response = Ok response; latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
    }
  in
  let provider_config = exact_provider_config () in
  let agent =
    Builder.create ~net ~model:"initial-model"
    |> Builder.with_provider_config provider_config
    |> Builder.with_max_tokens 777
    |> Builder.with_temperature 0.25
    |> Builder.with_response_format Types.JsonMode
    |> Builder.with_transport transport
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check bool)
    "exact carrier retained"
    true
    (Option.is_some (Agent.provider_config agent));
  Alcotest.(check (list string))
    "agent card observes canonical provider identity"
    [ "ollama" ]
    (Agent.card ~supported_interfaces:card_interfaces agent).supported_providers;
  let result = Eio.Switch.run (fun sw -> Agent.run ~sw agent "hello") in
  (match result with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Error.to_string error));
  (match Agent.lifecycle agent with
   | Some snapshot ->
     Alcotest.(check (option string))
       "lifecycle observes canonical provider identity"
       (Some "ollama")
       snapshot.requested_provider
   | None -> Alcotest.fail "completed agent has no lifecycle snapshot");
  let dispatched =
    match !observed with
    | Some config -> config
    | None -> Alcotest.fail "transport did not observe a provider config"
  in
  Alcotest.(check bool) "wire kind" true (dispatched.kind = provider_config.kind);
  Alcotest.(check (option string))
    "provider identity"
    provider_config.provider_id
    dispatched.provider_id;
  Alcotest.(check string) "endpoint" provider_config.base_url dispatched.base_url;
  Alcotest.(check string)
    "request path"
    provider_config.request_path
    dispatched.request_path;
  Alcotest.(check string)
    "credential"
    (provider_config.api_key :> string)
    (dispatched.api_key :> string);
  Alcotest.(check (list (pair string string)))
    "headers"
    provider_config.headers
    dispatched.headers;
  Alcotest.(check (option bool))
    "tool choice override"
    provider_config.supports_tool_choice_override
    dispatched.supports_tool_choice_override;
  Alcotest.(check (option bool))
    "structured output override"
    provider_config.supports_structured_output_override
    dispatched.supports_structured_output_override;
  Alcotest.(check bool)
    "capability override"
    true
    (match dispatched.model_capabilities_override with
     | Some capabilities ->
       capabilities.supports_tools && capabilities.supports_structured_output
     | None -> false);
  Alcotest.(check (option string)) "keep alive" (Some "-1") dispatched.keep_alive;
  Alcotest.(check (option int)) "num ctx" (Some 32768) dispatched.num_ctx;
  Alcotest.(check (option int)) "seed" (Some 2590) dispatched.seed;
  Alcotest.(check (option string))
    "previous response id"
    (Some "response-before-builder")
    dispatched.previous_response_id;
  Alcotest.(check (option (float 0.001)))
    "connect timeout"
    (Some 12.5)
    dispatched.connect_timeout_s;
  Alcotest.(check string)
    "model seeded from exact config"
    "builder-exact-model"
    dispatched.model_id;
  Alcotest.(check (option int))
    "later max_tokens setter wins"
    (Some 777)
    dispatched.max_tokens;
  Alcotest.(check (option (float 0.001)))
    "later temperature setter wins"
    (Some 0.25)
    dispatched.temperature;
  Alcotest.(check string)
    "later response format setter wins"
    (Types.show_response_format Types.JsonMode)
    (Types.show_response_format dispatched.response_format)
;;

let test_missing_provider_config_is_rejected_at_dispatch () =
  with_net
  @@ fun net ->
  let transport_called = ref false in
  let response : Types.api_response =
    { id = "must-not-dispatch"
    ; model = "must-not-dispatch"
    ; stop_reason = Types.EndTurn
    ; content = [ Types.Text "must not dispatch" ]
    ; usage = None
    ; telemetry = None
    }
  in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun _request ->
          transport_called := true;
          { response = Ok response; latency_ms = Some 0 })
    ; complete_stream =
        (fun ?on_telemetry:_ ~on_event:_ _request ->
          transport_called := true;
          Ok response)
    }
  in
  let agent =
    Builder.create ~net ~model:"missing-provider-config"
    |> Builder.with_transport transport
    |> Builder.build_safe
    |> Result.get_ok
  in
  (match Eio.Switch.run (fun sw -> Agent.run ~sw agent "hello") with
   | Error (Error.Config (Error.InvalidConfig { field; _ })) ->
     Alcotest.(check string) "exact carrier field" "provider_config" field
   | Error error -> Alcotest.failf "unexpected error: %s" (Error.to_string error)
   | Ok _ -> Alcotest.fail "missing provider_config reached transport");
  Alcotest.(check bool) "transport not called" false !transport_called
;;

let test_handoff_inherits_injected_transport () =
  with_net
  @@ fun net ->
  let response ~id ~stop_reason content : Types.api_response =
    { id
    ; model = "builder-exact-model"
    ; stop_reason
    ; content
    ; usage = None
    ; telemetry = None
    }
  in
  let responses =
    ref
      [ response
          ~id:"parent-handoff"
          ~stop_reason:Types.StopToolUse
          [ Types.ToolUse
              { id = "handoff-tool"
              ; name = "researcher"
              ; input = `Assoc [ "prompt", `String "inspect" ]
              }
          ]
      ; response
          ~id:"subagent-complete"
          ~stop_reason:Types.EndTurn
          [ Types.Text "sub ok" ]
      ; response
          ~id:"parent-complete"
          ~stop_reason:Types.EndTurn
          [ Types.Text "parent done" ]
      ]
  in
  let calls = ref 0 in
  let transport_error () =
    Llm_provider.Http_client.NetworkError
      { message = "scripted transport exhausted"; kind = Unknown }
  in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun _request ->
          incr calls;
          match !responses with
          | next :: rest ->
            responses := rest;
            { response = Ok next; latency_ms = Some 0 }
          | [] -> { response = Error (transport_error ()); latency_ms = Some 0 })
    ; complete_stream =
        (fun ?on_telemetry:_ ~on_event:_ _request -> Error (transport_error ()))
    }
  in
  let target =
    let parent_config = Types.default_config ~model:"parent-model" in
    { Handoff.name = "researcher"
    ; description = "Inspect the requested subject"
    ; config =
        { parent_config with
          name = "researcher"
        ; model = "subagent-model"
        ; system_prompt = Some "Inspect the request."
        }
    ; tools = []
    }
  in
  let agent =
    Builder.create ~net ~model:"parent-model"
    |> Builder.with_provider_config (exact_provider_config ())
    |> Builder.with_transport transport
    |> Builder.build_safe
    |> Result.get_ok
  in
  let result =
    Eio.Switch.run (fun sw ->
      Agent.run_with_handoffs ~sw agent ~targets:[ target ] "delegate")
  in
  (match result with
   | Ok response ->
     Alcotest.(check string)
       "parent completes"
       "parent done"
       (Types.visible_text_of_response response)
   | Error error -> Alcotest.fail (Error.to_string error));
  Alcotest.(check int) "parent and subagent use one transport" 3 !calls;
  Alcotest.(check int) "all scripted responses consumed" 0 (List.length !responses)
;;

(* --- 15. with_mcp_clients --- *)

let test_with_mcp_clients () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_mcp_clients []
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check int) "mcp_clients" 0 (List.length (Agent.options agent).mcp_clients)
;;

(* --- 17. with_contract composes prompt --- *)

let test_with_contract_composes_prompt () =
  with_net
  @@ fun net ->
  let contract =
    Contract.empty
    |> Contract.with_runtime_awareness
         "You are running inside an explicit runtime contract."
    |> Contract.with_trigger ~source:"room" ~reason:"direct mention" "direct_mention"
    |> Contract.add_instruction_layer ~label:"role" "Prefer concise, factual answers."
  in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_system_prompt "Base prompt."
    |> Builder.with_contract contract
    |> Builder.build_safe
    |> Result.get_ok
  in
  let prompt =
    match (Agent.state agent).config.system_prompt with
    | Some value -> value
    | None -> Alcotest.fail "missing composed system prompt"
  in
  Alcotest.(check bool)
    "base prompt preserved"
    true
    (contains_substring ~needle:"Base prompt." prompt);
  Alcotest.(check bool)
    "runtime awareness section"
    true
    (contains_substring ~needle:"[Runtime Awareness]" prompt
     && contains_substring
          ~needle:"You are running inside an explicit runtime contract."
          prompt);
  Alcotest.(check bool)
    "trigger section rendered"
    true
    (contains_substring ~needle:"[Trigger Context]" prompt
     && contains_substring ~needle:"kind: direct_mention" prompt
     && contains_substring ~needle:"source: room" prompt);
  Alcotest.(check bool)
    "instruction layer rendered"
    true
    (contains_substring ~needle:"[Instruction Layer: role]" prompt
     && contains_substring ~needle:"Prefer concise, factual answers." prompt)
;;

(* --- 19. with_skill appends skill prompt --- *)

let test_with_skill_appends_prompt () =
  with_net
  @@ fun net ->
  let skill =
    Skill.of_markdown
      "---\n\
       name: reviewer\n\
       description: Review skill\n\
       ---\n\
       State concrete findings first."
  in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_system_prompt "Base prompt."
    |> Builder.with_skill skill
    |> Builder.build_safe
    |> Result.get_ok
  in
  let prompt =
    match (Agent.state agent).config.system_prompt with
    | Some value -> value
    | None -> Alcotest.fail "missing prompt with skill"
  in
  Alcotest.(check bool)
    "skill label present"
    true
    (contains_substring ~needle:"[Skill: reviewer]" prompt);
  Alcotest.(check bool)
    "skill body present"
    true
    (contains_substring ~needle:"State concrete findings first." prompt)
;;

(* --- 20. with_contract injects context metadata --- *)

let test_with_contract_injects_context_metadata () =
  with_net
  @@ fun net ->
  let ctx = Context.create_sync () in
  Context.set ctx "original" (`String "kept");
  let contract =
    Contract.empty |> Contract.with_runtime_awareness "Aware of explicit grants."
  in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_context ctx
    |> Builder.with_contract contract
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check (option string))
    "original context kept"
    (Some "kept")
    (match Context.get (Agent.context agent) "original" with
     | Some (`String value) -> Some value
     | _ -> None);
  Alcotest.(check bool)
    "contract metadata injected"
    true
    (match Context.get (Agent.context agent) "agent_sdk.contract" with
     | Some (`Assoc _) -> true
     | _ -> false)
;;

(* --- 22. with_tool_choice --- *)

let test_with_tool_choice () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_tool_choice Types.Any
    |> Builder.build_safe
    |> Result.get_ok
  in
  let expected = Types.tool_choice_to_json Types.Any in
  let actual =
    match (Agent.state agent).config.tool_choice with
    | Some tc -> Types.tool_choice_to_json tc
    | None -> `Null
  in
  Alcotest.(check string)
    "tool_choice Any"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string actual)
;;

(* --- 23. with_thinking_budget --- *)

let test_with_thinking_budget () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_enable_thinking true
    |> Builder.with_thinking_budget 10000
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check (option int))
    "thinking_budget"
    (Some 10000)
    (Agent.state agent).config.thinking_budget
;;

let test_with_reasoning_effort () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_reasoning_effort Llm_provider.Reasoning_effort.Max
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check (option string))
    "reasoning_effort"
    (Some "max")
    (Option.map
       Llm_provider.Reasoning_effort.to_string
       (Agent.state agent).config.reasoning_effort)
;;

(* --- 26. build produces valid agent --- *)

let test_build_produces_valid_agent () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-opus-4-5"
    |> Builder.with_name "full-agent"
    |> Builder.with_system_prompt "Be concise."
    |> Builder.with_max_tokens 2048
    |> Builder.with_temperature 0.3
    |> Builder.build_safe
    |> Result.get_ok
  in
  let cfg = (Agent.state agent).config in
  Alcotest.(check string) "name" "full-agent" cfg.name;
  check_model "model" "claude-opus-4-5" cfg.model;
  Alcotest.(check (option string)) "system_prompt" (Some "Be concise.") cfg.system_prompt;
  Alcotest.(check (option int)) "max_tokens" (Some 2048) cfg.max_tokens;
  Alcotest.(check (option (float 0.001))) "temperature" (Some 0.3) cfg.temperature;
  Alcotest.(check int) "messages empty" 0 (List.length (Agent.state agent).messages);
  Alcotest.(check int) "turn_count zero" 0 (Agent.state agent).turn_count;
  Alcotest.(check int) "api_calls zero" 0 (Agent.state agent).usage.api_calls
;;

(* --- 27. chain multiple --- *)

let test_chain_multiple () =
  with_net
  @@ fun net ->
  let t1 = make_tool "t1" in
  let t2 = make_tool "t2" in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4"
    |> Builder.with_name "chained"
    |> Builder.with_system_prompt "system"
    |> Builder.with_max_tokens 1024
    |> Builder.with_temperature 0.5
    |> Builder.with_tool t1
    |> Builder.with_tool t2
    |> Builder.with_enable_thinking true
    |> Builder.with_thinking_budget 5000
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check string) "name" "chained" (Agent.state agent).config.name;
  Alcotest.(check (option int))
    "max_tokens"
    (Some 1024)
    (Agent.state agent).config.max_tokens;
  Alcotest.(check int) "tool count" 2 (Tool_set.size (Agent.tools agent));
  Alcotest.(check (option int))
    "thinking_budget"
    (Some 5000)
    (Agent.state agent).config.thinking_budget
;;

(* --- 28. immutability check --- *)

let test_immutability_check () =
  with_net
  @@ fun net ->
  let original = Builder.create ~net ~model:"claude-sonnet-4-6" in
  let _modified = original |> Builder.with_name "modified" in
  let agent_from_original = Builder.build_safe original |> Result.get_ok in
  Alcotest.(check string)
    "original name unchanged"
    "agent"
    (Agent.state agent_from_original).config.name
;;

(* --- 29. defaults match Agent.create defaults --- *)

let test_defaults_match_agent_create () =
  with_net
  @@ fun net ->
  let builder_agent =
    Builder.create ~net ~model:"claude-sonnet-4-6" |> Builder.build_safe |> Result.get_ok
  in
  let direct_agent =
    Agent.create ~config:(Types.default_config ~model:"claude-sonnet-4-6") ~net ()
  in
  let bc = (Agent.state builder_agent).config in
  let dc = (Agent.state direct_agent).config in
  Alcotest.(check string) "name" dc.name bc.name;
  check_model "model" dc.model bc.model;
  Alcotest.(check (option string)) "system_prompt" dc.system_prompt bc.system_prompt;
  Alcotest.(check (option int)) "max_tokens" dc.max_tokens bc.max_tokens;
  Alcotest.(check (option (float 0.001))) "temperature" dc.temperature bc.temperature;
  Alcotest.(check string)
    "response_format"
    (Types.show_response_format dc.response_format)
    (Types.show_response_format bc.response_format);
  Alcotest.(check (option int)) "thinking_budget" dc.thinking_budget bc.thinking_budget;
  Alcotest.(check bool)
    "cache_system_prompt"
    dc.cache_system_prompt
    bc.cache_system_prompt;
  Alcotest.(check int) "tools" 0 (Tool_set.size (Agent.tools builder_agent))
;;

(* --- 30. build with tools merges mcp --- *)

let test_build_with_tools_merges_mcp () =
  with_net
  @@ fun net ->
  let t1 = make_tool "explicit" in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_tool t1
    |> Builder.with_mcp_clients []
    |> Builder.build_safe
    |> Result.get_ok
  in
  Alcotest.(check int) "tool count with empty mcp" 1 (Tool_set.size (Agent.tools agent));
  Alcotest.(check string)
    "tool name"
    "explicit"
    (List.hd (Tool_set.to_list (Agent.tools agent))).schema.name
;;

(* --- 31. build minimal: only net+model, rest defaults --- *)

let test_build_minimal_required_only () =
  with_net
  @@ fun net ->
  let agent =
    Builder.create ~net ~model:"claude-3-7-sonnet" |> Builder.build_safe |> Result.get_ok
  in
  check_model "model" "claude-3-7-sonnet" (Agent.state agent).config.model;
  Alcotest.(check string) "name" "agent" (Agent.state agent).config.name;
  Alcotest.(check (option int)) "max_tokens" None (Agent.state agent).config.max_tokens;
  Alcotest.(check int) "tools" 0 (Tool_set.size (Agent.tools agent))
;;

(* --- Run all --- *)

let () =
  Alcotest.run
    "Builder"
    [ "create", [ Alcotest.test_case "sets model" `Quick test_create_sets_model ]
    ; ( "with_setters"
      , [ Alcotest.test_case "system_prompt" `Quick test_with_system_prompt
        ; Alcotest.test_case "name" `Quick test_with_name
        ; Alcotest.test_case "max_tokens" `Quick test_with_max_tokens
        ; Alcotest.test_case "temperature" `Quick test_with_temperature
        ; Alcotest.test_case "dashscope sampling" `Quick test_with_provider_m_sampling
        ; Alcotest.test_case "tools replaces" `Quick test_with_tools_replaces
        ; Alcotest.test_case "tool appends" `Quick test_with_tool_appends
        ; Alcotest.test_case "hooks" `Quick test_with_hooks
        ; Alcotest.test_case "tracer" `Quick test_with_tracer
        ; Alcotest.test_case "transport" `Quick test_with_transport
        ; Alcotest.test_case "context" `Quick test_with_context
        ; Alcotest.test_case
            "exact provider config reaches dispatch losslessly"
            `Quick
            test_with_provider_config_reaches_dispatch_losslessly
        ; Alcotest.test_case
            "missing provider config rejected at dispatch"
            `Quick
            test_missing_provider_config_is_rejected_at_dispatch
        ; Alcotest.test_case
            "handoff inherits injected transport"
            `Quick
            test_handoff_inherits_injected_transport
        ; Alcotest.test_case "mcp_clients" `Quick test_with_mcp_clients
        ; Alcotest.test_case
            "contract composes prompt"
            `Quick
            test_with_contract_composes_prompt
        ; Alcotest.test_case "skill appends prompt" `Quick test_with_skill_appends_prompt
        ; Alcotest.test_case
            "contract injects context metadata"
            `Quick
            test_with_contract_injects_context_metadata
        ; Alcotest.test_case "tool_choice" `Quick test_with_tool_choice
        ; Alcotest.test_case "thinking_budget" `Quick test_with_thinking_budget
        ; Alcotest.test_case "reasoning_effort" `Quick test_with_reasoning_effort
        ] )
    ; ( "build"
      , [ Alcotest.test_case "valid agent" `Quick test_build_produces_valid_agent
        ; Alcotest.test_case "chain multiple" `Quick test_chain_multiple
        ; Alcotest.test_case "immutability" `Quick test_immutability_check
        ; Alcotest.test_case
            "defaults match Agent.create"
            `Quick
            test_defaults_match_agent_create
        ; Alcotest.test_case "tools merges mcp" `Quick test_build_with_tools_merges_mcp
        ; Alcotest.test_case
            "minimal required only"
            `Quick
            test_build_minimal_required_only
        ] )
    ]
;;
