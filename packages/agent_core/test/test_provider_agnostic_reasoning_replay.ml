open Llm_provider
open Types

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)

let contract replay_policy : Reasoning_replay_contract.t =
  { replay_policy; streaming = No_streaming_reasoning; output_wire = No_output_control; content_carrier = Canonical_blocks }
;;

let source
      ?(kind = Provider_config.OpenAI_compat)
      ?(base_url = "https://provider.example")
      ?(request_path = "/v1/chat/completions")
      ?(model_id = "model-a")
      replay_policy
  =
  match
    Types.Reasoning_source.create
      ~provider_kind:kind
      ~provider_instance:
        (Types.Reasoning_source.provider_instance ~base_url ~request_path)
      ~canonical_model_id:model_id
      ~replay_contract:(contract replay_policy)
  with
  | Ok source -> source
  | Error detail -> Alcotest.fail detail
;;

let message ?(origin=Types.Conversation) ?(metadata = []) role content : message =
  { origin; role; content; name = None; tool_call_id = None; metadata }
;;

let with_source source role content =
  message ~metadata:(Types.Reasoning_source.metadata source) role content
;;

let reasoning_supported = function
  | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> true
  | Text _ | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> false
;;

(* Rotation defaults to the strictest declared rule so existing expectations
   keep exercising exact-source matching; the rotation-specific cases pass
   [~rotation] explicitly. *)
let project
      ?(rotation = Reasoning_replay_contract.Require_identical_source)
      ~target
      ~policy
      messages
  =
  let replay_capability : Reasoning_dialect.replay_capability =
    { target
    ; contract =
        { Reasoning_replay_contract.replay_policy = policy
        ; streaming = Reasoning_replay_contract.No_streaming_reasoning
        ; output_wire = Reasoning_replay_contract.No_output_control; content_carrier = Canonical_blocks
        }
    ; rotation
    }
  in
  Reasoning_history_projection.project
    ~assistant_has_payload:(fun content -> content <> [])
    ~reasoning_block_supported:reasoning_supported
    ~replay_capability
    messages
;;

let content_has_reasoning =
  List.exists (function
    | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> true
    | Text _ | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> false)
;;

let content_has_tool_use =
  List.exists (function
    | ToolUse _ -> true
    | Text _
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> false)
;;

let tool_result tool_use_id =
  ToolResult
    { tool_use_id
    ; content = "ok"
    ; outcome = Tool_succeeded
    ; json = None
    ; content_blocks = None
    }
;;

let test_source_exactness_and_classification () =
  let left = source All_assistant_messages in
  let same = source All_assistant_messages in
  let other_endpoint = source ~base_url:"https://other.example" All_assistant_messages in
  let other_model = source ~model_id:"model-b" All_assistant_messages in
  check_bool "same exact source" true (Types.Reasoning_source.equal left same);
  check_bool
    "endpoint identity differs"
    false
    (Types.Reasoning_source.equal left other_endpoint);
  check_bool
    "model identity differs"
    false
    (Types.Reasoning_source.equal left other_model);
  (match Types.Reasoning_source.classify (Types.Reasoning_source.metadata left) with
   | Present actual ->
     check_bool "metadata round-trip" true (Reasoning_source.equal left actual)
   | Absent | Invalid | Duplicate -> Alcotest.fail "expected present source");
  let entry = Types.Reasoning_source.entry left in
  match Types.Reasoning_source.classify [ entry; entry ] with
  | Duplicate -> ()
  | Absent | Present _ | Invalid -> Alcotest.fail "expected duplicate source"
;;

let test_whole_history_source_filtering () =
  let target = source All_assistant_messages in
  let foreign = source ~model_id:"foreign" All_assistant_messages in
  let messages =
    [ with_source target Assistant [ Thinking { content = "keep"; signature = None } ]
    ; with_source foreign Assistant [ Thinking { content = "foreign"; signature = None } ]
    ; message Assistant [ Thinking { content = "unsourced"; signature = None } ]
    ; message User [ Text "next" ]
    ]
  in
  match project ~target ~policy:All_assistant_messages messages with
  | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
  | Ok projection ->
    check_int
      "foreign and unsourced drops"
      2
      (List.length projection.reasoning_replay_drops);
    check_int
      "reasoning-only empty assistants removed"
      2
      (List.length projection.removed_empty_assistant_indices);
    check_int "kept assistant plus user" 2 (List.length projection.messages);
    let first = List.hd projection.messages in
    check_bool "exact-source reasoning remains" true (content_has_reasoning first.content)
;;

let test_tool_call_policy_applies_across_history () =
  let target = source Tool_call_assistant_messages_all_history in
  let messages =
    [ with_source
        target
        Assistant
        [ Thinking { content = "tool reasoning"; signature = None }
        ; ToolUse { id = "call"; name = "lookup"; input = `Assoc [] }
        ]
    ; message
        Tool
        [ ToolResult
            { tool_use_id = "call"
            ; content = "ok"
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ; with_source
        target
        Assistant
        [ Thinking { content = "plain reasoning"; signature = None }; Text "answer" ]
    ]
  in
  match project ~target ~policy:Tool_call_assistant_messages_all_history messages with
  | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
  | Ok projection ->
    let first = List.nth projection.messages 0 in
    let last = List.nth projection.messages 2 in
    check_bool
      "tool-call assistant keeps reasoning"
      true
      (content_has_reasoning first.content);
    check_bool
      "plain assistant drops reasoning"
      false
      (content_has_reasoning last.content)
;;

let test_latest_user_turn_policy_keeps_only_current_tool_reasoning () =
  let target = source Tool_call_assistant_messages_latest_user_turn in
  let messages =
    [ message User [ Text "first request" ]
    ; with_source
        target
        Assistant
        [ Thinking { content = "old tool reasoning"; signature = None }
        ; ToolUse { id = "old-call"; name = "lookup"; input = `Assoc [] }
        ]
    ; message Tool [ tool_result "old-call" ]
    ; message User [ Text "current request" ]
    ; with_source
        target
        Assistant
        [ Thinking { content = "current tool reasoning"; signature = None }
        ; ToolUse { id = "current-call"; name = "inspect"; input = `Assoc [] }
        ]
    ; message Tool [ tool_result "current-call" ]
    ]
  in
  match
    project ~target ~policy:Tool_call_assistant_messages_latest_user_turn messages
  with
  | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
  | Ok projection ->
    check_int
      "message and tool-result history is lossless"
      6
      (List.length projection.messages);
    check_int
      "only the older reasoning artifact is dropped"
      1
      (List.length projection.reasoning_replay_drops);
    let old_assistant = List.nth projection.messages 1 in
    let current_assistant = List.nth projection.messages 4 in
    check_bool "old tool call remains" true (content_has_tool_use old_assistant.content);
    check_bool
      "old reasoning is removed"
      false
      (content_has_reasoning old_assistant.content);
    check_bool
      "current tool reasoning remains"
      true
      (content_has_reasoning current_assistant.content)
;;

(* Live incident 2026-08-24 (task-514): every keeper provider round appends the
   extra-system-context carrier as a trailing User-role message, so the
   "latest user turn" anchored on the carrier and every reasoning block in the
   request was dropped, every round. The carrier must be invisible to the
   latest-user boundary while a real trailing user message still resets it. *)
let extra_context_carrier () =
  message
    ~origin:Types.System_context
    User
    [ Text "[system context] world state" ]
;;

let test_latest_user_turn_policy_ignores_extra_context_carrier () =
  let target = source Tool_call_assistant_messages_latest_user_turn in
  let messages =
    [ message User [ Text "current request" ]
    ; with_source
        target
        Assistant
        [ Thinking { content = "current tool reasoning"; signature = None }
        ; ToolUse { id = "current-call"; name = "inspect"; input = `Assoc [] }
        ]
    ; message Tool [ tool_result "current-call" ]
    ; extra_context_carrier ()
    ; message ~origin:Recovery_instruction User [Text "correct the rejected tool name"]
    ; message ~origin:Tool_result_followup User [Text "tool image description"]
    ; message ~origin:Agent_instruction User [Text "runtime range preamble"]
    ]
  in
  match
    project ~target ~policy:Tool_call_assistant_messages_latest_user_turn messages
  with
  | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
  | Ok projection ->
    check_int "no reasoning dropped" 0 (List.length projection.reasoning_replay_drops);
    let assistant = List.nth projection.messages 1 in
    check_bool
      "reasoning after the real user turn survives the trailing carrier"
      true
      (content_has_reasoning assistant.content)
;;

let test_latest_user_turn_policy_real_trailing_user_still_resets () =
  let target = source Tool_call_assistant_messages_latest_user_turn in
  let messages =
    [ message User [ Text "first request" ]
    ; with_source
        target
        Assistant
        [ Thinking { content = "old tool reasoning"; signature = None }
        ; ToolUse { id = "old-call"; name = "lookup"; input = `Assoc [] }
        ]
    ; message Tool [ tool_result "old-call" ]
    ; message User [ Text "a person actually speaking" ]
    ]
  in
  match
    project ~target ~policy:Tool_call_assistant_messages_latest_user_turn messages
  with
  | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
  | Ok projection ->
    check_int
      "reasoning before the real user turn is dropped"
      1
      (List.length projection.reasoning_replay_drops);
    let assistant = List.nth projection.messages 1 in
    check_bool
      "old reasoning is removed"
      false
      (content_has_reasoning assistant.content)
;;

let test_carrier_only_history_preserves_tool_reasoning () =
  let target = source Tool_call_assistant_messages_latest_user_turn in
  let messages =
    [ extra_context_carrier ()
    ; with_source
        target
        Assistant
        [ Thinking { content = "unscoped reasoning"; signature = None }
        ; ToolUse { id = "call"; name = "lookup"; input = `Assoc [] }
        ]
    ; message Tool [ tool_result "call" ]
    ]
  in
  match
    project ~target ~policy:Tool_call_assistant_messages_latest_user_turn messages
  with
  | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
  | Ok projection ->
    let assistant = List.nth projection.messages 1 in
    check_bool
      "a control carrier cannot prove the retained tool exchange is closed"
      true
      (content_has_reasoning assistant.content)
;;

let test_latest_user_turn_policy_without_user_preserves_tool_reasoning () =
  let target = source Tool_call_assistant_messages_latest_user_turn in
  let messages =
    [ with_source
        target
        Assistant
        [ Thinking { content = "unscoped reasoning"; signature = None }
        ; ToolUse { id = "call"; name = "lookup"; input = `Assoc [] }
        ]
    ; message Tool [ tool_result "call" ]
    ]
  in
  match
    project ~target ~policy:Tool_call_assistant_messages_latest_user_turn messages
  with
  | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
  | Ok projection ->
    let assistant = List.hd projection.messages in
    check_bool "tool call remains" true (content_has_tool_use assistant.content);
    check_bool
      "a missing caller boundary preserves compatible tool reasoning"
      true
      (content_has_reasoning assistant.content)
;;

let test_selected_unsupported_block_fails_closed () =
  let target = source All_assistant_messages in
  let result =
    Reasoning_history_projection.project
      ~assistant_has_payload:(fun content -> content <> [])
      ~reasoning_block_supported:(fun _ -> false)
      ~replay_capability:
        { target
        ; contract =
            { Reasoning_replay_contract.replay_policy = All_assistant_messages
            ; streaming = Reasoning_replay_contract.No_streaming_reasoning
            ; output_wire = Reasoning_replay_contract.No_output_control; content_carrier = Canonical_blocks
            }
        ; rotation = Reasoning_replay_contract.Require_identical_source
        }
      [ with_source target Assistant [ Thinking { content = "x"; signature = None } ] ]
  in
  match result with
  | Error (Unsupported_reasoning_block _) -> ()
  | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
  | Ok _ -> Alcotest.fail "unsupported selected reasoning must fail"
;;

let test_assistant_message_requires_live_source () =
  let response : api_response =
    { id = "response"
    ; model = "model-a"
    ; stop_reason = EndTurn
    ; content = [ Thinking { content = "reasoning"; signature = None } ]
    ; usage = None
    ; telemetry = None
    }
  in
  (match Types.assistant_message_of_response response with
   | Error Reasoning_source_telemetry_missing -> ()
   | Error _ | Ok _ -> Alcotest.fail "missing telemetry must be explicit");
  let source = source All_assistant_messages in
  let telemetry =
    { Types.default_inference_telemetry with reasoning_source = Some source }
  in
  match
    Types.assistant_message_of_response { response with telemetry = Some telemetry }
  with
  | Error error -> Alcotest.fail (Types.show_assistant_message_error error)
  | Ok assistant ->
    (match Types.Reasoning_source.classify assistant.metadata with
     | Present actual ->
       check_bool "response source persisted" true (Reasoning_source.equal source actual)
     | Absent | Invalid | Duplicate -> Alcotest.fail "expected persisted source")
;;

let preserving_capabilities =
  { Capabilities.default_capabilities with
    reasoning_replay_override = Force_preserve_always
  }
;;

let non_replaying_capabilities =
  { Capabilities.default_capabilities with
    supports_reasoning = true
  ; reasoning_replay_override = Force_no_replay
  }
;;

let latest_user_turn_capabilities =
  { Capabilities.default_capabilities with
    supports_reasoning = true
  ; thinking_control_format = Chat_template_kwargs
  ; preserve_thinking_control_format = Chat_template_kwargs_preserve_thinking
  ; reasoning_replay_override = Force_latest_user_turn_tool_calls
  }
;;

let source_for_config config =
  match Reasoning_dialect.reasoning_source_for_provider_config config with
  | Ok source -> source
  | Error detail -> Alcotest.fail detail
;;

(* A caller that has to size a request before building one asks
   [Complete_common.transmitted_history]. If that answer and the serializer's
   own removal could differ, the caller would budget for bytes the wire drops —
   which is how a keeper ends up charging 23.6% of its window to reasoning the
   provider never receives. Both sides now run the same per-codec function; this
   pins that the answer tracks the replay contract rather than a second
   opinion. *)
let transmitted_history_exn ~config messages =
  match Complete_common.transmitted_history ~config messages with
  | Ok projected -> projected
  | Error error ->
    Alcotest.fail (Reasoning_history_projection.error_to_string error)
;;

let reasoning_block_count messages =
  List.fold_left
    (fun total (message : message) ->
       total
       + List.length (List.filter reasoning_supported message.content))
    0
    messages
;;

let history_with_reasoning source =
  [ message User [ Text "first request" ]
  ; with_source source Assistant [ Thinking { content = "deliberation"; signature = None }; Text "answer" ]
  ; message User [ Text "second request" ]
  ]
;;

let test_transmitted_history_drops_what_the_wire_drops () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"model-a"
      ~base_url:"https://provider.example"
      ~model_capabilities_override:non_replaying_capabilities
      ()
  in
  let dialect = Reasoning_dialect.for_provider_config config in
  check_bool
    "this config replays nothing"
    true
    ((Reasoning_dialect.replay_contract dialect).replay_policy = No_replay);
  let messages = history_with_reasoning (source_for_config config) in
  check_int "the history carries reasoning" 1 (reasoning_block_count messages);
  check_int
    "and the transmitted view carries none"
    0
    (reasoning_block_count (transmitted_history_exn ~config messages));
  check_int
    "while the conversation itself survives"
    3
    (List.length (transmitted_history_exn ~config messages))
;;

let test_transmitted_history_keeps_what_the_wire_keeps () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"model-a"
      ~base_url:"https://provider.example"
      ~model_capabilities_override:preserving_capabilities
      ()
  in
  let messages = history_with_reasoning (source_for_config config) in
  check_int
    "a replaying config transmits its reasoning"
    1
    (reasoning_block_count (transmitted_history_exn ~config messages))
;;

(* Anthropic signs each thinking block against the system prompt, the tools and
   every message before it, and rejects a replayed block when any of them
   changed. A caller that edits its history between requests declares
   [Force_latest_user_turn_tool_calls] on the capability row, and the Messages
   wire has to honor it: only the latest user turn's tool loop carries
   reasoning back, an earlier turn's signed block (tool-call or plain) is left
   out. Dropping is always accepted by the API; a stale block is a 400 that a
   retry cannot clear. *)
let test_anthropic_honors_a_latest_turn_replay_declaration () =
  let config =
    Provider_config.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-5-5"
      ~base_url:"https://api.anthropic.com"
      ~model_capabilities_override:
        { (Capabilities.capabilities_of_kind Provider_config.Anthropic) with
          reasoning_replay_override = Capabilities.Force_latest_user_turn_tool_calls
        }
      ()
  in
  let source = source_for_config config in
  let signed content = Thinking { content; signature = Some "signature-of-the-producing-request" } in
  let messages =
    [ message User [ Text "first request" ]
    ; with_source source Assistant [ signed "plain answer reasoning"; Text "first answer" ]
    ; message User [ Text "current request" ]
    ; with_source
        source
        Assistant
        [ signed "current tool reasoning"
        ; ToolUse { id = "current-call"; name = "inspect"; input = `Assoc [] }
        ]
    ; message Tool [ tool_result "current-call" ]
    ]
  in
  let projected = transmitted_history_exn ~config messages in
  check_int "the conversation itself survives" 5 (List.length projected);
  check_bool
    "an earlier turn's signed reasoning is not replayed"
    false
    (content_has_reasoning (List.nth projected 1).content);
  check_bool
    "the earlier answer text remains"
    true
    (List.exists (function Text "first answer" -> true | _ -> false) (List.nth projected 1).content);
  check_bool
    "the current tool loop keeps its reasoning"
    true
    (content_has_reasoning (List.nth projected 3).content)
;;

(* Creation-prefix binding: a signed thinking block replays only while the
   system prompt, the tools, the controls, and every byte before it are
   unchanged. The live failure these pin: round one carries an extra-context
   block the post-tool round drops, so round two's replay of round one's
   thinking fails the whole request with an unretryable "Invalid signature
   in thinking block" 400. The fold drops the stale block instead, and the
   turn proceeds. *)

let anthropic_build_config () =
  Provider_config.make
    ~kind:Anthropic
    ~model_id:"claude-sonnet-5-5"
    ~base_url:"https://api.anthropic.com"
    ~max_tokens:4096
    ~system_prompt:"keeper system"
    ~model_capabilities_override:
      { (Capabilities.capabilities_of_kind Provider_config.Anthropic) with
        reasoning_replay_override = Capabilities.Force_latest_user_turn_tool_calls
      }
    ()
;;

let anthropic_build_config_variant
      ?(system = "keeper system")
      ?temperature
      ?tool_choice
      ?cache_system_prompt
      ?cap_override
      ()
  =
  let model_capabilities_override =
    match cap_override with
    | Some caps -> caps
    | None ->
      { (Capabilities.capabilities_of_kind Provider_config.Anthropic) with
        reasoning_replay_override = Capabilities.Force_latest_user_turn_tool_calls
      }
  in
  Provider_config.make
    ~kind:Anthropic
    ~model_id:"claude-sonnet-5-5"
    ~base_url:"https://api.anthropic.com"
    ~max_tokens:4096
    ~system_prompt:system
    ?temperature
    ?tool_choice
    ?cache_system_prompt
    ~model_capabilities_override
    ()
;;

let prefix_test_tool_schema =
  `Assoc
    [ "name", `String "inspect"
    ; "description", `String "inspect something"
    ; "input_schema", `Assoc [ "type", `String "object" ]
    ]
;;

let stamped_assistant ~config ~request_messages ~tools response_content =
  let prefix =
    Backend_anthropic.transmitted_reasoning_prefix
      ~config
      ~messages:request_messages
      ~tools
      ~response_content
      ()
  in
  check_bool "the producing request records a digest" true (Option.is_some prefix);
  let telemetry =
    { Types.default_inference_telemetry with
      reasoning_source = Some (source_for_config config)
    ; reasoning_prefix = prefix
    }
  in
  let response =
    { Types.id = "msg_test_round_one"
    ; model = "claude-sonnet-5-5"
    ; stop_reason = Types.EndTurn
    ; content = response_content
    ; usage = None
    ; telemetry = Some telemetry
    }
  in
  match Types.assistant_message_of_response response with
  | Ok message -> message
  | Error _ -> Alcotest.fail "a sourced response must stamp"
;;

let wire_content_types body =
  let open Yojson.Safe.Util in
  Yojson.Safe.from_string body |> member "messages" |> to_list
  |> List.map (fun message ->
      message |> member "content" |> to_list
      |> List.map (fun block -> block |> member "type" |> to_string))
;;

let round_one_fixtures () =
  let config = anthropic_build_config () in
  let tools = [ prefix_test_tool_schema ] in
  let carrier = message User [ Text "trigger"; Text "extra context block" ] in
  let response_content =
    [ Thinking { content = "round one reasoning"; signature = Some "sig-round-one" }
    ; Text "round one text"
    ; ToolUse { id = "call-1"; name = "inspect"; input = `Assoc [] }
    ]
  in
  let assistant =
    stamped_assistant ~config ~request_messages:[ carrier ] ~tools response_content
  in
  config, tools, carrier, assistant
;;

(* The agent pipeline admits every request body before it dispatches
   ([Pipeline_stage_route]: [admit_request_body], then [complete_serialized]
   or [complete_stream_serialized]), so a Keeper turn's response always
   arrives with an admitted body. It must still record its prefix, or the
   next round drops every thinking block as [Prefix_digest_absent]. *)
let admitted_round_one ~stream =
  let config = anthropic_build_config () in
  let tools = [ prefix_test_tool_schema ] in
  let carrier = message User [ Text "trigger"; Text "extra context block" ] in
  let response =
    { Types.id = "msg_admitted_round_one"
    ; model = "claude-sonnet-5-5"
    ; stop_reason = Types.EndTurn
    ; content =
        [ Thinking { content = "admitted round reasoning"; signature = Some "sig-admitted" }
        ; Text "admitted round text"
        ; ToolUse { id = "call-1"; name = "inspect"; input = `Assoc [] }
        ]
    ; usage = None
    ; telemetry = None
    }
  in
  let transport =
    Llm_provider.Llm_transport.custom ({ Llm_transport.complete_sync =
        (fun _ -> { Llm_transport.response = Ok response; latency_ms = None })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> Ok response)
    })
  in
  let completed =
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let prepared = Complete.prepare_request ~config ~messages:[ carrier ] ~tools () in
    match Complete.admit_request_body ~stream prepared with
    | Error _ -> Alcotest.fail "the round-one body must be admitted"
    | Ok serialized ->
      if stream
      then
        (Complete.complete_stream_serialized
          ~sw
          ~net
          ~transport
          serialized
          ~on_event:ignore
          ()).Llm_provider.Completion_outcome.result
      else (Complete.complete_serialized ~sw ~net ~transport serialized ()).Llm_provider.Completion_outcome.result
  in
  match completed with
  | Error _ -> Alcotest.fail "the stubbed admitted completion must succeed"
  | Ok resp -> config, tools, carrier, resp
;;

let check_admitted_round_two_keeps_thinking ~stream =
  let config, tools, carrier, resp = admitted_round_one ~stream in
  check_bool
    "the admitted response records its prefix"
    true
    (match resp.telemetry with
     | Some telemetry -> Option.is_some telemetry.reasoning_prefix
     | None -> false);
  match Types.assistant_message_of_response resp with
  | Error _ -> Alcotest.fail "the admitted response must stamp"
  | Ok assistant ->
    let round_two = [ carrier; assistant; message Tool [ tool_result "call-1" ] ] in
    let body = Backend_anthropic.build_request ~config ~messages:round_two ~tools () in
    check_bool
      "round one's thinking replays in round two"
      true
      (List.mem "thinking" (List.nth (wire_content_types body) 1))
;;

let test_an_admitted_completion_keeps_thinking_for_the_next_round () =
  check_admitted_round_two_keeps_thinking ~stream:false
;;

let test_an_admitted_stream_keeps_thinking_for_the_next_round () =
  check_admitted_round_two_keeps_thinking ~stream:true
;;

let test_prefix_binding_keeps_thinking_on_a_stable_prefix () =
  let config, tools, carrier, assistant = round_one_fixtures () in
  let round_two = [ carrier; assistant; message Tool [ tool_result "call-1" ] ] in
  let body = Backend_anthropic.build_request ~config ~messages:round_two ~tools () in
  let types = wire_content_types body in
  check_int "three wire messages" 3 (List.length types);
  check_bool
    "round one's thinking replays verbatim"
    true
    (List.mem "thinking" (List.nth types 1));
  check_bool
    "round one's text still rides"
    true
    (List.mem "text" (List.nth types 1))
;;

let test_prefix_binding_drops_thinking_when_the_carrier_block_is_gone () =
  let config, tools, _carrier, assistant = round_one_fixtures () in
  (* The post-tool round drops the extra-context block the signature was
     bound to: the live 400 shape. *)
  let round_two =
    [ message User [ Text "trigger" ]; assistant; message Tool [ tool_result "call-1" ] ]
  in
  let body = Backend_anthropic.build_request ~config ~messages:round_two ~tools () in
  let types = wire_content_types body in
  check_int "three wire messages" 3 (List.length types);
  check_bool
    "the stale thinking block is dropped instead of failing the request"
    false
    (List.mem "thinking" (List.nth types 1));
  check_bool "the answer text still rides" true (List.mem "text" (List.nth types 1));
  check_bool
    "the tool call still rides"
    true
    (List.mem "tool_use" (List.nth types 1))
;;

let test_prefix_binding_drops_thinking_edited_in_place () =
  let config, tools, carrier, assistant = round_one_fixtures () in
  let edited =
    { assistant with
      content =
        List.map
          (function
            | Thinking thinking -> Thinking { thinking with content = "edited reasoning" }
            | block -> block)
          assistant.content
    }
  in
  let round_two = [ carrier; edited; message Tool [ tool_result "call-1" ] ] in
  let body = Backend_anthropic.build_request ~config ~messages:round_two ~tools () in
  let types = wire_content_types body in
  check_bool
    "edited thinking fails the message digest"
    false
    (List.mem "thinking" (List.nth types 1))
;;

let test_prefix_binding_drops_legacy_thinking_without_a_digest () =
  let config = anthropic_build_config () in
  let tools = [ prefix_test_tool_schema ] in
  let source = source_for_config config in
  let assistant =
    with_source
      source
      Assistant
      [ Thinking { content = "legacy reasoning"; signature = Some "sig-legacy" }
      ; ToolUse { id = "call-1"; name = "inspect"; input = `Assoc [] }
      ]
  in
  let round_two =
    [ message User [ Text "trigger" ]; assistant; message Tool [ tool_result "call-1" ] ]
  in
  let body = Backend_anthropic.build_request ~config ~messages:round_two ~tools () in
  let types = wire_content_types body in
  check_bool
    "a stamp without a digest fails closed"
    false
    (List.mem "thinking" (List.nth types 1))
;;

let test_prefix_entry_round_trip_and_classification () =
  let prefix =
    { Types.Reasoning_prefix.request_digest = String.make 64 'a'
    ; message_digest = String.make 64 'b'
    }
  in
  (match Types.Reasoning_prefix.classify (Types.Reasoning_prefix.metadata prefix) with
   | Present
       { Types.Reasoning_prefix.request_digest = request_digest
       ; message_digest = message_digest
       } ->
     check_bool
       "metadata round-trip"
       true
       (String.equal request_digest (String.make 64 'a')
        && String.equal message_digest (String.make 64 'b'))
   | Absent | Invalid | Duplicate -> Alcotest.fail "expected a present prefix");
  (match Types.Reasoning_prefix.classify [] with
   | Absent -> ()
   | Present _ | Invalid | Duplicate -> Alcotest.fail "expected absent prefix");
  let bad_hex =
    { Types.Reasoning_prefix.request_digest = "not-hex"
    ; message_digest = String.make 64 'b'
    }
  in
  (match Types.Reasoning_prefix.classify (Types.Reasoning_prefix.metadata bad_hex) with
   | Invalid -> ()
   | Absent | Present _ | Duplicate -> Alcotest.fail "expected an invalid prefix");
  let entry = Types.Reasoning_prefix.entry prefix in
  (match Types.Reasoning_prefix.classify [ entry; entry ] with
   | Duplicate -> ()
   | Absent | Present _ | Invalid -> Alcotest.fail "expected a duplicate prefix")
;;

let drop_testable =
  Alcotest.testable Reasoning_history_projection.pp_prefix_drop ( = )
;;

let fold_role_tag = function
  | System -> "system"
  | User -> "user"
  | Assistant -> "assistant"
  | Tool -> "tool"
;;

let fold ~head messages =
  Reasoning_history_projection.verify_prefix_binding
    ~head
    ~encode_block:Api_common.content_block_to_json
    ~message_header:(fun (message : message) -> ["role",`String (fold_role_tag message.role)])
    messages
;;

let valid_prefix_for_tag_tests =
  { Types.Reasoning_prefix.request_digest = String.make 64 'a'
  ; message_digest = String.make 64 'b'
  }
;;

let invalid_prefix_entries =
  Types.Reasoning_prefix.metadata
    { Types.Reasoning_prefix.request_digest = "not-hex"
    ; message_digest = String.make 64 'b'
    }
;;

let duplicate_prefix_entries =
  let entry = Types.Reasoning_prefix.entry valid_prefix_for_tag_tests in
  [ entry; entry ]
;;

let assistant_with_prefix_entries ~config entries content =
  message
    ~metadata:(Types.Reasoning_source.metadata (source_for_config config) @ entries)
    Assistant
    content
;;

let test_prefix_unreadable_entry_drops_with_its_own_cause () =
  let config = anthropic_build_config () in
  let thinking = [ Thinking { content = "t"; signature = Some "s" } ] in
  List.iter
    (fun (label, entries, cause) ->
       let verdict =
         fold ~head:[] [ assistant_with_prefix_entries ~config entries thinking ]
       in
       Alcotest.(check (list drop_testable))
         (label ^ ": the drop names its message and cause")
         [ { Reasoning_history_projection.message_index = 0
           ; cause
           ; stored_message_digest = None
           }
         ]
         verdict.prefix_drops;
       check_int (label ^ ": one message entered the fold with reasoning") 1
         verdict.reasoning_message_count;
       check_bool
         (label ^ ": the reasoning block is not in the verdict")
         false
         (List.exists
            (fun (m : message) -> content_has_reasoning m.content)
            verdict.messages))
    [ ( "invalid tag"
      , invalid_prefix_entries
      , Reasoning_history_projection.Prefix_entry_invalid )
    ; ( "duplicate tag"
      , duplicate_prefix_entries
      , Reasoning_history_projection.Prefix_entry_duplicate )
    ]
;;

(* A corrupted tag sits in stored history, so a request that refused it would
   refuse again on every later request while the message stays in the window.
   The request is built without that block, and a block created after the
   corruption was already being dropped still replays. *)
let test_a_corrupted_tag_in_history_does_not_block_requests () =
  let preserve_always =
    { (Capabilities.capabilities_of_kind Provider_config.Anthropic) with
      reasoning_replay_override = Capabilities.Force_preserve_always
    }
  in
  let config = anthropic_build_config_variant ~cap_override:preserve_always () in
  let tools = [ prefix_test_tool_schema ] in
  let thinking_blocks ~call_id reasoning signature =
    [ Thinking { content = reasoning; signature = Some signature }
    ; Text (reasoning ^ " text")
    ; ToolUse { id = call_id; name = "inspect"; input = `Assoc [] }
    ]
  in
  List.iter
    (fun (label, entries) ->
       let u1 = message User [ Text "one" ] in
       let corrupted =
         assistant_with_prefix_entries
           ~config
           entries
           (thinking_blocks ~call_id:"call-1" "corrupted reasoning" "sig-corrupted")
       in
       let t1 = message Tool [ tool_result "call-1" ] in
       let u2 = message User [ Text "two" ] in
       let later =
         stamped_assistant
           ~config
           ~request_messages:[ u1; corrupted; t1; u2 ]
           ~tools
           (thinking_blocks ~call_id:"call-2" "later reasoning" "sig-later")
       in
       let t2 = message Tool [ tool_result "call-2" ] in
       let history = [ u1; corrupted; t1; u2; later; t2 ] in
       let assert_wire body =
         let types = wire_content_types body in
         check_int (label ^ ": six distinct wire messages") 6 (List.length types);
         check_bool
           (label ^ ": the corrupted block is not sent")
           false
           (List.mem "thinking" (List.nth types 1));
         check_bool
           (label ^ ": its text still rides")
           true
           (List.mem "text" (List.nth types 1));
         check_bool
           (label ^ ": the block created after the corruption replays")
           true
           (List.mem "thinking" (List.nth types 4))
       in
       assert_wire (Backend_anthropic.build_request ~config ~messages:history ~tools ());
       (* Token counting shares the payload builder and had the same refusal. *)
       assert_wire
         (Backend_anthropic.build_count_tokens_request ~config ~messages:history ~tools ()))
    [ "invalid tag", invalid_prefix_entries
    ; "duplicate tag", duplicate_prefix_entries
    ]
;;

let stored_message_digest_exn (message : message) =
  match Types.Reasoning_prefix.classify message.metadata with
  | Present prefix -> prefix.Types.Reasoning_prefix.message_digest
  | Absent | Invalid | Duplicate -> Alcotest.fail "expected a stamped message"
;;

(* Stamps a response the way the record side does: the request digest is the
   chain over what the request would send, drops included. *)
let stamp_over ~head ~request_messages content =
  let verdict = fold ~head request_messages in
  let prefix =
    { Types.Reasoning_prefix.request_digest =
        verdict.Reasoning_history_projection.final_digest
    ; message_digest =
        Reasoning_history_projection.content_wire_digest
          ~encode_block:Api_common.content_block_to_json
          content
    }
  in
  message
    ~metadata:
      (Types.Reasoning_source.metadata (source_for_config (anthropic_build_config ()))
       @ Types.Reasoning_prefix.metadata prefix)
    Assistant
    content
;;

let hex_head_12 digest = String.sub digest 0 12

let test_a_cut_counts_once_per_request_and_later_blocks_survive () =
  let head_one = [ "system", `String "one" ] in
  let head_two = [ "system", `String "two" ] in
  let reasoning label = [ Thinking { content = label; signature = Some ("sig-" ^ label) }; Text label ] in
  let u1 = message User [ Text "u1" ] in
  let a = stamp_over ~head:head_one ~request_messages:[ u1 ] (reasoning "a") in
  let u2 = message User [ Text "u2" ] in
  let b = stamp_over ~head:head_one ~request_messages:[ u1; a; u2 ] (reasoning "b") in
  let history = [ u1; a; u2; b ] in
  let stable = fold ~head:head_one history in
  Alcotest.(check (list drop_testable)) "the creating head drops nothing" [] stable.prefix_drops;
  check_int "both blocks entered" 2 stable.reasoning_message_count;
  let changed = fold ~head:head_two history in
  let digest_a = stored_message_digest_exn a in
  let digest_b = stored_message_digest_exn b in
  Alcotest.(check (list drop_testable))
    "the first mismatch is the cut; the later block is its cascade"
    [ { Reasoning_history_projection.message_index = 1
      ; cause = Reasoning_history_projection.Prefix_request_mismatch
      ; stored_message_digest = Some digest_a
      }
    ; { Reasoning_history_projection.message_index = 3
      ; cause = Reasoning_history_projection.Prefix_chain_broken_upstream
      ; stored_message_digest = Some digest_b
      }
    ]
    changed.prefix_drops;
  (* A block stamped after the cut was already in effect chains over the
     stripped history, so it verifies and is not a drop. *)
  let u3 = message User [ Text "u3" ] in
  let c =
    stamp_over ~head:head_two ~request_messages:[ u1; a; u2; b; u3 ] (reasoning "c")
  in
  let later = fold ~head:head_two [ u1; a; u2; b; u3; c ] in
  Alcotest.(check (list drop_testable))
    "only the two stale blocks are cut; the block created afterwards replays"
    changed.prefix_drops
    later.prefix_drops;
  check_int "three blocks entered" 3 later.reasoning_message_count;
  let snapshot =
    Reasoning_history_projection.prefix_snapshot_json
      ~component:"test"
      ~stream:false
      changed
  in
  let open Yojson.Safe.Util in
  let int_field name = snapshot |> member name |> to_int in
  check_int "snapshot: entering" 2 (int_field "reasoning_messages");
  check_int "snapshot: replayed" 0 (int_field "reasoning_messages_replayed");
  check_int "snapshot: dropped" 2 (int_field "reasoning_messages_dropped");
  check_int "snapshot: one root mismatch" 1 (int_field "request_mismatch");
  check_int "snapshot: one cascade" 1 (int_field "chain_broken_upstream");
  check_int "snapshot: no tag corruption" 0 (int_field "entry_invalid");
  Alcotest.(check (list string))
    "snapshot names blocks by the head of their stored digest"
    [ hex_head_12 digest_a; hex_head_12 digest_b ]
    (snapshot |> member "dropped_block_ids" |> to_list |> List.map to_string)
;;

(* A block that never carried a readable stamp is dropped the same way by every
   request, so it says nothing about a later block whose digest stopped
   matching. That later block is the first real mismatch. A block whose stamp
   is unreadable might have been sent, and its removal does move later digests. *)
let test_a_stable_earlier_drop_does_not_hide_the_first_real_mismatch () =
  let config = anthropic_build_config () in
  let head_one = [ "system", `String "one" ] in
  let head_two = [ "system", `String "two" ] in
  let reasoning label =
    [ Thinking { content = label; signature = Some ("sig-" ^ label) }; Text label ]
  in
  let u1 = message User [ Text "u1" ] in
  let u2 = message User [ Text "u2" ] in
  List.iter
    (fun (label, earlier, earlier_cause, later_cause) ->
       let b =
         stamp_over ~head:head_one ~request_messages:[ u1; earlier; u2 ] (reasoning "b")
       in
       let history = [ u1; earlier; u2; b ] in
       let stable = fold ~head:head_one history in
       Alcotest.(check (list drop_testable))
         (label ^ ": the creating head drops only the earlier block")
         [ { Reasoning_history_projection.message_index = 1
           ; cause = earlier_cause
           ; stored_message_digest = None
           }
         ]
         stable.prefix_drops;
       let changed = fold ~head:head_two history in
       Alcotest.(check (list drop_testable))
         (label ^ ": a changed head names the later block")
         [ { Reasoning_history_projection.message_index = 1
           ; cause = earlier_cause
           ; stored_message_digest = None
           }
         ; { Reasoning_history_projection.message_index = 3
           ; cause = later_cause
           ; stored_message_digest = Some (stored_message_digest_exn b)
           }
         ]
         changed.prefix_drops)
    [ ( "no stamp"
      , assistant_with_prefix_entries ~config [] (reasoning "earlier")
      , Reasoning_history_projection.Prefix_digest_absent
      , Reasoning_history_projection.Prefix_request_mismatch )
    ; ( "no source"
      , message Assistant (reasoning "earlier")
      , Reasoning_history_projection.Prefix_source_not_present
      , Reasoning_history_projection.Prefix_request_mismatch )
    ; ( "unreadable stamp"
      , assistant_with_prefix_entries ~config invalid_prefix_entries (reasoning "earlier")
      , Reasoning_history_projection.Prefix_entry_invalid
      , Reasoning_history_projection.Prefix_chain_broken_upstream )
    ]
;;

(* The Keeper path admits the request body before dispatch, so the response
   that stamps the digest comes from [complete_serialized] and
   [complete_stream_serialized], not from the direct [complete] calls. This
   goes admit, dispatch, stamp, admit again over a loopback provider and reads
   the second admitted body from the wire: the thinking block rides only when
   the digest recorded on the admitted path matched. *)
let admitted_thinking_response_json =
  {|{"id":"msg-1","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"thinking","thinking":"admitted reasoning","signature":"sig-admitted"},{"type":"text","text":"admitted text"},{"type":"tool_use","id":"call-1","name":"inspect","input":{}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":1}}|}
;;

let admitted_thinking_response_sse =
  "event: message_start\n\
   data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg-1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-sonnet-5-5\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n\
   event: content_block_start\n\
   data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n\
   event: content_block_delta\n\
   data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"admitted reasoning\"}}\n\n\
   event: content_block_delta\n\
   data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-admitted\"}}\n\n\
   event: content_block_stop\n\
   data: {\"type\":\"content_block_stop\",\"index\":0}\n\n\
   event: content_block_start\n\
   data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n\
   event: content_block_delta\n\
   data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"admitted text\"}}\n\n\
   event: content_block_stop\n\
   data: {\"type\":\"content_block_stop\",\"index\":1}\n\n\
   event: content_block_start\n\
   data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call-1\",\"name\":\"inspect\",\"input\":{}}}\n\n\
   event: content_block_delta\n\
   data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n\
   event: content_block_stop\n\
   data: {\"type\":\"content_block_stop\",\"index\":2}\n\n\
   event: message_delta\n\
   data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n\
   event: message_stop\n\
   data: {\"type\":\"message_stop\"}\n\n"
;;

let free_loopback_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> Alcotest.fail "loopback socket did not expose a TCP port"
  in
  Unix.close socket;
  port
;;

let extra_tool_schema =
  `Assoc
    [ "name", `String "msx_press"
    ; "description", `String "press a key on the MSX"
    ; "input_schema", `Assoc [ "type", `String "object" ]
    ]
;;

(* A restart reads the history back from its stored form. *)
let reload_through_checkpoint (stored : message) =
  let media_store = Agent_core.History.Memory_store.create () in
  let media_failed error = Alcotest.fail (Agent_core.History.show_media_error error) in
  match Agent_core.History.of_wire_message media_store stored with
  | Error error -> media_failed error
  | Ok history ->
    let json = Agent_core.Checkpoint.message_to_json history in
    (match
       Agent_core.Checkpoint.message_of_json
         (Yojson.Safe.from_string (Yojson.Safe.to_string json))
     with
     | Error _ -> Alcotest.fail "the checkpoint round trip failed"
     | Ok reloaded ->
       (match Agent_core.History.to_wire_message media_store reloaded with
        | Ok reloaded -> reloaded
        | Error error -> media_failed error))
;;

(* The second request keeps the creating request's tools and system prompt
   unless [second_tools] or [second_system] says otherwise, and reads its
   history back through the checkpoint codec when [reload_history] is set. *)
let admitted_wire_types
      ~stream
      ?(reload_history = false)
      ?(second_tools = [ prefix_test_tool_schema ])
      ?second_system
      ()
  =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port = free_loopback_port () in
  let completion_bodies = ref [] in
  let handler _conn _request body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    completion_bodies := body :: !completion_bodies;
    if stream
    then
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~headers:(Cohttp.Header.of_list [ "content-type", "text/event-stream" ])
        ~body:admitted_thinking_response_sse
        ()
    else
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~body:admitted_thinking_response_json
        ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:4
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run
      socket
      (Cohttp_eio.Server.make ~callback:handler ())
      ~on_error:(fun _ -> ()));
  let config =
    Provider_config.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-5-5"
      ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
      ~api_key:"test-key"
      ~headers:
        [ "Content-Type", "application/json"; "anthropic-version", "2023-06-01" ]
      ~request_path:"/proxy/messages"
      ~max_tokens:4096
      ~system_prompt:"keeper system"
      ~model_capabilities_override:
        { (Capabilities.capabilities_of_kind Provider_config.Anthropic) with
          reasoning_replay_override = Capabilities.Force_latest_user_turn_tool_calls
        }
      ()
  in
  let tools = [ prefix_test_tool_schema ] in
  let dispatch ~config ~tools messages =
    let serialized =
      match
        Complete.admit_request_body
          ~stream
          (Complete.prepare_request ~config ~messages ~tools ())
      with
      | Ok serialized -> serialized
      | Error _ -> Alcotest.fail "admission of the request body failed"
    in
    let result =
      if stream
      then (Complete.complete_stream_serialized ~sw ~net serialized ~on_event:ignore ()).Llm_provider.Completion_outcome.result
      else (Complete.complete_serialized ~sw ~net serialized ()).Llm_provider.Completion_outcome.result
    in
    match result with
    | Ok response -> response
    | Error _ -> Alcotest.fail "the loopback provider call failed"
  in
  let carrier = message User [ Text "trigger"; Text "extra context block" ] in
  let first = dispatch ~config ~tools [ carrier ] in
  let assistant =
    match Types.assistant_message_of_response first with
    | Ok assistant -> assistant
    | Error _ -> Alcotest.fail "a sourced response must stamp"
  in
  check_bool
    "the admitted response carries a recorded digest"
    true
    (match first.Types.telemetry with
     | Some { Types.reasoning_prefix = Some _; _ } -> true
     | Some { Types.reasoning_prefix = None; _ } | None -> false);
  let second_history =
    [ carrier; assistant; message Tool [ tool_result "call-1" ] ]
  in
  let second_history =
    if reload_history
    then List.map reload_through_checkpoint second_history
    else second_history
  in
  let second_config =
    match second_system with
    | None -> config
    | Some system -> { config with Provider_config.system_prompt = Some system }
  in
  let _second = dispatch ~config:second_config ~tools:second_tools second_history in
  match !completion_bodies with
  | second_body :: _first_body :: [] -> wire_content_types second_body
  | bodies ->
    Alcotest.failf "expected two dispatched bodies, saw %d" (List.length bodies)
;;

let test_admitted_path_records_a_digest_the_next_request_honors ~stream () =
  let types = admitted_wire_types ~stream () in
  check_int "three wire messages" 3 (List.length types);
  check_bool
    "thinking recorded on the admitted path replays in the next admitted body"
    true
    (List.mem "thinking" (List.nth types 1))
;;

(* A restart reads the stored history back, tags included. The block replays
   only if the tags survived the stored form. *)
let test_admitted_path_digest_survives_a_restart ~stream () =
  let types = admitted_wire_types ~stream ~reload_history:true () in
  check_int "three wire messages" 3 (List.length types);
  check_bool
    "thinking replays after the history is reloaded from its stored form"
    true
    (List.mem "thinking" (List.nth types 1))
;;

(* The live incident: a restart, then a tool set that grew between the request
   that created the thinking and the one that replays it. *)
let test_admitted_path_drops_thinking_when_the_tool_set_grows ~stream ~reload_history () =
  let types =
    admitted_wire_types
      ~stream
      ~reload_history
      ~second_tools:[ prefix_test_tool_schema; extra_tool_schema ]
      ()
  in
  check_int "three wire messages" 3 (List.length types);
  check_bool
    "an added tool drops the stale thinking from the admitted body"
    false
    (List.mem "thinking" (List.nth types 1));
  check_bool
    "the assistant text still rides"
    true
    (List.mem "text" (List.nth types 1))
;;

let test_admitted_path_drops_thinking_when_the_system_prompt_changes () =
  let types =
    admitted_wire_types ~stream:false ~second_system:"a different system prompt" ()
  in
  check_int "three wire messages" 3 (List.length types);
  check_bool
    "a new system prompt drops the stale thinking from the admitted body"
    false
    (List.mem "thinking" (List.nth types 1));
  check_bool
    "the assistant text still rides"
    true
    (List.mem "text" (List.nth types 1))
;;

let test_prefix_binding_drops_thinking_when_the_request_head_changes () =
  let _config, tools, carrier, assistant = round_one_fixtures () in
  let changed = anthropic_build_config_variant ~system:"a different system prompt" () in
  let round_two = [ carrier; assistant; message Tool [ tool_result "call-1" ] ] in
  let body = Backend_anthropic.build_request ~config:changed ~messages:round_two ~tools () in
  let types = wire_content_types body in
  check_bool
    "a new system prompt fails the request digest"
    false
    (List.mem "thinking" (List.nth types 1))
;;

let test_prefix_binding_keeps_thinking_when_only_sampling_changes () =
  let _config, tools, carrier, assistant = round_one_fixtures () in
  let resampled = anthropic_build_config_variant ~temperature:0.7 () in
  let round_two = [ carrier; assistant; message Tool [ tool_result "call-1" ] ] in
  let body = Backend_anthropic.build_request ~config:resampled ~messages:round_two ~tools () in
  let types = wire_content_types body in
  check_bool
    "temperature steers decoding, not conversation identity"
    true
    (List.mem "thinking" (List.nth types 1))
;;

let test_prefix_binding_keeps_thinking_when_tool_choice_changes () =
  let _config, tools, carrier, assistant = round_one_fixtures () in
  (* [tool_choice] is not part of the API's prefix check, so the head must
     not hash it: dropping here would discard thinking the API accepts. *)
  let rechosen = anthropic_build_config_variant ~tool_choice:Types.Any () in
  let round_two = [ carrier; assistant; message Tool [ tool_result "call-1" ] ] in
  let body = Backend_anthropic.build_request ~config:rechosen ~messages:round_two ~tools () in
  let types = wire_content_types body in
  check_bool
    "a tool_choice change keeps thinking"
    true
    (List.mem "thinking" (List.nth types 1))
;;

(* Turning [cache_system_prompt] on moves the system prompt from a string to a
   list of text blocks. The API documents no equality between the two forms, so
   the head treats the change as an edit and drops. *)
let test_prefix_binding_drops_thinking_when_the_system_form_changes () =
  let _config, tools, carrier, assistant = round_one_fixtures () in
  let cached = anthropic_build_config_variant ~cache_system_prompt:true () in
  let round_two = [ carrier; assistant; message Tool [ tool_result "call-1" ] ] in
  let body = Backend_anthropic.build_request ~config:cached ~messages:round_two ~tools () in
  let types = wire_content_types body in
  check_bool
    "a string system prompt that becomes a block list drops thinking"
    false
    (List.mem "thinking" (List.nth types 1))
;;

(* The [cache_control] marker on the system block is not part of the check, and
   the same form on both sides keeps thinking. *)
let test_prefix_binding_keeps_thinking_when_the_cached_system_form_is_unchanged () =
  let cached = anthropic_build_config_variant ~cache_system_prompt:true () in
  let tools = [ prefix_test_tool_schema ] in
  let carrier = message User [ Text "trigger"; Text "extra context block" ] in
  let assistant =
    stamped_assistant
      ~config:cached
      ~request_messages:[ carrier ]
      ~tools
      [ Thinking { content = "cached reasoning"; signature = Some "sig-cached" }
      ; Text "cached text"
      ; ToolUse { id = "call-1"; name = "inspect"; input = `Assoc [] }
      ]
  in
  let round_two = [ carrier; assistant; message Tool [ tool_result "call-1" ] ] in
  let body = Backend_anthropic.build_request ~config:cached ~messages:round_two ~tools () in
  let types = wire_content_types body in
  check_bool
    "a block-list system prompt on both requests keeps thinking"
    true
    (List.mem "thinking" (List.nth types 1))
;;

let test_prefix_binding_keeps_thinking_across_chained_rounds () =
  let preserve_always =
    { (Capabilities.capabilities_of_kind Provider_config.Anthropic) with
      reasoning_replay_override = Capabilities.Force_preserve_always
    }
  in
  let config = anthropic_build_config_variant ~cap_override:preserve_always () in
  let tools = [ prefix_test_tool_schema ] in
  let thinking ~call_id reasoning signature =
    [ Thinking { content = reasoning; signature = Some signature }
    ; Text (reasoning ^ " text")
    ; ToolUse { id = call_id; name = "inspect"; input = `Assoc [] }
    ]
  in
  let u1 = message User [ Text "one" ] in
  let asst1 =
    stamped_assistant
      ~config
      ~request_messages:[ u1 ]
      ~tools
      (thinking ~call_id:"call-1" "round one reasoning" "sig-one")
  in
  let t1 = message Tool [ tool_result "call-1" ] in
  let u2 = message User [ Text "two" ] in
  let asst2 =
    stamped_assistant
      ~config
      ~request_messages:[ u1; asst1; t1; u2 ]
      ~tools
      (thinking ~call_id:"call-2" "round two reasoning" "sig-two")
  in
  let t2 = message Tool [ tool_result "call-2" ] in
  let body =
    Backend_anthropic.build_request
      ~config
      ~messages:[ u1; asst1; t1; u2; asst2; t2 ]
      ~tools
      ()
  in
  (* Genuine caller messages remain distinct from tool-result messages.
     Both assistants keep their thinking at their original wire positions. *)
  let types = wire_content_types body in
  check_int "six distinct wire messages" 6 (List.length types);
  check_bool
    "round one thinking survives round three"
    true
    (List.mem "thinking" (List.nth types 1));
  check_bool
    "round two thinking survives round three"
    true
    (List.mem "thinking" (List.nth types 4))
;;

(* Every codec has to answer, because the caller asks before it knows which
   serializer will run. The expectation is not written down per codec — it is
   read off that codec's own replay contract, so a codec whose dispatch was
   forgotten fails here instead of quietly returning unprojected history, and a
   codec whose contract legitimately differs is not forced to match its
   neighbours. *)
let test_every_codec_answers_its_own_contract () =
  List.iter
    (fun (label, kind, base_url) ->
       let config =
         Provider_config.make
           ~kind
           ~model_id:"model-a"
           ~base_url
           ~model_capabilities_override:non_replaying_capabilities
           ()
       in
       let dialect = Reasoning_dialect.for_provider_config config in
       let expected =
         if
           Reasoning_dialect.should_replay_reasoning
             dialect
             ~assistant_had_tool_call:false
         then 1
         else 0
       in
       let messages = history_with_reasoning (source_for_config config) in
       Alcotest.(check int)
         (label ^ ": transmits exactly what its contract replays")
         expected
         (reasoning_block_count (transmitted_history_exn ~config messages)))
    [ "openai-compatible", Provider_config.OpenAI_compat, "https://provider.example"
    ; "anthropic", Provider_config.Anthropic, "https://api.anthropic.com"
    ; "ollama", Provider_config.Ollama, "http://localhost:11434"
    ]
;;

(* The projection validates reasoning provenance across the whole list it is
   handed, so a caller that hands it a keeper's entire checkpoint inherits a
   failure mode the serializer never had: one malformed tag anywhere aborts the
   projection, including tags on messages far outside any transmission window.
   Pinned here so a caller knows this is a refusal it has to absorb rather than
   propagate. *)
let test_a_malformed_tag_anywhere_refuses_the_projection () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"model-a"
      ~base_url:"https://provider.example"
      ~model_capabilities_override:non_replaying_capabilities
      ()
  in
  let source = source_for_config config in
  (* Reasoning provenance on a User message: the tag says a role carried
     reasoning that cannot have produced it. *)
  let messages =
    [ with_source source User [ Text "first request" ]
    ; message Assistant [ Text "answer" ]
    ]
  in
  match Complete_common.transmitted_history ~config messages with
  | Ok _ -> Alcotest.fail "expected the malformed tag to refuse the projection"
  | Error _ -> ()
;;

let test_explicit_preserve_promotes_latest_user_policy_to_full_history () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"model-a"
      ~base_url:"https://provider.example"
      ~model_capabilities_override:latest_user_turn_capabilities
      ~preserve_thinking:true
      ()
  in
  let source = source_for_config config in
  let dialect = Reasoning_dialect.for_provider_config config in
  check_bool
    "explicit preserve selects all assistant messages"
    true
    ((Reasoning_dialect.replay_contract dialect).replay_policy = All_assistant_messages);
  let messages =
    [ message User [ Text "first request" ]
    ; with_source
        source
        Assistant
        [ Thinking { content = "old tool reasoning"; signature = None }
        ; ToolUse { id = "old-call"; name = "lookup"; input = `Assoc [] }
        ]
    ; message Tool [ tool_result "old-call" ]
    ; message User [ Text "current request" ]
    ]
  in
  match
    Reasoning_history_projection.project_for_provider_config
      ~assistant_has_payload:(fun content -> content <> [])
      ~reasoning_block_supported:reasoning_supported
      config
      messages
  with
  | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
  | Ok projection ->
    let old_assistant = List.nth projection.messages 1 in
    check_bool
      "explicit preserve retains prior-turn reasoning"
      true
      (content_has_reasoning old_assistant.content)
;;

let test_openai_chat_request_uses_whole_history_projection () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"model-a"
      ~base_url:"https://provider.example"
      ~model_capabilities_override:preserving_capabilities
      ()
  in
  let source = source_for_config config in
  let body =
    Backend_openai.build_request
      ~config
      ~messages:
        [ with_source
            source
            Assistant
            [ Thinking { content = "reasoning"; signature = None }; Text "answer" ]
        ]
      ()
    |> Yojson.Safe.from_string
  in
  let assistant = Yojson.Safe.Util.(body |> member "messages" |> to_list |> List.hd) in
  check_bool
    "reasoning stays in dedicated field"
    true
    Yojson.Safe.Util.(assistant |> member "reasoning_content" |> to_string = "reasoning");
  check_bool
    "visible answer remains distinct"
    true
    Yojson.Safe.Util.(assistant |> member "content" |> to_string = "answer")
;;

(* Ollama's OpenAI-compat layer reads incoming assistant [reasoning] into the
   template's thinking slot and ignores unknown members, so replay emitted as
   a fixed "reasoning_content" never reached the model there. The request-side
   field must mirror the dialect's declared streaming field. *)
let test_openai_chat_replay_field_mirrors_streaming_field () =
  let capabilities =
    { preserving_capabilities with
      reasoning_streaming_format = Capabilities.Delta_reasoning_field "reasoning"
    }
  in
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"model-a"
      ~base_url:"https://provider.example"
      ~model_capabilities_override:capabilities
      ()
  in
  let source = source_for_config config in
  let body =
    Backend_openai.build_request
      ~config
      ~messages:
        [ with_source
            source
            Assistant
            [ Thinking { content = "replayed"; signature = None }; Text "answer" ]
        ]
      ()
    |> Yojson.Safe.from_string
  in
  let assistant = Yojson.Safe.Util.(body |> member "messages" |> to_list |> List.hd) in
  check_bool
    "reasoning replays into the dialect's own field"
    true
    Yojson.Safe.Util.(assistant |> member "reasoning" |> to_string = "replayed");
  check_bool
    "the fixed field name is not emitted alongside"
    true
    Yojson.Safe.Util.(assistant |> member "reasoning_content" = `Null)
;;

let test_ollama_request_replays_native_thinking_field () =
  let capabilities =
    { preserving_capabilities with thinking_control_format = Ollama_think }
  in
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"model-a"
      ~base_url:"http://localhost:11434"
      ~model_capabilities_override:capabilities
      ()
  in
  let source = source_for_config config in
  let body =
    Backend_ollama.build_request
      ~config
      ~messages:
        [ with_source
            source
            Assistant
            [ Thinking { content = "native reasoning"; signature = None }; Text "answer" ]
        ]
      ()
    |> Yojson.Safe.from_string
  in
  let assistant = Yojson.Safe.Util.(body |> member "messages" |> to_list |> List.hd) in
  check_bool
    "native thinking field"
    true
    Yojson.Safe.Util.(assistant |> member "thinking" |> to_string = "native reasoning")
;;

let ollama_native_capabilities reasoning_replay_override =
  { Capabilities.ollama_capabilities with
    supports_reasoning = true
  ; reasoning_replay_override
  }
;;

let test_ollama_native_default_replays_only_latest_user_turn_tool_thinking () =
  let config =
    Provider_config.make
      ~kind:Ollama
      ~model_id:"native-thinking-model"
      ~base_url:"http://localhost:11434"
      ~model_capabilities_override:(ollama_native_capabilities Default_reasoning_replay)
      ()
  in
  let dialect = Reasoning_dialect.for_provider_config config in
  check_bool
    "native default is latest-user-turn tool replay"
    true
    ((Reasoning_dialect.replay_contract dialect).replay_policy
     = Tool_call_assistant_messages_latest_user_turn);
  let source = source_for_config config in
  let body =
    Backend_ollama.build_request
      ~config
      ~messages:
        [ message User [ Text "old request" ]
        ; with_source
            source
            Assistant
            [ Thinking { content = "old reasoning"; signature = None }
            ; ToolUse { id = "old-call"; name = "old_lookup"; input = `Assoc [] }
            ]
        ; message Tool [ tool_result "old-call" ]
        ; message User [ Text "current request" ]
        ; with_source
            source
            Assistant
            [ Thinking { content = "current reasoning"; signature = None }
            ; ToolUse { id = "current-call"; name = "current_lookup"; input = `Assoc [] }
            ]
        ; message Tool [ tool_result "current-call" ]
        ]
      ()
    |> Yojson.Safe.from_string
  in
  let wire_messages = Yojson.Safe.Util.(body |> member "messages" |> to_list) in
  let expected_tool_call id name =
    `Assoc
      [ "id", `String id
      ; "type", `String "function"
      ; "function", `Assoc [ "name", `String name; "arguments", `Assoc [] ]
      ]
  in
  let expected_wire_messages =
    `List
      [ `Assoc [ "role", `String "user"; "content", `String "old request" ]
      ; `Assoc
          [ "tool_calls", `List [ expected_tool_call "old-call" "old_lookup" ]
          ; "role", `String "assistant"
          ; "content", `Null
          ]
      ; `Assoc
          [ "role", `String "tool"
          ; "tool_name", `String "old_lookup"
          ; "content", `String "ok"
          ]
      ; `Assoc [ "role", `String "user"; "content", `String "current request" ]
      ; `Assoc
          [ "thinking", `String "current reasoning"
          ; "tool_calls", `List [ expected_tool_call "current-call" "current_lookup" ]
          ; "role", `String "assistant"
          ; "content", `Null
          ]
      ; `Assoc
          [ "role", `String "tool"
          ; "tool_name", `String "current_lookup"
          ; "content", `String "ok"
          ]
      ]
  in
  check_bool
    "native replay preserves exact thinking/tool/result order"
    true
    (Yojson.Safe.equal (`List wire_messages) expected_wire_messages);
  let old_assistant = List.nth wire_messages 1 in
  let current_assistant = List.nth wire_messages 4 in
  check_bool
    "older turn thinking dropped"
    true
    Yojson.Safe.Util.(old_assistant |> member "thinking" = `Null);
  check_bool
    "current tool turn thinking retained"
    true
    Yojson.Safe.Util.(
      current_assistant |> member "thinking" |> to_string = "current reasoning")
;;

let test_ollama_native_catalog_replay_overrides_win () =
  let cases =
    [ Capabilities.Force_no_replay, Reasoning_replay_contract.No_replay
    ; ( Capabilities.Force_drop_without_tool_preserve_with_tool
      , Reasoning_replay_contract.Tool_call_assistant_messages_all_history )
    ; ( Capabilities.Force_latest_user_turn_tool_calls
      , Reasoning_replay_contract.Tool_call_assistant_messages_latest_user_turn )
    ; Capabilities.Force_preserve_always, Reasoning_replay_contract.All_assistant_messages
    ]
  in
  List.iteri
    (fun index (override, expected) ->
       let config =
         Provider_config.make
           ~kind:Ollama
           ~model_id:(Printf.sprintf "native-replay-override-%d" index)
           ~base_url:"http://localhost:11434"
           ~model_capabilities_override:(ollama_native_capabilities override)
           ()
       in
       let actual =
         Reasoning_dialect.for_provider_config config
         |> Reasoning_dialect.replay_contract
         |> fun contract -> contract.replay_policy
       in
       check_bool "catalog replay override remains authoritative" true (actual = expected))
    cases
;;

(* Every ollama_cloud row that states no replay contract of its own gets the
   provider's, on both wires a deployment may point at: the native /api/chat
   and the /v1 one. The rows are read from the default catalog, so a row added
   later is covered without being named here. *)
let test_undeclared_ollama_cloud_rows_replay_within_the_user_turn_on_both_wires () =
  let catalog =
    match Model_catalog.load_default () with
    | Ok catalog -> catalog
    | Error detail -> Alcotest.failf "default catalog did not load: %s" detail
  in
  let undeclared =
    Model_catalog.model_entries catalog
    |> List.filter (fun (entry : Model_catalog.model_entry) ->
      entry.provider_name = Some "ollama_cloud" && Option.is_none entry.reasoning_replay)
  in
  check_bool "ollama_cloud has rows without their own declaration" true (undeclared <> []);
  let wires =
    [ "native", Provider_config.Ollama, "https://ollama.com", "/api/chat"
    ; "/v1", Provider_config.OpenAI_compat, "https://ollama.com/v1", "/chat/completions"
    ]
  in
  List.iter
    (fun (entry : Model_catalog.model_entry) ->
       let model_id = Model_identifiers.Model_id.to_string entry.model_id in
       List.iter
         (fun (wire, kind, base_url, request_path) ->
            let config =
              Provider_config.make
                ~provider_id:"ollama_cloud"
                ~kind
                ~model_id
                ~base_url
                ~request_path
                ()
            in
            let actual = (Reasoning_dialect.for_provider_config config).replay_policy in
            check_bool
              (Printf.sprintf
                 "%s over %s replays the latest user turn's tool-call reasoning (got %s)"
                 model_id
                 wire
                 (Reasoning_replay_contract.show_replay_policy actual))
              true
              (actual
               = Reasoning_replay_contract.Tool_call_assistant_messages_latest_user_turn))
         wires)
    undeclared
;;

let test_openai_responses_replays_only_opaque_item () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"model-a"
      ~base_url:"https://api.example"
      ~request_path:"/v1/responses"
      ()
  in
  let source = source_for_config config in
  let opaque =
    Yojson.Safe.to_string
      (`Assoc
          [ "type", `String "reasoning"
          ; "id", `String "reasoning-item"
          ; "summary", `List []
          ; "encrypted_content", `String "opaque"
          ])
  in
  let body =
    Backend_openai_responses.build_request
      ~config
      ~messages:
        [ with_source
            source
            Assistant
            [ Thinking { content = "generic"; signature = None }
            ; RedactedThinking opaque
            ]
        ]
      ()
    |> Yojson.Safe.from_string
  in
  let input = Yojson.Safe.Util.(body |> member "input" |> to_list) in
  check_int "only opaque reasoning item remains" 1 (List.length input);
  check_bool
    "opaque item preserved"
    true
    Yojson.Safe.Util.(List.hd input |> member "type" |> to_string = "reasoning")
;;

(* ── Agent Core contract S1.1/S3.1: identity read once, replay read from the record ── *)

let resolved_replay_policy config =
  (Reasoning_dialect.for_provider_config config).replay_policy
;;

let clear_thinking_capabilities preserve_thinking_control_format =
  { Capabilities.default_capabilities with
    supports_reasoning = true
  ; preserve_thinking_control_format
  }
;;

(* Pins the resolved replay policy for one config per provider kind, plus every
   clear-thinking knob combination. The same matrix was captured from the
   pre-refactor tree and compared byte for byte; a regression in dialect
   resolution now shows up here as a changed constructor rather than as a silent
   history drop in production. *)
let test_provider_replay_policy_matrix_pinned () =
  let cfg
        ?request_path
        ?enable_thinking
        ?preserve_thinking
        ?clear_thinking
        ~kind
        ~model_id
        ~base_url
        ()
    =
    Provider_config.make
      ?request_path
      ?enable_thinking
      ?preserve_thinking
      ?clear_thinking
      ~kind
      ~model_id
      ~base_url
      ()
  in
  let check label expected config =
    check_bool
      (Printf.sprintf
         "%s resolves %s (got %s)"
         label
         (Reasoning_replay_contract.show_replay_policy expected)
         (Reasoning_replay_contract.show_replay_policy (resolved_replay_policy config)))
      true
      (resolved_replay_policy config = expected)
  in
  check
    "anthropic"
    Reasoning_replay_contract.All_assistant_messages
    (cfg
       ~kind:Provider_config.Anthropic
       ~model_id:"claude-sonnet-5"
       ~base_url:"https://api.anthropic.com"
       ());
  check
    "gemini"
    Reasoning_replay_contract.All_assistant_messages
    (cfg
       ~kind:Provider_config.Gemini
       ~model_id:"gemini-3-pro"
       ~base_url:"https://generativelanguage.googleapis.com"
       ());
  check
    "ollama"
    Reasoning_replay_contract.Tool_call_assistant_messages_latest_user_turn
    (cfg
       ~kind:Provider_config.Ollama
       ~model_id:"qwen3"
       ~base_url:"http://localhost:11434"
       ());
  check
    "kimi"
    Reasoning_replay_contract.Tool_call_assistant_messages_all_history
    (cfg
       ~kind:Provider_config.Kimi
       ~model_id:"kimi-k2.6"
       ~base_url:"https://api.moonshot.ai"
       ());
  check
    "openai chat"
    Reasoning_replay_contract.No_replay
    (cfg
       ~kind:Provider_config.OpenAI_compat
       ~model_id:"gpt-5.4"
       ~base_url:"https://api.openai.com"
       ());
  check
    "openai responses"
    Reasoning_replay_contract.Provider_opaque_state
    (cfg
       ~request_path:"/v1/responses"
       ~kind:Provider_config.OpenAI_compat
       ~model_id:"gpt-5.4"
       ~base_url:"https://api.openai.com"
       ());
  List.iter
    (fun model_id ->
       let base_url = "https://api.z.ai" in
       let label suffix = Printf.sprintf "glm/%s %s" model_id suffix in
       check
         (label "default")
         Reasoning_replay_contract.No_replay
         (cfg ~kind:Provider_config.Glm ~model_id ~base_url ());
       check
         (label "enable_thinking only")
         Reasoning_replay_contract.No_replay
         (cfg ~enable_thinking:true ~kind:Provider_config.Glm ~model_id ~base_url ());
       check
         (label "preserve only")
         Reasoning_replay_contract.No_replay
         (cfg ~preserve_thinking:true ~kind:Provider_config.Glm ~model_id ~base_url ());
       check
         (label "enable + preserve")
         Reasoning_replay_contract.All_assistant_messages
         (cfg
            ~enable_thinking:true
            ~preserve_thinking:true
            ~kind:Provider_config.Glm
            ~model_id
            ~base_url
            ());
       check
         (label "enable + clear_thinking=false")
         Reasoning_replay_contract.All_assistant_messages
         (cfg
            ~enable_thinking:true
            ~clear_thinking:false
            ~kind:Provider_config.Glm
            ~model_id
            ~base_url
            ()))
    [ "glm-5"; "glm-5.2"; "glm-4-flash"; "glm-4v"; "glm-4"; "glm-unlisted" ]
;;

(* The preserved-thinking replay gate is selected by the declared
   [preserve_thinking_control_format], not by the provider kind. Both directions
   are asserted: the gate turns on for a non-GLM kind that declares the wire and
   stays off for the GLM kind that does not. Reverting to a [config.kind = Glm]
   predicate turns both red. *)
let test_clear_thinking_gate_is_capability_not_identity () =
  let preserved kind capabilities =
    Provider_config.make
      ~kind
      ~model_id:"gate-probe"
      ~base_url:"https://gate.example"
      ~model_capabilities_override:capabilities
      ~enable_thinking:true
      ~preserve_thinking:true
      ()
  in
  let cleared kind capabilities =
    Provider_config.make
      ~kind
      ~model_id:"gate-probe"
      ~base_url:"https://gate.example"
      ~model_capabilities_override:capabilities
      ~enable_thinking:true
      ()
  in
  let declared =
    clear_thinking_capabilities Capabilities.Thinking_object_clear_thinking
  in
  let undeclared =
    clear_thinking_capabilities Capabilities.No_preserve_thinking_control
  in
  check_bool
    "non-GLM kind declaring the wire gets conditional replay"
    true
    (resolved_replay_policy (preserved Provider_config.OpenAI_compat declared)
     = Reasoning_replay_contract.All_assistant_messages);
  check_bool
    "non-GLM kind declaring the wire honours the clear_thinking default"
    true
    (resolved_replay_policy (cleared Provider_config.OpenAI_compat declared)
     = Reasoning_replay_contract.No_replay);
  check_bool
    "GLM kind without the declared wire does not get the gate"
    true
    (resolved_replay_policy (preserved Provider_config.Glm undeclared)
     = Reasoning_replay_contract.No_replay);
  check_bool
    "GLM kind declaring the wire still gets conditional replay"
    true
    (resolved_replay_policy (preserved Provider_config.Glm declared)
     = Reasoning_replay_contract.All_assistant_messages)
;;

(* ── Agent Core contract S3.1: the rotation drop is a declared policy ── *)

let test_rotation_policy_is_declared_per_dialect () =
  let rotation ?request_path ~kind ~model_id ~base_url () =
    Provider_config.make ?request_path ~kind ~model_id ~base_url ()
    |> Reasoning_dialect.for_provider_config
    |> Reasoning_dialect.rotation_policy
  in
  let check label expected actual =
    check_bool
      (Printf.sprintf
         "%s declares %s"
         label
         (Reasoning_replay_contract.show_rotation_policy expected))
      true
      (actual = expected)
  in
  check
    "anthropic signed thinking blocks"
    Reasoning_replay_contract.Require_identical_source
    (rotation
       ~kind:Provider_config.Anthropic
       ~model_id:"claude-sonnet-5"
       ~base_url:"https://api.anthropic.com"
       ());
  check
    "gemini thought signatures"
    Reasoning_replay_contract.Require_identical_source
    (rotation
       ~kind:Provider_config.Gemini
       ~model_id:"gemini-3-pro"
       ~base_url:"https://generativelanguage.googleapis.com"
       ());
  check
    "openai responses opaque state"
    Reasoning_replay_contract.Require_identical_source
    (rotation
       ~request_path:"/v1/responses"
       ~kind:Provider_config.OpenAI_compat
       ~model_id:"gpt-5.4"
       ~base_url:"https://api.openai.com"
       ());
  check
    "glm reasoning_content side channel"
    Reasoning_replay_contract.Allow_endpoint_rotation
    (rotation ~kind:Provider_config.Glm ~model_id:"glm-5" ~base_url:"https://api.z.ai" ());
  check
    "ollama thinking side channel"
    Reasoning_replay_contract.Allow_endpoint_rotation
    (rotation
       ~kind:Provider_config.Ollama
       ~model_id:"qwen3"
       ~base_url:"http://localhost:11434"
       ());
  check
    "kimi reasoning_content side channel"
    Reasoning_replay_contract.Allow_endpoint_rotation
    (rotation
       ~kind:Provider_config.Kimi
       ~model_id:"kimi-k2.6"
       ~base_url:"https://api.moonshot.ai"
       ())
;;

let incompatible_drop_count (projection : Reasoning_history_projection.t) =
  List.length
    (List.filter
       (fun (drop : Reasoning_history_projection.reasoning_replay_drop) ->
          match drop.reason with
          | Incompatible_reasoning_source _ -> true
          | Replay_policy_excluded _
          | Missing_reasoning_source
          | Reasoning_on_non_assistant -> false)
       projection.reasoning_replay_drops)
;;

(* Continuity across a rotation follows the declared rule, not a bare identity
   comparison: the same stored artifact and the same target are dropped under
   [Require_identical_source] and kept under [Allow_endpoint_rotation], while a
   model or replay-contract change is dropped under both. *)
let test_rotation_policy_drives_incompatible_drop () =
  let target = source All_assistant_messages in
  let rotated_endpoint =
    source ~base_url:"https://rotated.example" All_assistant_messages
  in
  let other_model = source ~model_id:"model-b" All_assistant_messages in
  let other_contract = source ~base_url:"https://rotated.example" No_replay in
  let history stored =
    [ with_source stored Assistant [ Thinking { content = "prior"; signature = None } ]
    ; message User [ Text "next" ]
    ]
  in
  let run ~rotation stored =
    match project ~rotation ~target ~policy:All_assistant_messages (history stored) with
    | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
    | Ok projection -> projection
  in
  check_int
    "identical-source rule drops an endpoint rotation"
    1
    (incompatible_drop_count
       (run ~rotation:Reasoning_replay_contract.Require_identical_source rotated_endpoint));
  let kept =
    run ~rotation:Reasoning_replay_contract.Allow_endpoint_rotation rotated_endpoint
  in
  check_int "endpoint-rotation rule keeps the artifact" 0 (incompatible_drop_count kept);
  check_bool
    "rotated reasoning survives into the projection"
    true
    (content_has_reasoning (List.hd kept.messages).content);
  check_int
    "endpoint-rotation rule still drops a model change"
    1
    (incompatible_drop_count
       (run ~rotation:Reasoning_replay_contract.Allow_endpoint_rotation other_model));
  check_int
    "endpoint-rotation rule still drops a replay-contract change"
    1
    (incompatible_drop_count
       (run ~rotation:Reasoning_replay_contract.Allow_endpoint_rotation other_contract))
;;

(* One request is serialized twice: exact-output planning runs with
   [stream:false], then admission runs with the transport's real flag. Both
   project the same history, so this summary fires twice with what used to be
   byte-identical payloads -- a pair that said nothing about which stage
   produced it (#28636). The flag is what tells them apart. *)
let test_drop_summary_names_its_serialization () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"model-a"
      ~base_url:"https://provider.example"
      ~model_capabilities_override:non_replaying_capabilities
      ()
  in
  let messages = history_with_reasoning (source_for_config config) in
  let captured = ref [] in
  Diag.set_sink (fun _level ~ctx:_ line -> captured := line :: !captured);
  let build stream =
    ignore (Backend_openai.build_request ~stream ~config ~messages ~tools:[] () : string)
  in
  build false;
  build true;
  Diag.set_sink (fun _ ~ctx:_ _ -> ());
  let drop_payloads =
    !captured
    |> List.filter (fun line ->
      match String.index_opt line '{' with
      | None -> false
      | Some i ->
        (match Yojson.Safe.from_string (String.sub line i (String.length line - i)) with
         | `Assoc fields ->
           List.assoc_opt "event" fields = Some (`String "reasoning_replay_dropped")
         | _ | (exception _) -> false))
  in
  check_int "both serializations reported a drop" 2 (List.length drop_payloads);
  let stream_flags =
    drop_payloads
    |> List.filter_map (fun line ->
      let i = String.index line '{' in
      match Yojson.Safe.from_string (String.sub line i (String.length line - i)) with
      | `Assoc fields -> List.assoc_opt "stream" fields
      | _ | (exception _) -> None)
    |> List.sort compare
  in
  check_bool
    "the pair is distinguishable by its stream flag"
    true
    (stream_flags = [ `Bool false; `Bool true ])
;;


let test_request_tools_selects_full_history_reasoning () =
  let caps =
    { Capabilities.default_capabilities with
      supports_reasoning = true
    ; thinking_control_format = Thinking_object
    ; reasoning_replay_override = Force_preserve_with_request_tools }
  in
  let config = Provider_config.make ~kind:OpenAI_compat
      ~model_id:"request-tools-fixture" ~base_url:"https://request-tools.example"
      ~max_tokens:1024 ~model_capabilities_override:caps () in
  let source = source_for_config config in
  let reasoning content = Thinking {content; signature=None} in
  let messages =
    [ message User [Text "First question"]
    ; with_source source Assistant [reasoning "plain prior reasoning"; Text "First answer"]
    ; message User [Text "Second question"]
    ; with_source source Assistant [reasoning "prior tool reasoning";
        ToolUse {id="lookup"; name="lookup"; input=`Assoc []}]
    ; message Tool [ToolResult {tool_use_id="lookup"; content="result";
        outcome=Tool_succeeded; json=None; content_blocks=None}]
    ; message User [Text "A real later human question"]
    ; message ~origin:Recovery_instruction User [Text "Continue the request"] ] in
  let tools = [`Assoc ["name", `String "lookup"; "description", `String "Lookup";
      "input_schema", `Assoc ["type", `String "object"; "properties", `Assoc []]]] in
  let build ~config ~tools ~stream = Backend_openai_request.build_request
      ~config ~messages ~tools ~stream () |> Yojson.Safe.from_string in
  let wire_reasoning body =
    let open Yojson.Safe.Util in
    body |> member "messages" |> to_list |> List.filter_map (fun item ->
      match member "reasoning_content" item with
      | `String value -> Some value
      | `Null -> None
      | _ -> Alcotest.fail "reasoning_content must be a string") in
  List.iter (fun stream ->
    let enabled = build ~config ~tools ~stream in
    Alcotest.(check (list string)) "all prior reasoning on outgoing tool request"
      ["plain prior reasoning"; "prior tool reasoning"] (wire_reasoning enabled);
    let without = build ~config ~tools:[] ~stream in
    Alcotest.(check (list string)) "no replay when tools is absent" []
      (wire_reasoning without);
    let disabled = build ~config:{config with tool_choice=Some None_} ~tools ~stream in
    Alcotest.(check (list string)) "tool-choice suppression also suppresses replay" []
      (wire_reasoning disabled);
    check_bool "disabled tools are absent on the wire" true
      (Yojson.Safe.Util.member "tools" disabled = `Null)) [false;true];
  let projected tools config =
    match Complete_common.transmitted_history ~tools ~config messages with
    | Ok messages -> reasoning_block_count messages
    | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error) in
  check_int "read-only projection uses outgoing tools" 2 (projected tools config);
  check_int "read-only projection knows tool omission" 0 (projected [] config);
  check_int "read-only projection applies tool-choice suppression" 0
    (projected tools {config with tool_choice=Some None_});
  let capability tools_present =
    match Reasoning_dialect.replay_capability_for_provider_config ~tools_present config with
    | Ok capability -> capability
    | Error detail -> Alcotest.fail detail in
  let enabled = capability true and disabled = capability false in
  check_bool "request tools never alter producing-source identity" true
    (Reasoning_source.equal enabled.target disabled.target);
  check_bool "enabled replay contract" true
    (enabled.contract.replay_policy = All_assistant_messages);
  check_bool "disabled replay contract" true
    (disabled.contract.replay_policy = No_replay);
  let previous_source : Reasoning_source.t =
    { source with replay_contract =
        {source.replay_contract with replay_policy = Tool_call_assistant_messages_all_history} } in
  let previous_history = List.map (fun (item : message) ->
    match item.role with
    | Assistant -> {item with metadata = Reasoning_source.metadata previous_source}
    | User | System | Tool -> item) messages in
  (match Backend_openai_serialize.project_history ~tools_present:true config previous_history with
   | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
   | Ok projection ->
     check_int "a changed producing contract is not migrated by request-tools selection" 0
       (reasoning_block_count projection.messages);
     check_int "both artifacts retain an explicit incompatibility reason" 2
       (List.length projection.reasoning_replay_drops);
     List.iter (fun (drop : Reasoning_history_projection.reasoning_replay_drop) ->
       match drop.reason with
       | Incompatible_reasoning_source actual ->
         check_bool "excluded source is the previous producing contract" true
           (Reasoning_source.equal previous_source actual)
       | Replay_policy_excluded _ | Missing_reasoning_source | Reasoning_on_non_assistant ->
         Alcotest.fail "policy transition must be classified as source incompatibility")
       projection.reasoning_replay_drops)
;;

let test_initial_system_control_lowering () =
  let caps = {latest_user_turn_capabilities with
      reasoning_replay_override = Force_initial_system_latest_user_turn_tool_calls;
      supports_image_input = true; modality_priority = Modality.Visual_first} in
  let config = Provider_config.make ~kind:OpenAI_compat ~model_id:"initial-system-fixture"
      ~base_url:"https://template.example" ~system_prompt:"Configured system policy"
      ~preserve_thinking:false ~max_tokens:1024 ~model_capabilities_override:caps () in
  let source = source_for_config config in
  let tool id = ToolUse {id; name="inspect"; input=`Assoc []} in
  let reasoning content = Thinking {content; signature=None} in
  let control origin text = message ~origin User [Text text] in
  let messages =
    [ message System [Text "Canonical system policy"]
    ; message User [Text "Old human query"]
    ; with_source source Assistant [reasoning "OLD_REASONING"; tool "old"]
    ; message Tool [tool_result "old"]
    ; control Recovery_instruction "OLD_RECOVERY"
    ; message User [Text "Current human query"]
    ; with_source source Assistant [reasoning "CURRENT_REASONING"; tool "current"]
    ; message Tool [tool_result "current"]
    ; control Recovery_instruction "ANSWERED_RECOVERY"
    ; message Assistant [Text "Recovery answered"]
    ; control Recovery_instruction "CURRENT_RECOVERY"
    ; control Historical_system_context "HISTORICAL_CONTEXT"
    ; control System_context "CURRENT_CONTEXT"
    ; control Agent_instruction "CURRENT_AGENT_INSTRUCTION" ] in
  let body messages config = Backend_openai_request.build_request ~config ~messages ()
      |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  let wire = body messages config |> member "messages" |> to_list in
  check_bool "one initial System plus original transcript roles" true
    (List.map (fun item -> member "role" item |> to_string) wire
     = ["system"; "user"; "assistant"; "tool"; "user"; "assistant"; "tool"; "assistant"]);
  let system = List.hd wire |> member "content" |> to_string in
  let system_lines = String.split_on_char '\n' system in
  check_bool "configured and canonical system policy are both present" true
    (List.mem "Configured system policy" system_lines && List.mem "Canonical system policy" system_lines);
  let reasoning_values wire = List.filter_map (fun item ->
    match member "reasoning_content" item with `String text -> Some text | _ -> None) wire in
  Alcotest.(check (list string)) "only current trajectory reasoning survives controls"
    ["CURRENT_REASONING"] (reasoning_values wire);
  let new_human = messages @ [message User [Text "<tool_response>Real new human</tool_response>"]] in
  Alcotest.(check (list string)) "actual human closes the trajectory regardless of text"
    [] (body new_human config |> member "messages" |> to_list |> reasoning_values);
  Alcotest.(check (list string)) "preserve_thinking=true is still explicit full-history opt-in"
    ["OLD_REASONING";"CURRENT_REASONING"]
    (body messages {config with preserve_thinking=Some true}
     |> member "messages" |> to_list |> reasoning_values);
  (match Backend_openai_serialize.project_history config messages with
   | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
   | Ok projection ->
     Alcotest.(check (list int)) "diagnostics retain canonical source coordinates" [2]
       (List.map (fun (drop : Reasoning_history_projection.reasoning_replay_drop) ->
          drop.message_index) projection.reasoning_replay_drops));
  let lower = match Message_origin_lowering.lower Initial_system_tool_response_media messages with
    | Ok lower -> lower | Error error -> Alcotest.fail (Message_origin_lowering.error_to_string error) in
  (match lower.messages with
   | {role=System; content=[Text text]; _} :: _ ->
     let active = String.split_on_char '\n' text in
     check_bool "answered and past recoveries are not standalone active instructions" true
       (not (List.mem "OLD_RECOVERY" active) && not (List.mem "ANSWERED_RECOVERY" active));
     check_bool "fresh recovery remains active" true (List.mem "CURRENT_RECOVERY" active)
   | _ -> Alcotest.fail "missing consolidated System");
  let invalid = messages @ [message ~origin:System_context User
      [image_block ~media_type:"image/png" ~source:(Base64 "image")]] in
  (match Backend_openai_serialize.project_history config invalid with
   | Error (Invalid_control_lowering (Non_text_control {message_index=14})) -> ()
   | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
   | Ok _ -> Alcotest.fail "template cannot hoist image context to System");
  (match Backend_openai_serialize.project_history config [control Recovery_instruction "Continue"] with
   | Error (Invalid_control_lowering Missing_caller_query) -> ()
   | Error error -> Alcotest.fail (Reasoning_history_projection.error_to_string error)
   | Ok _ -> Alcotest.fail "control cannot manufacture a human query");
  (match Message_origin_lowering.policy_for_provider_config {config with kind=Anthropic} with
   | Error Unsupported_codec -> ()
   | Error error -> Alcotest.fail (Message_origin_lowering.error_to_string error)
   | Ok _ -> Alcotest.fail "initial-system policy cannot rewrite a signed Anthropic prefix");
  let image = image_block ~media_type:"image/png" ~source:(Base64 "png") in
  let image_history = [message User [Text "Inspect"];
    with_source source Assistant [reasoning "MEDIA_REASONING"; tool "media"];
    message Tool [ToolResult {tool_use_id="media";content="image";outcome=Tool_succeeded;
      json=None;content_blocks=Some [Text "image result";image]}];
    control System_context "Still the same query"] in
  let media_wire = body image_history config |> member "messages" |> to_list in
  let followup = List.rev media_wire |> List.hd |> member "content" |> to_list in
  check_bool "protocol opening is before media even with Visual_first" true
    (member "text" (List.hd followup) = `String "<tool_response>");
  check_bool "protocol closing follows every media part" true
    (member "text" (List.rev followup |> List.hd) = `String "</tool_response>")
;;


(* Native scoped context must retain the exact signed creation prefix after its
   origin becomes historical and a client tool result clears its effect. *)
let native_context_config () =
  anthropic_build_config_variant
    ~cap_override:{ (Capabilities.capabilities_of_kind Provider_config.Anthropic) with
      reasoning_replay_override = Force_turn_scoped_system_context_preserve_always }
    ()
;;

let test_native_context_signed_tool_round_trip () =
  let open Yojson.Safe.Util in
  let config = native_context_config () in
  let tools = [prefix_test_tool_schema] in
  let caller = message User [Text "inspect workspace"] in
  let fresh = message ~origin:System_context User [Text "workspace version one"] in
  let response_content =
    [ Thinking {content="inspect first";signature=Some "synthetic-fixture-signature"}
    ; ToolUse {id="call-1";name="inspect";input=`Assoc []} ] in
  let assistant = stamped_assistant ~config ~request_messages:[caller;fresh] ~tools response_content in
  let historical = {fresh with origin=Historical_system_context} in
  let result = message Tool [tool_result "call-1"] in
  let next = message ~origin:System_context User [Text "workspace version two"] in
  let history = [caller;historical;assistant;result;next] in
  let wire history = Backend_anthropic.build_request ~config ~messages:history ~tools ()
      |> Yojson.Safe.from_string |> member "messages" |> to_list in
  let first = wire [caller;fresh] and second = wire history in
  Alcotest.(check string) "historical carrier is identical to its creation frame"
    (Yojson.Safe.to_string (List.nth first 1))
    (Yojson.Safe.to_string (List.nth second 1));
  let context = List.nth second 4 in
  Alcotest.(check string) "fresh context is a system message" "system" (context |> member "role" |> to_string);
  Alcotest.(check string) "tool results also clear the preceding context" "next_user_message"
    (context |> member "clear_at" |> to_string);
  check_bool "scoped content has no cache marker" true
    (List.for_all (fun block -> member "cache_control" block = `Null) (context |> member "content" |> to_list));
  check_bool "thinking survives the native tool continuation" true
    (List.mem "thinking" (List.nth (wire_content_types (Backend_anthropic.build_request ~config ~messages:history ~tools ())) 2));
  (match Backend_anthropic.retained_prefix_reasoning_indices ~config ~tools history with
   | Ok (Some indices) -> check_bool "source occurrence stays at index two" true (List.mem 2 indices)
   | _ -> Alcotest.fail "expected retained native reasoning occurrence");
  let changed = {historical with content=[Text "edited old workspace"]} in
  check_bool "editing the historical prefix drops its reasoning" false
    (List.mem "thinking" (List.nth (wire_content_types (Backend_anthropic.build_request
       ~config ~messages:[caller;changed;assistant;result;next] ~tools ())) 2));
  check_bool "canonical context retains its User role" true (historical.role=User);
  let count_body = Backend_anthropic.build_count_tokens_request ~config ~messages:history ~tools () in
  let count_frames = Yojson.Safe.from_string count_body |> member "messages" |> to_list in
  Alcotest.(check string) "count tokens uses the same scoped messages"
    (Yojson.Safe.to_string (`List second)) (Yojson.Safe.to_string (`List count_frames));
  let headers = Backend_anthropic.request_headers ~body:count_body ["Anthropic-Beta","custom-beta"] in
  let beta = List.assoc "anthropic-beta" headers in
  check_bool "count-token transport adds the scoped beta" true
    (List.mem "mid-conversation-system-clear-at-2026-08-21" (String.split_on_char ',' beta));
  check_bool "required betas merge idempotently" true
    (headers = Backend_anthropic.request_headers ~body:count_body headers)
;;

let test_native_context_placement_and_removed_assistant () =
  let module Lower = Message_origin_lowering in
  let policy = Lower.Turn_scoped_system_context in
  let caller = message User [Text "caller"] in
  let context = message ~origin:System_context User [Text "current context"] in
  let text_assistant = message Assistant [Text "answer"] in
  let valid history = Result.is_ok (Lower.lower policy history) in
  check_bool "context group may end the request" true (valid [caller;context;context]);
  List.iter (fun (label,history) -> check_bool label false (valid history))
    ["no leading context",[context;caller]
    ;"no context after an assistant",[caller;text_assistant;context]
    ;"no context before another caller",[caller;context;caller]
    ;"no context between tool use and result",
       [caller;message Assistant [ToolUse {id="call-1";name="inspect";input=`Assoc []}];context;message Tool [tool_result "call-1"]]
    ;"no nontext context",[caller;{context with content=[RedactedThinking "opaque"]}]];
  let config = native_context_config () in
  let unbound = with_source (source_for_config config) Assistant
      [Thinking {content="unbound";signature=Some "synthetic"}] in
  let history = [caller;context;unbound;caller] in
  (match Backend_anthropic.retained_prefix_reasoning_indices ~config ~tools:[] history with
   | Error (Reasoning_history_projection.Invalid_control_lowering _) -> ()
   | _ -> Alcotest.fail "removing an empty assistant must revalidate context placement");
  check_bool "invalid post-filter transcript cannot stamp a response" true
    (Backend_anthropic.transmitted_reasoning_prefix ~config ~messages:history ~tools:[]
       ~response_content:[Text "answer"] () = None);
  let empty_assistant = message Assistant [Thinking {content="orphan";signature=Some "synthetic"}] in
  check_bool "removed assistant leaves no phantom header" true
    ((fold ~head:[] [caller;empty_assistant]).final_digest = (fold ~head:[] [caller]).final_digest)
;;

let () =
  Alcotest.run
    "provider_agnostic_reasoning_replay"
    [ ( "typed replay projection"
      , [ Alcotest.test_case "native context preserves the signed tool prefix" `Quick
            test_native_context_signed_tool_round_trip
        ; Alcotest.test_case "native context validates post-filter placement" `Quick
            test_native_context_placement_and_removed_assistant
        ; Alcotest.test_case "initial System preserves the native caller boundary" `Quick
            test_initial_system_control_lowering
        ; Alcotest.test_case "request tools select full-history replay" `Quick
            test_request_tools_selects_full_history_reasoning
        ; Alcotest.test_case
            "provider replay policy matrix"
            `Quick
            test_provider_replay_policy_matrix_pinned
        ; Alcotest.test_case
            "clear-thinking gate is capability not identity"
            `Quick
            test_clear_thinking_gate_is_capability_not_identity
        ; Alcotest.test_case
            "rotation policy declared per dialect"
            `Quick
            test_rotation_policy_is_declared_per_dialect
        ; Alcotest.test_case
            "rotation policy drives incompatible drop"
            `Quick
            test_rotation_policy_drives_incompatible_drop
        ; Alcotest.test_case
            "source exactness"
            `Quick
            test_source_exactness_and_classification
        ; Alcotest.test_case
            "whole-history filtering"
            `Quick
            test_whole_history_source_filtering
        ; Alcotest.test_case
            "tool-call policy"
            `Quick
            test_tool_call_policy_applies_across_history
        ; Alcotest.test_case
            "latest user turn policy"
            `Quick
            test_latest_user_turn_policy_keeps_only_current_tool_reasoning
        ; Alcotest.test_case
            "latest user turn policy preserves an exchange without a caller boundary"
            `Quick
            test_latest_user_turn_policy_without_user_preserves_tool_reasoning
        ; Alcotest.test_case
            "latest user turn policy ignores the extra-context carrier"
            `Quick
            test_latest_user_turn_policy_ignores_extra_context_carrier
        ; Alcotest.test_case
            "a real trailing user message still resets the boundary"
            `Quick
            test_latest_user_turn_policy_real_trailing_user_still_resets
        ; Alcotest.test_case
            "carrier-only history preserves tool reasoning"
            `Quick
            test_carrier_only_history_preserves_tool_reasoning
        ; Alcotest.test_case
            "explicit preserve promotes latest-user policy"
            `Quick
            test_explicit_preserve_promotes_latest_user_policy_to_full_history
        ; Alcotest.test_case
            "unsupported codec fails"
            `Quick
            test_selected_unsupported_block_fails_closed
        ; Alcotest.test_case
            "response source required"
            `Quick
            test_assistant_message_requires_live_source
        ; Alcotest.test_case
            "OpenAI chat boundary"
            `Quick
            test_openai_chat_request_uses_whole_history_projection
        ; Alcotest.test_case
            "replay field mirrors the streaming field"
            `Quick
            test_openai_chat_replay_field_mirrors_streaming_field
        ; Alcotest.test_case
            "Ollama native boundary"
            `Quick
            test_ollama_request_replays_native_thinking_field
        ; Alcotest.test_case
            "Ollama native latest-turn default"
            `Quick
            test_ollama_native_default_replays_only_latest_user_turn_tool_thinking
        ; Alcotest.test_case
            "Ollama catalog replay override wins"
            `Quick
            test_ollama_native_catalog_replay_overrides_win
        ; Alcotest.test_case
            "undeclared ollama_cloud rows replay within the user turn on both wires"
            `Quick
            test_undeclared_ollama_cloud_rows_replay_within_the_user_turn_on_both_wires
        ; Alcotest.test_case
            "OpenAI Responses opaque boundary"
            `Quick
            test_openai_responses_replays_only_opaque_item
        ; Alcotest.test_case
            "transmitted history drops what the wire drops"
            `Quick
            test_transmitted_history_drops_what_the_wire_drops
        ; Alcotest.test_case
            "transmitted history keeps what the wire keeps"
            `Quick
            test_transmitted_history_keeps_what_the_wire_keeps
        ; Alcotest.test_case
            "anthropic honors a latest-turn replay declaration"
            `Quick
            test_anthropic_honors_a_latest_turn_replay_declaration
        ; Alcotest.test_case
            "an admitted completion keeps thinking for the next round"
            `Quick
            test_an_admitted_completion_keeps_thinking_for_the_next_round
        ; Alcotest.test_case
            "an admitted stream keeps thinking for the next round"
            `Quick
            test_an_admitted_stream_keeps_thinking_for_the_next_round
        ; Alcotest.test_case
            "prefix binding keeps thinking on a stable prefix"
            `Quick
            test_prefix_binding_keeps_thinking_on_a_stable_prefix
        ; Alcotest.test_case
            "prefix binding drops thinking when the carrier block is gone"
            `Quick
            test_prefix_binding_drops_thinking_when_the_carrier_block_is_gone
        ; Alcotest.test_case
            "prefix binding drops thinking edited in place"
            `Quick
            test_prefix_binding_drops_thinking_edited_in_place
        ; Alcotest.test_case
            "prefix binding drops legacy thinking without a digest"
            `Quick
            test_prefix_binding_drops_legacy_thinking_without_a_digest
        ; Alcotest.test_case
            "prefix entry round-trip and classification"
            `Quick
            test_prefix_entry_round_trip_and_classification
        ; Alcotest.test_case
            "prefix unreadable entry drops with its own cause"
            `Quick
            test_prefix_unreadable_entry_drops_with_its_own_cause
        ; Alcotest.test_case
            "a corrupted tag in history does not block requests"
            `Quick
            test_a_corrupted_tag_in_history_does_not_block_requests
        ; Alcotest.test_case
            "a cut counts once per request and later blocks survive"
            `Quick
            test_a_cut_counts_once_per_request_and_later_blocks_survive
        ; Alcotest.test_case
            "admitted sync path records a digest the next request honors"
            `Quick
            (test_admitted_path_records_a_digest_the_next_request_honors ~stream:false)
        ; Alcotest.test_case
            "admitted stream path records a digest the next request honors"
            `Quick
            (test_admitted_path_records_a_digest_the_next_request_honors ~stream:true)
        ; Alcotest.test_case
            "admitted sync digest survives a restart"
            `Quick
            (test_admitted_path_digest_survives_a_restart ~stream:false)
        ; Alcotest.test_case
            "admitted stream digest survives a restart"
            `Quick
            (test_admitted_path_digest_survives_a_restart ~stream:true)
        ; Alcotest.test_case
            "admitted sync path drops thinking when the tool set grows"
            `Quick
            (test_admitted_path_drops_thinking_when_the_tool_set_grows
               ~stream:false
               ~reload_history:false)
        ; Alcotest.test_case
            "admitted sync path drops thinking when the tool set grows after a restart"
            `Quick
            (test_admitted_path_drops_thinking_when_the_tool_set_grows
               ~stream:false
               ~reload_history:true)
        ; Alcotest.test_case
            "admitted stream path drops thinking when the tool set grows after a restart"
            `Quick
            (test_admitted_path_drops_thinking_when_the_tool_set_grows
               ~stream:true
               ~reload_history:true)
        ; Alcotest.test_case
            "admitted path drops thinking when the system prompt changes"
            `Quick
            test_admitted_path_drops_thinking_when_the_system_prompt_changes
        ; Alcotest.test_case
            "a stable earlier drop does not hide the first real mismatch"
            `Quick
            test_a_stable_earlier_drop_does_not_hide_the_first_real_mismatch
        ; Alcotest.test_case
            "prefix binding drops thinking when the request head changes"
            `Quick
            test_prefix_binding_drops_thinking_when_the_request_head_changes
        ; Alcotest.test_case
            "prefix binding keeps thinking when only sampling changes"
            `Quick
            test_prefix_binding_keeps_thinking_when_only_sampling_changes
        ; Alcotest.test_case
            "prefix binding keeps thinking when tool choice changes"
            `Quick
            test_prefix_binding_keeps_thinking_when_tool_choice_changes
        ; Alcotest.test_case
            "prefix binding drops thinking when the system form changes"
            `Quick
            test_prefix_binding_drops_thinking_when_the_system_form_changes
        ; Alcotest.test_case
            "prefix binding keeps thinking when the cached system form is unchanged"
            `Quick
            test_prefix_binding_keeps_thinking_when_the_cached_system_form_is_unchanged
        ; Alcotest.test_case
            "prefix binding keeps thinking across chained rounds"
            `Quick
            test_prefix_binding_keeps_thinking_across_chained_rounds
        ; Alcotest.test_case
            "a malformed tag anywhere refuses the projection"
            `Quick
            test_a_malformed_tag_anywhere_refuses_the_projection
        ; Alcotest.test_case
            "every codec answers its own contract"
            `Quick
            test_every_codec_answers_its_own_contract
        ; Alcotest.test_case
            "the drop summary names its serialization"
            `Quick
            test_drop_summary_names_its_serialization
        ] )
    ]
;;
