open Llm_provider
open Types

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)

let contract replay_policy : Reasoning_replay_contract.t =
  { replay_policy; streaming = No_streaming_reasoning; output_wire = No_output_control }
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

let message ?(metadata = []) role content : message =
  { role; content; name = None; tool_call_id = None; metadata }
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
        ; output_wire = Reasoning_replay_contract.No_output_control
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

let test_latest_user_turn_policy_without_user_replays_none () =
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
      "unscoped reasoning is removed"
      false
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
            ; output_wire = Reasoning_replay_contract.No_output_control
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

(* ── RFC-OAS-029 S1.1/S3.1: identity read once, replay read from the record ── *)

let resolved_replay_policy config =
  (Reasoning_dialect.for_provider_config config).replay_policy
;;

let clear_thinking_capabilities preserve_thinking_control_format =
  { Capabilities.default_capabilities with
    supports_reasoning = true
  ; supports_extended_thinking = true
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
       ~model_id:"claude-sonnet-4-6"
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
  check
    "dashscope"
    Reasoning_replay_contract.No_replay
    (cfg
       ~kind:Provider_config.DashScope
       ~model_id:"qwen-max"
       ~base_url:"https://dashscope.aliyuncs.com"
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

(* ── RFC-OAS-029 S3.1: the rotation drop is a declared policy ── *)

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
       ~model_id:"claude-sonnet-4-6"
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

let () =
  Alcotest.run
    "provider_agnostic_reasoning_replay"
    [ ( "typed replay projection"
      , [ Alcotest.test_case
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
            "latest user turn policy requires a user boundary"
            `Quick
            test_latest_user_turn_policy_without_user_replays_none
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
            "OpenAI Responses opaque boundary"
            `Quick
            test_openai_responses_replays_only_opaque_item
        ] )
    ]
;;
