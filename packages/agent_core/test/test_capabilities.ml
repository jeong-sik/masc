(** Tests for expanded capabilities — model lookup, limits, feature flags. *)

open Alcotest
open Llm_provider

let string_contains_sub s sub =
  let s_len = String.length s in
  let sub_len = String.length sub in
  let rec loop i =
    if sub_len = 0
    then true
    else if i + sub_len > s_len
    then false
    else if String.sub s i sub_len = sub
    then true
    else loop (i + 1)
  in
  loop 0
;;

let check_contains label s sub =
  if not (string_contains_sub s sub)
  then Alcotest.failf "%s: expected %S to contain %S" label s sub
;;

let check_thinking_control label expected actual =
  check bool label true (actual = expected)
;;

let accepted_reasoning_effort_strings caps =
  Option.map
    (List.map Reasoning_effort.to_string)
    caps.Capabilities.accepted_reasoning_efforts
;;

let with_temp_manifest contents f =
  let path = Filename.temp_file "oas-capability-manifest" ".json" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents);
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () -> f path)
;;

let with_temp_model_catalog contents f =
  let path = Filename.temp_file "oas-model-catalog" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents);
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () -> f path)
;;

let isolate_ambient_runtime_sources () =
  Capability_manifest.set_global [];
  Model_catalog_test_support.install_embedded_model_catalog ~suite:"Capabilities"
;;

(* ── Default capabilities ────────────────────────────── *)

let test_default_no_limits () =
  let c = Capabilities.default_capabilities in
  check bool "no context limit" true (c.max_context_tokens = None);
  check bool "no output limit" true (c.max_output_tokens = None);
  check bool "no tools" false c.supports_tools;
  check bool "system prompt default true" true c.supports_system_prompt
;;

let test_default_new_fields_false () =
  let c = Capabilities.default_capabilities in
  check bool "no parallel tools" false c.supports_parallel_tool_calls;
  check bool "no extended thinking" false c.supports_extended_thinking;
  check bool "no structured output" false c.supports_structured_output;
  check bool "no image input" false c.supports_image_input;
  check bool "no audio input" false c.supports_audio_input;
  check bool "no video input" false c.supports_video_input;
  check bool "no caching" false c.supports_caching;
  check bool "no computer use" false c.supports_computer_use;
  check bool "no code execution" false c.supports_code_execution
;;

(* ── Preset capabilities ─────────────────────────────── *)

let test_anthropic_capabilities () =
  let c = Capabilities.anthropic_capabilities in
  check bool "has tools" true c.supports_tools;
  check bool "has parallel tools" true c.supports_parallel_tool_calls;
  check bool "has extended thinking" true c.supports_extended_thinking;
  check bool "has reasoning budget" true c.supports_reasoning_budget;
  check bool "has image" true c.supports_image_input;
  check bool "has caching" true c.supports_caching;
  check bool "has computer use" true c.supports_computer_use;
  check bool "has structured output" true c.supports_structured_output;
  check bool "no audio" false c.supports_audio_input;
  (* Anthropic Messages API accepts top_k per its documented body
     params; pin the field so the #830/#831 capability-gated
     serializer paths do not silently drop it for claude configs. *)
  check bool "supports top_k" true c.supports_top_k;
  check bool "no min_p" false c.supports_min_p;
  check bool "context 200K" true (c.max_context_tokens = Some 200_000)
;;

let test_openai_capabilities () =
  let c = Capabilities.openai_compat_chat_capabilities in
  check bool "has structured output" true c.supports_structured_output;
  check bool "has parallel tools" true c.supports_parallel_tool_calls;
  check bool "no reasoning" false c.supports_reasoning;
  check bool "context 128K" true (c.max_context_tokens = Some 128_000)
;;

let test_openai_extended () =
  let c = Capabilities.openai_compat_chat_extended_capabilities in
  check bool "has reasoning" true c.supports_reasoning;
  check_thinking_control
    "uses reasoning_effort"
    Capabilities.Reasoning_effort
    c.thinking_control_format;
  check bool "has top_k" true c.supports_top_k;
  check bool "has min_p" true c.supports_min_p
;;

let test_lookup_mimo_v25_pro () =
  match
    Capabilities.for_provider_model_id
      ~allow_bare_fallback:false
      ~provider_label:"mimo"
      ~model_id:"mimo-v2.5-pro"
  with
  | Some c ->
    check (option int) "context 1M" (Some 1_000_000) c.max_context_tokens;
    check (option int) "output 128K" (Some 128_000) c.max_output_tokens;
    check bool "has reasoning" true c.supports_reasoning;
    check bool "has extended thinking" true c.supports_extended_thinking;
    check_thinking_control
      "uses thinking object only"
      Capabilities.Thinking_object_only
      c.thinking_control_format;
    check bool "has tools" true c.supports_tools;
    check bool "has tool_choice" true c.supports_tool_choice;
    check bool "has response_format json" true c.supports_response_format_json;
    check bool "no native structured output" false c.supports_structured_output;
    check bool "pro row is text-only" false c.supports_multimodal_inputs;
    check bool "pro row has no image input" false c.supports_image_input;
    check bool "pro row has no audio input" false c.supports_audio_input;
    check bool "pro row has no video input" false c.supports_video_input;
    check
      bool
      "uses split reasoning fields"
      true
      (c.reasoning_output_format = Capabilities.Split_reasoning_fields);
    check
      bool
      "streams reasoning_content deltas"
      true
      (c.reasoning_streaming_format
       = Capabilities.Delta_reasoning_field "reasoning_content");
    check
      bool
      "preserves reasoning on tool turns only"
      true
      (c.reasoning_replay_override
       = Capabilities.Force_drop_without_tool_preserve_with_tool);
    check bool "has native streaming" true c.supports_native_streaming
  | None -> fail "should match mimo-v2.5-pro"
;;

let test_lookup_mimo_v25_multimodal () =
  match
    Capabilities.for_provider_model_id
      ~allow_bare_fallback:false
      ~provider_label:"mimo"
      ~model_id:"mimo-v2.5"
  with
  | Some c ->
    check (option int) "context 1M" (Some 1_000_000) c.max_context_tokens;
    check (option int) "output 128K" (Some 128_000) c.max_output_tokens;
    check bool "has reasoning" true c.supports_reasoning;
    check bool "has response_format json" true c.supports_response_format_json;
    check bool "no native structured output" false c.supports_structured_output;
    check bool "multimodal" true c.supports_multimodal_inputs;
    check bool "image input" true c.supports_image_input;
    check bool "audio input" true c.supports_audio_input;
    check bool "video input" true c.supports_video_input
  | None -> fail "should match mimo-v2.5"
;;

(* ── Model lookup ────────────────────────────────────── *)

let test_lookup_claude_opus () =
  match Capabilities.for_model_id "claude-opus-4-6" with
  | Some c ->
    check (option int) "context 1M" (Some 1_000_000) c.max_context_tokens;
    check (option int) "output 128K" (Some 128_000) c.max_output_tokens;
    check bool "computer use" true c.supports_computer_use
  | None -> fail "should match claude-opus"
;;

let test_lookup_claude_sonnet () =
  match Capabilities.for_model_id "claude-sonnet-4-6" with
  | Some c ->
    check (option int) "output 64K" (Some 64_000) c.max_output_tokens;
    check bool "parallel tools" true c.supports_parallel_tool_calls
  | None -> fail "should match claude-sonnet"
;;

let test_lookup_gpt5 () =
  match Capabilities.for_model_id "gpt-5.4" with
  | Some c ->
    check (option int) "context 1.05M" (Some 1_050_000) c.max_context_tokens;
    check (option int) "output 128K" (Some 128_000) c.max_output_tokens;
    check bool "structured output" true c.supports_structured_output;
    check bool "computer use" true c.supports_computer_use;
    check
      (option (list string))
      "gpt-5.4 accepted reasoning efforts"
      (Some [ "none"; "minimal"; "low"; "medium"; "high"; "xhigh" ])
      (accepted_reasoning_effort_strings c);
    (match Capabilities.for_model_id "gpt-5" with
     | Some gpt5 ->
       check
         (option (list string))
         "gpt-5 accepted reasoning efforts"
         (Some [ "minimal"; "low"; "medium"; "high" ])
         (accepted_reasoning_effort_strings gpt5)
     | None -> fail "should match bare gpt-5")
  | None -> fail "should match gpt-5"
;;

let test_lookup_gemini () =
  match Capabilities.for_model_id "gemini-3.1-pro" with
  | Some c ->
    check bool "audio" true c.supports_audio_input;
    check bool "video" true c.supports_video_input;
    check bool "code execution" false c.supports_code_execution;
    check bool "structured output" true c.supports_structured_output
  | None -> fail "should match gemini"
;;

let test_gemini_catalog_drives_capabilities () =
  (* Behavioural cross-check: all three live variants resolve to
     their declared catalog capability rows (1M context). *)
  let ctx id =
    match Capabilities.for_model_id id with
    | Some c -> c.max_context_tokens
    | None -> None
  in
  check
    (option int)
    "gemini-3-flash-preview ctx"
    (Some 1_000_000)
    (ctx "gemini-3-flash-preview");
  check
    (option int)
    "gemini-3.1-pro-preview ctx"
    (Some 1_000_000)
    (ctx "gemini-3.1-pro-preview");
  check (option int) "gemini-2.5-flash ctx" (Some 1_000_000) (ctx "gemini-2.5-flash")
;;

let test_lookup_kimi_k2_native_cloud_suffix () =
  let check_visual_first label caps =
    match caps.Capabilities.modality_priority with
    | Modality.Visual_first -> ()
    | Modality.Preserve_input_order -> fail (label ^ " should be visual_first")
  in
  let check_preserve_order label caps =
    match caps.Capabilities.modality_priority with
    | Modality.Preserve_input_order -> ()
    | Modality.Visual_first -> fail (label ^ " should preserve input order")
  in
  match Capabilities.for_model_id "kimi-k2.7-code" with
  | Some native ->
    (* Kimi built-in semantics track the latest K2 code model. Older K2
       variants can still be expressed by external catalog entries through the
       separate preserve_thinking_control_format axis. *)
    check (option int) "native Kimi context 256K" (Some 256_000) native.max_context_tokens;
    check (option int) "native Kimi output 32K" (Some 32_768) native.max_output_tokens;
    check bool "native Kimi tools" true native.supports_tools;
    check
      bool
      "native Kimi supports auto/none tool_choice"
      true
      native.supports_tool_choice;
    check
      bool
      "native Kimi rejects required tool_choice"
      false
      native.supports_required_tool_choice;
    check
      bool
      "native Kimi rejects named tool_choice"
      false
      native.supports_named_tool_choice;
    check bool "native Kimi reasoning" true native.supports_reasoning;
    check
      bool
      "native Kimi does not claim strict structured output"
      false
      native.supports_structured_output;
    check_thinking_control
      "native latest Kimi has no thinking request toggle"
      Capabilities.No_thinking_control
      native.thinking_control_format;
    check
      bool
      "native latest Kimi always preserves reasoning"
      true
      (native.preserve_thinking_control_format = Capabilities.Always_preserved_thinking);
    let native_kimi_dialect = Reasoning_dialect.of_capabilities native in
    (match native_kimi_dialect.streaming with
     | Reasoning_dialect.Delta_field "reasoning_content" -> ()
     | Reasoning_dialect.Delta_field field ->
       fail ("native latest Kimi reasoning delta field drifted: " ^ field)
     | Reasoning_dialect.Delta_reasoning_details ->
       fail "native latest Kimi should not use split reasoning_details streaming"
     | Reasoning_dialect.No_streaming_reasoning ->
       fail "native latest Kimi reasoning stream field was dropped"
     | Reasoning_dialect.Template_parser ->
       fail "native latest Kimi should not use template parser streaming");
    check_preserve_order "native Kimi latest" native;
    check bool "native Kimi code execution" true native.supports_code_execution;
    (match Capabilities.for_model_id "kimi-k2" with
     | Some bare_native ->
       check
         (option int)
         "bare native Kimi context 256K"
         (Some 256_000)
         bare_native.max_context_tokens;
       check
         (option int)
         "bare native Kimi output 32K"
         (Some 32_768)
         bare_native.max_output_tokens;
       check bool "bare native Kimi tools" true bare_native.supports_tools;
       check
         bool
         "bare native Kimi supports auto/none tool_choice"
         true
         bare_native.supports_tool_choice;
       check
         bool
         "bare native Kimi rejects required tool_choice"
         false
         bare_native.supports_required_tool_choice;
       check
         bool
         "bare native Kimi rejects named tool_choice"
         false
         bare_native.supports_named_tool_choice;
       check bool "bare native Kimi reasoning" true bare_native.supports_reasoning;
       check
         bool
         "bare native Kimi does not claim strict structured output"
         false
         bare_native.supports_structured_output;
       check_thinking_control
         "bare native latest Kimi has no thinking request toggle"
         Capabilities.No_thinking_control
         bare_native.thinking_control_format;
       check
         bool
         "bare native latest Kimi always preserves reasoning"
         true
         (bare_native.preserve_thinking_control_format
          = Capabilities.Always_preserved_thinking);
       check_preserve_order "bare native Kimi" bare_native;
       check
         bool
         "bare native Kimi code execution"
         true
         bare_native.supports_code_execution
     | None -> fail "should match native bare Kimi route");
    (match Capabilities.for_model_id "kimi-k2.6" with
     | Some k26 ->
       check_thinking_control
         "Kimi K2.6 has thinking object control"
         Capabilities.Thinking_object_only
         k26.thinking_control_format;
       check
         bool
         "Kimi K2.6 supports thinking.keep all"
         true
         (k26.preserve_thinking_control_format = Capabilities.Thinking_object_keep_all);
       let dialect = Reasoning_dialect.of_capabilities k26 in
       check
         string
         "Kimi K2.6 replays only tool-call reasoning by default"
         "drop_without_tool_preserve_with_tool"
         (Reasoning_dialect.replay_policy_to_string dialect.replay_policy)
     | None -> fail "should match Kimi K2.6 native route");
    (match Capabilities.for_model_id "kimi-k2.5" with
     | Some k25 ->
       check_thinking_control
         "Kimi K2.5 has thinking object control"
         Capabilities.Thinking_object_only
         k25.thinking_control_format;
       check
         bool
         "Kimi K2.5 does not expose preserved thinking"
         true
         (k25.preserve_thinking_control_format = Capabilities.No_preserve_thinking_control);
       let dialect = Reasoning_dialect.of_capabilities k25 in
       check
         string
         "Kimi K2.5 does not replay historical reasoning"
         "no_replay"
         (Reasoning_dialect.replay_policy_to_string dialect.replay_policy)
     | None -> fail "should match Kimi K2.5 native route");
    (match Capabilities.for_model_id "kimi-k2.7-code-highspeed" with
     | Some highspeed ->
       check_thinking_control
         "Kimi K2.7 highspeed inherits latest no-toggle behavior"
         Capabilities.No_thinking_control
         highspeed.thinking_control_format;
       check
         bool
         "Kimi K2.7 highspeed always preserves reasoning"
         true
         (highspeed.preserve_thinking_control_format
          = Capabilities.Always_preserved_thinking);
       check
         (list string)
         "Kimi K2.7 highspeed ignores fixed sampling"
         [ "temperature"; "top_p" ]
         (List.map
            Capabilities.sampling_parameter_to_string
            highspeed.ignored_sampling_parameters)
     | None -> fail "should match Kimi K2.7 highspeed route");
    (match
       Capabilities.for_provider_model_id
         ~allow_bare_fallback:false
         ~provider_label:"ollama_cloud"
         ~model_id:"kimi-k2.7-code"
     with
     | Some cloud ->
       check
         (option int)
         "provider-qualified Ollama Cloud Kimi context"
         (Some 262_144)
         cloud.max_context_tokens;
       check_thinking_control
         "provider-qualified Ollama Cloud Kimi uses native think"
         Capabilities.Ollama_think
         cloud.thinking_control_format;
       check_visual_first "provider-qualified Ollama Cloud Kimi" cloud
     | None -> fail "should match provider-qualified Ollama Cloud Kimi route")
  | None -> fail "should match kimi-k2 cloud route"
;;

let test_lookup_provider_m () =
  match Capabilities.for_model_id "dashscope-3.5-35b-a3b" with
  | Some c ->
    check (option int) "context 262K" (Some 262_144) c.max_context_tokens;
    check bool "tools" true c.supports_tools;
    check bool "thinking" true c.supports_extended_thinking;
    check bool "reasoning budget" true c.supports_reasoning_budget;
    check
      bool
      "chat_template_kwargs thinking control"
      true
      (c.thinking_control_format = Capabilities.Chat_template_kwargs);
    check bool "top_k" true c.supports_top_k
  | None -> fail "should match qwen3"
;;

let test_lookup_provider_m_dashscope_gguf_name () =
  match Capabilities.for_model_id "DashScope_3.6-35B-A3B-UD-Q4_K_XL.gguf" with
  | Some c ->
    check
      bool
      "dashscope qwen3.6 uses chat_template_kwargs"
      true
      (c.thinking_control_format = Capabilities.Chat_template_kwargs)
  | None -> fail "should match qwen3.6 model id"
;;

let test_lookup_provider_m_qwen3_mtp_explicit_provider () =
  match
    Capabilities.for_provider_model_id
      ~allow_bare_fallback:false
      ~provider_label:"vllm-qwen3-mtp"
      ~model_id:"qwen36-35b-a3b-mtp"
  with
  | Some c ->
    check (option int) "context 128K" (Some 131_072) c.max_context_tokens;
    check bool "tools" true c.supports_tools;
    check bool "parallel tools" true c.supports_parallel_tool_calls;
    check bool "reasoning" true c.supports_reasoning;
    check
      bool
      "explicit vllm-qwen3-mtp qwen3.6 uses chat_template_kwargs"
      true
      (c.thinking_control_format = Capabilities.Chat_template_kwargs);
    let dialect = Reasoning_dialect.of_capabilities c in
    (match dialect.streaming with
     | Reasoning_dialect.Delta_field field ->
       check string "vllm-qwen3-mtp reasoning delta field" "reasoning_content" field
     | Reasoning_dialect.No_streaming_reasoning
     | Reasoning_dialect.Delta_reasoning_details
     | Reasoning_dialect.Template_parser ->
       fail "vllm-qwen3-mtp should stream reasoning_content as a typed delta field");
    check
      string
      "vllm-qwen3-mtp scopes tool-call reasoning to the latest user turn"
      "latest_user_turn_tool_calls"
      (Reasoning_dialect.replay_policy_to_string dialect.replay_policy);
    check
      bool
      "catalog resolves the closed latest-user replay policy"
      true
      (c.reasoning_replay_override = Capabilities.Force_latest_user_turn_tool_calls);
    (match Capabilities.for_model_id "qwen36-35b-a3b-mtp" with
     | Some bare ->
       check
         bool
         "bare runtime row resolves the same latest-user replay policy"
         true
         (bare.reasoning_replay_override = Capabilities.Force_latest_user_turn_tool_calls)
     | None -> fail "bare qwen3.6 runtime row should resolve")
  | None -> fail "explicit provider/model lookup should match qwen3.6 model id"
;;

let test_lookup_runpod_rtxa6000_gemma4_coder_catalog () =
  let check_gemma4_coder label (c : Capabilities.capabilities) =
    check (option int) (label ^ " context 256K") (Some 262_144) c.max_context_tokens;
    check bool (label ^ " tools") true c.supports_tools;
    check bool (label ^ " tool_choice") true c.supports_tool_choice;
    check bool (label ^ " parallel tools") true c.supports_parallel_tool_calls;
    check bool (label ^ " reasoning") true c.supports_reasoning;
    check bool (label ^ " extended thinking") true c.supports_extended_thinking;
    check
      bool
      (label ^ " chat_template_token thinking control")
      true
      (c.thinking_control_format = Capabilities.Chat_template_token "<|think|>");
    check bool (label ^ " json response format") true c.supports_response_format_json;
    check bool (label ^ " native streaming") true c.supports_native_streaming;
    check bool (label ^ " top_k") true c.supports_top_k;
    check bool (label ^ " seed") true c.supports_seed
  in
  (match
     Capabilities.for_provider_model_id
       ~allow_bare_fallback:false
       ~provider_label:"runpod_rtxa6000"
       ~model_id:"gemma4-coder-fable5-q4km"
   with
   | Some c -> check_gemma4_coder "runpod_rtxa6000 gemma4 coder" c
   | None -> fail "strict provider lookup should match runpod_rtxa6000 gemma4 coder");
  check
    bool
    "dot-qualified runtime id is not inferred"
    true
    (Option.is_none
       (Capabilities.for_model_id "runpod_rtxa6000.gemma4-coder-fable5-q4km"));
  match Capabilities.for_model_id "gemma4-coder-fable5-q4km" with
  | Some c -> check_gemma4_coder "bare gemma4 coder" c
  | None -> fail "bare lookup should match gemma4-coder-fable5-q4km"
;;

let test_lookup_local_ollama_gemma4_e2b_qat_catalog () =
  let model_id = "hf.co/unsloth/gemma-4-E2B-it-qat-GGUF:UD-Q4_K_XL" in
  let check_gemma4_e2b label (c : Capabilities.capabilities) =
    check (option int) (label ^ " context 128K") (Some 131_072) c.max_context_tokens;
    check bool (label ^ " tools") true c.supports_tools;
    check bool (label ^ " forced tool_choice disabled") false c.supports_tool_choice;
    check bool (label ^ " named tool_choice disabled") false c.supports_named_tool_choice;
    check bool (label ^ " reasoning") true c.supports_reasoning;
    check bool (label ^ " extended thinking") true c.supports_extended_thinking;
    check bool (label ^ " reasoning budget disabled") false c.supports_reasoning_budget;
    check
      bool
      (label ^ " chat_template_token thinking control")
      true
      (c.thinking_control_format = Capabilities.Chat_template_token "<|think|>");
    check bool (label ^ " image input") true c.supports_image_input;
    check bool (label ^ " audio input") true c.supports_audio_input;
    check bool (label ^ " multimodal inputs") true c.supports_multimodal_inputs;
    check
      bool
      (label ^ " visual-first priority")
      true
      (c.modality_priority = Modality.Visual_first);
    check bool (label ^ " native streaming") true c.supports_native_streaming;
    check bool (label ^ " seed") true c.supports_seed
  in
  (match
     Capabilities.for_provider_model_id
       ~allow_bare_fallback:true
       ~provider_label:"ollama"
       ~model_id
   with
   | Some c -> check_gemma4_e2b "ollama Gemma4 E2B QAT via bare fallback" c
   | None -> fail "Ollama lookup with bare fallback should match local Gemma4 E2B QAT");
  match Capabilities.for_model_id model_id with
  | Some c -> check_gemma4_e2b "bare local Gemma4 E2B QAT" c
  | None -> fail "bare lookup should match local Gemma4 E2B QAT"
;;

let test_lookup_deepseek_v4_flash () =
  match
    Capabilities.for_provider_model_id
      ~allow_bare_fallback:false
      ~provider_label:"deepseek"
      ~model_id:"deepseek-v4-flash"
  with
  | Some c ->
    check (option int) "context 1M" (Some 1_000_000) c.max_context_tokens;
    check (option int) "output 384K" (Some 384_000) c.max_output_tokens;
    check bool "tools" true c.supports_tools;
    (* thinking mode (default) 400s on forced tool_choice; auto stays valid *)
    check bool "accepts auto tool_choice" true c.supports_tool_choice;
    check bool "rejects named forced tool_choice" false c.supports_named_tool_choice;
    check bool "reasoning" true c.supports_reasoning;
    check_thinking_control
      "uses thinking object"
      Capabilities.Thinking_object
      c.thinking_control_format;
    check bool "caching" true c.supports_caching
  | None -> fail "should match deepseek-v4-flash"
;;

let test_lookup_deepseek_v4_pro () =
  match
    Capabilities.for_provider_model_id
      ~allow_bare_fallback:false
      ~provider_label:"deepseek"
      ~model_id:"deepseek-v4-pro"
  with
  | Some c ->
    check (option int) "context 1M" (Some 1_000_000) c.max_context_tokens;
    check (option int) "output 384K" (Some 384_000) c.max_output_tokens;
    check bool "tools" true c.supports_tools;
    (* thinking mode (default) 400s on forced tool_choice; auto stays valid *)
    check bool "accepts auto tool_choice" true c.supports_tool_choice;
    check bool "rejects named forced tool_choice" false c.supports_named_tool_choice;
    check bool "reasoning" true c.supports_reasoning;
    check_thinking_control
      "uses thinking object"
      Capabilities.Thinking_object
      c.thinking_control_format;
    check bool "caching" true c.supports_caching
  | None -> fail "should match deepseek-v4-pro"
;;

let test_lookup_minimax_m3_official_chat_dialect () =
  match Capabilities.for_model_id "minimax-m3" with
  | Some c ->
    check bool "has tools" true c.supports_tools;
    check bool "omits explicit Chat tool_choice" false c.supports_tool_choice;
    check bool "rejects required forced tool_choice" false c.supports_required_tool_choice;
    check bool "rejects named forced tool_choice" false c.supports_named_tool_choice;
    check bool "reasoning" true c.supports_reasoning;
    check bool "extended thinking" true c.supports_extended_thinking;
    check bool "no reasoning depth budget" false c.supports_reasoning_budget;
    check_thinking_control
      "uses MiniMax adaptive thinking object"
      Capabilities.Thinking_object_adaptive
      c.thinking_control_format;
    check
      bool
      "uses split reasoning fields"
      true
      (c.reasoning_output_format = Capabilities.Split_reasoning_fields);
    check bool "no Chat response_format json" false c.supports_response_format_json;
    check bool "no Chat structured output" false c.supports_structured_output;
    check bool "multimodal" true c.supports_multimodal_inputs;
    check bool "image input" true c.supports_image_input;
    check
      bool
      "complete assistant replay"
      true
      (c.reasoning_replay_override = Capabilities.Force_preserve_always);
    let dialect = Reasoning_dialect.of_capabilities c in
    check
      string
      "toggle wire"
      "thinking_object_adaptive"
      (Reasoning_dialect.toggle_wire_to_string dialect.toggle_wire);
    check
      string
      "replay policy"
      "preserve_always"
      (Reasoning_dialect.replay_policy_to_string dialect.replay_policy);
    check
      bool
      "dialect emits reasoning split"
      true
      (dialect.output_wire = Reasoning_dialect.Reasoning_split);
    check
      bool
      "dialect streams typed reasoning details"
      true
      (dialect.streaming = Reasoning_dialect.Delta_reasoning_details)
  | None -> fail "should match minimax-m3"
;;

let test_lookup_grok () =
  match
    Capabilities.for_provider_model_id
      ~allow_bare_fallback:false
      ~provider_label:"xai"
      ~model_id:"grok-4.3"
  with
  | Some c ->
    check (option int) "context 1M" (Some 1_000_000) c.max_context_tokens;
    check bool "structured" true c.supports_structured_output;
    check bool "reasoning" true c.supports_reasoning;
    check bool "image" true c.supports_image_input
  | None -> fail "should match grok"
;;

let test_lookup_qwen3_thinking_control () =
  (* RFC-OAS-023: self-served Qwen3 (vLLM / llama-server, OpenAI_compat kind)
     toggles reasoning on the wire via
     {"chat_template_kwargs":{"enable_thinking":b}}. Without an explicit
     thinking_control_format the Qwen_3 record defaulted to
     No_thinking_control and [supports_extended_thinking=true] never reached
     the wire.

     Route through [for_model_id_with_manifest] with a non-matching manifest
     so this assertion pins the catalog fallback instead of any ambient
     manifest entry supplied by the test environment. *)
  let non_matching =
    match
      Capability_manifest.of_json
        (Yojson.Safe.from_string {|{"schema_version":1,"models":[]}|})
    with
    | Ok m -> m
    | Error e -> Alcotest.failf "manifest parse error: %s" e
  in
  match Capabilities.for_model_id_with_manifest non_matching "qwen3-32b" with
  | Some c ->
    check bool "supports reasoning" true c.supports_reasoning;
    check_thinking_control
      "qwen3 uses chat_template_kwargs"
      Capabilities.Chat_template_kwargs
      c.thinking_control_format
  | None -> fail "should match qwen3"
;;

let test_lookup_unknown () =
  check
    bool
    "unknown returns None"
    true
    (Capabilities.for_model_id "totally-unknown-model" = None)
;;

let test_lookup_case_insensitive () =
  check bool "uppercase matches" true (Capabilities.for_model_id "Claude-Opus-4-6" <> None)
;;

let test_lookup_glm5_text_only () =
  match Capabilities.for_model_id "glm-5" with
  | Some c ->
    check bool "no image input" false c.supports_image_input;
    check bool "reasoning" true c.supports_reasoning;
    check bool "structured output disabled" false c.supports_structured_output
  | None -> fail "should match glm-5"
;;

let test_lookup_glm5v_vision () =
  match Capabilities.for_model_id "glm-5v-turbo" with
  | Some c ->
    check bool "has image input" true c.supports_image_input;
    check bool "multimodal" true c.supports_multimodal_inputs
  | None -> fail "should match glm-5v"
;;

let test_lookup_glm46v_vision () =
  match Capabilities.for_model_id "glm-4.6v-flashx" with
  | Some c ->
    check bool "has image input" true c.supports_image_input;
    check bool "multimodal" true c.supports_multimodal_inputs;
    check bool "reasoning" true c.supports_reasoning
  | None -> fail "should match glm-4.6v"
;;

let test_lookup_glm_ocr () =
  match Capabilities.for_model_id "glm-ocr" with
  | Some c ->
    check bool "has image input" true c.supports_image_input;
    check bool "multimodal" true c.supports_multimodal_inputs;
    check bool "no tools" false c.supports_tools
  | None -> fail "should match glm-ocr"
;;

let test_ollama_cloud_current_catalog_resolves () =
  let cases =
    [ "deepseek-v4-pro", 524_288, false
    ; "minimax-m2.1", 204_800, false
    ; "minimax-m2.5", 196_608, false
    ; "qwen3.5:397b", 262_144, true
    ; "deepseek-v3.1:671b", 163_840, false
    ; "nemotron-3-nano:30b", 262_144, false
    ; "devstral-2:123b", 262_144, false
    ; "gemma3:12b", 131_072, true
    ; "nemotron-3-ultra", 262_144, false
    ; "qwen3-coder:480b", 262_144, false
    ; "devstral-small-2:24b", 262_144, true
    ; "gemini-3-flash-preview", 1_048_576, true
    ; "gemma4:31b", 262_144, true
    ; "kimi-k2.5", 262_144, true
    ; "kimi-k2.7-code", 262_144, true
    ; "gpt-oss:20b", 131_072, false
    ; "gemma3:27b", 131_072, true
    ; "kimi-k2.6", 262_144, true
    ; "deepseek-v3.2", 163_840, false
    ; "mistral-large-3:675b", 262_144, true
    ; "glm-5.1", 202_752, false
    ; "glm-5.2", 1_000_000, false
    ; "gpt-oss:120b", 131_072, false
    ; "minimax-m3", 524_288, true
    ; "ministral-3:3b", 262_144, true
    ; "glm-5", 202_752, false
    ; "qwen3-coder-next", 262_144, false
    ; "minimax-m2.7", 196_608, false
    ; "ministral-3:8b", 262_144, true
    ; "deepseek-v4-flash", 1_048_576, false
    ; "ministral-3:14b", 262_144, true
    ; "gemma3:4b", 131_072, true
    ; "nemotron-3-super", 262_144, false
    ; "glm-4.7", 202_752, false
    ]
  in
  List.iter
    (fun (model_id, context, vision) ->
       match
         Capabilities.for_provider_model_id
           ~allow_bare_fallback:false
           ~provider_label:"ollama_cloud"
           ~model_id
       with
       | None -> failf "ollama_cloud/%s should resolve" model_id
       | Some c ->
         check (option int) (model_id ^ " context") (Some context) c.max_context_tokens;
         check bool (model_id ^ " vision") vision c.supports_image_input;
         check bool (model_id ^ " multimodal") vision c.supports_multimodal_inputs)
    cases
;;

let test_ollama_cloud_v1_vendor_models_resolve_exact_capabilities () =
  List.iter
    (fun model_id ->
       match
         Capabilities.for_provider_model_id
           ~allow_bare_fallback:false
           ~provider_label:"ollama_cloud"
           ~model_id
       with
       | None -> failf "ollama_cloud/%s should resolve exactly" model_id
       | Some c ->
         check (option int) (model_id ^ " context") (Some 262_144) c.max_context_tokens;
         check bool (model_id ^ " tools") true c.supports_tools;
         check bool (model_id ^ " reasoning") true c.supports_reasoning;
         check bool (model_id ^ " extended thinking") true c.supports_extended_thinking;
         check
           bool
           (model_id ^ " no reasoning budget control")
           false
           c.supports_reasoning_budget;
         check_thinking_control
           (model_id ^ " inherent thinking has no request control")
           Capabilities.No_thinking_control
           c.thinking_control_format;
         check bool (model_id ^ " json mode") true c.supports_response_format_json;
         check
           bool
           (model_id ^ " no native schema guarantee")
           false
           c.supports_structured_output;
         check bool (model_id ^ " multimodal") true c.supports_multimodal_inputs;
         check bool (model_id ^ " image input") true c.supports_image_input;
         check bool (model_id ^ " native streaming") true c.supports_native_streaming)
    [ "qwen3.5:cloud"; "gemma4:31b-cloud" ]
;;

let test_ollama_cloud_grouped_rows_have_required_axes () =
  (* Live grouped smokes for these Ollama Cloud rows exercise the same
     production workflow: tool call -> tool_result replay -> final answer while
     reasoning may stream on a side channel. The catalog must not regress any
     one of these axes to a generic text-only profile. JSON response-format
     support is an exact per-model contract rather than a provider-wide rule. *)
  let cases =
    [ "qwen3.5:397b", false
    ; "gemma4:31b", true
    ; "kimi-k2.7-code", false
    ; "minimax-m3", true
    ; "nemotron-3-ultra", false
    ; "deepseek-v4-flash", false
    ; "deepseek-v4-pro", false
    ; "glm-5.2", false
    ; "gpt-oss:20b", false
    ; "gpt-oss:120b", false
    ]
  in
  List.iter
    (fun (model_id, expected_json) ->
       match
         Capabilities.for_provider_model_id
           ~allow_bare_fallback:false
           ~provider_label:"ollama_cloud"
           ~model_id
       with
       | None -> failf "ollama_cloud/%s should resolve" model_id
       | Some c ->
         check bool (model_id ^ " tools") true c.supports_tools;
         check bool (model_id ^ " reasoning") true c.supports_reasoning;
         check bool (model_id ^ " extended thinking") true c.supports_extended_thinking;
         check bool (model_id ^ " native streaming") true c.supports_native_streaming;
         check
           bool
           (model_id ^ " json response format")
           expected_json
           c.supports_response_format_json;
         check_thinking_control
           (model_id ^ " uses Ollama native think")
           Capabilities.Ollama_think
           c.thinking_control_format)
    cases
;;

let test_ollama_cloud_grouped_rows_follow_exact_output_contract () =
  (* JSON response-format support is model-specific. Native structured output
     remains disabled by the Ollama Cloud provider contract. *)
  let cases =
    [ "kimi-k2.5", false
    ; "kimi-k2.6", true
    ; "kimi-k2.7-code", false
    ; "minimax-m3", true
    ; "deepseek-v4-pro", false
    ; "deepseek-v4-flash", false
    ; "glm-5.2", false
    ; "gpt-oss:20b", false
    ; "gpt-oss:120b", false
    ; "nemotron-3-ultra", false
    ; "qwen3.5:397b", false
    ]
  in
  List.iter
    (fun (model_id, expected_json) ->
       match
         Capabilities.for_provider_model_id
           ~allow_bare_fallback:false
           ~provider_label:"ollama_cloud"
           ~model_id
       with
       | None -> failf "ollama_cloud/%s should resolve" model_id
       | Some c ->
         check
           bool
           (model_id ^ " json response format")
           expected_json
           c.supports_response_format_json;
         check bool (model_id ^ " structured output") false c.supports_structured_output)
    cases
;;

let test_ollama_cloud_kimi_preserves_historical_reasoning () =
  match
    Capabilities.for_provider_model_id
      ~allow_bare_fallback:false
      ~provider_label:"ollama_cloud"
      ~model_id:"kimi-k2.7-code"
  with
  | None -> fail "ollama_cloud/kimi-k2.7-code should resolve"
  | Some c ->
    check
      bool
      "Kimi Cloud preserves all reasoning"
      true
      (c.reasoning_replay_override = Capabilities.Force_preserve_always)
;;

let test_ollama_cloud_structured_output_is_disabled_by_provider_contract () =
  (* The official Ollama structured-output documentation currently says that
     Ollama Cloud does not support structured outputs. Keep JSON mode and
     schema enforcement separate: every Cloud row must remain schema-disabled
     even when a historical probe appeared to accept a schema-shaped reply. *)
  let cases =
    [ "devstral-2:123b", false
    ; "devstral-small-2:24b", false
    ; "ministral-3:14b", false
    ; "mistral-large-3:675b", false
    ; "ministral-3:3b", false
    ; "ministral-3:8b", false
    ]
  in
  List.iter
    (fun (model_id, structured_output) ->
       match
         Capabilities.for_provider_model_id
           ~allow_bare_fallback:false
           ~provider_label:"ollama_cloud"
           ~model_id
       with
       | None -> failf "ollama_cloud/%s should resolve" model_id
       | Some c ->
         check bool (model_id ^ " tools") true c.supports_tools;
         check
           bool
           (model_id ^ " json response format")
           true
           c.supports_response_format_json;
         check
           bool
           (model_id ^ " structured output guarantee")
           structured_output
           c.supports_structured_output;
         check bool (model_id ^ " no reasoning") false c.supports_reasoning;
         check_thinking_control
           (model_id ^ " no thinking control")
           Capabilities.No_thinking_control
           c.thinking_control_format)
    cases
;;

let test_ollama_cloud_provider_qualified_preserves_shared_bare_family () =
  let open Capabilities in
  let bare_glm =
    match for_model_id "glm-5.1" with
    | Some c -> c
    | None -> fail "bare glm-5.1 should resolve"
  in
  let cloud_glm =
    match
      for_provider_model_id
        ~allow_bare_fallback:false
        ~provider_label:"ollama_cloud"
        ~model_id:"glm-5.1"
    with
    | Some c -> c
    | None -> fail "ollama_cloud/glm-5.1 should resolve"
  in
  check (option int) "bare GLM context" (Some 200_000) bare_glm.max_context_tokens;
  check (option int) "cloud GLM context" (Some 202_752) cloud_glm.max_context_tokens;
  check_thinking_control
    "cloud GLM uses Ollama native think"
    Ollama_think
    cloud_glm.thinking_control_format;
  let bare_glm52 =
    match for_model_id "glm-5.2" with
    | Some c -> c
    | None -> fail "bare glm-5.2 should resolve"
  in
  let cloud_glm52 =
    match
      for_provider_model_id
        ~allow_bare_fallback:false
        ~provider_label:"ollama_cloud"
        ~model_id:"glm-5.2"
    with
    | Some c -> c
    | None -> fail "ollama_cloud/glm-5.2 should resolve"
  in
  check_thinking_control
    "bare GLM-5.2 keeps ZAI GLM thinking control"
    No_thinking_control
    bare_glm52.thinking_control_format;
  check_thinking_control
    "cloud GLM-5.2 uses Ollama native think"
    Ollama_think
    cloud_glm52.thinking_control_format;
  let bare_kimi =
    match for_model_id "kimi-k2.7-code" with
    | Some c -> c
    | None -> fail "bare kimi-k2.7-code should resolve"
  in
  let cloud_kimi =
    match
      for_provider_model_id
        ~allow_bare_fallback:false
        ~provider_label:"ollama_cloud"
        ~model_id:"kimi-k2.7-code"
    with
    | Some c -> c
    | None -> fail "ollama_cloud/kimi-k2.7-code should resolve"
  in
  check_thinking_control
    "bare latest Kimi has no thinking request toggle"
    No_thinking_control
    bare_kimi.thinking_control_format;
  check
    bool
    "bare latest Kimi always preserves reasoning"
    true
    (bare_kimi.preserve_thinking_control_format = Always_preserved_thinking);
  check_thinking_control
    "cloud Kimi uses Ollama native think"
    Ollama_think
    cloud_kimi.thinking_control_format;
  check
    (option int)
    "bare Kimi native context"
    (Some 256_000)
    bare_kimi.max_context_tokens;
  check
    (option int)
    "cloud Kimi official context"
    (Some 262_144)
    cloud_kimi.max_context_tokens;
  check
    bool
    "bare/cloud Kimi contexts intentionally differ"
    true
    (bare_kimi.max_context_tokens <> cloud_kimi.max_context_tokens);
  check bool "bare Kimi vision" true bare_kimi.supports_image_input;
  check bool "cloud Kimi vision" true cloud_kimi.supports_image_input
;;

type structured_contract =
  | Response_format_json_schema
  | Response_format_json
  | Native_structured_output
  | No_structured_output

type replay_contract =
  | Replay_not_required
  | Replay_tool_turn_only
  | Replay_latest_user_tool_turn_only
  | Replay_every_turn

type streaming_contract =
  | Streaming_not_required
  | Delta_stream of string
  | Delta_reasoning_details_stream
  | Template_stream

let streaming_reasoning_to_string = function
  | Reasoning_dialect.No_streaming_reasoning -> "no_streaming_reasoning"
  | Reasoning_dialect.Template_parser -> "template_parser"
  | Reasoning_dialect.Delta_field actual -> "delta_field:" ^ actual
  | Reasoning_dialect.Delta_reasoning_details -> "delta_reasoning_details"
;;

type thinking_contract =
  | Reasoning_only
  | Extended_thinking

type provider_route =
  | Direct_model
  | Provider_qualified of string
  | Native_provider of Provider_config.provider_kind

let frontier_capabilities route model_id =
  match route with
  | Direct_model -> Capabilities.for_model_id model_id
  | Provider_qualified provider_label ->
    Capabilities.for_provider_model_id
      ~allow_bare_fallback:false
      ~provider_label
      ~model_id
  | Native_provider _ -> Capabilities.for_model_id model_id
;;

let frontier_dialect route model_id caps =
  match route with
  | Native_provider kind ->
    let base_url =
      match kind with
      | Provider_config.Anthropic -> "https://api.anthropic.com"
      | Provider_config.Gemini -> "https://generativelanguage.googleapis.com/v1beta"
      | Provider_config.Kimi
      | Provider_config.OpenAI_compat
      | Provider_config.Ollama
      | Provider_config.Glm
      | Provider_config.DashScope -> "https://example.invalid"
    in
    Provider_config.make ~kind ~model_id ~base_url ()
    |> Reasoning_dialect.for_provider_config
  | Direct_model | Provider_qualified _ -> Reasoning_dialect.of_capabilities caps
;;

let check_frontier_model
      ~label
      ~route
      ~model_id
      ~thinking_contract
      ~structured_contract
      ~replay_contract
      ~streaming_contract
      ()
  =
  match frontier_capabilities route model_id with
  | None -> failf "%s should resolve capabilities" label
  | Some c ->
    check bool (label ^ " supports tools") true c.supports_tools;
    check bool (label ^ " supports reasoning") true c.supports_reasoning;
    (match thinking_contract with
     | Reasoning_only -> ()
     | Extended_thinking ->
       check
         bool
         (label ^ " supports extended thinking")
         true
         c.supports_extended_thinking);
    check bool (label ^ " supports native streaming") true c.supports_native_streaming;
    (match structured_contract with
     | Response_format_json_schema ->
       check
         bool
         (label ^ " supports structured output")
         true
         c.supports_structured_output;
       check
         bool
         (label ^ " supports response_format/json_schema")
         true
         c.supports_response_format_json
     | Response_format_json ->
       check bool (label ^ " no structured output") false c.supports_structured_output;
       check
         bool
         (label ^ " supports response_format/json")
         true
         c.supports_response_format_json
     | Native_structured_output ->
       check
         bool
         (label ^ " supports structured output")
         true
         c.supports_structured_output
     | No_structured_output ->
       check bool (label ^ " no structured output") false c.supports_structured_output);
    let dialect = frontier_dialect route model_id c in
    (match replay_contract with
     | Replay_not_required ->
       check
         bool
         (label ^ " does not replay plain-turn reasoning")
         false
         (Reasoning_dialect.should_replay_reasoning
            dialect
            ~assistant_had_tool_call:false);
       check
         bool
         (label ^ " does not replay tool-turn reasoning")
         false
         (Reasoning_dialect.should_replay_reasoning dialect ~assistant_had_tool_call:true)
     | Replay_tool_turn_only ->
       check
         string
         (label ^ " replay policy")
         "drop_without_tool_preserve_with_tool"
         (Reasoning_dialect.replay_policy_to_string dialect.replay_policy);
       check
         bool
         (label ^ " drops plain-turn reasoning")
         false
         (Reasoning_dialect.should_replay_reasoning
            dialect
            ~assistant_had_tool_call:false);
       check
         bool
         (label ^ " preserves tool-turn reasoning")
         true
         (Reasoning_dialect.should_replay_reasoning dialect ~assistant_had_tool_call:true);
       check
         bool
         (label ^ " requires replay only on tool call")
         true
         (Reasoning_dialect.requires_reasoning_replay_on_tool_call dialect)
     | Replay_latest_user_tool_turn_only ->
       check
         string
         (label ^ " replay policy")
         "latest_user_turn_tool_calls"
         (Reasoning_dialect.replay_policy_to_string dialect.replay_policy);
       check
         bool
         (label ^ " drops plain-turn reasoning")
         false
         (Reasoning_dialect.should_replay_reasoning
            dialect
            ~assistant_had_tool_call:false);
       check
         bool
         (label ^ " preserves a selected tool-call reasoning artifact")
         true
         (Reasoning_dialect.should_replay_reasoning dialect ~assistant_had_tool_call:true);
       check
         bool
         (label ^ " requires replay only on a selected tool call")
         true
         (Reasoning_dialect.requires_reasoning_replay_on_tool_call dialect)
     | Replay_every_turn ->
       check
         string
         (label ^ " replay policy")
         "preserve_always"
         (Reasoning_dialect.replay_policy_to_string dialect.replay_policy);
       check
         bool
         (label ^ " preserves plain-turn reasoning")
         true
         (Reasoning_dialect.should_replay_reasoning
            dialect
            ~assistant_had_tool_call:false);
       check
         bool
         (label ^ " preserves tool-turn reasoning")
         true
         (Reasoning_dialect.should_replay_reasoning dialect ~assistant_had_tool_call:true);
       check
         bool
         (label ^ " is not tool-only replay")
         false
         (Reasoning_dialect.requires_reasoning_replay_on_tool_call dialect));
    (match streaming_contract with
     | Streaming_not_required -> ()
     | Delta_stream field ->
       (match dialect.streaming with
        | Reasoning_dialect.Delta_field actual ->
          check string (label ^ " reasoning delta field") field actual
        | other ->
          failf
            "%s expected Delta_field(%s), got %s"
            label
            field
            (streaming_reasoning_to_string other))
     | Delta_reasoning_details_stream ->
       check
         string
         (label ^ " reasoning details stream")
         "delta_reasoning_details"
         (streaming_reasoning_to_string dialect.streaming)
     | Template_stream ->
       check
         string
         (label ^ " template stream")
         "template_parser"
         (streaming_reasoning_to_string dialect.streaming))
;;

let test_frontier_grouped_tool_thinking_provider_contracts () =
  (* This matrix is intentionally named after current production-provider
     evidence, not broad model families. Every row must keep the axes needed by
     multi-turn + thinking/reasoning + tool-use + provider output-contract
     workflows. The structured_contract field covers strict schema support,
     native structured support, and explicit no-structured-output rows.
     Replay semantics are provider-specific: Kimi/Anthropic preserve every
     turn, DeepSeek preserves tool-call turns, and other side-channel providers
     only need stream separation here. *)
  let cases =
    [ ( "Xiaomi MiMo V2.5"
      , Provider_qualified "mimo"
      , "mimo-v2.5-pro"
      , Reasoning_only
      , No_structured_output
      , Replay_tool_turn_only
      , Delta_stream "reasoning_content" )
    ; ( "DeepSeek V4 Pro"
      , Provider_qualified "deepseek"
      , "deepseek-v4-pro"
      , Extended_thinking
      , Response_format_json
      , Replay_tool_turn_only
      , Delta_stream "reasoning_content" )
    ; ( "DeepSeek V4 Flash"
      , Provider_qualified "deepseek"
      , "deepseek-v4-flash"
      , Extended_thinking
      , Response_format_json_schema
      , Replay_tool_turn_only
      , Delta_stream "reasoning_content" )
    ; ( "MiniMax M3 native/openai-compatible"
      , Direct_model
      , "minimax-m3"
      , Extended_thinking
      , No_structured_output
      , Replay_every_turn
      , Delta_reasoning_details_stream )
    ; ( "OpenAI GPT-5.5"
      , Direct_model
      , "gpt-5.5"
      , Extended_thinking
      , Response_format_json_schema
      , Replay_not_required
      , Delta_stream "reasoning" )
    ; ( "OpenAI GPT-5.4 mini"
      , Direct_model
      , "gpt-5.4-mini"
      , Extended_thinking
      , Response_format_json_schema
      , Replay_not_required
      , Delta_stream "reasoning" )
    ; ( "Claude Haiku 4.5"
      , Native_provider Provider_config.Anthropic
      , "claude-haiku-4-5"
      , Extended_thinking
      , Native_structured_output
      , Replay_every_turn
      , Delta_stream "thinking_delta" )
    ; ( "Claude Sonnet 4.6"
      , Native_provider Provider_config.Anthropic
      , "claude-sonnet-4-6"
      , Extended_thinking
      , Native_structured_output
      , Replay_every_turn
      , Delta_stream "thinking_delta" )
    ; ( "Claude Opus 4.6"
      , Native_provider Provider_config.Anthropic
      , "claude-opus-4-6"
      , Extended_thinking
      , Native_structured_output
      , Replay_every_turn
      , Delta_stream "thinking_delta" )
    ; ( "Qwen3.6 RunPod/self-hosted"
      , Direct_model
      , "qwen/qwen3.6-35b-a3b"
      , Extended_thinking
      , Response_format_json_schema
      , Replay_latest_user_tool_turn_only
      , Delta_stream "reasoning_content" )
    ; ( "Ollama Cloud Qwen3.5"
      , Provider_qualified "ollama_cloud"
      , "qwen3.5:397b"
      , Extended_thinking
      , No_structured_output
      , Replay_not_required
      , Delta_stream "thinking" )
    ; ( "Ollama Cloud Gemma4"
      , Provider_qualified "ollama_cloud"
      , "gemma4:31b"
      , Extended_thinking
      , Response_format_json
      , Replay_not_required
      , Delta_stream "thinking" )
    ; ( "Ollama Cloud Kimi K2.7 Code"
      , Provider_qualified "ollama_cloud"
      , "kimi-k2.7-code"
      , Extended_thinking
      , No_structured_output
      , Replay_every_turn
      , Delta_stream "thinking" )
    ; ( "Ollama Cloud MiniMax M3"
      , Provider_qualified "ollama_cloud"
      , "minimax-m3"
      , Extended_thinking
      , Response_format_json
      , Replay_not_required
      , Delta_stream "reasoning" )
    ; ( "Ollama Cloud Nemotron 3 Ultra"
      , Provider_qualified "ollama_cloud"
      , "nemotron-3-ultra"
      , Extended_thinking
      , No_structured_output
      , Replay_not_required
      , Delta_stream "thinking" )
    ; ( "Ollama Cloud DeepSeek V4 Pro"
      , Provider_qualified "ollama_cloud"
      , "deepseek-v4-pro"
      , Extended_thinking
      , No_structured_output
      , Replay_not_required
      , Delta_stream "thinking" )
    ; ( "Ollama Cloud DeepSeek V4 Flash"
      , Provider_qualified "ollama_cloud"
      , "deepseek-v4-flash"
      , Extended_thinking
      , No_structured_output
      , Replay_not_required
      , Delta_stream "thinking" )
    ; ( "Ollama Cloud GLM 5.2"
      , Provider_qualified "ollama_cloud"
      , "glm-5.2"
      , Extended_thinking
      , No_structured_output
      , Replay_not_required
      , Delta_stream "thinking" )
    ; ( "Ollama Cloud GPT-OSS 20B"
      , Provider_qualified "ollama_cloud"
      , "gpt-oss:20b"
      , Extended_thinking
      , No_structured_output
      , Replay_not_required
      , Delta_stream "thinking" )
    ; ( "Ollama Cloud GPT-OSS 120B"
      , Provider_qualified "ollama_cloud"
      , "gpt-oss:120b"
      , Extended_thinking
      , No_structured_output
      , Replay_not_required
      , Delta_stream "thinking" )
    ]
  in
  List.iter
    (fun ( label
         , route
         , model_id
         , thinking_contract
         , structured_contract
         , replay_contract
         , streaming_contract ) ->
       check_frontier_model
         ~label
         ~route
         ~model_id
         ~thinking_contract
         ~structured_contract
         ~replay_contract
         ~streaming_contract
         ())
    cases
;;

(* ── with_context_size ───────────────────────────────── *)

let test_with_context_size () =
  let c = Capabilities.default_capabilities in
  let c2 = Capabilities.with_context_size c ~ctx_size:131072 in
  check (option int) "ctx_size set" (Some 131072) c2.max_context_tokens;
  check bool "other fields unchanged" false c2.supports_tools
;;

(* ── Capability manifest ─────────────────────────────── *)

let make_manifest_json ?(base = "default_capabilities") ?(extra_fields = []) prefix =
  let fields =
    [ "id_prefix", Printf.sprintf {|"%s"|} prefix ]
    @ (if base = "default_capabilities"
       then []
       else [ "base", Printf.sprintf {|"%s"|} base ])
    @ extra_fields
  in
  let inner =
    fields |> List.map (fun (k, v) -> Printf.sprintf {|"%s":%s|} k v) |> String.concat ","
  in
  Printf.sprintf {|{"schema_version":1,"models":[{%s}]}|} inner
;;

let make_manifest ?(base = "default_capabilities") ?(extra_fields = []) prefix =
  let json = Yojson.Safe.from_string (make_manifest_json ~base ~extra_fields prefix) in
  match Capability_manifest.of_json json with
  | Ok m -> m
  | Error e -> Alcotest.failf "manifest parse error: %s" e
;;

let test_explicit_manifest_lookup_precedes_catalog_fallback () =
  (* [for_model_id_with_manifest] is the explicit-manifest API, so the supplied
     manifest wins before falling back to the globally loaded catalog. *)
  let m =
    make_manifest
      ~base:"openai_chat"
      ~extra_fields:
        [ "max_context_tokens", "999999"
        ; "supports_computer_use", "false"
        ; "supports_tools", "true"
        ]
      "claude-opus-4"
  in
  match Capabilities.for_model_id_with_manifest m "claude-opus-4-6" with
  | Some c ->
    check (option int) "manifest overrides ctx" (Some 999999) c.max_context_tokens;
    check bool "manifest overrides computer_use" false c.supports_computer_use;
    check bool "manifest keeps tools" true c.supports_tools
  | None -> fail "expected Some from manifest"
;;

let test_explicit_manifest_lookup_falls_back_to_catalog () =
  (* Manifest has no entry for claude-opus, so the lookup should fall through to
     the loaded model catalog. *)
  let m = make_manifest "totally-other-model" in
  match Capabilities.for_model_id_with_manifest m "claude-opus-4-6" with
  | Some c ->
    check (option int) "fallback ctx 1M" (Some 1_000_000) c.max_context_tokens;
    check bool "fallback computer_use" true c.supports_computer_use
  | None -> fail "should fall through to model catalog"
;;

let test_manifest_unknown_model_still_none () =
  (* Neither manifest nor model catalog knows this model. *)
  let m = make_manifest "known-prefix" in
  check
    bool
    "unknown → None"
    true
    (Capabilities.for_model_id_with_manifest m "totally-unknown-xyz" = None)
;;

let test_manifest_base_label_openai_chat () =
  let m =
    make_manifest
      ~base:"openai_chat"
      ~extra_fields:[ "max_context_tokens", "65536" ]
      "custom-gpt"
  in
  match Capabilities.for_model_id_with_manifest m "custom-gpt-v2" with
  | Some c ->
    check (option int) "custom ctx" (Some 65536) c.max_context_tokens;
    check bool "openai_chat base: tools" true c.supports_tools;
    check bool "openai_chat base: streaming" true c.supports_native_streaming
  | None -> fail "expected Some"
;;

let test_manifest_base_label_anthropic () =
  let m =
    make_manifest
      ~base:"anthropic"
      ~extra_fields:[ "max_context_tokens", "512000" ]
      "my-claude"
  in
  match Capabilities.for_model_id_with_manifest m "my-claude-custom" with
  | Some c ->
    check (option int) "custom ctx 512K" (Some 512000) c.max_context_tokens;
    check bool "anthropic base: caching" true c.supports_caching;
    check bool "anthropic base: extended thinking" true c.supports_extended_thinking
  | None -> fail "expected Some"
;;

let test_manifest_base_absent_uses_default () =
  (* No base label — should use default_capabilities as base. *)
  let m =
    make_manifest
      ~extra_fields:[ "supports_tools", "true"; "max_context_tokens", "32768" ]
      "my-special-model"
  in
  match Capabilities.for_model_id_with_manifest m "my-special-model-q4" with
  | Some c ->
    check bool "tools overridden true" true c.supports_tools;
    check (option int) "ctx overridden" (Some 32768) c.max_context_tokens;
    (* default has supports_reasoning=false — not overridden *)
    check bool "reasoning unchanged from default" false c.supports_reasoning
  | None -> fail "expected Some"
;;

let test_manifest_base_label_constructor_rejects_unknown () =
  match Capability_manifest.base_label_of_string "not_a_preset" with
  | Error _ -> ()
  | Ok _ -> fail "unknown base label should not be constructible"
;;

let test_manifest_base_label_constructor_canonicalizes () =
  match Capability_manifest.base_label_of_string " OpenAI_CHAT " with
  | Ok label ->
    check
      string
      "canonical base label"
      "openai_chat"
      (Capability_manifest.base_label_to_string label)
  | Error msg -> failf "known base label should parse: %s" msg
;;

let test_example_manifest_base_labels_are_canonical () =
  let path =
    [ "docs/example-capability-manifest.json"
    ; "../docs/example-capability-manifest.json"
    ; "../../docs/example-capability-manifest.json"
    ]
    |> List.find_opt Sys.file_exists
    |> Option.value ~default:"docs/example-capability-manifest.json"
  in
  match Capability_manifest.load_file path with
  | Error msg -> failf "example manifest should parse: %s" msg
  | Ok entries ->
    List.iter
      (fun (entry : Capability_manifest.entry) ->
         match entry.base_label with
         | None ->
           (* The Codex Spark entry intentionally does not inherit a public
              chat-completions preset; every other example entry must specify a
              base so the manifest actually applies the intended preset. *)
           if entry.id_prefix <> "gpt-5.3-codex-spark"
           then
             check bool (Printf.sprintf "expected base for %s" entry.id_prefix) true false
         | Some label ->
           let label = Capability_manifest.base_label_to_string label in
           check
             bool
             (Printf.sprintf "base label resolves for %s: %s" entry.id_prefix label)
             true
             (Option.is_some (Capabilities.capabilities_for_provider_label label)))
      entries
;;

let test_explicit_manifest_prefix_precedes_catalog_fallback () =
  (* Explicit manifest lookup lets callers test or apply a manifest before
     consulting the global catalog fallback. *)
  let m =
    make_manifest
      ~base:"openai_chat"
      ~extra_fields:[ "supports_reasoning", "false" ]
      "dashscope-3"
  in
  match Capabilities.for_model_id_with_manifest m "dashscope-3.5-35b-a3b-q4" with
  | Some c ->
    check bool "manifest disables reasoning" false c.supports_reasoning;
    check bool "base openai_chat: tools" true c.supports_tools
  | None -> fail "expected Some"
;;

let test_global_catalog_precedes_global_manifest () =
  let manifest =
    make_manifest
      ~base:"anthropic"
      ~extra_fields:
        [ "max_context_tokens", "999999"
        ; "supports_tools", "false"
        ; "supports_computer_use", "true"
        ; "thinking_control_format", {|"thinking_object"|}
        ]
      "s9-precedence-model"
  in
  with_temp_model_catalog
    {|
[[models]]
id_prefix = "s9-precedence-model"
base = "openai_chat"
max_context_tokens = 123456
supports_tools = true
supports_computer_use = false
thinking_control_format = "chat_template_kwargs"
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg -> Alcotest.failf "model catalog parse error: %s" msg
       | Ok catalog ->
         Model_catalog.set_global catalog;
         Capability_manifest.set_global manifest;
         Fun.protect
           ~finally:(fun () -> isolate_ambient_runtime_sources ())
           (fun () ->
              match Capabilities.for_model_id "s9-precedence-model-v1" with
              | Some c ->
                check (option int) "catalog ctx wins" (Some 123456) c.max_context_tokens;
                check bool "catalog tools wins" true c.supports_tools;
                check bool "catalog computer_use wins" false c.supports_computer_use;
                check_thinking_control
                  "catalog thinking format wins"
                  Capabilities.Chat_template_kwargs
                  c.thinking_control_format
              | None -> fail "expected catalog-backed capabilities"))
;;

let test_provider_scoped_catalog_identity_is_exact () =
  with_temp_model_catalog
    {|
[[models]]
id_prefix = "exact-model"
base = "openai_chat"
supports_tools = false
thinking_control_format = "chat_template_token"
thinking_control_token = "<|bare|>"

[[models]]
id_prefix = "exact-model"
provider_name = "acme"
base = "openai_chat"
supports_tools = true
thinking_control_format = "chat_template_token"
thinking_control_token = "<|provider|>"
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg -> Alcotest.failf "model catalog parse error: %s" msg
       | Ok catalog ->
         let previous_catalog = Model_catalog.global () in
         let restore () =
           match previous_catalog with
           | Some catalog -> Model_catalog.set_global catalog
           | None -> Model_catalog.clear_global ()
         in
         Fun.protect ~finally:restore (fun () ->
           Model_catalog.set_global catalog;
           (match
              Capabilities.for_provider_model_id
                ~allow_bare_fallback:false
                ~provider_label:" ACME "
                ~model_id:" EXACT-MODEL "
            with
            | Some caps ->
              check bool "exact normalized pair resolves" true caps.supports_tools
            | None -> fail "exact normalized provider/model pair must resolve");
           check
             (option reject)
             "provider-scoped model prefix extension is absent"
             None
             (Capabilities.for_provider_model_id
                ~allow_bare_fallback:false
                ~provider_label:"acme"
                ~model_id:"exact-model-preview");
           (match Capabilities.for_model_id "exact-model-preview" with
            | Some caps ->
              check
                bool
                "bare family lookup retains prefix semantics"
                false
                caps.supports_tools
            | None -> fail "provider-independent family lookup must remain available");
           check
             (option string)
             "exact provider/model token resolves"
             (Some "<|provider|>")
             (Capabilities.thinking_control_token_for_provider_model_id
                ~provider_label:"acme"
                ~model_id:"exact-model");
           check
             (option string)
             "provider token near-miss does not fall back to bare family"
             None
             (Capabilities.thinking_control_token_for_provider_model_id
                ~provider_label:"acme"
                ~model_id:"exact-model-preview")))
;;

let test_apply_manifest_entry_all_none_uses_base () =
  (* Entry with only id_prefix set — should be identical to base. *)
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"x","base":"anthropic"}]}|}
  in
  let manifest = Capability_manifest.of_json json |> Result.get_ok in
  let entry = List.hd manifest in
  let caps = Capabilities.apply_manifest_entry entry in
  let base = Capabilities.anthropic_capabilities in
  check bool "tools matches base" base.supports_tools caps.supports_tools;
  check (option int) "ctx matches base" base.max_context_tokens caps.max_context_tokens;
  check bool "caching matches base" base.supports_caching caps.supports_caching
;;

let check_manifest_rejects_typed_field ~field ~value ~expected_type =
  let json =
    `Assoc
      [ "schema_version", `Int 1
      ; ( "models"
        , `List [ `Assoc [ "id_prefix", `String "typed-manifest-field"; field, value ] ] )
      ]
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains (field ^ " mentions field") msg field;
    check_contains (field ^ " mentions expected type") msg expected_type
  | Ok _ -> Alcotest.failf "wrong-type manifest field %s should reject" field
;;

let test_manifest_rejects_wrong_type_bool () =
  check_manifest_rejects_typed_field
    ~field:"supports_tools"
    ~value:(`String "yes")
    ~expected_type:"expected bool"
;;

let test_manifest_rejects_wrong_type_int () =
  check_manifest_rejects_typed_field
    ~field:"max_context_tokens"
    ~value:(`String "131072")
    ~expected_type:"expected int"
;;

let test_manifest_rejects_wrong_type_string_list () =
  List.iter
    (fun (label, value) ->
       let json =
         `Assoc
           [ "schema_version", `Int 1
           ; ( "models"
             , `List
                 [ `Assoc
                     [ "id_prefix", `String "typed-string-list"
                     ; "accepted_reasoning_efforts", value
                     ]
                 ] )
           ]
       in
       match Capability_manifest.of_json json with
       | Error msg ->
         check_contains (label ^ " mentions field") msg "accepted_reasoning_efforts";
         check_contains (label ^ " mentions expected type") msg "expected string array"
       | Ok _ -> Alcotest.failf "%s string-list value should reject" label)
    [ "scalar", `String "low"; "non-string item", `List [ `String "low"; `Bool true ] ]
;;

let test_manifest_rejects_empty_id_prefix () =
  let json =
    Yojson.Safe.from_string {|{"schema_version":1,"models":[{"id_prefix":""}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions id_prefix" msg "id_prefix";
    check_contains "mentions empty" msg "must not be empty"
  | Ok _ -> Alcotest.fail "empty manifest id_prefix should reject"
;;

let test_manifest_rejects_padded_id_prefix () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":" padded-model "}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions id_prefix" msg "id_prefix";
    check_contains "mentions exact value" msg "leading or trailing whitespace"
  | Ok _ -> Alcotest.fail "padded manifest id_prefix should reject"
;;

let test_manifest_rejects_duplicate_root_field () =
  let json =
    `Assoc [ "schema_version", `Int 1; "models", `List []; "schema_version", `Int 1 ]
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "identifies duplicate" msg "duplicate field";
    check_contains "names duplicate" msg "schema_version"
  | Ok _ -> Alcotest.fail "duplicate manifest root field should reject"
;;

let test_manifest_rejects_duplicate_entry_field () =
  let json =
    `Assoc
      [ "schema_version", `Int 1
      ; ( "models"
        , `List
            [ `Assoc
                [ "id_prefix", `String "duplicate-entry"
                ; "supports_tools", `Bool true
                ; "supports_tools", `Bool false
                ]
            ] )
      ]
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "identifies duplicate" msg "duplicate field";
    check_contains "names duplicate" msg "supports_tools"
  | Ok _ -> Alcotest.fail "duplicate manifest entry field should reject"
;;

let test_manifest_rejects_wrong_type_base () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"bad-base","base":17}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions field" msg "base";
    check_contains "mentions expected type" msg "expected string"
  | Ok _ -> Alcotest.fail "wrong-type base should reject"
;;

let test_manifest_rejects_wrong_type_policy_string () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"bad-policy","thinking_control_format":false}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions field" msg "thinking_control_format";
    check_contains "mentions expected type" msg "expected string"
  | Ok _ -> Alcotest.fail "wrong-type thinking_control_format should reject"
;;

let test_manifest_accepts_ollama_think_policy_string () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"ollama-manifest","thinking_control_format":"ollama_think"}]}|}
  in
  match Capability_manifest.of_json json with
  | Ok [ entry ] ->
    let caps = Capabilities.apply_manifest_entry entry in
    check_thinking_control
      "manifest ollama_think"
      Capabilities.Ollama_think
      caps.thinking_control_format
  | Ok _ -> Alcotest.fail "expected one manifest entry"
  | Error msg -> Alcotest.failf "unexpected parse error: %s" msg
;;

let test_manifest_accepts_thinking_control_token () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"token-model","thinking_control_format":"chat_template_token","thinking_control_token":"<|custom_think|>"}]}|}
  in
  match Capability_manifest.of_json json with
  | Ok [ entry ] ->
    Alcotest.(check bool)
      "token carried by the constructor"
      true
      (entry.thinking_control_format
       = Some (Capabilities.Chat_template_token "<|custom_think|>"))
  | Ok _ -> Alcotest.fail "expected one manifest entry"
  | Error msg -> Alcotest.failf "unexpected parse error: %s" msg
;;

let test_manifest_rejects_tokenless_chat_template_token () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"tokenless-template-model","thinking_control_format":"chat_template_token"}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "names the offending id_prefix" msg "tokenless-template-model";
    check_contains "mentions the required token" msg "thinking_control_token"
  | Ok _ -> Alcotest.fail "chat_template_token without a token should fail closed"
;;

let test_manifest_rejects_blank_thinking_control_token () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"token-model","thinking_control_token":"   "}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions field" msg "thinking_control_token";
    check_contains "mentions blank rejection" msg "must not be empty"
  | Ok _ -> Alcotest.fail "blank thinking_control_token should reject"
;;

let test_manifest_rejects_padded_thinking_control_token () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"token-model","thinking_control_token":" <|custom_think|> "}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions field" msg "thinking_control_token";
    check_contains "mentions exact rejection" msg "leading or trailing whitespace"
  | Ok _ -> Alcotest.fail "padded thinking_control_token should reject"
;;

let test_manifest_accepts_thinking_object_adaptive_policy_string () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"adaptive-manifest","thinking_control_format":"thinking_object_adaptive"}]}|}
  in
  match Capability_manifest.of_json json with
  | Ok [ entry ] ->
    let caps = Capabilities.apply_manifest_entry entry in
    check_thinking_control
      "manifest thinking_object_adaptive"
      Capabilities.Thinking_object_adaptive
      caps.thinking_control_format
  | Ok _ -> Alcotest.fail "expected one manifest entry"
  | Error msg -> Alcotest.failf "unexpected parse error: %s" msg
;;

let test_manifest_accepts_reasoning_output_format () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"split-manifest","reasoning_output_format":"split_reasoning_fields"}]}|}
  in
  match Capability_manifest.of_json json with
  | Ok [ entry ] ->
    let caps = Capabilities.apply_manifest_entry entry in
    check
      bool
      "manifest split_reasoning_fields"
      true
      (caps.reasoning_output_format = Capabilities.Split_reasoning_fields)
  | Ok _ -> Alcotest.fail "expected one manifest entry"
  | Error msg -> Alcotest.failf "unexpected parse error: %s" msg
;;

let test_manifest_accepts_reasoning_streaming_format () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"stream-manifest","reasoning_streaming_format":"delta:reasoning"}]}|}
  in
  match Capability_manifest.of_json json with
  | Ok [ entry ] ->
    let caps = Capabilities.apply_manifest_entry entry in
    check
      bool
      "manifest delta reasoning stream"
      true
      (caps.reasoning_streaming_format = Capabilities.Delta_reasoning_field "reasoning")
  | Ok _ -> Alcotest.fail "expected one manifest entry"
  | Error msg -> Alcotest.failf "unexpected parse error: %s" msg
;;

let test_manifest_applies_ignored_sampling_parameters () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"sampling-manifest","ignored_sampling_parameters":["temperature","top_p"]}]}|}
  in
  match Capability_manifest.of_json json with
  | Ok [ entry ] ->
    let caps = Capabilities.apply_manifest_entry entry in
    check
      (list string)
      "ignored sampling parameters"
      [ "temperature"; "top_p" ]
      (List.map
         Capabilities.sampling_parameter_to_string
         caps.ignored_sampling_parameters)
  | Ok _ -> Alcotest.fail "expected one manifest entry"
  | Error msg -> Alcotest.failf "unexpected parse error: %s" msg
;;

let test_manifest_rejects_unknown_ignored_sampling_parameter () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"sampling-manifest","ignored_sampling_parameters":["temp"]}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg -> check_contains "mentions field" msg "ignored_sampling"
  | Ok _ -> Alcotest.fail "expected unknown ignored_sampling_parameters rejection"
;;

let test_manifest_rejects_unknown_preserve_thinking_control_format () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"bad-preserve","preserve_thinking_control_format":"memory_palace"}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg -> check_contains "mentions field" msg "preserve_thinking_control_format"
  | Ok _ -> Alcotest.fail "unknown preserve_thinking_control_format should reject"
;;

let test_manifest_rejects_unknown_reasoning_output_format () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"bad-output","reasoning_output_format":"split_thoughts"}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions field" msg "reasoning_output_format";
    check_contains "mentions value" msg "split_thoughts"
  | Ok _ -> Alcotest.fail "unknown reasoning_output_format should reject"
;;

let test_manifest_rejects_unknown_reasoning_streaming_format () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"bad-stream","reasoning_streaming_format":"delta:"}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions field" msg "reasoning_streaming_format";
    check_contains "mentions value" msg "delta:"
  | Ok _ -> Alcotest.fail "unknown reasoning_streaming_format should reject"
;;

let test_manifest_rejects_unknown_reasoning_replay () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"bad-replay","reasoning_replay":"preserve-allways"}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions field" msg "reasoning_replay";
    check_contains "mentions value" msg "preserve-allways"
  | Ok _ -> Alcotest.fail "unknown reasoning_replay should reject"
;;

(* [reasoning_visibility] was retired with the #2236 CoT-loop fix: the parsed
   override only ever drove the reasoning->Text promotion that re-injected
   reasoning as answer content. The manifest key is now unknown, so a stale
   config is rejected fail-closed (via [reject_unknown_keys]) rather than
   silently ignored. *)
let test_manifest_rejects_retired_reasoning_visibility_key () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"retired-visibility","reasoning_visibility":"visible_text"}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "names the retired key" msg "reasoning_visibility";
    check_contains "rejected as unknown field" msg "unknown field"
  | Ok _ -> Alcotest.fail "retired reasoning_visibility key should reject"
;;

let test_manifest_applies_accepted_reasoning_efforts () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"effort-ok","accepted_reasoning_efforts":["none","low","high"]}]}|}
  in
  match Capability_manifest.of_json json with
  | Ok [ entry ] ->
    Alcotest.(check (option (list string)))
      "accepted subset"
      (Some [ "none"; "low"; "high" ])
      (Option.map
         (List.map Reasoning_effort.to_string)
         (Capabilities.apply_manifest_entry entry).accepted_reasoning_efforts)
  | Ok _ -> Alcotest.fail "expected one manifest entry"
  | Error msg -> Alcotest.failf "unexpected parse error: %s" msg
;;

let test_manifest_rejects_unknown_accepted_reasoning_effort () =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"effort-bad","accepted_reasoning_efforts":["turbo"]}]}|}
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions field" msg "accepted_reasoning_efforts";
    check_contains "mentions value" msg "turbo"
  | Ok _ -> Alcotest.fail "unknown accepted reasoning effort should reject"
;;

let test_manifest_intlit_in_range_accepted () =
  (* Exercise the exact upper native-int boundary through Yojson's [Intlit]
     constructor rather than relying on parser/platform representation. *)
  let json =
    `Assoc
      [ "schema_version", `Int 1
      ; ( "models"
        , `List
            [ `Assoc
                [ "id_prefix", `String "intlit-ok"
                ; "max_context_tokens", `Intlit (string_of_int max_int)
                ]
            ] )
      ]
  in
  match Capability_manifest.of_json json with
  | Ok [ entry ] ->
    check (option int) "max_int intlit accepted" (Some max_int) entry.max_context_tokens
  | Ok _ -> Alcotest.fail "expected one manifest entry"
  | Error msg -> Alcotest.failf "unexpected parse error: %s" msg
;;

let test_manifest_intlit_out_of_range_rejects () =
  let first_out_of_range = Int64.add (Int64.of_int max_int) 1L |> Int64.to_string in
  let json =
    `Assoc
      [ "schema_version", `Int 1
      ; ( "models"
        , `List
            [ `Assoc
                [ "id_prefix", `String "intlit-overflow"
                ; "max_context_tokens", `Intlit first_out_of_range
                ]
            ] )
      ]
  in
  match Capability_manifest.of_json json with
  | Error msg ->
    check_contains "mentions field" msg "max_context_tokens";
    check_contains "mentions exact literal" msg first_out_of_range;
    check_contains "mentions overflow" msg "out of native int range"
  | Ok _ -> Alcotest.fail "out-of-range manifest int literal should reject"
;;

let test_manifest_load_file_missing_returns_error () =
  let path = Filename.temp_file "oas-capability-manifest-missing" ".json" in
  Sys.remove path;
  match Capability_manifest.load_file path with
  | Error msg ->
    check_contains "mentions cannot read" msg "cannot read capability manifest";
    check_contains "mentions path" msg path
  | Ok _ -> Alcotest.fail "expected missing manifest path to fail"
;;

let test_manifest_load_file_malformed_returns_error () =
  with_temp_manifest {|{"schema_version":1,"models":[|} (fun path ->
    match Capability_manifest.load_file path with
    | Error msg ->
      check_contains "mentions JSON parse" msg "capability manifest JSON parse error";
      check_contains "mentions path" msg path
    | Ok _ -> Alcotest.fail "expected malformed manifest JSON to fail")
;;

let test_model_catalog_rejects_unknown_reasoning_replay () =
  with_temp_model_catalog
    {|
[[models]]
id_prefix = "bad-replay"
reasoning_replay = "preserve-allways"
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg ->
         check_contains "mentions field" msg "reasoning_replay";
         check_contains "mentions value" msg "preserve-allways"
       | Ok _ -> Alcotest.fail "unknown model catalog reasoning_replay should reject")
;;

let test_model_catalog_rejects_wrong_type_policy_string () =
  with_temp_model_catalog
    {|
[[models]]
id_prefix = "bad-policy-type"
reasoning_replay = true
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg ->
         check_contains "mentions field" msg "reasoning_replay";
         check_contains "mentions expected type" msg "expected string"
       | Ok _ -> Alcotest.fail "wrong-type model catalog reasoning_replay should reject")
;;

let test_model_catalog_rejects_unknown_policy_strings () =
  let cases =
    [ "thinking_control_format", "mind_palace"
    ; "preserve_thinking_control_format", "memory_palace"
    ; "reasoning_output_format", "split_thoughts"
    ; "reasoning_streaming_format", "delta:"
    ; "modality_priority", "image_only"
    ]
  in
  List.iter
    (fun (field, value) ->
       with_temp_model_catalog
         (Printf.sprintf
            {|
[[models]]
id_prefix = "bad-%s"
%s = "%s"
|}
            field
            field
            value)
         (fun path ->
            match Model_catalog.load_file path with
            | Error msg ->
              check_contains (field ^ " mentions field") msg field;
              check_contains (field ^ " mentions value") msg value
            | Ok _ -> Alcotest.failf "unknown model catalog %s should reject" field))
    cases
;;

let test_model_catalog_rejects_wrong_type_base_label () =
  with_temp_model_catalog
    {|
[[models]]
id_prefix = "bad-base-type"
base = 17
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg ->
         check_contains "mentions base" msg "base";
         check_contains "mentions expected type" msg "expected string"
       | Ok _ -> Alcotest.fail "wrong-type model catalog base should reject")
;;

let check_model_catalog_rejects_typed_field ~field ~value ~expected_type =
  with_temp_model_catalog
    (Printf.sprintf
       {|
[[models]]
id_prefix = "typed-field"
%s = %s
|}
       field
       value)
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg ->
         check_contains (field ^ " mentions field") msg field;
         check_contains (field ^ " mentions expected type") msg expected_type
       | Ok _ -> Alcotest.failf "wrong-type model catalog %s should reject" field)
;;

let test_model_catalog_rejects_wrong_type_bool () =
  check_model_catalog_rejects_typed_field
    ~field:"supports_tools"
    ~value:{|"true"|}
    ~expected_type:"expected bool"
;;

let test_model_catalog_rejects_wrong_type_int () =
  check_model_catalog_rejects_typed_field
    ~field:"max_context_tokens"
    ~value:{|"131072"|}
    ~expected_type:"expected integer"
;;

let test_model_catalog_rejects_wrong_type_float () =
  check_model_catalog_rejects_typed_field
    ~field:"input_per_million"
    ~value:{|"1.0"|}
    ~expected_type:"expected float"
;;

let test_model_catalog_rejects_wrong_type_string_list () =
  check_model_catalog_rejects_typed_field
    ~field:"accepted_reasoning_efforts"
    ~value:{|"low"|}
    ~expected_type:"expected string array"
;;

let test_model_catalog_rejects_empty_id_prefix () =
  with_temp_model_catalog
    {|
[[models]]
id_prefix = ""
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg ->
         check_contains "mentions id_prefix" msg "id_prefix";
         check_contains "mentions empty" msg "must not be empty"
       | Ok _ -> Alcotest.fail "empty model catalog id_prefix should reject")
;;

let test_model_catalog_rejects_padded_id_prefix () =
  with_temp_model_catalog
    {|
[[models]]
id_prefix = " padded-model "
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg ->
         check_contains "mentions id_prefix" msg "id_prefix";
         check_contains "mentions exact value" msg "leading or trailing whitespace"
       | Ok _ -> Alcotest.fail "padded model catalog id_prefix should reject")
;;

let test_model_catalog_rejects_empty_provider_name () =
  with_temp_model_catalog
    {|
[[models]]
id_prefix = "bad-provider-name"
provider_name = "   "
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg ->
         check_contains "mentions provider_name" msg "provider_name";
         check_contains "mentions empty" msg "must not be empty"
       | Ok _ -> Alcotest.fail "empty model catalog provider_name should reject")
;;

let test_model_catalog_rejects_empty_thinking_control_token () =
  with_temp_model_catalog
    {|
[[models]]
id_prefix = "bad-thinking-token"
thinking_control_token = "   "
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg ->
         check_contains "mentions thinking_control_token" msg "thinking_control_token";
         check_contains "mentions empty" msg "must not be empty"
       | Ok _ -> Alcotest.fail "empty model catalog thinking_control_token should reject")
;;

let test_model_catalog_rejects_padded_thinking_control_token () =
  with_temp_model_catalog
    {|
[[models]]
id_prefix = "bad-thinking-token"
thinking_control_token = " <|custom_think|> "
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg ->
         check_contains "mentions thinking_control_token" msg "thinking_control_token";
         check_contains "mentions exact" msg "leading or trailing whitespace"
       | Ok _ -> Alcotest.fail "padded model catalog thinking_control_token should reject")
;;

let test_model_catalog_rejects_unknown_accepted_reasoning_effort () =
  with_temp_model_catalog
    {|
[[models]]
id_prefix = "bad-effort"
accepted_reasoning_efforts = ["low", "turbo"]
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg ->
         check_contains "mentions field" msg "accepted_reasoning_efforts";
         check_contains "mentions value" msg "turbo"
       | Ok _ ->
         Alcotest.fail "unknown model catalog accepted_reasoning_effort should reject")
;;

let test_manifest_and_catalog_common_override_parity () =
  let manifest_caps =
    let json =
      Yojson.Safe.from_string
        {|{
          "schema_version": 1,
          "models": [{
            "id_prefix": "parity-model",
            "max_context_tokens": 123456,
            "max_output_tokens": 7890,
            "supports_tools": true,
            "supports_tool_choice": true,
            "supports_required_tool_choice": true,
            "supports_named_tool_choice": true,
            "supports_parallel_tool_calls": true,
            "assistant_tool_content_format": "empty_string",
            "supports_reasoning": true,
            "supports_extended_thinking": true,
            "supports_reasoning_budget": true,
            "accepted_reasoning_efforts": ["low", "medium"],
            "supports_response_format_json": true,
            "supports_structured_output": true,
            "supports_multimodal_inputs": true,
            "supports_image_input": true,
            "supports_audio_input": true,
            "supports_video_input": true,
            "supports_native_streaming": true,
            "supports_system_prompt": false,
            "supports_caching": true,
            "supports_prompt_caching": true,
            "supports_top_k": true,
            "supports_min_p": true,
            "supports_seed": true,
            "supports_computer_use": true,
            "supports_code_execution": true,
            "thinking_control_format": "chat_template_kwargs",
            "preserve_thinking_control_format": "chat_template_kwargs_preserve_thinking",
            "reasoning_output_format": "split_reasoning_fields",
            "reasoning_streaming_format": "delta:reasoning_content",
            "reasoning_replay": "preserve_always"
          }]
        }|}
    in
    match Capability_manifest.of_json json with
    | Ok [ entry ] -> Capabilities.apply_manifest_entry entry
    | Ok _ -> Alcotest.fail "expected one capability manifest entry"
    | Error msg -> Alcotest.failf "manifest parse failed: %s" msg
  in
  with_temp_model_catalog
    {|
[[models]]
id_prefix = "parity-model"
max_context_tokens = 123456
max_output_tokens = 7890
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true
supports_parallel_tool_calls = true
assistant_tool_content_format = "empty_string"
supports_reasoning = true
supports_extended_thinking = true
supports_reasoning_budget = true
accepted_reasoning_efforts = ["low", "medium"]
supports_response_format_json = true
supports_structured_output = true
supports_multimodal_inputs = true
supports_image_input = true
supports_audio_input = true
supports_video_input = true
supports_native_streaming = true
supports_system_prompt = false
supports_caching = true
supports_prompt_caching = true
supports_top_k = true
supports_min_p = true
supports_seed = true
supports_computer_use = true
supports_code_execution = true
thinking_control_format = "chat_template_kwargs"
preserve_thinking_control_format = "chat_template_kwargs_preserve_thinking"
reasoning_output_format = "split_reasoning_fields"
reasoning_streaming_format = "delta:reasoning_content"
reasoning_replay = "preserve_always"
|}
    (fun path ->
       match Model_catalog.load_file path with
       | Error msg -> Alcotest.failf "model catalog parse failed: %s" msg
       | Ok catalog ->
         let previous_catalog = Model_catalog.global () in
         let restore () =
           match previous_catalog with
           | Some catalog -> Model_catalog.set_global catalog
           | None -> Model_catalog.clear_global ()
         in
         Fun.protect ~finally:restore (fun () ->
           Model_catalog.set_global catalog;
           let catalog_caps =
             match Capabilities.for_model_id_catalog "parity-model-v1" with
             | Some caps -> caps
             | None -> Alcotest.fail "expected parity model catalog lookup"
           in
           check
             bool
             "manifest/catalog common declarative overrides produce identical \
              capabilities"
             true
             (manifest_caps = catalog_caps)))
;;

(* ── DashScope preset ────────────────────────────────── *)

let test_dashscope_capabilities () =
  let c = Capabilities.dashscope_capabilities in
  (* DashScope (DashScope) exposes response_format.json_schema on its OpenAI-compatible
     endpoint; native schema output is supported. Ref: DashScope structured output
     guide — checked 2026-05-05. *)
  check bool "has structured output" true c.supports_structured_output;
  check bool "has json mode" true c.supports_response_format_json;
  check bool "has tools" true c.supports_tools;
  check bool "has tool_choice" true c.supports_tool_choice;
  check bool "has reasoning" true c.supports_reasoning;
  check_thinking_control
    "enable_thinking control"
    Capabilities.Enable_thinking
    c.thinking_control_format;
  check bool "has min_p" true c.supports_min_p
;;

(* ── Kimi tool_choice preset ─────────────────────────── *)

let test_kimi_tool_choice_capabilities () =
  let c = Capabilities.kimi_capabilities in
  (* Kimi's chat API documents [tools] but not [tool_choice] in any request
     schema, and tool_choice=required is unsupported (developers prompt the model
     to force a tool). Plain [auto] passes through the OpenAI-compatible endpoint
     so [supports_tool_choice] stays true, but a forced named tool_choice has no
     faithful wire representation — Kimi mirrors GLM: tools supported, named
     forced tool_choice rejected (typed) rather than serialized. Ref checked
     2026-06-30: platform.kimi.ai/docs/api/chat, platform.kimi.ai/docs/api/tool-use. *)
  check bool "has tools" true c.supports_tools;
  check bool "accepts auto tool_choice" true c.supports_tool_choice;
  check bool "rejects named forced tool_choice" false c.supports_named_tool_choice
;;

let test_mimo_provider_capabilities () =
  let c = Capabilities.mimo_capabilities in
  check (option int) "context 1M" (Some 1_000_000) c.max_context_tokens;
  check (option int) "output 128K" (Some 128_000) c.max_output_tokens;
  check bool "has reasoning" true c.supports_reasoning;
  check_thinking_control
    "uses thinking object only"
    Capabilities.Thinking_object_only
    c.thinking_control_format;
  check bool "has tools" true c.supports_tools;
  check bool "has JSON mode" true c.supports_response_format_json;
  check bool "does not claim json_schema" false c.supports_structured_output;
  check
    bool
    "preserves reasoning on tool turns only"
    true
    (c.reasoning_replay_override = Capabilities.Force_drop_without_tool_preserve_with_tool);
  match Capabilities.capabilities_for_provider_label "mimo" with
  | Some via_label ->
    check bool "provider label resolves MiMo preset" true (via_label == c)
  | None -> fail "mimo provider label should resolve"
;;

let test_openai_compat_reasoning_records_have_explicit_control () =
  let cases =
    [ "openai_chat_extended", Some Capabilities.openai_compat_chat_extended_capabilities
    ; "kimi", Some Capabilities.kimi_capabilities
    ; "mimo", Some Capabilities.mimo_capabilities
    ; "dashscope", Some Capabilities.dashscope_capabilities
    ; ( "mimo-v2.5-pro"
      , Capabilities.for_provider_model_id
          ~allow_bare_fallback:false
          ~provider_label:"mimo"
          ~model_id:"mimo-v2.5-pro" )
    ; "dashscope-3.5", Capabilities.for_model_id "dashscope-3.5-35b-a3b"
    ; ( "deepseek-v4-flash"
      , Capabilities.for_provider_model_id
          ~allow_bare_fallback:false
          ~provider_label:"deepseek"
          ~model_id:"deepseek-v4-flash" )
    ; "nvidia-ultra", Capabilities.for_model_id "nvidia-ultra-253b"
    ]
  in
  List.iter
    (fun (label, caps) ->
       match caps with
       | None -> fail (Printf.sprintf "%s should resolve capabilities" label)
       | Some (c : Capabilities.capabilities) ->
         check bool (label ^ " supports reasoning") true c.supports_reasoning;
         check
           bool
           (label ^ " has explicit reasoning control or preserve policy")
           true
           (c.thinking_control_format <> Capabilities.No_thinking_control
            || c.preserve_thinking_control_format
               <> Capabilities.No_preserve_thinking_control))
    cases
;;

(* ── Prefix ordering invariant (M01) ────────────────────── *)

(* Provider-independent catalog lookup selects the longest exact declared
   prefix. Whenever prefix A is a string prefix of prefix B (every model-id
   starting with B also starts with A), B must win; otherwise A captures the
   request and silently returns the wrong capabilities (e.g. tool_choice sent
   to a model that does not support it → 400 error, anti-pattern M01).

   Each case below uses a concrete model-id that begins with the *longer*
   (more-specific) prefix — and therefore also with the *shorter* one — and
   asserts the capability fingerprint that is unique to the longer branch.
   If the two branches were swapped the assertion would fail. Provider-scoped
   rows are exact identities and therefore do not participate in this test. *)
let test_prefix_ordering_invariant () =
  (* Each entry: (route, model_id, label, discriminating_predicate).
     The predicate is true only when the more-specific (longer-prefix)
     branch wins. *)
  let cases =
    [ (* glm-5v-turbo must precede glm-5 (inside broad branch).
         Discriminator: supports_image_input (5v-turbo) vs not (broad glm-5). *)
      ( Direct_model
      , "glm-5v-turbo-x"
      , "glm-5v-turbo must precede broad glm-5"
      , fun (c : Capabilities.capabilities) ->
          c.supports_image_input && c.max_output_tokens = Some 128_000 )
    ; (* glm-5-code must precede glm-5 (inside broad branch).
         Discriminator: 128K context (code branch) vs 200K (broad glm-5). *)
      ( Direct_model
      , "glm-5-code-x"
      , "glm-5-code must precede broad glm-5"
      , fun (c : Capabilities.capabilities) ->
          c.max_context_tokens = Some 128_000 && c.supports_extended_thinking )
    ; (* glm-4.6v must precede glm-4.6 (inside broad branch) *)
      ( Direct_model
      , "glm-4.6v-x"
      , "glm-4.6v must precede broad glm-4.6"
      , fun (c : Capabilities.capabilities) ->
          c.supports_image_input
          && c.supports_reasoning
          && c.max_output_tokens = Some 32_768 )
    ; (* glm-4.5v must precede glm-4.5 (inside broad branch) *)
      ( Direct_model
      , "glm-4.5v-x"
      , "glm-4.5v must precede broad glm-4.5"
      , fun (c : Capabilities.capabilities) ->
          c.supports_image_input
          && c.supports_reasoning
          && c.max_output_tokens = Some 16_384 )
    ; (* broad glm-4.5 branch must precede glm-4.
         Discriminator: supports_reasoning + 96K output (broad) vs neither (glm-4). *)
      ( Direct_model
      , "glm-4.5-latest"
      , "broad glm-4.5 branch must precede glm-4"
      , fun (c : Capabilities.capabilities) ->
          c.supports_reasoning && c.max_output_tokens = Some 96_000 )
    ]
  in
  List.iter
    (fun (route, model_id, label, ok) ->
       match frontier_capabilities route model_id with
       | None ->
         fail
           (Printf.sprintf
              "prefix ordering [%s]: for_model_id %S returned None"
              label
              model_id)
       | Some c -> check bool (Printf.sprintf "prefix ordering: %s" label) true (ok c))
    cases
;;

(* ── Suite ───────────────────────────────────────────── *)

let () =
  isolate_ambient_runtime_sources ();
  run
    "Capabilities"
    [ ( "defaults"
      , [ test_case "no limits" `Quick test_default_no_limits
        ; test_case "new fields false" `Quick test_default_new_fields_false
        ] )
    ; ( "presets"
      , [ test_case "anthropic" `Quick test_anthropic_capabilities
        ; test_case "openai" `Quick test_openai_capabilities
        ; test_case "openai extended" `Quick test_openai_extended
        ; test_case "dashscope" `Quick test_dashscope_capabilities
        ; test_case "kimi tool_choice" `Quick test_kimi_tool_choice_capabilities
        ; test_case "mimo provider" `Quick test_mimo_provider_capabilities
        ; test_case
            "openai compat reasoning records have explicit control"
            `Quick
            test_openai_compat_reasoning_records_have_explicit_control
        ] )
    ; ( "model_lookup"
      , [ test_case "claude opus" `Quick test_lookup_claude_opus
        ; test_case "claude sonnet" `Quick test_lookup_claude_sonnet
        ; test_case "gpt-5" `Quick test_lookup_gpt5
        ; test_case "gemini" `Quick test_lookup_gemini
        ; test_case
            "gemini catalog drives 1M ctx capabilities"
            `Quick
            test_gemini_catalog_drives_capabilities
        ; test_case
            "kimi-k2 native cloud suffix vs Ollama Cloud"
            `Quick
            test_lookup_kimi_k2_native_cloud_suffix
        ; test_case "dashscope" `Quick test_lookup_provider_m
        ; test_case
            "dashscope gguf name"
            `Quick
            test_lookup_provider_m_dashscope_gguf_name
        ; test_case
            "vllm-qwen3-mtp explicit provider"
            `Quick
            test_lookup_provider_m_qwen3_mtp_explicit_provider
        ; test_case
            "runpod rtxa6000 gemma4 coder catalog"
            `Quick
            test_lookup_runpod_rtxa6000_gemma4_coder_catalog
        ; test_case
            "local ollama gemma4 e2b qat catalog"
            `Quick
            test_lookup_local_ollama_gemma4_e2b_qat_catalog
        ; test_case "deepseek v4 flash" `Quick test_lookup_deepseek_v4_flash
        ; test_case "deepseek v4 pro" `Quick test_lookup_deepseek_v4_pro
        ; test_case
            "minimax m3 official chat dialect"
            `Quick
            test_lookup_minimax_m3_official_chat_dialect
        ; test_case "grok 4.3 1M context" `Quick test_lookup_grok
        ; test_case "glm-5 text only" `Quick test_lookup_glm5_text_only
        ; test_case "glm-5v vision" `Quick test_lookup_glm5v_vision
        ; test_case "glm-4.6v vision" `Quick test_lookup_glm46v_vision
        ; test_case "glm-ocr vision" `Quick test_lookup_glm_ocr
        ; test_case
            "ollama cloud current catalog"
            `Quick
            test_ollama_cloud_current_catalog_resolves
        ; test_case
            "ollama cloud v1 vendor models resolve exact capabilities"
            `Quick
            test_ollama_cloud_v1_vendor_models_resolve_exact_capabilities
        ; test_case
            "ollama cloud grouped rows keep required axes"
            `Quick
            test_ollama_cloud_grouped_rows_have_required_axes
        ; test_case
            "ollama cloud grouped rows follow exact-output contract"
            `Quick
            test_ollama_cloud_grouped_rows_follow_exact_output_contract
        ; test_case
            "ollama cloud Kimi preserves historical reasoning"
            `Quick
            test_ollama_cloud_kimi_preserves_historical_reasoning
        ; test_case
            "ollama cloud structured output follows provider contract"
            `Quick
            test_ollama_cloud_structured_output_is_disabled_by_provider_contract
        ; test_case
            "ollama cloud preserves shared bare families"
            `Quick
            test_ollama_cloud_provider_qualified_preserves_shared_bare_family
        ; test_case
            "frontier grouped tool/thinking/provider contracts"
            `Quick
            test_frontier_grouped_tool_thinking_provider_contracts
        ; test_case "mimo-v2.5-pro" `Quick test_lookup_mimo_v25_pro
        ; test_case "mimo-v2.5 multimodal" `Quick test_lookup_mimo_v25_multimodal
        ; test_case "qwen3 thinking control" `Quick test_lookup_qwen3_thinking_control
        ; test_case "unknown" `Quick test_lookup_unknown
        ; test_case "case insensitive" `Quick test_lookup_case_insensitive
        ; test_case
            "provider-scoped identity is exact"
            `Quick
            test_provider_scoped_catalog_identity_is_exact
        ] )
    ; "merge", [ test_case "with_context_size" `Quick test_with_context_size ]
    ; ( "manifest"
      , [ test_case
            "explicit manifest precedes catalog fallback"
            `Quick
            test_explicit_manifest_lookup_precedes_catalog_fallback
        ; test_case
            "explicit manifest falls back to catalog"
            `Quick
            test_explicit_manifest_lookup_falls_back_to_catalog
        ; test_case "unknown model → None" `Quick test_manifest_unknown_model_still_none
        ; test_case "base openai_chat" `Quick test_manifest_base_label_openai_chat
        ; test_case "base anthropic" `Quick test_manifest_base_label_anthropic
        ; test_case "base absent = default" `Quick test_manifest_base_absent_uses_default
        ; test_case
            "base label constructor rejects unknown"
            `Quick
            test_manifest_base_label_constructor_rejects_unknown
        ; test_case
            "base label constructor canonicalizes"
            `Quick
            test_manifest_base_label_constructor_canonicalizes
        ; test_case
            "example base labels are canonical"
            `Quick
            test_example_manifest_base_labels_are_canonical
        ; test_case
            "explicit manifest prefix precedes catalog fallback"
            `Quick
            test_explicit_manifest_prefix_precedes_catalog_fallback
        ; test_case
            "global catalog precedes global manifest"
            `Quick
            test_global_catalog_precedes_global_manifest
        ; test_case
            "all-None entry matches base"
            `Quick
            test_apply_manifest_entry_all_none_uses_base
        ; test_case "wrong-type bool rejects" `Quick test_manifest_rejects_wrong_type_bool
        ; test_case "wrong-type int rejects" `Quick test_manifest_rejects_wrong_type_int
        ; test_case
            "wrong-type string list rejects"
            `Quick
            test_manifest_rejects_wrong_type_string_list
        ; test_case "empty id_prefix rejects" `Quick test_manifest_rejects_empty_id_prefix
        ; test_case
            "padded id_prefix rejects"
            `Quick
            test_manifest_rejects_padded_id_prefix
        ; test_case
            "duplicate root field rejects"
            `Quick
            test_manifest_rejects_duplicate_root_field
        ; test_case
            "duplicate entry field rejects"
            `Quick
            test_manifest_rejects_duplicate_entry_field
        ; test_case "wrong-type base rejects" `Quick test_manifest_rejects_wrong_type_base
        ; test_case
            "wrong-type policy string rejects"
            `Quick
            test_manifest_rejects_wrong_type_policy_string
        ; test_case
            "ollama_think policy string accepted"
            `Quick
            test_manifest_accepts_ollama_think_policy_string
        ; test_case
            "thinking_control_token accepted"
            `Quick
            test_manifest_accepts_thinking_control_token
        ; test_case
            "tokenless chat_template_token rejects"
            `Quick
            test_manifest_rejects_tokenless_chat_template_token
        ; test_case
            "blank thinking_control_token rejects"
            `Quick
            test_manifest_rejects_blank_thinking_control_token
        ; test_case
            "padded thinking_control_token rejects"
            `Quick
            test_manifest_rejects_padded_thinking_control_token
        ; test_case
            "thinking_object_adaptive policy string accepted"
            `Quick
            test_manifest_accepts_thinking_object_adaptive_policy_string
        ; test_case
            "reasoning_output_format accepted"
            `Quick
            test_manifest_accepts_reasoning_output_format
        ; test_case
            "reasoning_streaming_format accepted"
            `Quick
            test_manifest_accepts_reasoning_streaming_format
        ; test_case
            "ignored sampling parameters applied"
            `Quick
            test_manifest_applies_ignored_sampling_parameters
        ; test_case
            "unknown ignored sampling parameter rejects"
            `Quick
            test_manifest_rejects_unknown_ignored_sampling_parameter
        ; test_case
            "unknown preserve_thinking_control_format rejects"
            `Quick
            test_manifest_rejects_unknown_preserve_thinking_control_format
        ; test_case
            "unknown reasoning_output_format rejects"
            `Quick
            test_manifest_rejects_unknown_reasoning_output_format
        ; test_case
            "unknown reasoning_streaming_format rejects"
            `Quick
            test_manifest_rejects_unknown_reasoning_streaming_format
        ; test_case
            "unknown reasoning_replay rejects"
            `Quick
            test_manifest_rejects_unknown_reasoning_replay
        ; test_case
            "retired reasoning_visibility key rejects"
            `Quick
            test_manifest_rejects_retired_reasoning_visibility_key
        ; test_case
            "accepted reasoning efforts applied"
            `Quick
            test_manifest_applies_accepted_reasoning_efforts
        ; test_case
            "unknown accepted reasoning effort rejects"
            `Quick
            test_manifest_rejects_unknown_accepted_reasoning_effort
        ; test_case
            "intlit in range accepted"
            `Quick
            test_manifest_intlit_in_range_accepted
        ; test_case
            "intlit out of range rejects"
            `Quick
            test_manifest_intlit_out_of_range_rejects
        ; test_case
            "missing manifest file errors"
            `Quick
            test_manifest_load_file_missing_returns_error
        ; test_case
            "malformed manifest file errors"
            `Quick
            test_manifest_load_file_malformed_returns_error
        ; test_case
            "model catalog rejects unknown reasoning_replay"
            `Quick
            test_model_catalog_rejects_unknown_reasoning_replay
        ; test_case
            "model catalog rejects wrong-type policy string"
            `Quick
            test_model_catalog_rejects_wrong_type_policy_string
        ; test_case
            "model catalog rejects unknown policy strings"
            `Quick
            test_model_catalog_rejects_unknown_policy_strings
        ; test_case
            "model catalog rejects wrong-type base"
            `Quick
            test_model_catalog_rejects_wrong_type_base_label
        ; test_case
            "model catalog rejects wrong-type bool"
            `Quick
            test_model_catalog_rejects_wrong_type_bool
        ; test_case
            "model catalog rejects wrong-type int"
            `Quick
            test_model_catalog_rejects_wrong_type_int
        ; test_case
            "model catalog rejects wrong-type float"
            `Quick
            test_model_catalog_rejects_wrong_type_float
        ; test_case
            "model catalog rejects wrong-type string list"
            `Quick
            test_model_catalog_rejects_wrong_type_string_list
        ; test_case
            "model catalog rejects empty id_prefix"
            `Quick
            test_model_catalog_rejects_empty_id_prefix
        ; test_case
            "model catalog rejects padded id_prefix"
            `Quick
            test_model_catalog_rejects_padded_id_prefix
        ; test_case
            "model catalog rejects empty provider_name"
            `Quick
            test_model_catalog_rejects_empty_provider_name
        ; test_case
            "model catalog rejects empty thinking_control_token"
            `Quick
            test_model_catalog_rejects_empty_thinking_control_token
        ; test_case
            "model catalog rejects padded thinking_control_token"
            `Quick
            test_model_catalog_rejects_padded_thinking_control_token
        ; test_case
            "model catalog rejects unknown accepted reasoning effort"
            `Quick
            test_model_catalog_rejects_unknown_accepted_reasoning_effort
        ; test_case
            "manifest catalog common override parity"
            `Quick
            test_manifest_and_catalog_common_override_parity
        ] )
    ; ( "prefix_ordering"
      , [ test_case
            "shadow pairs all resolve to specific branch (M01)"
            `Quick
            test_prefix_ordering_invariant
        ] )
    ]
;;
