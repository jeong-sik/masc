(** Thinking-control dialect regression matrix.

    The same user-facing [enable_thinking] knob maps to different provider wire
    formats depending on the model family and serving backend. Keep these
    fixtures together so catalog changes cannot silently move a model family to
    the wrong dialect. *)

module PC = Llm_provider.Provider_config
module BOR = Llm_provider.Backend_openai_request
module BOL = Llm_provider.Backend_ollama
module BAN = Llm_provider.Backend_anthropic
module CAP = Llm_provider.Capabilities
module CM = Llm_provider.Capability_manifest
module MC = Llm_provider.Model_catalog
module RD = Llm_provider.Reasoning_dialect
module RE = Llm_provider.Reasoning_effort
module S = Llm_provider.Streaming
open Alcotest
open Llm_provider.Types
open Yojson.Safe.Util

let json_of_body body = Yojson.Safe.from_string body
let member_is_absent name json = json |> member name = `Null

let sampling_parameter_names parameters =
  List.map CAP.sampling_parameter_to_string parameters
;;

let string_contains_sub s sub =
  let len = String.length s
  and sub_len = String.length sub in
  let rec loop i = i + sub_len <= len && (String.sub s i sub_len = sub || loop (i + 1)) in
  sub_len = 0 || loop 0
;;

let with_manifest json f =
  match CM.of_json (Yojson.Safe.from_string json) with
  | Error msg -> fail ("manifest parse failed: " ^ msg)
  | Ok manifest ->
    CM.set_global manifest;
    Fun.protect ~finally:(fun () -> CM.set_global []) f
;;

let install_repository_catalog () =
  Model_catalog_test_support.install_embedded_model_catalog
    ~suite:"thinking-control dialect"
;;

let without_ambient_manifest f =
  CM.set_global [];
  install_repository_catalog ();
  Fun.protect
    ~finally:(fun () ->
      MC.clear_global ();
      CM.clear_global ())
    f
;;

let with_catalog_toml contents f =
  let path = Filename.temp_file "oas-thinking-catalog" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       output_string oc contents;
       close_out oc;
       match MC.load_file path with
       | Error msg -> fail ("custom catalog parse failed: " ^ msg)
       | Ok catalog ->
         MC.set_global catalog;
         Fun.protect ~finally:install_repository_catalog f)
;;

let check_member_absent name json =
  check bool (name ^ " absent") true (member_is_absent name json)
;;

let openai_compat_config ?enable_thinking ?preserve_thinking ?thinking_budget model_id =
  PC.make
    ~kind:OpenAI_compat
    ~model_id
    ~base_url:"https://provider.example/v1"
    ?enable_thinking
    ?preserve_thinking
    ?thinking_budget
    ()
;;

let catalog_capabilities ?provider_id model_id =
  let capabilities =
    match provider_id with
    | None -> CAP.for_model_id model_id
    | Some provider_label ->
      CAP.for_provider_model_id ~allow_bare_fallback:false ~provider_label ~model_id
  in
  match capabilities with
  | Some caps -> caps
  | None ->
    fail
      (Printf.sprintf
         "expected catalog capabilities for %s%s"
         (match provider_id with
          | None -> ""
          | Some provider_label -> provider_label ^ "/")
         model_id)
;;

let declared_catalog_openai_compat_config
      ?(base_url = "https://declared-openai-compat.example/v1")
      ?provider_id
      ?enable_thinking
      ?preserve_thinking
      ?thinking_budget
      ?temperature
      ?top_p
      ?tool_choice
      ?(response_format = Off)
      model_id
  =
  PC.make
    ~kind:OpenAI_compat
    ?provider_id
    ~model_id
    ~base_url
    ~model_capabilities_override:(catalog_capabilities ?provider_id model_id)
    ?enable_thinking
    ?preserve_thinking
    ?thinking_budget
    ?temperature
    ?top_p
    ?tool_choice
    ~response_format
    ()
;;

let declared_qwen_openai_compat_capabilities =
  { CAP.openai_compat_chat_capabilities with
    supports_reasoning = true
  ; supports_extended_thinking = true
  ; supports_reasoning_budget = true
  ; thinking_control_format = CAP.Chat_template_kwargs
  ; preserve_thinking_control_format = CAP.Chat_template_kwargs_preserve_thinking
  ; reasoning_streaming_format = CAP.Delta_reasoning_field "reasoning_content"
  ; reasoning_replay_override = CAP.Force_latest_user_turn_tool_calls
  }
;;

let declared_qwen_openai_compat_config
      ?enable_thinking
      ?preserve_thinking
      ?thinking_budget
      model_id
  =
  PC.make
    ~kind:OpenAI_compat
    ~model_id
    ~base_url:"https://declared-qwen.example/v1"
    ~model_capabilities_override:declared_qwen_openai_compat_capabilities
    ?enable_thinking
    ?preserve_thinking
    ?thinking_budget
    ()
;;

let kimi_config
      ?enable_thinking
      ?preserve_thinking
      ?thinking_budget
      ?temperature
      ?top_p
      model_id
  =
  PC.make
    ~kind:Kimi
    ~model_id
    ~base_url:"https://api.moonshot.ai/v1"
    ?enable_thinking
    ?preserve_thinking
    ?thinking_budget
    ?temperature
    ?top_p
    ()
;;

let ollama_config ?system_prompt ?enable_thinking model_id =
  PC.make
    ~kind:Ollama
    ~model_id
    ~base_url:"http://127.0.0.1:11434"
    ?system_prompt
    ?enable_thinking
    ()
;;

let ollama_cloud_config ?system_prompt ?enable_thinking model_id =
  PC.make
    ~kind:Ollama
    ~provider_id:"ollama_cloud"
    ~model_id
    ~base_url:"https://ollama.com"
    ~request_path:"/api/chat"
    ?system_prompt
    ?enable_thinking
    ()
;;

let anthropic_config
      ?enable_thinking
      ?thinking_budget
      ?reasoning_effort
      ?response_format
      model_id
  =
  PC.make
    ~kind:Anthropic
    ~model_id
    ~base_url:"https://api.anthropic.com"
    ~max_tokens:16_000
    ?enable_thinking
    ?thinking_budget
    ?reasoning_effort
    ?response_format
    ()
;;

let test_raw_qwen_openai_compat_does_not_infer_chat_template_kwargs () =
  let config =
    openai_compat_config
      ~enable_thinking:false
      ~preserve_thinking:true
      "undeclared-runtime/qwen3-32b"
  in
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check_member_absent "chat_template_kwargs" json;
  check_member_absent "thinking" json;
  check_member_absent "reasoning_effort" json;
  check_member_absent "think" json;
  check_member_absent "enable_thinking" json
;;

let test_declared_qwen36_openai_compat_uses_chat_template_kwargs () =
  let config =
    declared_qwen_openai_compat_config
      ~enable_thinking:false
      ~preserve_thinking:true
      "Qwen/Qwen3.6-35B-A3B"
  in
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  let ctk = json |> member "chat_template_kwargs" in
  check bool "enable_thinking false" false (ctk |> member "enable_thinking" |> to_bool);
  check bool "preserve_thinking true" true (ctk |> member "preserve_thinking" |> to_bool);
  check_member_absent "thinking" json;
  check_member_absent "reasoning_effort" json;
  check_member_absent "enable_thinking" json
;;

let test_raw_qwen36_reasoning_dialect_does_not_infer_chat_template_kwargs () =
  let config =
    openai_compat_config
      ~enable_thinking:false
      ~preserve_thinking:true
      "undeclared-runtime/Qwen3.6-35B-A3B"
  in
  let dialect = RD.for_provider_config config in
  check string "toggle wire" "no_toggle" (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "no_replay"
    (RD.replay_policy_to_string dialect.replay_policy)
;;

let test_declared_qwen36_reasoning_dialect_uses_chat_template_kwargs () =
  let config =
    declared_qwen_openai_compat_config
      ~enable_thinking:false
      ~preserve_thinking:true
      "Qwen/Qwen3.6-35B-A3B"
  in
  let dialect = RD.for_provider_config config in
  check
    string
    "toggle wire"
    "chat_template_kwargs"
    (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "preserve_always"
    (RD.replay_policy_to_string dialect.replay_policy);
  check
    bool
    "no tool-call replay requirement"
    false
    (RD.requires_reasoning_replay_on_tool_call dialect);
  check
    (list string)
    "no ignored sampling params"
    []
    (sampling_parameter_names (RD.sampling_params_ignored_when_thinking dialect))
;;

let test_qwen36_reasoning_dialect_without_preserve_keeps_tool_reasoning () =
  let config =
    declared_qwen_openai_compat_config
      ~enable_thinking:true
      ~preserve_thinking:false
      "Qwen/Qwen3.6-35B-A3B"
  in
  let dialect = RD.for_provider_config config in
  check
    string
    "replay policy"
    "latest_user_turn_tool_calls"
    (RD.replay_policy_to_string dialect.replay_policy);
  check
    bool
    "plain assistant reasoning is omitted"
    false
    (RD.should_replay_reasoning dialect ~assistant_had_tool_call:false);
  check
    bool
    "assistant tool-call reasoning is retained"
    true
    (RD.should_replay_reasoning dialect ~assistant_had_tool_call:true)
;;

let test_qwen36_dashscope_uses_top_level_enable_thinking () =
  let config =
    PC.make
      ~kind:DashScope
      ~model_id:"Qwen3.6-35B-A3B"
      ~base_url:"https://dashscope.aliyuncs.com/compatible-mode/v1"
      ~enable_thinking:true
      ~preserve_thinking:true
      ~thinking_budget:4096
      ()
  in
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check bool "enable_thinking true" true (json |> member "enable_thinking" |> to_bool);
  check bool "preserve_thinking true" true (json |> member "preserve_thinking" |> to_bool);
  check int "thinking budget" 4096 (json |> member "thinking_budget" |> to_int);
  check_member_absent "chat_template_kwargs" json;
  check_member_absent "thinking" json;
  check_member_absent "reasoning_effort" json
;;

let test_qwen36_dashscope_dialect_reports_enable_thinking () =
  (* The reported dialect metadata must match what build_request actually emits
     for a DashScope Qwen config (top-level enable_thinking, asserted above),
     not the model catalog's chat_template_kwargs. *)
  let config =
    PC.make
      ~kind:DashScope
      ~model_id:"Qwen3.6-35B-A3B"
      ~base_url:"https://dashscope.aliyuncs.com/compatible-mode/v1"
      ~enable_thinking:true
      ~preserve_thinking:true
      ()
  in
  let dialect = RD.for_provider_config config in
  check
    string
    "toggle wire"
    "enable_thinking"
    (RD.toggle_wire_to_string dialect.toggle_wire)
;;

let test_mimo_v25_uses_thinking_object_and_json_mode () =
  let config =
    declared_catalog_openai_compat_config
      ~base_url:"https://token-plan-sgp.xiaomimimo.com/v1"
      ~provider_id:"mimo"
      ~enable_thinking:false
      ~response_format:JsonMode
      "mimo-v2.5-pro"
  in
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  let dialect = RD.for_provider_config config in
  check
    string
    "toggle wire"
    "thinking_object_only"
    (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "drop_without_tool_preserve_with_tool"
    (RD.replay_policy_to_string dialect.replay_policy);
  check
    bool
    "requires tool-call reasoning replay"
    true
    (RD.requires_reasoning_replay_on_tool_call dialect);
  (* reasoning_visibility vocab was retired (#2304, #2236 CoT loop fix);
     "side_channel:reasoning_content" is now governed by reasoning_replay
     policy, exercised in test_provider_agnostic_reasoning_replay. *)
  let thinking = json |> member "thinking" in
  check string "thinking type" "disabled" (thinking |> member "type" |> to_string);
  check_member_absent "chat_template_kwargs" json;
  check_member_absent "reasoning_effort" json;
  let response_format = json |> member "response_format" in
  check
    string
    "response_format type"
    "json_object"
    (response_format |> member "type" |> to_string);
  check_member_absent "json_schema" response_format
;;

let test_openai_reasoning_dialect_uses_reasoning_effort () =
  let dialect =
    RD.of_capabilities Llm_provider.Capabilities.openai_compat_chat_extended_capabilities
  in
  check
    string
    "toggle wire"
    "reasoning_effort"
    (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "no_replay"
    (RD.replay_policy_to_string dialect.replay_policy);
  check
    (option string)
    "typed preserve minimal"
    (Some "minimal")
    (RD.normalize_effort_value dialect RE.Minimal);
  check
    (option string)
    "typed preserve high"
    (Some "high")
    (RD.normalize_effort_value dialect RE.High);
  check
    (option string)
    "typed preserve xhigh"
    (Some "xhigh")
    (RD.normalize_effort_value dialect RE.XHigh);
  check
    (option string)
    "typed preserve max"
    (Some "max")
    (RD.normalize_effort_value dialect RE.Max)
;;

let test_openai_reasoning_request_uses_reasoning_effort () =
  with_manifest
    {|{"schema_version":1,"models":[{"id_prefix":"openai-reasoning-test-9fx","base":"openai_chat_extended","thinking_control_format":"reasoning_effort","accepted_reasoning_efforts":["low","medium","high"]}]}|}
    (fun () ->
       let config =
         PC.make
           ~kind:OpenAI_compat
           ~model_id:"openai-reasoning-test-9fx"
           ~base_url:"https://api.openai.com/v1"
           ~model_capabilities_override:(catalog_capabilities "openai-reasoning-test-9fx")
           ~enable_thinking:true
           ~reasoning_effort:RE.Medium
           ()
       in
       let json =
         BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body
       in
       check
         string
         "reasoning_effort"
         "medium"
         (json |> member "reasoning_effort" |> to_string);
       check_member_absent "thinking" json;
       check_member_absent "enable_thinking" json;
       check_member_absent "chat_template_kwargs" json)
;;

let test_deepseek_openai_compat_uses_thinking_object () =
  let config =
    declared_catalog_openai_compat_config
      ~base_url:"https://api.deepseek.com"
      ~provider_id:"deepseek"
      ~enable_thinking:false
      "deepseek-v4-flash"
  in
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check
    string
    "thinking type"
    "disabled"
    (json |> member "thinking" |> member "type" |> to_string);
  check_member_absent "reasoning_effort" json;
  check_member_absent "chat_template_kwargs" json;
  check_member_absent "think" json
;;

let test_minimax_m3_openai_compat_uses_adaptive_thinking_object () =
  let enabled_config =
    declared_catalog_openai_compat_config ~enable_thinking:true "minimax-m3"
  in
  let enabled_json =
    BOR.build_request ~config:enabled_config ~messages:[ user_msg "hi" ] ()
    |> json_of_body
  in
  check
    string
    "enabled thinking type"
    "adaptive"
    (enabled_json |> member "thinking" |> member "type" |> to_string);
  check
    bool
    "enabled reasoning split"
    true
    (enabled_json |> member "reasoning_split" |> to_bool);
  check_member_absent "reasoning_effort" enabled_json;
  check_member_absent "chat_template_kwargs" enabled_json;
  let default_config = declared_catalog_openai_compat_config "minimax-m3" in
  let default_json =
    BOR.build_request ~config:default_config ~messages:[ user_msg "hi" ] ()
    |> json_of_body
  in
  check
    bool
    "default reasoning split"
    true
    (default_json |> member "reasoning_split" |> to_bool);
  let disabled_config =
    declared_catalog_openai_compat_config ~enable_thinking:false "minimax-m3"
  in
  let disabled_json =
    BOR.build_request ~config:disabled_config ~messages:[ user_msg "hi" ] ()
    |> json_of_body
  in
  check
    string
    "disabled thinking type"
    "disabled"
    (disabled_json |> member "thinking" |> member "type" |> to_string);
  check_member_absent "reasoning_split" disabled_json;
  let auto_tool_choice_config =
    declared_catalog_openai_compat_config
      ~base_url:"https://api.minimaxi.com/v1"
      ~tool_choice:Auto
      "minimax-m3"
  in
  let auto_tool_choice_json =
    BOR.build_request ~config:auto_tool_choice_config ~messages:[ user_msg "hi" ] ()
    |> json_of_body
  in
  check_member_absent "tool_choice" auto_tool_choice_json;
  let dialect = RD.for_provider_config enabled_config in
  check
    string
    "toggle wire"
    "thinking_object_adaptive"
    (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "preserve_always"
    (RD.replay_policy_to_string dialect.replay_policy)
;;

let test_ollama_cloud_openai_compat_streams_reasoning_delta () =
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~provider_id:"ollama_cloud"
      ~model_id:"minimax-m3"
      ~base_url:"https://ollama.com/v1"
      ()
  in
  let caps =
    match PC.capabilities_for_config_model config with
    | Some caps -> caps
    | None -> fail "expected Ollama Cloud MiniMax-M3 catalog capabilities"
  in
  (match caps.CAP.reasoning_streaming_format with
   | CAP.Delta_reasoning_field "reasoning" -> ()
   | CAP.Delta_reasoning_field field ->
     fail (Printf.sprintf "unexpected catalog reasoning stream field: %s" field)
   | CAP.Default_reasoning_streaming ->
     fail "catalog reasoning stream override was not applied"
   | CAP.No_reasoning_streaming ->
     fail "catalog reasoning stream override disabled streaming"
   | CAP.Template_reasoning_streaming ->
     fail "catalog reasoning stream override selected template parser");
  let dialect = RD.for_provider_config config in
  (match dialect.streaming with
   | RD.Delta_field "reasoning" -> ()
   | RD.Delta_field field ->
     fail
       (Printf.sprintf
          "ollama cloud OpenAI-compatible reasoning delta field drifted: %s"
          field)
   | RD.Delta_reasoning_details ->
     fail "ollama cloud OpenAI-compatible should not use reasoning_details streaming"
   | RD.No_streaming_reasoning ->
     fail "ollama cloud OpenAI-compatible reasoning stream field was dropped"
   | RD.Template_parser ->
     fail "ollama cloud OpenAI-compatible should not use template parser streaming");
  let live_shape =
    {|{"id":"chatcmpl-ollama-minimax","object":"chat.completion.chunk","created":1782812554,"model":"minimax-m3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"9.9 is bigger."},"finish_reason":null}]}|}
  in
  let chunk =
    match S.parse_openai_sse_chunk ~streaming_reasoning:dialect.streaming live_shape with
    | S.Openai_chunk chunk -> chunk
    | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
      -> fail "expected Ollama Cloud OpenAI-compatible reasoning chunk"
  in
  check
    (option string)
    "delta.reasoning parsed"
    (Some "9.9 is bigger.")
    chunk.delta_reasoning;
  let events, _telemetry =
    S.openai_chunk_to_events
      (S.create_openai_stream_state
         ~provider:"ollama_cloud_openai"
         ~model:"minimax-m3"
         ())
      chunk
  in
  match events with
  | [ ContentBlockStart { content_type = "thinking"; _ }
    ; ContentBlockDelta { delta = ThinkingDelta "9.9 is bigger."; _ }
    ] -> ()
  | _ -> fail "expected delta.reasoning to emit thinking block events, not visible text"
;;

let test_deepseek_reasoning_dialect_semantics () =
  let config =
    declared_catalog_openai_compat_config
      ~base_url:"https://api.deepseek.com"
      ~provider_id:"deepseek"
      ~enable_thinking:true
      "deepseek-v4-pro"
  in
  let dialect = RD.for_provider_config config in
  check
    string
    "toggle wire"
    "thinking_object"
    (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "drop_without_tool_preserve_with_tool"
    (RD.replay_policy_to_string dialect.replay_policy);
  check
    bool
    "plain assistant reasoning may be dropped"
    false
    (RD.should_replay_reasoning dialect ~assistant_had_tool_call:false);
  check
    bool
    "tool-call assistant reasoning must replay"
    true
    (RD.should_replay_reasoning dialect ~assistant_had_tool_call:true);
  check
    bool
    "requires tool-call replay"
    true
    (RD.requires_reasoning_replay_on_tool_call dialect);
  check
    (option string)
    "typed high stays high"
    (Some "high")
    (RD.normalize_effort_value dialect RE.High);
  check
    (option string)
    "typed max stays max"
    (Some "max")
    (RD.normalize_effort_value dialect RE.Max);
  check
    (option string)
    "typed low is unsupported"
    None
    (RD.normalize_effort_value dialect RE.Low);
  check
    (option string)
    "typed minimal omitted"
    None
    (RD.normalize_effort_value dialect RE.Minimal);
  check
    (list string)
    "ignored sampling params"
    [ "temperature"; "top_p"; "presence_penalty"; "frequency_penalty" ]
    (sampling_parameter_names (RD.sampling_params_ignored_when_thinking dialect))
;;

let test_deepseek_sampling_suppressed_in_thinking_mode () =
  let config =
    declared_catalog_openai_compat_config
      ~base_url:"https://api.deepseek.com"
      ~provider_id:"deepseek"
      ~temperature:0.7
      ~top_p:0.9
      "deepseek-v4-flash"
  in
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check_member_absent "temperature" json;
  check_member_absent "top_p" json
;;

let test_deepseek_disabled_thinking_keeps_sampling () =
  let config =
    declared_catalog_openai_compat_config
      ~base_url:"https://api.deepseek.com"
      ~provider_id:"deepseek"
      ~enable_thinking:false
      ~temperature:0.7
      ~top_p:0.9
      "deepseek-v4-flash"
  in
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check (float 0.001) "temperature" 0.7 (json |> member "temperature" |> to_float);
  check (float 0.001) "top_p" 0.9 (json |> member "top_p" |> to_float)
;;

let assistant_with_reasoning ?(tool = false) config =
  let content =
    if tool
    then
      [ Thinking { signature = None; content = "use calculator" }
      ; ToolUse { id = "call_1"; name = "calc"; input = `Assoc [ "expr", `String "2+2" ] }
      ]
    else [ Thinking { signature = None; content = "plain thought" }; Text "answer" ]
  in
  let source =
    match RD.reasoning_source_for_provider_config config with
    | Ok source -> source
    | Error detail -> fail ("invalid reasoning source fixture: " ^ detail)
  in
  { role = Assistant
  ; content
  ; name = None
  ; tool_call_id = None
  ; metadata = Reasoning_source.metadata source
  }
;;

let test_deepseek_replays_reasoning_only_for_tool_call_turns () =
  let config =
    declared_catalog_openai_compat_config
      ~base_url:"https://api.deepseek.com"
      ~provider_id:"deepseek"
      "deepseek-v4-flash"
  in
  let plain =
    BOR.build_request ~config ~messages:[ assistant_with_reasoning config ] ()
    |> json_of_body
  in
  let tool =
    BOR.build_request ~config ~messages:[ assistant_with_reasoning ~tool:true config ] ()
    |> json_of_body
  in
  let plain_assistant = plain |> member "messages" |> index 0 in
  let tool_assistant = tool |> member "messages" |> index 0 in
  check_member_absent "reasoning_content" plain_assistant;
  check
    string
    "tool reasoning_content"
    "use calculator"
    (tool_assistant |> member "reasoning_content" |> to_string)
;;

let test_qwen_preserve_replays_reasoning_content () =
  let config =
    declared_qwen_openai_compat_config
      ~enable_thinking:true
      ~preserve_thinking:true
      "Qwen/Qwen3.6-35B-A3B"
  in
  let json =
    BOR.build_request ~config ~messages:[ assistant_with_reasoning config ] ()
    |> json_of_body
  in
  let assistant = json |> member "messages" |> index 0 in
  check
    string
    "reasoning_content"
    "plain thought"
    (assistant |> member "reasoning_content" |> to_string)
;;

let test_declared_reasoning_content_accumulates_as_typed_thinking () =
  (* The typed capability override declares the wire dialect explicitly. This
     test is only about streaming accumulation: multiple [reasoning_content]
     deltas must produce one Thinking block rather than re-opening a block per
     chunk. *)
  let config =
    declared_qwen_openai_compat_config
      ~enable_thinking:true
      ~preserve_thinking:false
      "opaque-qwen-runtime-model"
  in
  let dialect = RD.for_provider_config config in
  (match dialect.streaming with
   | RD.Delta_field "reasoning_content" -> ()
   | RD.Delta_field other ->
     fail ("catalog qwen3.6 row resolved unexpected reasoning delta field: " ^ other)
   | RD.No_streaming_reasoning | RD.Delta_reasoning_details | RD.Template_parser ->
     fail "catalog qwen3.6 row must resolve the reasoning_content streaming dialect");
  let parse raw =
    match S.parse_openai_sse_chunk ~streaming_reasoning:dialect.streaming raw with
    | S.Openai_chunk chunk -> chunk
    | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
      -> fail "expected Qwen reasoning_content SSE chunk"
  in
  let chunk1 =
    parse
      {|{"id":"qwen-live-1","model":"Qwen3.6-35B-A3B","choices":[{"index":0,"delta":{"reasoning_content":"inspect "},"finish_reason":null}]}|}
  in
  let chunk2 =
    parse
      {|{"id":"qwen-live-1","model":"Qwen3.6-35B-A3B","choices":[{"index":0,"delta":{"reasoning_content":"repository"},"finish_reason":null}]}|}
  in
  check (option string) "reasoning is not visible content" None chunk1.delta_content;
  let state = S.create_openai_stream_state () in
  let events1, _ = S.openai_chunk_to_events state chunk1 in
  let events2, _ = S.openai_chunk_to_events state chunk2 in
  match events1, events2 with
  | ( [ ContentBlockStart { index = 0; content_type = "thinking"; _ }
      ; ContentBlockDelta { index = 0; delta = ThinkingDelta "inspect " }
      ]
    , [ ContentBlockDelta { index = 0; delta = ThinkingDelta "repository" } ] ) -> ()
  | _ ->
    fail
      "expected two catalog reasoning_content deltas to accumulate into one Thinking \
       block (single ContentBlockStart at index 0)"
;;

let keep_all_axis_manifest =
  {|{"schema_version":1,"models":[{"id_prefix":"keep-all-axis-test","base":"openai_chat","supports_reasoning":true,"supports_extended_thinking":true,"thinking_control_format":"thinking_object_only","preserve_thinking_control_format":"thinking_object_keep_all"}]}|}
;;

let test_thinking_object_keep_all_axis_uses_keep_all () =
  with_manifest keep_all_axis_manifest (fun () ->
    let config =
      declared_catalog_openai_compat_config ~preserve_thinking:true "keep-all-axis-test"
    in
    let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
    let thinking = json |> member "thinking" in
    check string "thinking type" "enabled" (thinking |> member "type" |> to_string);
    check string "thinking keep" "all" (thinking |> member "keep" |> to_string);
    check_member_absent "chat_template_kwargs" json;
    check_member_absent "preserve_thinking" json)
;;

let test_thinking_object_keep_all_axis_replays_reasoning () =
  with_manifest keep_all_axis_manifest (fun () ->
    let config =
      declared_catalog_openai_compat_config ~preserve_thinking:true "keep-all-axis-test"
    in
    let dialect = RD.for_provider_config config in
    check
      string
      "toggle wire"
      "thinking_object_only"
      (RD.toggle_wire_to_string dialect.toggle_wire);
    check
      string
      "replay policy"
      "preserve_always"
      (RD.replay_policy_to_string dialect.replay_policy);
    check
      bool
      "no tool-call replay requirement"
      false
      (RD.requires_reasoning_replay_on_tool_call dialect);
    let json =
      BOR.build_request ~config ~messages:[ assistant_with_reasoning config ] ()
      |> json_of_body
    in
    let assistant = json |> member "messages" |> index 0 in
    check
      string
      "reasoning_content"
      "plain thought"
      (assistant |> member "reasoning_content" |> to_string))
;;

let test_thinking_object_keep_all_axis_defaults_to_tool_replay () =
  with_manifest keep_all_axis_manifest (fun () ->
    let config = declared_catalog_openai_compat_config "keep-all-axis-test" in
    let dialect = RD.for_provider_config config in
    check
      string
      "replay policy"
      "drop_without_tool_preserve_with_tool"
      (RD.replay_policy_to_string dialect.replay_policy);
    check
      bool
      "requires tool-call replay"
      true
      (RD.requires_reasoning_replay_on_tool_call dialect);
    let plain =
      BOR.build_request ~config ~messages:[ assistant_with_reasoning config ] ()
      |> json_of_body
    in
    let tool =
      BOR.build_request
        ~config
        ~messages:[ assistant_with_reasoning ~tool:true config ]
        ()
      |> json_of_body
    in
    let plain_assistant = plain |> member "messages" |> index 0 in
    let tool_assistant = tool |> member "messages" |> index 0 in
    check_member_absent "reasoning_content" plain_assistant;
    check
      string
      "tool reasoning_content"
      "use calculator"
      (tool_assistant |> member "reasoning_content" |> to_string))
;;

let test_kimi_k26_defaults_to_tool_call_replay () =
  let config = kimi_config "kimi-k2.6" in
  let dialect = RD.for_provider_config config in
  check
    string
    "toggle wire"
    "thinking_object_only"
    (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "drop_without_tool_preserve_with_tool"
    (RD.replay_policy_to_string dialect.replay_policy);
  check
    bool
    "requires tool-call replay"
    true
    (RD.requires_reasoning_replay_on_tool_call dialect);
  check
    (list string)
    "ignored sampling params"
    [ "temperature"; "top_p" ]
    (sampling_parameter_names (RD.sampling_params_ignored_when_thinking dialect));
  let user_json =
    BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body
  in
  check_member_absent "thinking" user_json;
  let plain =
    BOR.build_request ~config ~messages:[ assistant_with_reasoning config ] ()
    |> json_of_body
  in
  let tool =
    BOR.build_request ~config ~messages:[ assistant_with_reasoning ~tool:true config ] ()
    |> json_of_body
  in
  check_member_absent "reasoning_content" (plain |> member "messages" |> index 0);
  check
    string
    "tool reasoning_content"
    "use calculator"
    (tool |> member "messages" |> index 0 |> member "reasoning_content" |> to_string)
;;

let test_kimi_k26_omits_fixed_sampling_with_disabled_thinking () =
  let config =
    kimi_config ~enable_thinking:false ~temperature:0.7 ~top_p:0.9 "kimi-k2.6"
  in
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check_member_absent "temperature" json;
  check_member_absent "top_p" json
;;

let test_kimi_k26_preserve_requests_keep_all () =
  let config = kimi_config ~preserve_thinking:true "kimi-k2.6" in
  let dialect = RD.for_provider_config config in
  check
    string
    "replay policy"
    "preserve_always"
    (RD.replay_policy_to_string dialect.replay_policy);
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  let thinking = json |> member "thinking" in
  check string "thinking type" "enabled" (thinking |> member "type" |> to_string);
  check string "thinking keep" "all" (thinking |> member "keep" |> to_string);
  check_member_absent "chat_template_kwargs" json
;;

let test_kimi_k25_does_not_emit_keep_all () =
  let config = kimi_config ~enable_thinking:true ~preserve_thinking:true "kimi-k2.5" in
  let dialect = RD.for_provider_config config in
  check
    string
    "replay policy"
    "no_replay"
    (RD.replay_policy_to_string dialect.replay_policy);
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  let thinking = json |> member "thinking" in
  check string "thinking type" "enabled" (thinking |> member "type" |> to_string);
  check_member_absent "keep" thinking
;;

let test_kimi_latest_always_preserved_omits_thinking_param () =
  let config = kimi_config "kimi-k2.7-code" in
  let dialect = RD.for_provider_config config in
  check string "toggle wire" "no_toggle" (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "preserve_always"
    (RD.replay_policy_to_string dialect.replay_policy);
  check
    (list string)
    "ignored sampling params"
    [ "temperature"; "top_p" ]
    (sampling_parameter_names (RD.sampling_params_ignored_when_thinking dialect));
  let user_json =
    BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body
  in
  check_member_absent "thinking" user_json;
  check_member_absent "chat_template_kwargs" user_json;
  check_member_absent "preserve_thinking" user_json;
  let reasoning_json =
    BOR.build_request ~config ~messages:[ assistant_with_reasoning config ] ()
    |> json_of_body
  in
  let assistant = reasoning_json |> member "messages" |> index 0 in
  check
    string
    "reasoning_content"
    "plain thought"
    (assistant |> member "reasoning_content" |> to_string)
;;

let test_kimi_latest_highspeed_uses_k27_semantics () =
  let config = kimi_config "kimi-k2.7-code-highspeed" in
  let dialect = RD.for_provider_config config in
  check string "toggle wire" "no_toggle" (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "preserve_always"
    (RD.replay_policy_to_string dialect.replay_policy);
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check_member_absent "thinking" json;
  check_member_absent "chat_template_kwargs" json
;;

let test_kimi_latest_omits_sampling_even_with_disabled_thinking_override () =
  let config =
    kimi_config ~enable_thinking:false ~temperature:0.7 ~top_p:0.9 "kimi-k2.7-code"
  in
  let json = BOR.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check_member_absent "thinking" json;
  check_member_absent "temperature" json;
  check_member_absent "top_p" json
;;

let test_ollama_qwen_uses_native_think_bool () =
  let config = ollama_config ~enable_thinking:true "qwen3:32b" in
  let json = BOL.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check bool "think true" true (json |> member "think" |> to_bool);
  check_member_absent "chat_template_kwargs" json;
  check_member_absent "thinking" json;
  check_member_absent "reasoning_effort" json
;;

let test_ollama_cloud_glm_uses_native_think_not_zai_thinking () =
  let config = ollama_cloud_config ~enable_thinking:true "glm-5.2" in
  let json = BOL.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check string "model" "glm-5.2" (json |> member "model" |> to_string);
  check bool "think true" true (json |> member "think" |> to_bool);
  check_member_absent "thinking" json;
  check_member_absent "reasoning_content" json;
  check_member_absent "reasoning_effort" json;
  check_member_absent "tool_stream" json;
  let dialect = RD.for_provider_config config in
  check string "toggle wire" "ollama_think" (RD.toggle_wire_to_string dialect.toggle_wire)
;;

let test_ollama_gemma4_enabled_uses_chat_template_token () =
  let config =
    ollama_config
      ~system_prompt:"You are a helpful assistant."
      ~enable_thinking:true
      "hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL"
  in
  let json =
    BOL.build_request ~config ~messages:[ user_msg "solve 19*21" ] () |> json_of_body
  in
  check_member_absent "think" json;
  let first_message = json |> member "messages" |> index 0 in
  check string "system role" "system" (first_message |> member "role" |> to_string);
  check
    bool
    "system prompt starts with think token"
    true
    (String.starts_with
       ~prefix:"<|think|>\n"
       (first_message |> member "content" |> to_string))
;;

let test_ollama_chat_template_token_uses_catalog_token () =
  with_catalog_toml
    {|
[[models]]
id_prefix = "local-token-model"
base = "ollama"
supports_reasoning = true
supports_extended_thinking = true
thinking_control_format = "chat_template_token"
thinking_control_token = "<|custom_think|>"
|}
    (fun () ->
       let config =
         ollama_config
           ~system_prompt:"Keep replies short."
           ~enable_thinking:true
           "local-token-model:latest"
       in
       let json =
         BOL.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body
       in
       check_member_absent "think" json;
       let first_message = json |> member "messages" |> index 0 in
       check
         bool
         "system prompt starts with catalog token"
         true
         (String.starts_with
            ~prefix:"<|custom_think|>\n"
            (first_message |> member "content" |> to_string)))
;;

let test_ollama_chat_template_token_missing_token_fails_closed () =
  (* The token is part of the [Chat_template_token] constructor, so a
     chat_template_token row with no thinking_control_token now fails closed at
     catalog LOAD naming the offending id_prefix — not per request. *)
  let path = Filename.temp_file "oas-tokenless-template" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       output_string
         oc
         {|
[[models]]
id_prefix = "tokenless-template-model"
base = "ollama"
supports_reasoning = true
supports_extended_thinking = true
thinking_control_format = "chat_template_token"
|};
       close_out oc;
       match MC.load_file path with
       | Error msg ->
         check
           bool
           "names the offending id_prefix"
           true
           (string_contains_sub msg "tokenless-template-model");
         check
           bool
           "mentions the required token"
           true
           (string_contains_sub msg "thinking_control_token")
       | Ok _ -> fail "tokenless chat_template_token row should fail closed at load")
;;

let test_ollama_gemma4_disabled_uses_native_think_false () =
  let config =
    ollama_config
      ~system_prompt:"You are a helpful assistant."
      ~enable_thinking:false
      "hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL"
  in
  let json = BOL.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  check bool "think false" false (json |> member "think" |> to_bool);
  let first_message = json |> member "messages" |> index 0 in
  check
    string
    "system prompt unchanged"
    "You are a helpful assistant."
    (first_message |> member "content" |> to_string)
;;

let test_gemma4_reasoning_dialect_uses_template_parser () =
  let config =
    ollama_config
      ~enable_thinking:true
      "hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL"
  in
  let dialect = RD.for_provider_config config in
  check
    string
    "toggle wire"
    "chat_template_token"
    (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "latest_user_turn_tool_calls"
    (RD.replay_policy_to_string dialect.replay_policy);
  check
    bool
    "native tool-call thinking replay required"
    true
    (RD.requires_reasoning_replay_on_tool_call dialect);
  check
    (list string)
    "no ignored sampling params"
    []
    (sampling_parameter_names (RD.sampling_params_ignored_when_thinking dialect))
;;

let test_anthropic_reasoning_dialect_preserves_thinking () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-4-6"
      ~base_url:"https://api.anthropic.com"
      ()
  in
  let dialect = RD.for_provider_config config in
  check
    string
    "toggle wire"
    "anthropic_thinking"
    (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "preserve_always"
    (RD.replay_policy_to_string dialect.replay_policy);
  check
    (option string)
    "xhigh effort stays exact"
    (Some "xhigh")
    (RD.normalize_effort_value dialect RE.XHigh);
  check
    (option string)
    "max effort stays exact"
    (Some "max")
    (RD.normalize_effort_value dialect RE.Max)
;;

let test_anthropic_manual_model_uses_budget_tokens () =
  let config =
    anthropic_config ~enable_thinking:true ~thinking_budget:4096 "claude-opus-4-5"
  in
  let json = BAN.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  let thinking = json |> member "thinking" in
  check string "thinking type" "enabled" (thinking |> member "type" |> to_string);
  check int "budget tokens" 4096 (thinking |> member "budget_tokens" |> to_int);
  check_member_absent "output_config" json
;;

let test_anthropic_opus48_uses_adaptive_effort () =
  let config =
    anthropic_config ~enable_thinking:true ~reasoning_effort:RE.Medium "claude-opus-4-8"
  in
  let json = BAN.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  let thinking = json |> member "thinking" in
  check string "thinking type" "adaptive" (thinking |> member "type" |> to_string);
  check_member_absent "budget_tokens" thinking;
  check
    string
    "effort"
    "medium"
    (json |> member "output_config" |> member "effort" |> to_string)
;;

let test_anthropic_agent_llm_alias_uses_adaptive_effort () =
  let config =
    anthropic_config
      ~enable_thinking:true
      ~reasoning_effort:RE.Medium
      "claude-sonnet-4-6-20250514"
  in
  let json = BAN.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  let thinking = json |> member "thinking" in
  check string "thinking type" "adaptive" (thinking |> member "type" |> to_string);
  check_member_absent "budget_tokens" thinking;
  check
    string
    "effort"
    "medium"
    (json |> member "output_config" |> member "effort" |> to_string)
;;

let test_anthropic_sonnet46_defaults_to_adaptive () =
  let config = anthropic_config ~enable_thinking:true "claude-sonnet-4-6" in
  let json = BAN.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  let thinking = json |> member "thinking" in
  check string "thinking type" "adaptive" (thinking |> member "type" |> to_string);
  check_member_absent "budget_tokens" thinking;
  check_member_absent "output_config" json
;;

let test_anthropic_output_config_merges_format_and_effort () =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "string" ] ]
      ]
  in
  let config =
    anthropic_config
      ~enable_thinking:true
      ~reasoning_effort:RE.Max
      ~response_format:(JsonSchema schema)
      "claude-opus-4-8"
  in
  let json = BAN.build_request ~config ~messages:[ user_msg "hi" ] () |> json_of_body in
  let output_config = json |> member "output_config" in
  check string "effort" "max" (output_config |> member "effort" |> to_string);
  check
    string
    "format type"
    "json_schema"
    (output_config |> member "format" |> member "type" |> to_string)
;;

let test_gemini_reasoning_dialect_uses_thinking_config () =
  let config =
    PC.make
      ~kind:Gemini
      ~model_id:"gemini-2.5-flash"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ()
  in
  let dialect = RD.for_provider_config config in
  check
    string
    "toggle wire"
    "gemini_thinking_config"
    (RD.toggle_wire_to_string dialect.toggle_wire);
  check
    string
    "replay policy"
    "preserve_always"
    (RD.replay_policy_to_string dialect.replay_policy)
;;

let () =
  without_ambient_manifest (fun () ->
    run
      "thinking_control_dialects"
      [ ( "openai_compat"
        , [ test_case
              "raw qwen does not infer chat_template_kwargs"
              `Quick
              test_raw_qwen_openai_compat_does_not_infer_chat_template_kwargs
          ; test_case
              "declared qwen3.6 endpoint uses chat_template_kwargs"
              `Quick
              test_declared_qwen36_openai_compat_uses_chat_template_kwargs
          ; test_case
              "raw qwen3.6 dialect does not infer chat_template_kwargs"
              `Quick
              test_raw_qwen36_reasoning_dialect_does_not_infer_chat_template_kwargs
          ; test_case
              "declared qwen3.6 dialect uses chat_template_kwargs"
              `Quick
              test_declared_qwen36_reasoning_dialect_uses_chat_template_kwargs
          ; test_case
              "declared qwen3.6 dialect keeps tool reasoning"
              `Quick
              test_qwen36_reasoning_dialect_without_preserve_keeps_tool_reasoning
          ; test_case
              "qwen3.6 dashscope uses top-level enable_thinking"
              `Quick
              test_qwen36_dashscope_uses_top_level_enable_thinking
          ; test_case
              "qwen3.6 dashscope dialect reports enable_thinking"
              `Quick
              test_qwen36_dashscope_dialect_reports_enable_thinking
          ; test_case
              "mimo v2.5 uses thinking object and json mode"
              `Quick
              test_mimo_v25_uses_thinking_object_and_json_mode
          ; test_case
              "openai reasoning dialect uses reasoning_effort"
              `Quick
              test_openai_reasoning_dialect_uses_reasoning_effort
          ; test_case
              "openai reasoning request uses reasoning_effort"
              `Quick
              test_openai_reasoning_request_uses_reasoning_effort
          ; test_case
              "deepseek uses thinking object"
              `Quick
              test_deepseek_openai_compat_uses_thinking_object
          ; test_case
              "minimax m3 uses adaptive thinking object"
              `Quick
              test_minimax_m3_openai_compat_uses_adaptive_thinking_object
          ; test_case
              "ollama cloud openai-compat streams reasoning delta"
              `Quick
              test_ollama_cloud_openai_compat_streams_reasoning_delta
          ; test_case
              "deepseek reasoning dialect semantics"
              `Quick
              test_deepseek_reasoning_dialect_semantics
          ; test_case
              "deepseek suppresses ignored sampling in thinking mode"
              `Quick
              test_deepseek_sampling_suppressed_in_thinking_mode
          ; test_case
              "deepseek disabled thinking keeps sampling"
              `Quick
              test_deepseek_disabled_thinking_keeps_sampling
          ; test_case
              "deepseek replays reasoning only for tool call turns"
              `Quick
              test_deepseek_replays_reasoning_only_for_tool_call_turns
          ; test_case
              "qwen preserve replays reasoning_content"
              `Quick
              test_qwen_preserve_replays_reasoning_content
          ; test_case
              "declared reasoning_content accumulates as typed thinking"
              `Quick
              test_declared_reasoning_content_accumulates_as_typed_thinking
          ; test_case
              "thinking_object_keep_all axis uses thinking keep all"
              `Quick
              test_thinking_object_keep_all_axis_uses_keep_all
          ; test_case
              "thinking_object_keep_all axis replays reasoning"
              `Quick
              test_thinking_object_keep_all_axis_replays_reasoning
          ; test_case
              "thinking_object_keep_all axis defaults to tool-call replay"
              `Quick
              test_thinking_object_keep_all_axis_defaults_to_tool_replay
          ; test_case
              "kimi k2.6 defaults to tool-call replay"
              `Quick
              test_kimi_k26_defaults_to_tool_call_replay
          ; test_case
              "kimi k2.6 omits fixed sampling with disabled thinking"
              `Quick
              test_kimi_k26_omits_fixed_sampling_with_disabled_thinking
          ; test_case
              "kimi k2.6 preserve requests keep all"
              `Quick
              test_kimi_k26_preserve_requests_keep_all
          ; test_case
              "kimi k2.5 does not emit keep all"
              `Quick
              test_kimi_k25_does_not_emit_keep_all
          ; test_case
              "kimi latest always-preserved omits thinking param"
              `Quick
              test_kimi_latest_always_preserved_omits_thinking_param
          ; test_case
              "kimi latest highspeed uses k2.7 semantics"
              `Quick
              test_kimi_latest_highspeed_uses_k27_semantics
          ; test_case
              "kimi latest omits fixed sampling params"
              `Quick
              test_kimi_latest_omits_sampling_even_with_disabled_thinking_override
          ] )
      ; ( "ollama"
        , [ test_case
              "qwen uses native think bool"
              `Quick
              test_ollama_qwen_uses_native_think_bool
          ; test_case
              "cloud GLM uses native think not ZAI thinking"
              `Quick
              test_ollama_cloud_glm_uses_native_think_not_zai_thinking
          ; test_case
              "gemma4 enabled uses chat template token"
              `Quick
              test_ollama_gemma4_enabled_uses_chat_template_token
          ; test_case
              "chat_template_token uses catalog token"
              `Quick
              test_ollama_chat_template_token_uses_catalog_token
          ; test_case
              "chat_template_token without token fails closed"
              `Quick
              test_ollama_chat_template_token_missing_token_fails_closed
          ; test_case
              "gemma4 disabled uses native think false"
              `Quick
              test_ollama_gemma4_disabled_uses_native_think_false
          ; test_case
              "gemma4 reasoning dialect uses template parser"
              `Quick
              test_gemma4_reasoning_dialect_uses_template_parser
          ] )
      ; ( "native"
        , [ test_case
              "anthropic reasoning dialect preserves thinking"
              `Quick
              test_anthropic_reasoning_dialect_preserves_thinking
          ; test_case
              "anthropic manual model uses budget_tokens"
              `Quick
              test_anthropic_manual_model_uses_budget_tokens
          ; test_case
              "anthropic opus 4.8 uses adaptive effort"
              `Quick
              test_anthropic_opus48_uses_adaptive_effort
          ; test_case
              "anthropic claude alias uses adaptive effort"
              `Quick
              test_anthropic_agent_llm_alias_uses_adaptive_effort
          ; test_case
              "anthropic sonnet 4.6 defaults to adaptive"
              `Quick
              test_anthropic_sonnet46_defaults_to_adaptive
          ; test_case
              "anthropic output_config merges format and effort"
              `Quick
              test_anthropic_output_config_merges_format_and_effort
          ; test_case
              "gemini reasoning dialect uses thinking config"
              `Quick
              test_gemini_reasoning_dialect_uses_thinking_config
          ] )
      ])
;;
