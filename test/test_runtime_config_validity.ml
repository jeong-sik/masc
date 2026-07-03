open Alcotest
open Masc

let empty_env _name = None

let parse_or_fail content =
  match Keeper_toml_loader.parse_toml content with
  | Ok doc -> doc
  | Error msg -> failf "TOML parse failed: %s" msg

let rec repo_root_from dir =
  let dune_project = Filename.concat dir "dune-project" in
  if Sys.file_exists dune_project then dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then
      failf "unable to locate repo root from cwd=%s" (Sys.getcwd ())
    else repo_root_from parent

let repo_root () = repo_root_from (Sys.getcwd ())

type ollama_cloud_case =
  { runtime_id : string
  ; api_name : string
  ; context : int
  ; tools : bool
  ; thinking : bool
  ; vision : bool
  }

let ollama_cloud_seed_cases =
  [ { runtime_id = "ollama_cloud.ollama-cloud-deepseek-v3-1-671b"
    ; api_name = "deepseek-v3.1:671b"
    ; context = 163840
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-deepseek-v3-2"
    ; api_name = "deepseek-v3.2"
    ; context = 163840
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-deepseek-v4-flash"
    ; api_name = "deepseek-v4-flash"
    ; context = 1048576
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-deepseek-v4-pro"
    ; api_name = "deepseek-v4-pro"
    ; context = 524288
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-devstral-2-123b"
    ; api_name = "devstral-2:123b"
    ; context = 262144
    ; tools = true
    ; thinking = false
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-devstral-small-2-24b"
    ; api_name = "devstral-small-2:24b"
    ; context = 262144
    ; tools = true
    ; thinking = false
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-gemini-3-flash-preview"
    ; api_name = "gemini-3-flash-preview"
    ; context = 1048576
    ; tools = true
    ; thinking = true
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-gemma3-4b"
    ; api_name = "gemma3:4b"
    ; context = 131072
    ; tools = false
    ; thinking = false
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-gemma3-12b"
    ; api_name = "gemma3:12b"
    ; context = 131072
    ; tools = false
    ; thinking = false
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-gemma3-27b"
    ; api_name = "gemma3:27b"
    ; context = 131072
    ; tools = false
    ; thinking = false
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-gemma4-31b"
    ; api_name = "gemma4:31b"
    ; context = 262144
    ; tools = true
    ; thinking = true
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-glm-4-7"
    ; api_name = "glm-4.7"
    ; context = 202752
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-glm-5"
    ; api_name = "glm-5"
    ; context = 202752
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-glm-5-1"
    ; api_name = "glm-5.1"
    ; context = 202752
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-glm-5-2"
    ; api_name = "glm-5.2"
    ; context = 1000000
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-gpt-oss-20b"
    ; api_name = "gpt-oss:20b"
    ; context = 131072
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-gpt-oss-120b"
    ; api_name = "gpt-oss:120b"
    ; context = 131072
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-kimi-k2-5"
    ; api_name = "kimi-k2.5"
    ; context = 262144
    ; tools = true
    ; thinking = true
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-kimi-k2-6"
    ; api_name = "kimi-k2.6"
    ; context = 262144
    ; tools = true
    ; thinking = true
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-kimi-k2-7-code"
    ; api_name = "kimi-k2.7-code"
    ; context = 262144
    ; tools = true
    ; thinking = true
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-minimax-m2-1"
    ; api_name = "minimax-m2.1"
    ; context = 204800
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-minimax-m2-5"
    ; api_name = "minimax-m2.5"
    ; context = 196608
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-minimax-m2-7"
    ; api_name = "minimax-m2.7"
    ; context = 196608
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-minimax-m3"
    ; api_name = "minimax-m3"
    ; context = 524288
    ; tools = true
    ; thinking = true
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-ministral-3-3b"
    ; api_name = "ministral-3:3b"
    ; context = 262144
    ; tools = true
    ; thinking = false
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-ministral-3-8b"
    ; api_name = "ministral-3:8b"
    ; context = 262144
    ; tools = true
    ; thinking = false
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-ministral-3-14b"
    ; api_name = "ministral-3:14b"
    ; context = 262144
    ; tools = true
    ; thinking = false
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-mistral-large-3-675b"
    ; api_name = "mistral-large-3:675b"
    ; context = 262144
    ; tools = true
    ; thinking = false
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-nemotron-3-nano-30b"
    ; api_name = "nemotron-3-nano:30b"
    ; context = 262144
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-nemotron-3-super"
    ; api_name = "nemotron-3-super"
    ; context = 262144
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-nemotron-3-ultra"
    ; api_name = "nemotron-3-ultra"
    ; context = 262144
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-qwen3-coder-480b"
    ; api_name = "qwen3-coder:480b"
    ; context = 262144
    ; tools = true
    ; thinking = false
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-qwen3-coder-next"
    ; api_name = "qwen3-coder-next"
    ; context = 262144
    ; tools = true
    ; thinking = false
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-qwen3-5-397b"
    ; api_name = "qwen3.5:397b"
    ; context = 262144
    ; tools = true
    ; thinking = true
    ; vision = true
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-rnj-1-8b"
    ; api_name = "rnj-1:8b"
    ; context = 32768
    ; tools = true
    ; thinking = false
    ; vision = false
    }
  ]

let has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let find_runtime runtimes runtime_id =
  List.find_opt
    (fun (runtime : Runtime.t) -> String.equal runtime.id runtime_id)
    runtimes

let assert_ollama_cloud_seed_runtime runtimes case =
  match find_runtime runtimes case.runtime_id with
  | None -> failf "expected Ollama Cloud runtime in seed: %s" case.runtime_id
  | Some runtime ->
    check string (case.runtime_id ^ " api name") case.api_name
      runtime.model.api_name;
    check int (case.runtime_id ^ " context") case.context
      runtime.model.max_context;
    check bool (case.runtime_id ^ " tools") case.tools
      runtime.model.tools_support;
    check bool (case.runtime_id ^ " thinking") case.thinking
      runtime.model.thinking_support;
    check bool (case.runtime_id ^ " known to provider-qualified OAS catalog") true
      (Option.is_some
         (Llm_provider.Provider_config.capabilities_for_config_model
            runtime.provider_config));
    (match runtime.model.capabilities with
     | None -> failf "expected capabilities for %s" case.runtime_id
     | Some caps ->
       let expected_thinking_format =
         if case.thinking
         then Runtime_schema.Reasoning_effort
         else Runtime_schema.No_thinking_control
       in
       check bool (case.runtime_id ^ " forced tool_choice disabled") false
         caps.supports_tool_choice;
       check bool (case.runtime_id ^ " image input") case.vision
         caps.supports_image_input;
       check bool (case.runtime_id ^ " multimodal input") case.vision
         caps.supports_multimodal_inputs;
       check bool (case.runtime_id ^ " extended thinking") case.thinking
         caps.supports_extended_thinking;
       check bool (case.runtime_id ^ " reasoning budget") case.thinking
         caps.supports_reasoning_budget;
       check bool (case.runtime_id ^ " thinking control") true
         (Runtime_schema.equal_thinking_control_format
            caps.thinking_control_format
            expected_thinking_format))

let test_runtime_json_not_in_repo_config () =
  let path = Filename.concat (repo_root ()) "config/runtime.json" in
  check bool "retired runtime.json absent" false (Sys.file_exists path)

let with_repo_oas_model_catalog f =
  let path = Filename.concat (repo_root ()) "oas-models.toml" in
  check bool "repo oas-models.toml present" true (Sys.file_exists path);
  match Llm_provider.Model_catalog.load_file path with
  | Error msg -> failf "repo oas-models.toml should load: %s" msg
  | Ok catalog ->
    Fun.protect
      ~finally:Llm_provider.Model_catalog.clear_global
      (fun () ->
         Llm_provider.Model_catalog.set_global catalog;
         f catalog)

let test_repo_oas_model_catalog_covers_live_runpod_mtp () =
  with_repo_oas_model_catalog @@ fun catalog ->
  let runpod_model_id = "qwen36-35b-a3b-mtp" in
  let provider_model_ids =
    [ "runpod_mtp/" ^ runpod_model_id; "openai_compat/" ^ runpod_model_id ]
  in
  let expect_lookup model_id =
    match Llm_provider.Model_catalog.lookup catalog model_id with
    | None -> failf "expected repo OAS catalog row for %s" model_id
    | Some entry ->
      check (option string) (model_id ^ " base") (Some "openai_chat")
        entry.base_label;
      check (option int) (model_id ^ " context") (Some 131072)
        entry.max_context_tokens
  in
  let expect_runpod_caps
        name
      (caps : Llm_provider.Capabilities.capabilities)
    =
    check bool (name ^ " tools") true caps.supports_tools;
    check bool (name ^ " tool choice") true caps.supports_tool_choice;
    check bool (name ^ " extended thinking") true
      caps.supports_extended_thinking;
    check bool (name ^ " chat-template thinking") true
      (Llm_provider.Capabilities.(
         caps.thinking_control_format = Chat_template_kwargs))
  in
  List.iter expect_lookup provider_model_ids;
  expect_lookup runpod_model_id;
  List.iter
    (fun provider_model_id ->
       match
         Llm_provider.Capabilities.for_model_id_catalog provider_model_id
       with
       | None ->
         failf "expected RunPod qwen3.6 capability lookup for %s"
           provider_model_id
       | Some caps -> expect_runpod_caps provider_model_id caps)
    provider_model_ids;
  (* Verify the actual boot gate path without bare fallback. current pinned OAS
     emits openai_compat for RunPod proxy URLs; jeong-sik/oas#2374 emits
     runpod_mtp after the pin bump. Both labels must resolve during the
     transition window. *)
  List.iter
    (fun provider_label ->
       let name = "RunPod qwen3.6 gate " ^ provider_label in
       match
         Llm_provider.Capabilities.for_provider_model_id
           ~allow_bare_fallback:false
           ~provider_label
           ~model_id:runpod_model_id
       with
       | None ->
         failf "RunPod qwen3.6 must resolve via gate path (%s)"
           provider_label
       | Some gate_caps -> expect_runpod_caps name gate_caps)
    [ "runpod_mtp"; "openai_compat" ]

let test_repo_oas_model_catalog_covers_live_runpod_rtxa6000_gemma () =
  with_repo_oas_model_catalog @@ fun catalog ->
  let model_id = "gemma4-coder-fable5-q4km" in
  let provider_model_id = "openai_compat/" ^ model_id in
  (match Llm_provider.Model_catalog.lookup catalog provider_model_id with
   | None -> failf "expected repo OAS catalog row for %s" provider_model_id
   | Some entry ->
     check (option string) (provider_model_id ^ " base") (Some "openai_chat")
       entry.base_label;
     check (option int) (provider_model_id ^ " context") (Some 262144)
       entry.max_context_tokens);
  match
    Llm_provider.Capabilities.for_provider_model_id
      ~allow_bare_fallback:false
      ~provider_label:"openai_compat"
      ~model_id
  with
  | None ->
    failf
      "live RunPod RTX A6000 Gemma runtime must resolve via raw \
       OpenAI-compatible gate path"
  | Some caps ->
    check bool "RunPod RTX A6000 Gemma tools" true caps.supports_tools;
    check bool "RunPod RTX A6000 Gemma tool choice" true
      caps.supports_tool_choice;
    check bool "RunPod RTX A6000 Gemma extended thinking" true
      caps.supports_extended_thinking;
    check bool "RunPod RTX A6000 Gemma top_k" true caps.supports_top_k;
    check bool "RunPod RTX A6000 Gemma seed" true caps.supports_seed;
    check bool "RunPod RTX A6000 Gemma chat-template token thinking" true
      (Llm_provider.Capabilities.(
         caps.thinking_control_format = Chat_template_token))

let test_repo_oas_model_catalog_preserve_axes_resolve () =
  with_repo_oas_model_catalog @@ fun catalog ->
  let expect_catalog_field ~field_name ~get model_id expected =
    match Llm_provider.Model_catalog.lookup catalog model_id with
    | None -> failf "expected repo OAS catalog row for %s" model_id
    | Some entry ->
      check (option string) (model_id ^ " " ^ field_name) (Some expected)
        (get entry)
  in
  let expect_request_side_preserve model_id =
    expect_catalog_field
      ~field_name:"preserve_thinking_control_format"
      ~get:(fun entry -> entry.preserve_thinking_control_format)
      model_id
      "chat_template_kwargs_preserve_thinking";
    match Llm_provider.Capabilities.for_model_id model_id with
    | None -> failf "expected OAS capabilities for %s" model_id
    | Some caps ->
      check bool (model_id ^ " request-side preserve capability") true
        (Llm_provider.Capabilities.(
           caps.preserve_thinking_control_format
           = Chat_template_kwargs_preserve_thinking))
  in
  let expect_preserve_always_replay model_id =
    expect_catalog_field
      ~field_name:"reasoning_replay"
      ~get:(fun entry -> entry.reasoning_replay)
      model_id
      "preserve_always";
    match Llm_provider.Capabilities.for_model_id model_id with
    | None -> failf "expected OAS capabilities for %s" model_id
    | Some caps ->
      check bool (model_id ^ " reasoning replay override") true
        (Llm_provider.Capabilities.(
           caps.reasoning_replay_override = Force_preserve_always))
  in
  let expect_bare_native_kimi_wire_semantics model_id =
    (match Llm_provider.Model_catalog.lookup catalog model_id with
     | None -> failf "expected repo OAS catalog row for %s" model_id
     | Some entry ->
       check (option string) (model_id ^ " native base") (Some "kimi")
         entry.base_label;
       check (option string) (model_id ^ " no catalog thinking override") None
         entry.thinking_control_format;
       check (option string) (model_id ^ " no catalog replay override") None
         entry.reasoning_replay);
    match Llm_provider.Capabilities.for_model_id model_id with
    | None -> failf "expected OAS capabilities for %s" model_id
    | Some caps ->
      check bool (model_id ^ " native no request thinking knob") true
        (Llm_provider.Capabilities.(
           caps.thinking_control_format = No_thinking_control));
      check bool (model_id ^ " native always preserves reasoning") true
        (Llm_provider.Capabilities.(
           caps.preserve_thinking_control_format = Always_preserved_thinking));
      check bool (model_id ^ " native preserves reasoning replay") true
        (Llm_provider.Capabilities.(
           caps.reasoning_replay_override = Force_preserve_always))
  in
  expect_request_side_preserve "runpod_mtp/qwen36-35b-a3b-mtp";
  expect_request_side_preserve "qwen36-35b-a3b-mtp";
  expect_preserve_always_replay "ollama_cloud/kimi-k2.6";
  expect_bare_native_kimi_wire_semantics "kimi-k2.6"

let test_repo_runtime_bindings_resolve_through_oas_catalog () =
  with_repo_oas_model_catalog @@ fun _catalog ->
  let path = Filename.concat (repo_root ()) "config/runtime.toml" in
  match Runtime.load_list ~config_path:path with
  | Error msg -> failf "repo runtime.toml should load: %s" msg
  | Ok
      ( runtimes
      , _default
      , _assignments
      , _librarian
      , _structured_judge
      , _cross_verifier
      , _media_failover ) ->
    check bool "at least one runtime binding" true (List.length runtimes > 0);
    List.iter
      (fun (runtime : Runtime.t) ->
         match
           Llm_provider.Provider_config.capabilities_for_config_model
             runtime.provider_config
         with
         | None ->
           failf
             "runtime binding %s provider/model %s/%s must resolve through repo \
              OAS catalog"
             runtime.id
             (Llm_provider.Provider_config.capability_provider_label
                runtime.provider_config)
             runtime.provider_config.model_id
         | Some _ -> ())
      runtimes

let test_repo_oas_model_catalog_modality_priorities_resolve () =
  with_repo_oas_model_catalog @@ fun catalog ->
  let rows =
    List.filter
      (fun (entry : Llm_provider.Model_catalog.model_entry) ->
         Option.is_some entry.modality_priority)
      catalog
  in
  check bool "repo OAS catalog has modality priority rows" true (rows <> []);
  List.iter
    (fun (entry : Llm_provider.Model_catalog.model_entry) ->
       match entry.modality_priority with
       | None -> ()
       | Some raw ->
         let expected =
           match String.lowercase_ascii (String.trim raw) with
           | "visual_first" | "visual-first" -> Llm_provider.Modality.Visual_first
           | "preserve_input_order" | "preserve-input-order" | "preserve" ->
             Llm_provider.Modality.Preserve_input_order
           | normalized ->
             failf
               "unsupported modality_priority %S (normalized %S) in %s"
               raw
               normalized
               entry.id_prefix
         in
         (match
            Llm_provider.Capabilities.for_model_id_catalog entry.id_prefix
          with
          | None ->
            failf
              "modality_priority row %s must resolve through repo OAS catalog"
              entry.id_prefix
          | Some caps ->
            check
              bool
              (entry.id_prefix ^ " modality_priority resolves")
              true
              (caps.modality_priority = expected)))
    rows

let test_repo_runtime_toml_loads () =
  with_repo_oas_model_catalog @@ fun _catalog ->
  let path = Filename.concat (repo_root ()) "config/runtime.toml" in
  check bool "repo runtime.toml present" true (Sys.file_exists path);
  match Runtime.load_list ~config_path:path with
  | Error msg -> failf "repo runtime.toml should load: %s" msg
  | Ok
      ( runtimes
      , default
      , assignments
      , _librarian
      , structured_judge
      , _cross_verifier
      , _media_failover ) ->
    check bool "at least one runtime" true (List.length runtimes > 0);
    check string "default runtime" "ollama_cloud.deepseek-v4-flash"
      default.Runtime.id;
    check
      (option string)
      "structured judge runtime"
      (Some "ollama_cloud_native.minimax-m3-native-structured")
      structured_judge;
    check (option (float 0.0)) "Ollama Cloud connect timeout override"
      (Some 600.0)
      default.provider_config.connect_timeout_s;
    check int "one local Gemma canary pin in seed" 1 (List.length assignments);
    check (option string) "nick0cave Gemma canary pin"
      (Some "ollama.gemma4-26b-a4b-qat")
      (List.assoc_opt "nick0cave" assignments);
    check int "Ollama Cloud canonical seed count"
      (List.length ollama_cloud_seed_cases)
      (List.length
         (List.filter
            (fun (runtime : Runtime.t) ->
               has_prefix ~prefix:"ollama_cloud.ollama-cloud-" runtime.id)
            runtimes));
    List.iter
      (assert_ollama_cloud_seed_runtime runtimes)
      ollama_cloud_seed_cases;
    (match
       List.find_opt
         (fun (runtime : Runtime.t) ->
            String.equal runtime.id "ollama.gemma4-26b-a4b-qat")
         runtimes
     with
     | None -> fail "expected Gemma4 Ollama runtime in seed"
     | Some runtime ->
       check bool "Gemma4 thinking enabled" true runtime.model.thinking_support;
       check (option bool) "Gemma4 thinking not preserved" (Some false)
         runtime.model.preserve_thinking;
       (match runtime.model.capabilities with
        | Some caps ->
          check bool "Gemma4 chat-template-token thinking control" true
            (Runtime_schema.equal_thinking_control_format
               caps.thinking_control_format
               Runtime_schema.Chat_template_token);
          (* Native Ollama /api/chat never serializes tool_choice
             (oas backend_ollama.ml:24); declaring true here would override
             oas models.toml false while the transport drops forced tool
             choice. *)
          check bool "Gemma4 forced tool_choice disabled" false
            caps.supports_tool_choice
        | None -> fail "expected Gemma4 capabilities"));
    (match
       List.find_opt
         (fun (runtime : Runtime.t) ->
            String.equal runtime.id "glm-coding.glm-4-7-coding")
         runtimes
     with
     | None -> fail "expected GLM Coding Plan runtime in seed"
     | Some runtime ->
       check string "GLM Coding Plan model api name" "glm-4.7"
         runtime.model.api_name;
       check int "GLM Coding Plan context" 200000 runtime.model.max_context;
       check bool "GLM Coding Plan thinking enabled" true
         runtime.model.thinking_support;
      check (option bool) "GLM Coding Plan does not preserve thinking by default" (Some false)
        runtime.model.preserve_thinking;
       (match runtime.model.capabilities with
        | Some caps ->
          check (option int) "GLM Coding Plan output cap" (Some 128000)
            caps.max_output_tokens;
          check bool "GLM Coding Plan forced tool_choice disabled" false
            caps.supports_tool_choice;
          check bool "GLM Coding Plan extended thinking" true
            caps.supports_extended_thinking
        | None -> fail "expected GLM Coding Plan capabilities"));
    (match
       List.find_opt
         (fun (runtime : Runtime.t) ->
            String.equal runtime.id "deepseek.deepseek-v4-pro")
         runtimes
     with
     | None -> fail "expected DeepSeek Pro runtime in seed"
     | Some runtime ->
       check (option (float 0.0)) "DeepSeek keeps OAS connect timeout default"
         None
         runtime.provider_config.connect_timeout_s);
    (match
       List.find_opt
         (fun (runtime : Runtime.t) ->
            String.equal runtime.id "ollama_cloud.minimax-m3")
         runtimes
     with
     | None -> fail "expected MiniMax M3 Ollama Cloud runtime in seed"
     | Some runtime ->
       check string "MiniMax M3 api name" "minimax-m3" runtime.model.api_name;
       check int "MiniMax M3 context" 524288 runtime.model.max_context;
       (match runtime.model.capabilities with
       | Some caps ->
          check bool "MiniMax M3 response_format json disabled" false
            caps.supports_response_format_json;
          check bool "MiniMax M3 structured output disabled" false
            caps.supports_structured_output;
          check bool "MiniMax M3 image input" true caps.supports_image_input;
          check bool "MiniMax M3 multimodal input" true
            caps.supports_multimodal_inputs;
          check bool "MiniMax M3 forced tool_choice disabled" false
            caps.supports_tool_choice
        | None -> fail "expected MiniMax M3 capabilities"));
    (match
       List.find_opt
         (fun (runtime : Runtime.t) ->
            String.equal runtime.id
              "ollama_cloud_native.minimax-m3-native-structured")
         runtimes
     with
     | None -> fail "expected native MiniMax M3 structured-output runtime in seed"
     | Some runtime ->
       check string "native MiniMax M3 api name" "minimax-m3"
         runtime.model.api_name;
       check (option (float 0.0)) "native MiniMax M3 connect timeout"
         (Some 600.0)
         runtime.provider_config.connect_timeout_s;
       (match runtime.model.capabilities with
       | Some caps ->
         check bool "native MiniMax M3 response_format json" true
           caps.supports_response_format_json;
         check bool "native MiniMax M3 structured output" true
           caps.supports_structured_output;
         check bool "native MiniMax M3 Ollama think control" true
           (Runtime_schema.equal_thinking_control_format
              caps.thinking_control_format
              Runtime_schema.Ollama_think)
       | None -> fail "expected native MiniMax M3 capabilities"));
    (match
       List.find_opt
         (fun (runtime : Runtime.t) ->
            String.equal runtime.id "ollama_cloud.kimi-k2-6")
         runtimes
     with
     | None -> fail "expected Kimi K2.6 Ollama Cloud runtime in seed"
     | Some runtime ->
       check string "Kimi K2.6 api name" "kimi-k2.6" runtime.model.api_name;
       check int "Kimi K2.6 context" 262144 runtime.model.max_context;
       (match runtime.model.capabilities with
        | Some caps ->
          check bool "Kimi K2.6 image input" true caps.supports_image_input;
          check bool "Kimi K2.6 multimodal input" true
            caps.supports_multimodal_inputs;
          check bool "Kimi K2.6 reasoning effort" true
            (Runtime_schema.equal_thinking_control_format
               caps.thinking_control_format
               Runtime_schema.Reasoning_effort)
        | None -> fail "expected Kimi K2.6 capabilities"))

let test_toml_catalog_resolves_lifecycle_keys () =
  let doc =
    parse_or_fail
      "[lifecycle]\n\
       self_preservation_ratio = 0.4\n\
       self_preservation_min = 2\n\
       dead_ttl_sec = 86400\n\
       paused_cleanup_ttl_sec = 604800\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied lifecycle overrides" 4 count;
  check (option string) "self preservation ratio" (Some "0.4")
    (List.assoc_opt "MASC_KEEPER_SELF_PRESERVATION_RATIO" overrides);
  check (option string) "self preservation min" (Some "2")
    (List.assoc_opt "MASC_KEEPER_SELF_PRESERVATION_MIN_CANDIDATES" overrides);
  check (option string) "dead ttl" (Some "86400")
    (List.assoc_opt "MASC_KEEPER_DEAD_TTL_SEC" overrides);
  check (option string) "paused cleanup ttl" (Some "604800")
    (List.assoc_opt "MASC_KEEPER_PAUSED_CLEANUP_TTL_SEC" overrides)

let test_toml_catalog_resolves_web_search_keys () =
  let doc =
    parse_or_fail
      "[web_search]\n\
       searxng_url = \"http://localhost:8888\"\n\
       provider = \"auto\"\n\
       provider_order = \"searxng,brave,duckduckgo\"\n\
       fallbacks = \"duckduckgo,bing_rss\"\n\
       timeout_sec = 12\n\
       cache_ttl_sec = 45.5\n\
       rate_limit_window_sec = 20.0\n\
       rate_limit_max_calls = 9\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied web search overrides" 8 count;
  check (option string) "searxng url" (Some "http://localhost:8888")
    (List.assoc_opt "MASC_SEARXNG_URL" overrides);
  check (option string) "provider" (Some "auto")
    (List.assoc_opt "MASC_WEB_SEARCH_PROVIDER" overrides);
  check (option string) "provider order" (Some "searxng,brave,duckduckgo")
    (List.assoc_opt "MASC_WEB_SEARCH_PROVIDER_ORDER" overrides);
  check (option string) "fallbacks" (Some "duckduckgo,bing_rss")
    (List.assoc_opt "MASC_WEB_SEARCH_FALLBACKS" overrides);
  check (option string) "timeout" (Some "12")
    (List.assoc_opt "MASC_WEB_SEARCH_TIMEOUT_SEC" overrides);
  check (option string) "cache ttl" (Some "45.5")
    (List.assoc_opt "MASC_WEB_SEARCH_CACHE_TTL_SEC" overrides);
  check (option string) "rate window" (Some "20")
    (List.assoc_opt "MASC_WEB_SEARCH_RATE_LIMIT_WINDOW_SEC" overrides);
  check (option string) "rate max" (Some "9")
    (List.assoc_opt "MASC_WEB_SEARCH_RATE_LIMIT_MAX_CALLS" overrides);
  let preempt_searxng name =
    if String.equal name "MASC_SEARXNG_URL"
    then Some "http://operator.example"
    else None
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:preempt_searxng doc
  in
  check int "env preempts only searxng url" 7 count;
  check (option string) "preempted searxng absent" None
    (List.assoc_opt "MASC_SEARXNG_URL" overrides)

let test_runtime_toml_reserves_web_search_namespace () =
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     [runtime]\n\
     default = \"local.sample\"\n\
     \n\
     [web_search]\n\
     searxng_url = \"http://localhost:8888\"\n"
  in
  match Runtime_toml.parse_string content with
  | Error errs ->
    let rendered =
      errs
      |> List.map (fun (err : Runtime_toml.parse_error) ->
        Printf.sprintf "%s: %s" err.path err.message)
      |> String.concat "\n"
    in
    failf "runtime TOML should parse with [web_search]:\n%s" rendered
  | Ok cfg ->
    check int "web_search is not a provider binding" 1
      (List.length cfg.Runtime_schema.bindings);
    (match cfg.Runtime_schema.bindings with
     | [ binding ] ->
       check (option int) "missing max-concurrent means no static cap" None
         binding.Runtime_schema.max_concurrent
     | _ -> ());
    check (option string) "default runtime" (Some "local.sample")
      cfg.Runtime_schema.default_runtime_id

let test_runtime_toml_rejects_unknown_runtime_key () =
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n\
     defualt = \"local.typo\"\n"
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> failf "unknown [runtime] key should fail parse"
  | Error errs ->
    let rendered =
      errs
      |> List.map (fun (err : Runtime_toml.parse_error) ->
        Printf.sprintf "%s: %s" err.path err.message)
      |> String.concat "\n"
    in
    check bool "error mentions runtime.defualt" true
      (String_util.contains_substring rendered "runtime.defualt");
    check bool "error explains unknown runtime key" true
      (String_util.contains_substring rendered "unknown [runtime] key")

let test_runtime_toml_allows_runtime_profile_tables () =
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n\
     \n\
     [runtime.primary_profile]\n\
     members = [\"local.sample\"]\n\
     tiers = [\"primary_profile\"]\n\
     \n\
     [runtime.secondary_profile]\n\
     members = [\"local.sample\"]\n\
     tiers = [\"secondary_profile\"]\n"
  in
  match Runtime_toml.parse_string content with
  | Error errs ->
    let rendered =
      errs
      |> List.map (fun (err : Runtime_toml.parse_error) ->
        Printf.sprintf "%s: %s" err.path err.message)
      |> String.concat "\n"
    in
    failf "runtime TOML should allow [runtime.<profile>] tables:\n%s" rendered
  | Ok cfg ->
    check (option string) "default runtime" (Some "local.sample")
      cfg.Runtime_schema.default_runtime_id;
    check int "profile tables are not provider bindings" 1
      (List.length cfg.Runtime_schema.bindings)

let test_runtime_toml_rejects_wrong_type_media_failover () =
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n\
     media_failover = \"local.sample\"\n"
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> failf "wrong-type [runtime].media_failover should fail parse"
  | Error errs ->
    let rendered =
      errs
      |> List.map (fun (err : Runtime_toml.parse_error) ->
        Printf.sprintf "%s: %s" err.path err.message)
      |> String.concat "\n"
    in
    check bool "error mentions runtime.media_failover" true
      (String_util.contains_substring rendered "runtime.media_failover");
    check bool "error explains media_failover type" true
      (String_util.contains_substring
         rendered
         "media_failover must be an array of string runtime ids")

let test_runtime_toml_preserves_explicit_empty_media_failover () =
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n\
     media_failover = []\n"
  in
  match Runtime_toml.parse_string content with
  | Error errs ->
    let rendered =
      errs
      |> List.map (fun (err : Runtime_toml.parse_error) ->
        Printf.sprintf "%s: %s" err.path err.message)
      |> String.concat "\n"
    in
    failf "runtime TOML should parse explicit empty media_failover:\n%s" rendered
  | Ok cfg -> check (list string) "media_failover" [] cfg.Runtime_schema.media_failover

(** The runtime singletons were migrated from plain [ref]s to [Atomic.t] so
    that reads from worker domains on OCaml 5 see published writes.  This test
    exercises the public getter surface after [init_default] to ensure the
    atomic reads return consistent, repeatable values. *)
let test_runtime_atomic_getters_are_consistent_after_init () =
  let path = Filename.concat (repo_root ()) "config/runtime.toml" in
  match Runtime.init_default ~config_path:path with
  | Error msg -> failf "repo runtime.toml should init: %s" msg
  | Ok () ->
    let default1 = Runtime.get_default_runtime () in
    let default2 = Runtime.get_default_runtime () in
    check
      (option string)
      "get_default_runtime is stable"
      (Option.map (fun (rt : Runtime.t) -> rt.id) default1)
      (Option.map (fun (rt : Runtime.t) -> rt.id) default2);
    let ids1 = Runtime.get_runtime_ids () in
    let ids2 = Runtime.get_runtime_ids () in
    check (list string) "get_runtime_ids is stable" ids1 ids2;
    check bool "runtime_id_for_keeper resolves through atomic cache"
      true
      (match Runtime.runtime_id_for_keeper "nick0cave" with
       | Some id -> Option.is_some (Runtime.get_runtime_by_id id)
       | None -> false)

let test_runtime_toml_parses_optional_max_concurrent () =
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     max-concurrent = 7\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n"
  in
  match Runtime_toml.parse_string content with
  | Error errs ->
    let rendered =
      errs
      |> List.map (fun (err : Runtime_toml.parse_error) ->
        Printf.sprintf "%s: %s" err.path err.message)
      |> String.concat "\n"
    in
    failf "runtime TOML should parse optional max-concurrent:\n%s" rendered
  | Ok cfg ->
    (match cfg.Runtime_schema.bindings with
     | [ binding ] ->
       check (option int) "explicit max-concurrent opt-in" (Some 7)
         binding.Runtime_schema.max_concurrent
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

let test_runtime_toml_rejects_non_positive_max_concurrent () =
  let template n =
    Printf.sprintf
      "[providers.local]\n\
       protocol = \"openai-compatible-http\"\n\
       endpoint = \"http://127.0.0.1:1/v1\"\n\
       \n\
       [models.sample]\n\
       api-name = \"sample\"\n\
       max-context = 1024\n\
       \n\
       [local.sample]\n\
       max-concurrent = %d\n\
       \n\
       [runtime]\n\
       default = \"local.sample\"\n"
      n
  in
  List.iter
    (fun n ->
       match Runtime_toml.parse_string (template n) with
       | Ok _ -> failf "max-concurrent = %d should be rejected" n
       | Error errs ->
         let rendered =
           errs
           |> List.map (fun (err : Runtime_toml.parse_error) ->
             Printf.sprintf "%s: %s" err.path err.message)
           |> String.concat "\n"
         in
         check bool (Printf.sprintf "error mentions max-concurrent for %d" n) true
           (String_util.contains_substring rendered "max-concurrent"))
    [ 0; -1 ]

let with_temp_runtime_toml content f =
  let path = Filename.temp_file "runtime" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
       (try Sys.remove path with
        | _ -> ())
       )
    (fun () -> f path)

let with_fake_runtime_model_catalog f =
  let content =
    "[[models]]\n\
     id_prefix = \"chat\"\n\
     base = \"ollama\"\n\
     max_context_tokens = 1024\n\
     \n\
     [[models]]\n\
     id_prefix = \"libr\"\n\
     base = \"ollama\"\n\
     max_context_tokens = 1024\n\
     \n\
     [[models]]\n\
     id_prefix = \"no-cap\"\n\
     base = \"openai_chat\"\n\
     max_context_tokens = 1024\n\
     \n\
     [[models]]\n\
     id_prefix = \"capped\"\n\
     base = \"openai_chat\"\n\
     max_context_tokens = 1024\n"
  in
  let path = Filename.temp_file "oas-models" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
       Llm_provider.Model_catalog.clear_global ();
       (try Sys.remove path with
        | _ -> ())
       )
    (fun () ->
       match Llm_provider.Model_catalog.load_file path with
       | Error msg -> failf "fake OAS model catalog should load: %s" msg
       | Ok catalog ->
         Llm_provider.Model_catalog.set_global catalog;
         f ())

let with_model_catalog_content content f =
  let path = Filename.temp_file "oas-provider-qualified-models" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
       Llm_provider.Model_catalog.clear_global ();
       (try Sys.remove path with
        | _ -> ())
       )
    (fun () ->
       match Llm_provider.Model_catalog.load_file path with
       | Error msg -> failf "provider-qualified OAS model catalog should load: %s" msg
       | Ok catalog ->
         Llm_provider.Model_catalog.set_global catalog;
         f ())

let test_runtime_capability_gate_uses_provider_qualified_catalog () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"ollama_cloud/shared-thinking\"\n\
     base = \"ollama_cloud\"\n\
     max_context_tokens = 1024\n\
     supports_tools = true\n\
     supports_reasoning = true\n\
     supports_extended_thinking = true\n\
     supports_reasoning_budget = true\n\
     thinking_control_format = \"chat_template_kwargs\"\n\
     preserve_thinking_control_format = \"chat_template_kwargs_preserve_thinking\"\n"
  in
  let runtime_toml =
    "[providers.ollama_cloud]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://ollama.com/v1\"\n\
     \n\
     [models.shared]\n\
     api-name = \"shared-thinking\"\n\
     max-context = 1024\n\
     tools-support = true\n\
     thinking-support = true\n\
     \n\
     [ollama_cloud.shared]\n\
     \n\
     [runtime]\n\
     default = \"ollama_cloud.shared\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_model_catalog_content catalog @@ fun () ->
       with_temp_runtime_toml runtime_toml (fun path ->
         match Runtime.init_default_strict ~config_path:path with
         | Error msg ->
           failf
             "provider-qualified catalog row should satisfy strict runtime \
              capability gate: %s"
             msg
         | Ok () ->
           check (option bool) "provider-qualified preserve policy" None
             (Runtime.preserve_thinking_of_runtime_id "ollama_cloud.shared")))

let test_runtime_capability_gate_reports_missing_catalog_models () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"other-family\"\n\
     base = \"openai_chat\"\n\
     max_context_tokens = 1024\n"
  in
  let runtime_toml =
    "[providers.custom]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://custom.example/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"missing-family-123\"\n\
     max-context = 2048\n\
     \n\
     [custom.sample]\n\
     \n\
     [runtime]\n\
     default = \"custom.sample\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_model_catalog_content catalog @@ fun () ->
       with_temp_runtime_toml runtime_toml @@ fun path ->
       match Runtime.init_default_strict_report ~config_path:path with
       | Ok () -> fail "missing provider-qualified catalog row should fail strict init"
       | Error (Runtime.Runtime_config_error msg) ->
         failf "expected missing catalog report, got config error: %s" msg
       | Error (Runtime.Missing_catalog_models report) ->
         check int "one missing runtime" 1 (List.length report.missing_models);
         let missing = List.hd report.missing_models in
         check string "runtime id" "custom.sample" missing.runtime_id;
         check string "provider id" "custom" missing.provider_id;
         check string "provider label" "openai_compat" missing.provider_label;
         check string "model id" "missing-family-123" missing.model_id;
         check bool "diagnostic names OAS catalog file" true
           (String_util.contains_substring
              (Runtime.strict_init_error_to_string
                 (Runtime.Missing_catalog_models report))
              "oas-models.toml"))

let test_runtime_toml_max_concurrent_flows_to_candidate () =
  with_fake_runtime_model_catalog @@ fun () ->
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.no-cap]\n\
     api-name = \"no-cap\"\n\
     max-context = 1024\n\
     \n\
     [models.capped]\n\
     api-name = \"capped\"\n\
     max-context = 1024\n\
     \n\
     [local.no-cap]\n\
     \n\
     [local.capped]\n\
     max-concurrent = 5\n\
     \n\
     [runtime]\n\
     default = \"local.no-cap\"\n"
  in
  with_temp_runtime_toml content (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "runtime TOML should materialize: %s" msg
    | Ok
        ( runtimes
        , _default
        , _assignments
        , _librarian
        , _structured_judge
        , _cross_verifier
        , _media_failover ) ->
      let expect id expected =
        match
          List.find_opt (fun (rt : Runtime.t) -> String.equal rt.id id) runtimes
        with
        | None -> failf "expected runtime %s" id
        | Some rt ->
          check
            (option int)
            (Printf.sprintf "%s binding max_concurrent" id)
            expected
            rt.Runtime.binding.max_concurrent;
          let candidate =
            Runtime_candidate.of_provider_config
              ~max_concurrent:rt.Runtime.binding.max_concurrent
              rt.Runtime.provider_config
          in
          check
            (option int)
            (Printf.sprintf "%s candidate max_concurrent" id)
            expected
            (Runtime_candidate.max_concurrent candidate)
      in
      expect "local.no-cap" None;
      expect "local.capped" (Some 5))

(* [runtime].librarian (RFC: memory-os librarian routing): resolves to a
   configured runtime and is returned by load_list; absent = None (inherit
   keeper runtime); an unknown id is rejected at load like [runtime].default. *)
let test_librarian_runtime_routing () =
  with_fake_runtime_model_catalog @@ fun () ->
  let base =
    "[providers.local]\n\
     display-name = \"Local\"\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://localhost:11434\"\n\
     \n\
     [models.chat]\n\
     api-name = \"chat\"\n\
     max-context = 1024\n\
     \n\
     [models.libr]\n\
     api-name = \"libr\"\n\
     max-context = 1024\n\
     \n\
     [models.libr.capabilities]\n\
     supports-response-format-json = true\n\
     \n\
     [local.chat]\n\
     \n\
     [local.libr]\n\
     \n\
     [runtime]\n\
     default = \"local.chat\"\n"
  in
  with_temp_runtime_toml (base ^ "librarian = \"local.libr\"\n") (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "librarian routing should load: %s" msg
    | Ok
        ( _runtimes
        , _default
        , _assignments
        , librarian
        , _structured_judge
        , _cross_verifier
        , _media_failover ) ->
      check (option string) "librarian runtime id" (Some "local.libr") librarian);
  with_temp_runtime_toml base (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "absent librarian should load: %s" msg
    | Ok (_, _, _, librarian, _structured_judge, _cross_verifier, _media_failover) ->
      check (option string) "librarian unset is None" None librarian);
  with_temp_runtime_toml (base ^ "librarian = \"local.nope\"\n") (fun path ->
    match Runtime.load_list ~config_path:path with
    | Ok _ -> failf "unknown [runtime].librarian id must be rejected at load"
    | Error _ -> ());
  with_temp_runtime_toml (base ^ "cross_verifier = \"local.libr\"\n") (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "cross_verifier routing should load: %s" msg
    | Ok
        ( _runtimes
        , _default
        , _assignments
        , _librarian
        , _structured_judge
        , cross_verifier
        , _media_failover ) ->
      check (option string) "cross_verifier runtime id" (Some "local.libr")
        cross_verifier);
  with_temp_runtime_toml base (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "absent cross_verifier should load: %s" msg
    | Ok (_, _, _, _, _structured_judge, cross_verifier, _media_failover) ->
      check (option string) "cross_verifier unset is None" None cross_verifier);
  with_temp_runtime_toml (base ^ "cross_verifier = \"local.nope\"\n") (fun path ->
    match Runtime.load_list ~config_path:path with
    | Ok _ -> failf "unknown [runtime].cross_verifier id must be rejected at load"
    | Error _ -> ());
  with_temp_runtime_toml (base ^ "cross_verifier = \"local.chat\"\n") (fun path ->
    match Runtime.load_list ~config_path:path with
    | Ok _ ->
      failf
        "[runtime].cross_verifier must reject models without JSON response \
         format support"
    | Error _ -> ())

let test_structured_judge_runtime_routing () =
  with_fake_runtime_model_catalog @@ fun () ->
  let base =
    "[providers.local]\n\
     display-name = \"Local\"\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://localhost:11434\"\n\
     \n\
     [models.chat]\n\
     api-name = \"chat\"\n\
     max-context = 1024\n\
     \n\
     [models.judge]\n\
     api-name = \"judge\"\n\
     max-context = 1024\n\
     \n\
     [models.judge.capabilities]\n\
     supports-response-format-json = true\n\
     supports-structured-output = true\n\
     \n\
     [local.chat]\n\
     \n\
     [local.judge]\n\
     \n\
     [runtime]\n\
     default = \"local.chat\"\n"
  in
  with_temp_runtime_toml (base ^ "structured_judge = \"local.judge\"\n") (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "structured_judge routing should load: %s" msg
    | Ok (_, _, _, _, structured_judge, _, _) ->
      check
        (option string)
        "structured_judge runtime id"
        (Some "local.judge")
        structured_judge);
  with_temp_runtime_toml base (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "absent structured_judge should load: %s" msg
    | Ok (_, _, _, _, structured_judge, _, _) ->
      check (option string) "structured_judge unset is None" None structured_judge);
  with_temp_runtime_toml (base ^ "structured_judge = \"local.nope\"\n") (fun path ->
    match Runtime.load_list ~config_path:path with
    | Ok _ -> failf "unknown [runtime].structured_judge id must be rejected"
    | Error _ -> ());
  with_temp_runtime_toml (base ^ "structured_judge = \"local.chat\"\n") (fun path ->
    match Runtime.load_list ~config_path:path with
    | Ok _ ->
      failf
        "[runtime].structured_judge must reject models without structured-output \
         support"
    | Error _ -> ());
  let librarian_fallback = base ^ "librarian = \"local.judge\"\n" in
  with_temp_runtime_toml librarian_fallback (fun path ->
    match Runtime.save_config_text ~runtime_config_path:path librarian_fallback with
    | Error msg -> failf "save_config_text should load librarian fallback: %s" msg
    | Ok () ->
      check string "structured judge falls back to librarian" "local.judge"
        (Runtime.runtime_id_for_structured_judge ()));
  let explicit_structured_judge = base ^ "structured_judge = \"local.judge\"\n" in
  with_temp_runtime_toml explicit_structured_judge (fun path ->
    match
      Runtime.save_config_text ~runtime_config_path:path explicit_structured_judge
    with
    | Error msg -> failf "save_config_text should load structured_judge: %s" msg
    | Ok () ->
      check
        (option string)
        "saved structured_judge runtime id"
        (Some "local.judge")
        (Runtime.structured_judge_runtime_id ());
      check string "resolved structured judge runtime" "local.judge"
        (Runtime.runtime_id_for_structured_judge ()))
  ;
  with_temp_runtime_toml base (fun path ->
    match
      Runtime.set_runtime_structured_judge
        ~runtime_config_path:path
        ~runtime_id:(Some "local.judge")
        ()
    with
    | Error msg -> failf "set_runtime_structured_judge should validate: %s" msg
    | Ok () ->
      check
        (option string)
        "writer saved structured_judge runtime id"
        (Some "local.judge")
        (Runtime.structured_judge_runtime_id ());
      check bool "runtime.toml structured_judge persisted" true
        (String_util.contains_substring
           (Fs_compat.load_file path)
           "structured_judge = \"local.judge\""));
  with_temp_runtime_toml (base ^ "structured_judge = \"local.judge\"\n") (fun path ->
    match
      Runtime.set_runtime_structured_judge
        ~runtime_config_path:path
        ~runtime_id:None
        ()
    with
    | Error msg -> failf "clear structured_judge should validate: %s" msg
    | Ok () ->
      check (option string) "writer cleared structured_judge" None
        (Runtime.structured_judge_runtime_id ());
      check bool "runtime.toml structured_judge removed" false
        (String_util.contains_substring
           (Fs_compat.load_file path)
           "structured_judge"))

let test_save_config_text_refreshes_cross_verifier_runtime () =
  with_fake_runtime_model_catalog @@ fun () ->
  let content =
    "[providers.local]\n\
     display-name = \"Local\"\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://localhost:11434\"\n\
     \n\
     [models.chat]\n\
     api-name = \"chat\"\n\
     max-context = 1024\n\
     \n\
     [models.libr]\n\
     api-name = \"libr\"\n\
     max-context = 1024\n\
     \n\
     [models.libr.capabilities]\n\
     supports-response-format-json = true\n\
     \n\
     [local.chat]\n\
     \n\
     [local.libr]\n\
     \n\
     [runtime]\n\
     default = \"local.chat\"\n\
     cross_verifier = \"local.libr\"\n"
  in
  with_temp_runtime_toml content (fun path ->
    match Runtime.save_config_text ~runtime_config_path:path content with
    | Error msg -> failf "save_config_text should validate and reload: %s" msg
    | Ok () ->
      check (option string) "saved cross_verifier runtime id"
        (Some "local.libr")
        (Runtime.cross_verifier_runtime_id ()))

let test_deprecated_capability_notice_warns_once_per_process () =
  (* runtime.toml is re-parsed on every keeper boot; a per-parse deprecation
     warning flooded the WARN log (~315/day, 25% of live WARN volume). The
     notice must fire once per process per capability key, not once per parse.
     [dedupcheck] is a unique provider id so the process-level dedup table is
     not pre-populated by another test. The deprecated key sits under
     [providers.<id>.capabilities] because that is where parse_capabilities (the
     emitter) runs. *)
  let content =
    "[providers.dedupcheck]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [providers.dedupcheck.capabilities]\n\
     supports-runtime-mcp-tools = true\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [dedupcheck.sample]\n\
     \n\
     [runtime]\n\
     default = \"dedupcheck.sample\"\n"
  in
  let warns = ref [] in
  Console_sink.For_testing.reset ();
  Console_sink.For_testing.set_writer (Some (fun l -> warns := l :: !warns));
  Fun.protect ~finally:Console_sink.For_testing.reset (fun () ->
    (* Parse twice; the deprecated key is present both times. *)
    ignore (Runtime_toml.parse_string content);
    ignore (Runtime_toml.parse_string content));
  let dep_warns =
    List.filter
      (fun l ->
        String_util.contains_substring l "dedupcheck"
        && String_util.contains_substring l "is deprecated")
      !warns
  in
  check int "deprecation notice fires once per process across two parses" 1
    (List.length dep_warns)

let () =
  run "runtime_config_validity"
    [ ( "runtime TOML gate",
        [ test_case "runtime.json is not a repo config source" `Quick
            test_runtime_json_not_in_repo_config;
          test_case "repo OAS catalog covers live RunPod MTP runtime" `Quick
            test_repo_oas_model_catalog_covers_live_runpod_mtp;
          test_case
            "repo OAS catalog covers live RunPod RTX A6000 Gemma runtime"
            `Quick test_repo_oas_model_catalog_covers_live_runpod_rtxa6000_gemma;
          test_case
            "repo OAS catalog preserves typed thinking/replay axes"
            `Quick test_repo_oas_model_catalog_preserve_axes_resolve;
          test_case
            "repo runtime bindings resolve through the OAS catalog"
            `Quick test_repo_runtime_bindings_resolve_through_oas_catalog;
          test_case
            "repo OAS catalog modality priority strings resolve"
            `Quick test_repo_oas_model_catalog_modality_priorities_resolve;
          test_case "repo runtime.toml loads through runtime parser" `Quick
            test_repo_runtime_toml_loads;
          test_case
            "[runtime].librarian and .cross_verifier resolve, default None, \
             reject unknown"
            `Quick test_librarian_runtime_routing;
          test_case
            "[runtime].structured_judge resolves and rejects unsupported models"
            `Quick test_structured_judge_runtime_routing;
          test_case
            "save_config_text validates and refreshes cross_verifier runtime"
            `Quick test_save_config_text_refreshes_cross_verifier_runtime;
          test_case
            "lifecycle TOML keys resolve through the declarative catalog"
            `Quick test_toml_catalog_resolves_lifecycle_keys;
          test_case
            "web_search TOML keys resolve through the declarative catalog"
            `Quick test_toml_catalog_resolves_web_search_keys;
          test_case "web_search is a reserved runtime TOML namespace" `Quick
            test_runtime_toml_reserves_web_search_namespace;
          test_case "runtime table rejects unknown keys" `Quick
            test_runtime_toml_rejects_unknown_runtime_key;
          test_case "runtime table allows profile tables" `Quick
            test_runtime_toml_allows_runtime_profile_tables;
          test_case "runtime table rejects wrong-type media_failover" `Quick
            test_runtime_toml_rejects_wrong_type_media_failover;
          test_case "runtime table preserves empty media_failover" `Quick
            test_runtime_toml_preserves_explicit_empty_media_failover;
          test_case
            "runtime capability gate uses provider-qualified OAS catalog rows"
            `Quick test_runtime_capability_gate_uses_provider_qualified_catalog;
          test_case
            "runtime capability gate reports missing catalog models"
            `Quick test_runtime_capability_gate_reports_missing_catalog_models;
          test_case "atomic runtime getters are consistent after init" `Quick
            test_runtime_atomic_getters_are_consistent_after_init;
          test_case "max-concurrent is optional opt-in" `Quick
            test_runtime_toml_parses_optional_max_concurrent;
          test_case "non-positive max-concurrent is rejected" `Quick
            test_runtime_toml_rejects_non_positive_max_concurrent;
          test_case "max-concurrent flows from binding to runtime candidate" `Quick
            test_runtime_toml_max_concurrent_flows_to_candidate;
          test_case
            "deprecated capability notice warns once per process, not per parse"
            `Quick test_deprecated_capability_notice_warns_once_per_process ] )
    ]
