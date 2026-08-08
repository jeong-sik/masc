(** Request-serialization snapshot ratchet (WP9).

    Pins the CURRENT request-body wire output of each provider backend's
    request builder against an inline expected string. The pinned strings
    record present behavior — they are a regression fence, not an assertion
    that the current shape is "correct". When a serializer changes on
    purpose, regenerate the expected string in the same PR and review the
    diff.

    Determinism note: every field in the fixture is supplied explicitly so
    the wire string is a pure function of the fixture, not of the host
    environment. In particular:
    - [model_id] ("oas-snapshot-fixture-model") matches no static capability
      prefix and is not expected in any capability manifest, so capability
      lookup falls through to per-kind defaults.
    - [supports_tool_choice_override:true] pins whether the OpenAI/GLM
      [tool_choice] field is emitted, independent of any manifest entry.
    - [keep_alive:"-1"] explicitly pins the Ollama [keep_alive] field.
    - No model in this fixture reports [supports_seed], so no [seed] field is
      emitted. *)

open Alcotest
open Llm_provider
open Types

(* ── Shared fixture ─────────────────────────────────── *)

let msg role content : message =
  { role; content; name = None; tool_call_id = None; metadata = [] }
;;

(* One tool declaration in the SDK's input_schema shape. *)
let tool_decl =
  `Assoc
    [ "name", `String "get_weather"
    ; "description", `String "Get weather for a city"
    ; ( "input_schema"
      , `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "city", `Assoc [ "type", `String "string" ] ]
          ; "required", `List [ `String "city" ]
          ] )
    ]
;;

(* A representative conversation exercising a ToolUse turn followed by a
   ToolResult, so the snapshot covers assistant tool-call serialization and
   user/tool-result serialization (block ordering included). *)
let messages =
  [ msg User [ Text "What's the weather in Seoul?" ]
  ; msg
      Assistant
      [ ToolUse
          { id = "call_1"
          ; name = "get_weather"
          ; input = `Assoc [ "city", `String "Seoul" ]
          }
      ]
  ; msg
      Tool
      [ ToolResult
          { tool_use_id = "call_1"
          ; content = "Sunny, 25C"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  ]
;;

let parallel_messages =
  [ msg User [ Text "What's the weather in Seoul and London?" ]
  ; msg
      Assistant
      [ ToolUse
          { id = "call_1"
          ; name = "get_weather"
          ; input = `Assoc [ "city", `String "Seoul" ]
          }
      ; ToolUse
          { id = "call_2"
          ; name = "get_weather"
          ; input = `Assoc [ "city", `String "London" ]
          }
      ]
  ; msg
      Tool
      [ ToolResult
          { tool_use_id = "call_1"
          ; content = "Sunny, 25C"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ; ToolResult
          { tool_use_id = "call_2"
          ; content = "Rain, 16C"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  ]
;;

let nudged_messages =
  [ msg User [ Text "What's the weather in Seoul?" ]
  ; msg
      Assistant
      [ ToolUse
          { id = "call_1"
          ; name = "get_weather"
          ; input = `Assoc [ "city", `String "Seoul" ]
          }
      ]
  ; msg
      Tool
      [ ToolResult
          { tool_use_id = "call_1"
          ; content = "Sunny, 25C"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  ; msg User [ Text "nudge: try a different tool" ]
  ]
;;

let cfg ~kind ~base_url ~tool_choice =
  Provider_config.make
    ~kind
    ~model_id:"oas-snapshot-fixture-model"
    ~base_url
    ~api_key:"test-key"
    ~max_tokens:1024
    ~temperature:0.7
    ~tool_choice
    ~disable_parallel_tool_use:true
    ~supports_tool_choice_override:true
    ~keep_alive:"-1"
    ()
;;

let openai_cfg = cfg ~kind:OpenAI_compat ~base_url:"https://api.openai.com/v1"
let anthropic_cfg = cfg ~kind:Anthropic ~base_url:"https://api.anthropic.com"

let gemini_cfg =
  cfg ~kind:Gemini ~base_url:"https://generativelanguage.googleapis.com/v1beta"
;;

let glm_cfg = cfg ~kind:Glm ~base_url:"https://open.bigmodel.cn/api/paas/v4"
let ollama_cfg = cfg ~kind:Ollama ~base_url:"http://127.0.0.1:11434"

let openai_no_parallel_capability_cfg =
  Provider_config.make
    ~kind:OpenAI_compat
    ~model_id:"unknown-no-parallel-tools"
    ~base_url:"https://api.openai.com/v1"
    ~model_capabilities_override:
      { Llm_provider.Capabilities.openai_compat_chat_capabilities with
        supports_parallel_tool_calls = false
      }
    ~api_key:"test-key"
    ~max_tokens:1024
    ~temperature:0.7
    ~disable_parallel_tool_use:false
    ()
;;

(* RFC-OAS-023 fixture. Unlike the shared [cfg] above, this one uses the real
   provider/model identity ([deepseek]/[deepseek-v4-flash]). DeepSeek's direct
   API speaks the OpenAI-compatible Chat Completions wire, but provider-specific
   thinking/tool-choice semantics must come from that exact catalog tuple rather
   than a duplicated test record or a bare model id. *)
let deepseek_cfg ?enable_thinking ?reasoning_effort ~tool_choice () =
  Provider_config.make
    ~kind:OpenAI_compat
    ~provider_id:"deepseek"
    ~model_id:"deepseek-v4-flash"
    ~base_url:"https://api.deepseek.com"
    ~api_key:"test-key"
    ~max_tokens:1024
    ~temperature:0.7
    ~tool_choice
    ~disable_parallel_tool_use:true
    ?enable_thinking
    ?reasoning_effort
    ()
;;

(* Structured-output wire fixture. Pins the [output_schema] -> provider wire
   field for the two native backends whose schema serialization path had no
   snapshot: Ollama emits the raw schema under [format]; Anthropic wraps it as
   [format].{type:"json_schema", schema}. Guards against a silent-drop
   regression where a serializer refactor stops emitting the schema (the
   structured-output boundary of RFC-OAS-023 / RFC-OAS-034). OpenAI and Gemini
   already have this coverage in test_backend_openai_codec / test_backend_gemini;
   these two backends did not. *)
let output_schema_fixture =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "string" ] ]
    ; "required", `List [ `String "answer" ]
    ]
;;

let schema_cfg ~kind ~base_url =
  Provider_config.make
    ~kind
    ~model_id:"oas-snapshot-fixture-model"
    ~base_url
    ~api_key:"test-key"
    ~max_tokens:1024
    ~temperature:0.7
    ~response_format:(Types.JsonSchema output_schema_fixture)
    ~supports_structured_output_override:true
    ~keep_alive:"-1"
    ()
;;

let ollama_schema_cfg = schema_cfg ~kind:Ollama ~base_url:"http://127.0.0.1:11434"

let anthropic_schema_cfg =
  schema_cfg ~kind:Anthropic ~base_url:"https://api.anthropic.com"
;;

(* ── Helpers ────────────────────────────────────────── *)

let snapshot label expected actual = check string label expected actual

(* Substring containment, used for legible per-field assertions in addition
   to the full-string ratchet. *)
let contains ~needle haystack =
  let nl = String.length needle
  and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0
;;

let json_body body = Yojson.Safe.from_string body

let has_field name json =
  match Yojson.Safe.Util.member name json with
  | `Null -> false
  | _ -> true
;;

let assistant_message body =
  let open Yojson.Safe.Util in
  body
  |> json_body
  |> member "messages"
  |> to_list
  |> List.find (fun msg -> msg |> member "role" |> to_string = "assistant")
;;

let check_reasoning_content label expected body =
  let msg = assistant_message body in
  check bool label expected (has_field "reasoning_content" msg)
;;

let check_thinking_enabled_clear label expected_clear body =
  let open Yojson.Safe.Util in
  let thinking = body |> json_body |> member "thinking" in
  check string (label ^ " type") "enabled" (thinking |> member "type" |> to_string);
  check
    bool
    (label ^ " clear_thinking")
    expected_clear
    (thinking |> member "clear_thinking" |> to_bool)
;;

(* ── OpenAI-compatible ──────────────────────────────── *)

let openai_forced_expected =
  {|{"parallel_tool_calls":false,"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":{"type":"function","function":{"name":"get_weather"}},"temperature":0.7,"model":"oas-snapshot-fixture-model","messages":[{"role":"user","content":"What's the weather in Seoul?"},{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Seoul\"}"}}],"role":"assistant","content":null},{"role":"tool","tool_call_id":"call_1","content":"Sunny, 25C"}],"max_tokens":1024}|}
;;

let openai_required_expected =
  {|{"parallel_tool_calls":false,"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"required","temperature":0.7,"model":"oas-snapshot-fixture-model","messages":[{"role":"user","content":"What's the weather in Seoul?"},{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Seoul\"}"}}],"role":"assistant","content":null},{"role":"tool","tool_call_id":"call_1","content":"Sunny, 25C"}],"max_tokens":1024}|}
;;

(* None_ omits both [tools] and [tool_choice] entirely (it does not emit
   "none"). Pinned as current behavior, not a serializer fix. *)
let openai_none_expected =
  {|{"temperature":0.7,"model":"oas-snapshot-fixture-model","messages":[{"role":"user","content":"What's the weather in Seoul?"},{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Seoul\"}"}}],"role":"assistant","content":null},{"role":"tool","tool_call_id":"call_1","content":"Sunny, 25C"}],"max_tokens":1024}|}
;;

let test_openai_forced () =
  let body =
    Backend_openai_request.build_request
      ~config:(openai_cfg ~tool_choice:(Tool "get_weather"))
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  snapshot "openai tool_choice=forced(Tool) snapshot" openai_forced_expected body;
  check
    bool
    "parallel_tool_calls:false present when disabled"
    true
    (contains ~needle:{|"parallel_tool_calls":false|} body);
  check bool "role:tool present" true (contains ~needle:{|"role":"tool"|} body);
  check
    bool
    "forced tool_choice names the function"
    true
    (contains
       ~needle:{|"tool_choice":{"type":"function","function":{"name":"get_weather"}}|}
       body)
;;

let test_openai_required () =
  let body =
    Backend_openai_request.build_request
      ~config:(openai_cfg ~tool_choice:Any)
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  snapshot "openai tool_choice=required(Any) snapshot" openai_required_expected body;
  check
    bool
    {|Any maps to tool_choice:"required"|}
    true
    (contains ~needle:{|"tool_choice":"required"|} body)
;;

let test_openai_none () =
  let body =
    Backend_openai_request.build_request
      ~config:(openai_cfg ~tool_choice:None_)
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  snapshot "openai tool_choice=none(None_) snapshot" openai_none_expected body;
  check
    bool
    "None_ omits tool_choice field"
    false
    (contains ~needle:{|"tool_choice"|} body);
  check bool "None_ omits tools field" false (contains ~needle:{|"tools"|} body)
;;

let test_openai_parallel_disabled_by_capability () =
  let body =
    Backend_openai_request.build_request
      ~config:openai_no_parallel_capability_cfg
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  check
    bool
    "parallel_tool_calls:false follows provider capability"
    true
    (contains ~needle:{|"parallel_tool_calls":false|} body)
;;

(* ── DeepSeek via OpenAI-compat (RFC-OAS-023 routing fence) ───
   This fixture pins the current provider wire for [deepseek-v4-flash]
   through the OpenAI-compat backend. It exercises the REAL capability
   lookup (no [supports_tool_choice_override]), so it runs through the
   prefix dispatcher fixed in RFC-OAS-023.

   It is a regression FENCE, not a discrimination proof: with
   [enable_thinking=None] and [max_tokens=1024], no thinking control field is
   emitted, so the wire is byte-identical before/after the
   de-anonymization. The
   actual proof that [deepseek-v4-flash] resolves to [Deepseek_v4_flash]
   lives in the inline [let%test "for_model_id_catalog: specific model IDs
   get correct (not shadowed) capabilities"] in [capabilities.ml] and in
   [test_capabilities.ml]'s cloud-suffix route checks. *)
let deepseek_auto_expected =
  {|{"parallel_tool_calls":false,"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"auto","model":"deepseek-v4-flash","messages":[{"role":"user","content":"What's the weather in Seoul?"},{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Seoul\"}"}}],"role":"assistant","content":null},{"role":"tool","tool_call_id":"call_1","content":"Sunny, 25C"}],"max_tokens":1024}|}
;;

let test_deepseek_auto_serializes_auto_tool_choice () =
  let body =
    Backend_openai_request.build_request
      ~config:(deepseek_cfg ~tool_choice:Auto ())
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  snapshot
    "deepseek-v4-flash openai-compat tool_choice=auto snapshot"
    deepseek_auto_expected
    body;
  check
    bool
    {|Auto maps to tool_choice:"auto"|}
    true
    (contains ~needle:{|"tool_choice":"auto"|} body);
  check
    bool
    {|Any-only required tool_choice is not emitted|}
    false
    (contains ~needle:{|"tool_choice":"required"|} body);
  check
    bool
    "model id is the real fleet id"
    true
    (contains ~needle:{|"model":"deepseek-v4-flash"|} body)
;;

let test_deepseek_required_rejected () =
  match
    Provider_config.validate_tool_choice_request_typed (deepseek_cfg ~tool_choice:Any ())
  with
  | Error (Provider_config.Unsupported_required_tool_choice { provider_kind; model_id })
    ->
    check
      string
      "required rejection provider"
      "openai_compat"
      (Provider_config.string_of_provider_kind provider_kind);
    check string "required rejection model" "deepseek-v4-flash" model_id
  | Error rejection ->
    failf
      "deepseek-v4-flash rejected required tool_choice with unexpected reason: %s"
      (Provider_config.tool_choice_request_rejection_to_message rejection)
  | Ok () -> fail "deepseek-v4-flash unexpectedly accepted required tool_choice"
;;

let test_deepseek_disabled_reasoning_omits_reasoning_effort () =
  let body =
    Backend_openai_request.build_request
      ~config:(deepseek_cfg ~enable_thinking:false ~tool_choice:Auto ())
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  check
    bool
    {|DeepSeek disabled reasoning sends thinking.disabled|}
    true
    (contains ~needle:{|"thinking":{"type":"disabled"}|} body);
  check
    bool
    "disabled reasoning omits reasoning_effort"
    false
    (contains ~needle:{|"reasoning_effort"|} body)
;;

let test_deepseek_explicit_effort_is_serialized () =
  let body =
    Backend_openai_request.build_request
      ~config:
        (deepseek_cfg
           ~enable_thinking:true
           ~reasoning_effort:Reasoning_effort.High
           ~tool_choice:Auto
           ())
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  check
    bool
    {|DeepSeek enabled thinking sends thinking.enabled|}
    true
    (contains ~needle:{|"thinking":{"type":"enabled"}|} body);
  check
    bool
    "explicit reasoning effort serialized"
    true
    (contains ~needle:{|"reasoning_effort":"high"|} body)
;;

(* A raw OpenAI-compatible config is only a generic wire declaration. Even when
   its endpoint and model text resemble Z.AI, it must not acquire native GLM
   thinking/replay semantics. Native GLM behavior is covered by the typed
   [kind:Glm] fixtures below. *)
let raw_zai_openai_compat_cfg () =
  Provider_config.make
    ~kind:OpenAI_compat
    ~model_id:"glm-5"
    ~base_url:"https://api.z.ai/api/paas/v4"
    ~api_key:"test-key"
    ~max_tokens:1024
    ~temperature:0.7
    ~tool_choice:Auto
    ~disable_parallel_tool_use:true
    ~enable_thinking:true
    ~preserve_thinking:true
    ()
;;

(* Provenance stamp mirroring the production response path:
   [Complete_common.patch_telemetry] resolves the source with
   [Reasoning_dialect.reasoning_source_for_provider_config] and
   [Types.assistant_message_of_response] moves it onto the stored assistant
   message metadata. A reasoning-bearing history message without this stamp is
   unrepresentable through the production path, and
   [Reasoning_history_projection] drops its reasoning fail-closed
   (missing_source) before the replay policy is even consulted. *)
let reasoning_source_metadata config =
  match Reasoning_dialect.reasoning_source_for_provider_config config with
  | Ok source -> Reasoning_source.metadata source
  | Error detail -> Alcotest.fail detail
;;

let zai_glm_messages_with_reasoning ~config =
  [ msg User [ Text "solve" ]
  ; { (msg
         Assistant
         [ Text "answer"; Thinking { signature = None; content = "chain of thought" } ])
      with
      metadata = reasoning_source_metadata config
    }
  ]
;;

let test_raw_openai_compat_does_not_infer_glm_thinking_or_replay () =
  let config = raw_zai_openai_compat_cfg () in
  let body =
    Backend_openai_request.build_request
      ~config
      ~messages:(zai_glm_messages_with_reasoning ~config)
      ()
  in
  check
    bool
    "generic compat omits GLM thinking object"
    false
    (body |> json_body |> has_field "thinking");
  check_reasoning_content
    "generic compat does not replay GLM reasoning_content"
    false
    body
;;

(* Native [kind:Glm] reasoning_content replay gate (oas#2236). Typed [Glm] is
   the sole positive native GLM path: replay historical reasoning_content only
   under Preserved Thinking (clear_thinking=false). Before the gate the native
   path replayed unconditionally, contradicting the default
   clear_thinking=true contract. *)
let native_glm_cfg ?(enable_thinking = Some true) ?preserve_thinking ?clear_thinking () =
  Provider_config.make
    ~kind:Glm
    ~model_id:"glm-5"
    ~base_url:"https://api.z.ai/api/paas/v4"
    ~api_key:"test-key"
    ~max_tokens:1024
    ~temperature:0.7
    ~tool_choice:Any
    ~disable_parallel_tool_use:true
    ?enable_thinking
    ?preserve_thinking
    ?clear_thinking
    ()
;;

let test_native_glm_replays_reasoning_when_preserve_thinking () =
  let config = native_glm_cfg ~preserve_thinking:true () in
  let body =
    Backend_openai_request.build_request
      ~config
      ~messages:(zai_glm_messages_with_reasoning ~config)
      ()
  in
  check_reasoning_content
    "native GLM replays reasoning_content under preserve thinking"
    true
    body
;;

let test_native_glm_drops_reasoning_by_default () =
  let config = native_glm_cfg () in
  let body =
    Backend_openai_request.build_request
      ~config
      ~messages:(zai_glm_messages_with_reasoning ~config)
      ()
  in
  check_reasoning_content
    "native GLM omits reasoning_content with default clear_thinking=true"
    false
    body
;;

let test_native_glm_drops_reasoning_when_thinking_disabled () =
  let config = native_glm_cfg ~enable_thinking:(Some false) ~preserve_thinking:true () in
  let body =
    Backend_openai_request.build_request
      ~config
      ~messages:(zai_glm_messages_with_reasoning ~config)
      ()
  in
  check_reasoning_content
    "native GLM omits reasoning_content when thinking disabled"
    false
    body
;;

(* ── Anthropic ──────────────────────────────────────── *)

let anthropic_forced_expected =
  {|{"tool_choice":{"disable_parallel_tool_use":true,"type":"tool","name":"get_weather"},"tools":[{"name":"get_weather","description":"Get weather for a city","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}],"temperature":0.7,"model":"oas-snapshot-fixture-model","max_tokens":1024,"messages":[{"role":"user","content":[{"type":"text","text":"What's the weather in Seoul?"}]},{"role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"get_weather","input":{"city":"Seoul"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"Sunny, 25C","is_error":false}]}],"stream":false}|}
;;

let test_anthropic_forced () =
  let body =
    Backend_anthropic.build_request
      ~config:(anthropic_cfg ~tool_choice:(Tool "get_weather"))
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  snapshot "anthropic tool_choice=forced(Tool) snapshot" anthropic_forced_expected body;
  check
    bool
    "disable_parallel_tool_use nested inside tool_choice"
    true
    (contains
       ~needle:{|"tool_choice":{"disable_parallel_tool_use":true,"type":"tool"|}
       body);
  check bool "tool_use block present" true (contains ~needle:{|"type":"tool_use"|} body);
  check
    bool
    "tool_result block present"
    true
    (contains ~needle:{|"type":"tool_result"|} body);
  (* Block ordering: text/tool_use/tool_result appear in message order. *)
  check
    bool
    "no top-level disable_parallel field"
    false
    (contains ~needle:{|,"disable_parallel_tool_use":true}|} body
     && not (contains ~needle:{|"type":"tool"|} body))
;;

let test_anthropic_nudged_tool_turn_merges_followup_text () =
  let body =
    Backend_anthropic.build_request
      ~config:(anthropic_cfg ~tool_choice:(Tool "get_weather"))
      ~messages:nudged_messages
      ~tools:[ tool_decl ]
      ()
  in
  let open Yojson.Safe.Util in
  let messages_json = Yojson.Safe.from_string body |> member "messages" |> to_list in
  check int "wire messages" 3 (List.length messages_json);
  let final_message = List.nth messages_json 2 in
  check string "final role" "user" (final_message |> member "role" |> to_string);
  let content = final_message |> member "content" |> to_list in
  check int "merged content blocks" 2 (List.length content);
  check
    string
    "first block"
    "tool_result"
    (List.nth content 0 |> member "type" |> to_string);
  check string "second block" "text" (List.nth content 1 |> member "type" |> to_string);
  check
    string
    "followup text"
    "nudge: try a different tool"
    (List.nth content 1 |> member "text" |> to_string)
;;

(* ── Gemini ─────────────────────────────────────────── *)

let gemini_any_expected =
  {|{"toolConfig":{"functionCallingConfig":{"mode":"ANY"}},"tools":[{"functionDeclarations":[{"name":"get_weather","description":"Get weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]}],"generationConfig":{"temperature":0.7,"maxOutputTokens":1024},"contents":[{"role":"user","parts":[{"text":"What's the weather in Seoul?"}]},{"role":"model","parts":[{"functionCall":{"id":"call_1","name":"get_weather","args":{"city":"Seoul"}}}]},{"role":"user","parts":[{"functionResponse":{"id":"call_1","name":"get_weather","response":{"result":"Sunny, 25C"}}}]}]}|}
;;

let test_gemini_any () =
  let body =
    Backend_gemini.build_request
      ~config:(gemini_cfg ~tool_choice:Any)
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  snapshot "gemini tool_choice=Any snapshot" gemini_any_expected body;
  check
    bool
    "functionDeclarations present"
    true
    (contains ~needle:{|"functionDeclarations"|} body);
  check
    bool
    "functionCallingConfig present"
    true
    (contains ~needle:{|"functionCallingConfig":{"mode":"ANY"}|} body);
  (* #1840: Gemini has no parallel-disable; the field must be absent even
     though disable_parallel_tool_use=true. *)
  check
    bool
    "no parallel_tool_calls on the wire (#1840)"
    false
    (contains ~needle:"parallel_tool_calls" body);
  check
    bool
    "no disable_parallel on the wire (#1840)"
    false
    (contains ~needle:"disable_parallel" body)
;;

let test_gemini_nudged_tool_turn_merges_followup_text () =
  let body =
    Backend_gemini.build_request
      ~config:(gemini_cfg ~tool_choice:Any)
      ~messages:nudged_messages
      ~tools:[ tool_decl ]
      ()
  in
  let open Yojson.Safe.Util in
  let contents = Yojson.Safe.from_string body |> member "contents" |> to_list in
  check int "wire contents" 3 (List.length contents);
  let final_content = List.nth contents 2 in
  check string "final role" "user" (final_content |> member "role" |> to_string);
  let parts = final_content |> member "parts" |> to_list in
  check int "merged parts" 2 (List.length parts);
  check
    bool
    "functionResponse first"
    true
    (List.nth parts 0 |> member "functionResponse" <> `Null);
  check
    string
    "text followup"
    "nudge: try a different tool"
    (List.nth parts 1 |> member "text" |> to_string)
;;

(* ── GLM (OpenAI-compatible wire format) ────────────── *)

let glm_any_expected =
  {|{"parallel_tool_calls":false,"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"auto","temperature":0.7,"model":"oas-snapshot-fixture-model","messages":[{"role":"user","content":"What's the weather in Seoul?"},{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Seoul\"}"}}],"role":"assistant","content":""},{"role":"tool","tool_call_id":"call_1","content":"Sunny, 25C"}],"max_tokens":1024}|}
;;

let test_glm_any () =
  let body =
    Backend_glm.build_request
      ~config:(glm_cfg ~tool_choice:Any)
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  snapshot "glm tool_choice=Any snapshot" glm_any_expected body;
  check
    bool
    "parallel_tool_calls:false present when disabled"
    true
    (contains ~needle:{|"parallel_tool_calls":false|} body);
  check
    bool
    {|GLM coerces tool_choice Any to "auto"|}
    true
    (contains ~needle:{|"tool_choice":"auto"|} body)
;;

(* ── Ollama (native /api/chat shape) ────────────────── *)

let ollama_any_expected =
  {|{"options":{"temperature":0.7,"num_predict":1024},"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"keep_alive":-1,"stream":false,"model":"oas-snapshot-fixture-model","messages":[{"role":"user","content":"What's the weather in Seoul?"},{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":{"city":"Seoul"}}}],"role":"assistant","content":null},{"role":"tool","tool_name":"get_weather","content":"Sunny, 25C"}]}|}
;;

let ollama_parallel_expected =
  {|{"options":{"temperature":0.7,"num_predict":1024},"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"keep_alive":-1,"stream":true,"model":"oas-snapshot-fixture-model","messages":[{"role":"user","content":"What's the weather in Seoul and London?"},{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":{"city":"Seoul"}}},{"id":"call_2","type":"function","function":{"name":"get_weather","arguments":{"city":"London"}}}],"role":"assistant","content":null},{"role":"tool","tool_name":"get_weather","content":"Sunny, 25C"},{"role":"tool","tool_name":"get_weather","content":"Rain, 16C"}]}|}
;;

let test_ollama_any () =
  let body =
    Backend_ollama.build_request
      ~config:(ollama_cfg ~tool_choice:Any)
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  snapshot "ollama tool_choice=Any snapshot" ollama_any_expected body;
  check
    bool
    "ollama options carries temperature + num_predict"
    true
    (contains ~needle:{|"options":{"temperature":0.7,"num_predict":1024}|} body);
  check bool "keep_alive pinned to -1" true (contains ~needle:{|"keep_alive":-1|} body);
  (* Ollama native /api/chat takes no tool_choice / parallel_tool_calls. *)
  check bool "no tool_choice field" false (contains ~needle:{|"tool_choice"|} body)
;;

let test_ollama_parallel_tool_results () =
  let body =
    Backend_ollama.build_request
      ~stream:true
      ~config:(ollama_cfg ~tool_choice:Any)
      ~messages:parallel_messages
      ~tools:[ tool_decl ]
      ()
  in
  snapshot
    "ollama parallel tool-result correlation snapshot"
    ollama_parallel_expected
    body
;;

(* ── Structured-output wire (output_schema serialization) ──── *)

let test_ollama_output_schema () =
  let body =
    Backend_ollama.build_request
      ~config:ollama_schema_cfg
      ~messages:[ msg User [ Text "Answer as JSON." ] ]
      ()
  in
  (* Ollama native /api/chat carries the raw JSON Schema under [format]. *)
  check
    bool
    "ollama emits output_schema under the [format] field"
    true
    (contains ~needle:{|"format":{"type":"object"|} body);
  check
    bool
    "ollama [format] schema retains the declared required key"
    true
    (contains ~needle:{|"required":["answer"]|} body)
;;

let test_anthropic_tools_with_output_schema () =
  (* Tools + structured output in ONE request: the output_config format merge
     must not clobber tool wiring, and vice versa. *)
  let body =
    Backend_anthropic.build_request
      ~config:anthropic_schema_cfg
      ~messages
      ~tools:[ tool_decl ]
      ()
  in
  check
    bool
    "format.json_schema coexists with tools"
    true
    (contains ~needle:{|"format":{"type":"json_schema","schema":{|} body);
  check
    bool
    "tool declaration on the wire"
    true
    (contains ~needle:{|"name":"get_weather"|} body);
  check
    bool
    "tool input_schema on the wire"
    true
    (contains ~needle:{|"input_schema"|} body)
;;

let test_openai_tools_with_response_format () =
  let cfg = schema_cfg ~kind:OpenAI_compat ~base_url:"https://api.openai.com/v1" in
  let body =
    Backend_openai_request.build_request ~config:cfg ~messages ~tools:[ tool_decl ] ()
  in
  check
    bool
    "response_format json_schema coexists with tools"
    true
    (contains ~needle:{|"response_format":{"type":"json_schema"|} body);
  check
    bool
    "tool declaration on the wire"
    true
    (contains ~needle:{|"function":{"name":"get_weather"|} body)
;;

let test_anthropic_output_schema () =
  let body =
    Backend_anthropic.build_request
      ~config:anthropic_schema_cfg
      ~messages:[ msg User [ Text "Answer as JSON." ] ]
      ()
  in
  (* Anthropic wraps the schema as [format].{type:"json_schema", schema}. *)
  check
    bool
    {|anthropic emits [format] with type "json_schema"|}
    true
    (contains ~needle:{|"format":{"type":"json_schema","schema":{|} body);
  check
    bool
    "anthropic [format] schema retains the declared required key"
    true
    (contains ~needle:{|"required":["answer"]|} body)
;;

(* ── Suite ──────────────────────────────────────────── *)

let () =
  run
    "snapshot_provider_serialization"
    [ ( "openai"
      , [ test_case "tool_choice forced(Tool)" `Quick test_openai_forced
        ; test_case "tool_choice required(Any)" `Quick test_openai_required
        ; test_case "tool_choice none(None_)" `Quick test_openai_none
        ; test_case
            "parallel disabled by capability"
            `Quick
            test_openai_parallel_disabled_by_capability
        ; test_case
            "deepseek-v4-flash auto tool_choice"
            `Quick
            test_deepseek_auto_serializes_auto_tool_choice
        ; test_case
            "deepseek-v4-flash rejects required(Any)"
            `Quick
            test_deepseek_required_rejected
        ; test_case
            "deepseek-v4-flash disabled reasoning omits reasoning_effort"
            `Quick
            test_deepseek_disabled_reasoning_omits_reasoning_effort
        ; test_case
            "deepseek-v4-flash explicit effort"
            `Quick
            test_deepseek_explicit_effort_is_serialized
        ; test_case
            "raw openai-compat does not infer GLM thinking/replay"
            `Quick
            test_raw_openai_compat_does_not_infer_glm_thinking_or_replay
        ; test_case
            "native-glm replays reasoning when preserve_thinking"
            `Quick
            test_native_glm_replays_reasoning_when_preserve_thinking
        ; test_case
            "native-glm drops reasoning by default (clear_thinking=true)"
            `Quick
            test_native_glm_drops_reasoning_by_default
        ; test_case
            "native-glm drops reasoning when thinking disabled"
            `Quick
            test_native_glm_drops_reasoning_when_thinking_disabled
        ] )
    ; ( "anthropic"
      , [ test_case "tool_choice forced(Tool)" `Quick test_anthropic_forced
        ; test_case
            "nudged tool turn merges followup text"
            `Quick
            test_anthropic_nudged_tool_turn_merges_followup_text
        ] )
    ; ( "gemini"
      , [ test_case "tool_choice Any" `Quick test_gemini_any
        ; test_case
            "nudged tool turn merges followup text"
            `Quick
            test_gemini_nudged_tool_turn_merges_followup_text
        ] )
    ; "glm", [ test_case "tool_choice Any" `Quick test_glm_any ]
    ; ( "ollama"
      , [ test_case "tool_choice Any" `Quick test_ollama_any
        ; test_case
            "parallel tool-result correlation"
            `Quick
            test_ollama_parallel_tool_results
        ] )
    ; ( "structured_output_wire"
      , [ test_case "ollama output_schema -> format" `Quick test_ollama_output_schema
        ; test_case
            "anthropic output_schema -> format.json_schema"
            `Quick
            test_anthropic_output_schema
        ; test_case
            "anthropic tools coexist with output_schema"
            `Quick
            test_anthropic_tools_with_output_schema
        ; test_case
            "openai tools coexist with response_format"
            `Quick
            test_openai_tools_with_response_format
        ] )
    ]
;;
