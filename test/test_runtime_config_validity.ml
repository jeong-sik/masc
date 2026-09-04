open Alcotest
open Masc

module Exact_output = Agent_core.Exact_output

let empty_env _name = None

let parse_or_fail content =
  match Keeper_toml_loader.parse_toml content with
  | Ok doc -> doc
  | Error msg -> failf "TOML parse failed: %s" msg

let agent_core_provider_config (runtime : Runtime.t) =
  match runtime.execution with
  | Runtime_execution.Agent_core provider_config -> provider_config
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Claude_code _
  | Runtime_execution.Antigravity_cli _ ->
    failf "runtime %s is not an agent_core provider" runtime.id
;;

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
  [ { runtime_id = "ollama_cloud.ollama-cloud-deepseek-v4-flash"
    ; api_name = "deepseek-v4-flash"
    ; context = 1048576
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"
    ; api_name = "deepseek-v4-flash:0731"
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
  ; { runtime_id = "ollama_cloud.ollama-cloud-gemma4-31b"
    ; api_name = "gemma4:31b"
    ; context = 262144
    ; tools = true
    ; thinking = true
    ; vision = true
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
  ; { runtime_id = "ollama_cloud.ollama-cloud-glm-5-3"
    ; api_name = "glm-5.3"
    ; context = 1048576
    ; tools = true
    ; thinking = true
    ; vision = false
    }
  ; { runtime_id = "ollama_cloud.ollama-cloud-glm-5-3-flash"
    ; api_name = "glm-5.3-flash"
    ; context = 1048576
    ; tools = true
    ; thinking = true
    ; vision = true
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
  ; { runtime_id = "ollama_cloud.ollama-cloud-kimi-k3"
    ; api_name = "kimi-k3"
    ; context = 1048576
    ; tools = true
    ; thinking = true
    ; vision = true
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
  ; { runtime_id = "ollama_cloud.ollama-cloud-qwen3-5-397b"
    ; api_name = "qwen3.5:397b"
    ; context = 262144
    ; tools = true
    ; thinking = true
    ; vision = true
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
    (* The effective window, not the declaration. These cases pinned
       runtime.model.max_context, the runtime.toml override, which holds only
       while it stays under the model's catalog window; above it the resolver
       clamps and the pinned number never reaches anything (#28738). What the
       seed must keep stable is the window the runtime resolves. *)
    check (option int) (case.runtime_id ^ " context") (Some case.context)
      (Runtime.resolve_max_context_of_runtime runtime |> Option.map fst);
    check bool (case.runtime_id ^ " tools") case.tools
      runtime.model.tools_support;
    check bool (case.runtime_id ^ " thinking") case.thinking
      runtime.model.thinking_support;
    check bool (case.runtime_id ^ " known to provider-qualified AGENT_CORE catalog") true
      (Option.is_some
         (Llm_provider.Provider_config.capabilities_for_config_model
            (agent_core_provider_config runtime)));
    (match runtime.model.capabilities with
     | None -> failf "expected capabilities for %s" case.runtime_id
     | Some caps ->
       (* [thinking] says the model reasons; it does not say the endpoint takes a
          control on the wire. ollama.com /v1 serves reasoning inherently and
          accepts no control field, so [reasoning-effort] there declares a
          dialect that can never be encoded: the format carries no effort value,
          runtime.toml has no key that supplies one, and runtime_adapter never
          sets reasoning_effort. Every enable_thinking=true turn is then rejected
          as Enable_not_encodable — measured 25/25 on the acceptance harness,
          0/25 after the first five models dropped the declaration. Deployed
          config has carried none since 2026-08-04; the audit is dated 2026-07-20
          (2026-07-20).

          This is a property of the endpoint, not of individual models, and
          every case in this list is an ollama.com /v1 model. Asserting it for
          the whole list keeps a new model from declaring a dialect the
          endpoint cannot read; a per-model exception set would admit one on
          the next addition. *)
       let expected_reasoning_budget = false
       and expected_thinking_format = Runtime_schema.No_thinking_control in
       check bool (case.runtime_id ^ " forced tool_choice disabled") false
         caps.supports_tool_choice;
       check bool (case.runtime_id ^ " image input") case.vision
         caps.supports_image_input;
       check bool (case.runtime_id ^ " multimodal input") case.vision
         caps.supports_multimodal_inputs;
       check bool (case.runtime_id ^ " extended thinking") case.thinking
         caps.supports_extended_thinking;
       check bool (case.runtime_id ^ " reasoning budget") expected_reasoning_budget
         caps.supports_reasoning_budget;
       check bool (case.runtime_id ^ " thinking control") true
         (Runtime_schema.equal_thinking_control_format
            caps.thinking_control_format
            expected_thinking_format))

let test_runtime_json_not_in_repo_config () =
  let path = Filename.concat (repo_root ()) "config/runtime.json" in
  check bool "retired runtime.json absent" false (Sys.file_exists path)

let with_deployment_agent_core_model_catalog f =
  let overlay_path = Filename.concat (repo_root ()) "config/agent-core-models-overlay.toml" in
  check bool "deployment catalog overlay present" true (Sys.file_exists overlay_path);
  match Llm_provider.Model_catalog.load_file overlay_path with
  | Error msg -> failf "deployment catalog overlay should load: %s" msg
  | Ok overlay ->
    Fun.protect
      ~finally:Llm_provider.Model_catalog.clear_global
      (fun () ->
         Llm_provider.Model_catalog.clear_global ();
         Llm_provider.Model_catalog.set_global_overlay overlay;
         match Llm_provider.Model_catalog.global () with
         | None -> fail "embedded plus deployment overlay catalog should load"
         | Some catalog -> f catalog)

let test_deployment_agent_core_model_catalog_covers_live_runpod_mtp () =
  with_deployment_agent_core_model_catalog @@ fun catalog ->
  let runpod_model_id = "qwen36-35b-a3b-mtp" in
  let provider_labels = [ "runpod_mtp"; "vllm-qwen3-mtp" ] in
  let expect_provider_lookup provider_name =
    match
      Llm_provider.Model_catalog.lookup_for_provider
        catalog
        ~provider_name
        ~model_id:runpod_model_id
    with
    | None ->
      failf
        "expected deployment AGENT_CORE catalog row for provider=%s model=%s"
        provider_name
        runpod_model_id
    | Some entry ->
      check (option string) (provider_name ^ " base") (Some "openai_chat")
        entry.base_label;
      check (option int) (provider_name ^ " context") (Some 131072)
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
  List.iter expect_provider_lookup provider_labels;
  List.iter
    (fun provider_label ->
       match
         Llm_provider.Capabilities.for_provider_model_id
           ~wire:None
           ~allow_bare_fallback:false
           ~provider_label
           ~model_id:runpod_model_id
       with
       | None ->
         failf "expected RunPod qwen3.6 capability lookup for %s" provider_label
       | Some caps -> expect_runpod_caps provider_label caps)
    provider_labels;
  (* Verify both the deployment transport alias and the upstream serving
     contract without bare fallback. *)
  List.iter
    (fun provider_label ->
       let name = "RunPod qwen3.6 gate " ^ provider_label in
       match
         Llm_provider.Capabilities.for_provider_model_id
           ~wire:None
           ~allow_bare_fallback:false
           ~provider_label
           ~model_id:runpod_model_id
       with
       | None ->
         failf "RunPod qwen3.6 must resolve via gate path (%s)"
           provider_label
       | Some gate_caps -> expect_runpod_caps name gate_caps)
    provider_labels

(* Every GLM row that claims reasoning and native streaming must also name the
   delta field, because a row that leaves [reasoning_streaming_format] out
   resolves to [Default_reasoning_streaming], and for this family the derived
   dialect is [No_streaming_reasoning] -- which makes [Streaming] discard the
   provider's reasoning_content deltas instead of forwarding them. Enumerating
   the catalog rather than naming one model keeps a newly added GLM row from
   re-opening that hole: #26329 declared the field on GLM-5-Turbo only, and the
   sibling glm-4.7 rows sat undeclared behind an assertion that could not see
   them. *)
let test_deployment_agent_core_model_catalog_covers_glm_streaming_reasoning () =
  with_deployment_agent_core_model_catalog @@ fun catalog ->
  let glm_rows =
    List.filter
      (fun (entry : Llm_provider.Model_catalog.model_entry) ->
         match entry.provider_name with
         | Some provider_label ->
           String.starts_with ~prefix:"glm-coding" provider_label
         | None -> false)
      (Llm_provider.Model_catalog.model_entries catalog)
  in
  check bool "deployment catalog carries GLM rows" true (glm_rows <> []);
  List.iter
    (fun (entry : Llm_provider.Model_catalog.model_entry) ->
       let provider_label = Option.value entry.provider_name ~default:"" in
       let model_id = entry.id_prefix in
       let label = provider_label ^ "/" ^ model_id in
       match
         Llm_provider.Capabilities.for_provider_model_id
           ~wire:None
           ~allow_bare_fallback:false
           ~provider_label
           ~model_id
       with
       | None -> failf "expected deployment GLM capability for %s" label
       | Some caps ->
         if caps.supports_reasoning && caps.supports_native_streaming
         then (
           check bool (label ^ " typed reasoning delta") true
             (Llm_provider.Capabilities.(
                caps.reasoning_streaming_format
                = Delta_reasoning_field "reasoning_content"));
           match
             (Llm_provider.Reasoning_dialect.of_capabilities caps)
               .Llm_provider.Reasoning_dialect.streaming
           with
           | Delta_field "reasoning_content" -> ()
           | No_streaming_reasoning
           | Delta_field _
           | Delta_reasoning_details
           | Template_parser ->
             failf "%s resolves to a dialect that drops reasoning deltas" label))
    glm_rows

let test_deployment_agent_core_model_catalog_covers_live_runpod_rtxa6000_gemma () =
  with_deployment_agent_core_model_catalog @@ fun catalog ->
  let model_id = "gemma4-coder-fable5-q4km" in
  let provider_name = "runpod_rtxa6000" in
  (match
     Llm_provider.Model_catalog.lookup_for_provider catalog ~provider_name ~model_id
   with
   | None ->
     failf
       "expected deployment AGENT_CORE catalog row for provider=%s model=%s"
       provider_name
       model_id
   | Some entry ->
     check (option string) (provider_name ^ " base") (Some "openai_chat")
       entry.base_label;
     check (option int) (provider_name ^ " context") (Some 262144)
       entry.max_context_tokens);
  match
    Llm_provider.Capabilities.for_provider_model_id
      ~wire:None
      ~allow_bare_fallback:false
      ~provider_label:"runpod_rtxa6000"
      ~model_id
  with
  | None ->
    failf
      "live RunPod RTX A6000 Gemma runtime must resolve via raw \
       deployment provider gate path"
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
         caps.thinking_control_format = Chat_template_token "<|think|>"))

let test_deployment_agent_core_model_catalog_covers_local_gemma4_e2b_qat () =
  with_deployment_agent_core_model_catalog @@ fun catalog ->
  let model_id = "hf.co/unsloth/gemma-4-E2B-it-qat-GGUF:UD-Q4_K_XL" in
  let provider_name = "ollama" in
  (match
     Llm_provider.Model_catalog.lookup_for_provider catalog ~provider_name ~model_id
   with
   | None ->
     failf
       "expected deployment AGENT_CORE catalog row for provider=%s model=%s"
       provider_name
       model_id
   | Some entry ->
     check (option string) (provider_name ^ " base") (Some "ollama")
       entry.base_label;
     check (option int) (provider_name ^ " context") (Some 131072)
       entry.max_context_tokens;
     check (option bool) (provider_name ^ " audio input") (Some true)
       entry.supports_audio_input;
     check
       (option string)
       (provider_name ^ " thinking token")
       (Some "<|think|>")
       (match entry.thinking_control_format with
        | Some (Llm_provider.Capabilities.Chat_template_token token) ->
          Some token
        | Some _ | None -> None));
  match
    Llm_provider.Capabilities.for_provider_model_id
      ~wire:None
      ~allow_bare_fallback:false
      ~provider_label:"ollama"
      ~model_id
  with
  | None -> failf "local Gemma4 E2B QAT must resolve via strict Ollama gate path"
  | Some caps ->
    check (option int) "Local Gemma4 E2B context" (Some 131072)
      caps.max_context_tokens;
    check bool "Local Gemma4 E2B tools" true caps.supports_tools;
    check bool "Local Gemma4 E2B forced tool_choice disabled" false
      caps.supports_tool_choice;
    check bool "Local Gemma4 E2B image input" true caps.supports_image_input;
    check bool "Local Gemma4 E2B audio input" true caps.supports_audio_input;
    check bool "Local Gemma4 E2B chat-template token thinking" true
      (Llm_provider.Capabilities.(
         caps.thinking_control_format = Chat_template_token "<|think|>"));
    check
      (option string)
      "Local Gemma4 E2B thinking token"
      (Some "<|think|>")
      (Llm_provider.Capabilities.thinking_control_token_for_provider_model_id
         ~provider_label:"ollama"
         ~model_id)

let test_deployment_agent_core_model_catalog_preserve_axes_resolve () =
  with_deployment_agent_core_model_catalog @@ fun catalog ->
  let expect_provider_catalog_field
        ~field_name
        ~get
        ~provider_name
        ~model_id
        expected
    =
    match
      Llm_provider.Model_catalog.lookup_for_provider catalog ~provider_name ~model_id
    with
    | None ->
      failf
        "expected deployment AGENT_CORE catalog row for provider=%s model=%s"
        provider_name
        model_id
    | Some entry ->
      check (option string) (provider_name ^ " " ^ field_name) (Some expected)
        (get entry)
  in
  let expect_request_side_preserve ~provider_name ~model_id =
    expect_provider_catalog_field
      ~field_name:"preserve_thinking_control_format"
      ~get:(fun entry -> entry.preserve_thinking_control_format)
      ~provider_name
      ~model_id
      "chat_template_kwargs_preserve_thinking";
    match
      Llm_provider.Capabilities.for_provider_model_id
        ~wire:None
        ~allow_bare_fallback:false
        ~provider_label:provider_name
        ~model_id
    with
    | None ->
      failf "expected AGENT_CORE capabilities for provider=%s model=%s" provider_name model_id
    | Some caps ->
      check bool (provider_name ^ " request-side preserve capability") true
        (Llm_provider.Capabilities.(
           caps.preserve_thinking_control_format
           = Chat_template_kwargs_preserve_thinking))
  in
  let expect_preserve_always_replay ~provider_name ~model_id =
    expect_provider_catalog_field
      ~field_name:"reasoning_replay"
      ~get:(fun entry -> entry.reasoning_replay)
      ~provider_name
      ~model_id
      "preserve_always";
    match
      Llm_provider.Capabilities.for_provider_model_id
        ~wire:None
        ~allow_bare_fallback:false
        ~provider_label:provider_name
        ~model_id
    with
    | None ->
      failf "expected AGENT_CORE capabilities for provider=%s model=%s" provider_name model_id
    | Some caps ->
      check bool (provider_name ^ " reasoning replay override") true
        (Llm_provider.Capabilities.(
           caps.reasoning_replay_override = Force_preserve_always))
  in
  let expect_bare_kimi_k27_wire_semantics model_id =
    (match Llm_provider.Model_catalog.lookup catalog model_id with
     | None -> failf "expected deployment AGENT_CORE catalog row for %s" model_id
     | Some entry ->
       check (option string) (model_id ^ " native base") (Some "kimi")
         entry.base_label;
       check bool (model_id ^ " no request thinking knob") true
         (match entry.thinking_control_format with
          | Some Llm_provider.Capabilities.No_thinking_control -> true
          | Some _ | None -> false);
       check (option string) (model_id ^ " always preserved thinking")
         (Some "always_preserved")
         entry.preserve_thinking_control_format;
       check (option string) (model_id ^ " no catalog replay override") None
         entry.reasoning_replay);
    match Llm_provider.Capabilities.for_model_id model_id with
    | None -> failf "expected AGENT_CORE capabilities for %s" model_id
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
  expect_request_side_preserve
    ~provider_name:"runpod_mtp"
    ~model_id:"qwen36-35b-a3b-mtp";
  expect_preserve_always_replay
    ~provider_name:"ollama_cloud"
    ~model_id:"kimi-k2.7-code";
  expect_bare_kimi_k27_wire_semantics "kimi-k2.7-code"

let test_repo_runtime_bindings_resolve_through_agent_core_provider_config () =
  with_deployment_agent_core_model_catalog @@ fun catalog ->
  (match
     Llm_provider.Model_catalog.lookup_for_provider
       catalog
       ~provider_name:"ollama_cloud"
       ~model_id:"deepseek-v4-pro"
   with
   | None -> fail "expected exact Ollama Cloud deepseek-v4-pro catalog row"
   | Some entry ->
     check string "deepseek pro exact model" "deepseek-v4-pro" entry.id_prefix;
     check (option string) "deepseek pro exact provider" (Some "ollama_cloud")
       entry.provider_name;
     check (option int) "deepseek pro context" (Some 524288)
       entry.max_context_tokens;
     check (option bool) "deepseek pro tools" (Some true) entry.supports_tools;
     check (option bool) "deepseek pro reasoning" (Some true)
       entry.supports_reasoning;
     check (option bool) "deepseek pro image input" (Some false)
       entry.supports_image_input);
  let path = Filename.concat (repo_root ()) "config/runtime.toml" in
  match Runtime.load_list ~config_path:path with
  | Error msg -> failf "repo runtime.toml should load: %s" msg
  | Ok
      ( runtimes
      , _default
      , _assignments
      , _media_failover , _lanes ) ->
    check bool "at least one runtime binding" true (List.length runtimes > 0);
    List.iter
      (fun (runtime : Runtime.t) ->
         match
           Llm_provider.Provider_config.capabilities_for_config_model
             (agent_core_provider_config runtime)
         with
         | None ->
           failf
             "runtime binding %s provider/model %s/%s must resolve through its \
              AGENT_CORE Provider_config"
             runtime.id
             (Llm_provider.Provider_config.capability_provider_label
                (agent_core_provider_config runtime))
             (agent_core_provider_config runtime).model_id
         | Some _ ->
           if String.equal runtime.id "ollama_cloud.ollama-cloud-deepseek-v4-pro"
           then
             check
               bool
               "runtime wire controls refine the exact catalog row"
               true
               (Option.is_some
                  (agent_core_provider_config runtime).model_capabilities_override))
      runtimes

let test_deployment_agent_core_model_catalog_modality_priorities_resolve () =
  with_deployment_agent_core_model_catalog @@ fun catalog ->
  let rows =
    List.filter
      (fun (entry : Llm_provider.Model_catalog.model_entry) ->
         Option.is_some entry.modality_priority)
      (Llm_provider.Model_catalog.model_entries catalog)
  in
  check bool "deployment AGENT_CORE catalog has modality priority rows" true (rows <> []);
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
         let capabilities =
           match entry.provider_name with
           | None ->
             Llm_provider.Capabilities.for_model_id_catalog entry.id_prefix
           | Some provider_label ->
             Llm_provider.Capabilities.for_provider_model_id
               ~wire:None
               ~allow_bare_fallback:false
               ~provider_label
               ~model_id:entry.id_prefix
         in
         (match capabilities with
          | None ->
            failf
              "modality_priority row %s must resolve through deployment AGENT_CORE catalog"
              entry.id_prefix
          | Some caps ->
            check
              bool
              (entry.id_prefix ^ " modality_priority resolves")
              true
              (caps.modality_priority = expected)))
    rows

(* [reasoning-effort] is the only declared reasoning control official-client
   runtimes have: Keeper_official_client_host.resolve_reasoning_effort rejects
   enable_thinking outright. Asserting the parsed variant rather than "parsing
   succeeded" is what separates a declaration that reached the model spec from
   one that was accepted and dropped. *)
let test_model_reasoning_effort_parses_into_the_typed_variant () =
  let config =
    "[models.probe]\napi-name = \"probe\"\nreasoning-effort = \"xhigh\"\n"
  in
  match Runtime_toml.parse_string config with
  | Error _ -> fail "a model declaring a known reasoning-effort must parse"
  | Ok parsed ->
    (match parsed.Runtime_schema.models with
     | [ model ] ->
       check
         bool
         "reasoning-effort xhigh reaches the model spec as XHigh"
         true
         (model.Runtime_schema.reasoning_effort
          = Some Llm_provider.Reasoning_effort.XHigh)
     | _ -> fail "exactly one model must parse")

let test_model_reasoning_effort_rejects_unknown_value_at_load () =
  let config =
    "[models.probe]\napi-name = \"probe\"\nreasoning-effort = \"turbo\"\n"
  in
  match Runtime_toml.parse_string config with
  | Ok _ -> fail "an unknown reasoning-effort must be rejected at load"
  | Error errors ->
    check
      bool
      "the rejection names the offending value"
      true
      (List.exists
         (fun (e : Runtime_toml.parse_error) ->
            let contains needle =
              let n = String.length needle in
              let rec scan i =
                i + n <= String.length e.message
                && (String.sub e.message i n = needle || scan (i + 1))
              in
              scan 0
            in
            contains "turbo")
         errors)

let test_model_without_reasoning_effort_leaves_it_unset () =
  let config = "[models.probe]\napi-name = \"probe\"\n" in
  match Runtime_toml.parse_string config with
  | Error _ -> fail "a model without reasoning-effort must still parse"
  | Ok parsed ->
    (match parsed.Runtime_schema.models with
     | [ model ] ->
       check
         bool
         "an undeclared reasoning-effort stays None rather than defaulting"
         true
         (model.Runtime_schema.reasoning_effort = None)
     | _ -> fail "exactly one model must parse")

(* [turn-timeout-s] exists because reasoning effort is per model while the only
   pre-existing bound was per provider (antigravity [timeout-s]) or absent
   entirely (claude-code, codex-app-server, both fixed at 300s in the adapter).
   A max-effort binding could therefore not be given more wall clock than a
   low-effort one sharing its provider. Live evidence, 2026-08-10: keeper
   delta on claude_code.claude-opus-5-max failed every turn with "timed out
   after 300.000s" at 5,884 bytes of system+user input.

   The rejection case is the load-bearing one, but only for values that state
   no intent: a negative or non-finite bound would read as a provider fault
   rather than a config typo. [0] is not in that set — it declares that no
   deadline is installed, which is a posture an operator may want and which
   the sibling case below pins. *)
let test_model_turn_timeout_parses_as_a_positive_float () =
  let config = "[models.probe]\napi-name = \"probe\"\nturn-timeout-s = 900.0\n" in
  match Runtime_toml.parse_string config with
  | Error _ -> fail "a model declaring a positive turn-timeout-s must parse"
  | Ok parsed ->
    (match parsed.Runtime_schema.models with
     | [ model ] ->
       check
         bool
         "turn-timeout-s reaches the model spec"
         true
         (model.Runtime_schema.turn_timeout_s = Some 900.0)
     | _ -> fail "exactly one model must parse")

(* [0] is a declaration, not a typo: it says no deadline is installed, so the
   spawned client decides when its own turn ends. Absent stays distinct from
   it — absent keeps the adapter default — which is what the sibling case
   below pins. Negative and non-finite remain rejected, because neither states
   an intent the adapter can act on. *)
let test_model_turn_timeout_admits_zero_and_rejects_negative () =
  let parse value =
    Runtime_toml.parse_string
      (Printf.sprintf "[models.probe]\napi-name = \"probe\"\nturn-timeout-s = %s\n" value)
  in
  (match parse "0" with
   | Error _ -> fail "turn-timeout-s = 0 must parse: it declares no deadline"
   | Ok parsed ->
     (match parsed.Runtime_schema.models with
      | [ model ] ->
        check
          bool
          "zero reaches the model spec as a declared value"
          true
          (model.Runtime_schema.turn_timeout_s = Some 0.0)
      | _ -> fail "exactly one model must parse"));
  (* Control. Without this, removing the validator entirely would also pass. *)
  match parse "-1.0" with
  | Ok _ -> fail "a negative turn-timeout-s must be rejected at load"
  | Error errors ->
    check
      bool
      "the rejection names the offending key"
      true
      (List.exists
         (fun (e : Runtime_toml.parse_error) ->
            let contains needle =
              let n = String.length needle in
              let rec scan i =
                i + n <= String.length e.path
                && (String.sub e.path i n = needle || scan (i + 1))
              in
              scan 0
            in
            contains "turn-timeout-s")
         errors)

let test_model_without_turn_timeout_leaves_it_unset () =
  let config = "[models.probe]\napi-name = \"probe\"\n" in
  match Runtime_toml.parse_string config with
  | Error _ -> fail "a model without turn-timeout-s must still parse"
  | Ok parsed ->
    (match parsed.Runtime_schema.models with
     | [ model ] ->
       check
         bool
         "an undeclared turn-timeout-s stays None so the caller keeps its bound"
         true
         (model.Runtime_schema.turn_timeout_s = None)
     | _ -> fail "exactly one model must parse")

(* [wall-clock-ceiling-s] bounds the WHOLE turn and never resets on protocol
   messages, so unlike [turn-timeout-s] there is no "0 removes the bound"
   posture: the ceiling is the fail-safe against a turn that keeps emitting
   forever (masc#31364's 1h+ turn shape), and the config may tighten it but
   not delete it. *)
let test_model_wall_clock_ceiling_parses_as_a_positive_float () =
  let config =
    "[models.probe]\napi-name = \"probe\"\nwall-clock-ceiling-s = 7200.0\n"
  in
  match Runtime_toml.parse_string config with
  | Error _ -> fail "a model declaring a positive wall-clock-ceiling-s must parse"
  | Ok parsed ->
    (match parsed.Runtime_schema.models with
     | [ model ] ->
       check
         bool
         "wall-clock-ceiling-s reaches the model spec"
         true
         (model.Runtime_schema.wall_clock_ceiling_s = Some 7200.0)
     | _ -> fail "exactly one model must parse")

let test_model_wall_clock_ceiling_rejects_zero_and_negative () =
  let parse value =
    Runtime_toml.parse_string
      (Printf.sprintf
         "[models.probe]\napi-name = \"probe\"\nwall-clock-ceiling-s = %s\n"
         value)
  in
  let names_the_key = function
    | Ok _ -> false
    | Error errors ->
      List.exists
        (fun (e : Runtime_toml.parse_error) ->
           let needle = "wall-clock-ceiling-s" in
           let n = String.length needle in
           let rec scan i =
             i + n <= String.length e.path
             && (String.sub e.path i n = needle || scan (i + 1))
           in
           scan 0)
        errors
  in
  check bool "zero is rejected: the ceiling cannot be removed" true
    (names_the_key (parse "0"));
  check bool "negative is rejected and names the key" true
    (names_the_key (parse "-1.0"))

let test_model_without_wall_clock_ceiling_leaves_it_unset () =
  let config = "[models.probe]\napi-name = \"probe\"\n" in
  match Runtime_toml.parse_string config with
  | Error _ -> fail "a model without wall-clock-ceiling-s must still parse"
  | Ok parsed ->
    (match parsed.Runtime_schema.models with
     | [ model ] ->
       check
         bool
         "an undeclared wall-clock-ceiling-s stays None (runtime default)"
         true
         (model.Runtime_schema.wall_clock_ceiling_s = None)
     | _ -> fail "exactly one model must parse")

let test_exact_output_lane_config_is_ordered_and_rejects_duplicates () =
  let valid =
    "[runtime.exact_output_lanes.auxiliary_exact]\nslots = [\"slot-b\", \"slot-a\"]\n"
  in
  (match Runtime_toml.parse_string valid with
   | Error _ -> fail "valid exact-output lane must parse"
   | Ok config ->
     (match config.Runtime_schema.exact_output_lane_decls with
      | [ lane ] ->
        check (list string) "declaration order is preserved"
          [ "slot-b"; "slot-a" ] lane.slot_ids
      | _ -> fail "exactly one exact-output lane must parse"));
  let duplicate =
    "[runtime.exact_output_lanes.auxiliary_exact]\nslots = [\"slot-a\", \"slot-a\"]\n"
  in
  match Runtime_toml.parse_string duplicate with
  | Error _ -> ()
  | Ok _ -> fail "duplicate exact-output slots must fail config parsing"

let test_exact_output_lane_cli_slots_parse_in_order () =
  let config =
    "[runtime.exact_output_lanes.hitl_auto_judge]\n\
     slots = [\"slot-a\"]\n\
     cli_slots = [\"antigravity_subscription.gemini-3-7-flash-high\", \"claude_subscription.claude-opus-5\"]\n"
  in
  (match Runtime_toml.parse_string config with
   | Error _ -> fail "cli_slots must parse"
   | Ok config ->
     (match config.Runtime_schema.exact_output_lane_decls with
      | [ lane ] ->
        check (list string) "cli declaration order is preserved"
          [ "antigravity_subscription.gemini-3-7-flash-high"
          ; "claude_subscription.claude-opus-5"
          ]
          lane.cli_slot_ids
      | _ -> fail "exactly one exact-output lane must parse"));
  let absent = "[runtime.exact_output_lanes.hitl_auto_judge]\nslots = [\"slot-a\"]\n" in
  (match Runtime_toml.parse_string absent with
   | Error _ -> fail "a lane without cli_slots must parse"
   | Ok config ->
     (match config.Runtime_schema.exact_output_lane_decls with
      | [ lane ] ->
        check (list string) "absent cli_slots means HTTP-only" [] lane.cli_slot_ids
      | _ -> fail "exactly one exact-output lane must parse"));
  let duplicate =
    "[runtime.exact_output_lanes.hitl_auto_judge]\n\
     slots = [\"slot-a\"]\n\
     cli_slots = [\"rt.x\", \"rt.x\"]\n"
  in
  match Runtime_toml.parse_string duplicate with
  | Error _ -> ()
  | Ok _ -> fail "duplicate cli slots must fail config parsing"

let test_exact_output_lane_rejects_unknown_key () =
  let config =
    "[runtime.exact_output_lanes.auxiliary_exact]\n\
     slots = [\"slot-a\"]\n\
     slost = [\"slot-b\"]\n"
  in
  match Runtime_toml.parse_string config with
  | Error errors ->
    check bool "unknown exact-output lane key is named" true
      (List.exists
         (fun (error : Runtime_toml.parse_error) ->
            String.equal
              error.path
              "runtime.exact_output_lanes.auxiliary_exact.slost")
         errors)
  | Ok _ -> fail "unknown exact-output lane key must fail config parsing"

(* The routing rebirth (RFC-0206) dropped the lane strategy ADT — a lane is
   ordered by construction — but a [strategy = "ordered"] line survived in the
   seed config and fixtures because the lane parser silently skipped keys it
   did not read. The concrete unknown key here is that purged line, so a
   reintroduction fails this test by name. *)
let test_lane_rejects_unknown_key () =
  let config =
    "[runtime.lanes.default]\n\
     strategy = \"ordered\"\n\
     candidates = [\"local.sample\"]\n"
  in
  match Runtime_toml.parse_string config with
  | Error errors ->
    check bool "unknown lane key is named" true
      (List.exists
         (fun (error : Runtime_toml.parse_error) ->
            String.equal error.path "runtime.lanes.default.strategy")
         errors)
  | Ok _ -> fail "unknown lane key must fail config parsing"

(* A [models.X].max-context above the model's catalog window resolves to the
   catalog number with source Override_clamped_by_capability: the declaration
   is clamped away and reaches nothing. Two shipped runtimes carried one, and
   one of them — glm-coding.glm-5-turbo, declaring 203000 against a catalog
   window of 200000 — was cited in #28737 as this model's context window while
   the number in effect was the catalog's (#28738).

   The clamp itself stays — it is the safe direction if the catalog ever
   shrinks under a deployment's override. What must not ship is a declaration
   that reads as authoritative and is not. This drives the real resolver over
   the real config rather than reading the file as text. *)
let test_repo_runtime_toml_declares_no_clamped_max_context () =
  with_deployment_agent_core_model_catalog @@ fun _catalog ->
  let path = Filename.concat (repo_root ()) "config/runtime.toml" in
  match Runtime.load_list ~config_path:path with
  | Error msg -> failf "repo runtime.toml should load: %s" msg
  | Ok (runtimes, _default, _assignments, _media_failover, _lanes) ->
    let clamped =
      List.filter_map
        (fun (rt : Runtime.t) ->
           match Runtime.resolve_max_context_of_runtime rt with
           | Some (effective, Runtime.Override_clamped_by_capability) ->
             Some
               (Printf.sprintf
                  "%s declares %s and the catalog gives %d"
                  rt.Runtime.id
                  (match rt.Runtime.model.Runtime_schema.max_context with
                   | Some declared -> string_of_int declared
                   | None -> "<none>")
                  effective)
           | Some (_, (Runtime.Override | Runtime.Capability)) | None -> None)
        runtimes
    in
    check (list string)
      "no shipped runtime declares a max-context its model cannot take"
      []
      (List.sort String.compare clamped)

(* Both the self-hosted server templates (llama.cpp, vLLM, MLX) and the official
   client examples ship commented out. A provider declared as live TOML has to be
   fully enabled with a concrete binding or the install wizard refuses it
   ("has no concrete runtime binding"), and none of these servers exists on a
   fresh install. Commented TOML is never parsed, so without a gate the examples
   rot in place and the operator finds out months later. Both tests below
   uncomment one region and drive the real resolver over the result.

   A region runs from its heading to the first live TOML line after it. Only
   lines that look like TOML get uncommented; the prose around them stays put. *)
let line_contains ~(needle : string) (haystack : string) : bool =
  let nl = String.length needle and hl = String.length haystack in
  nl <= hl
  && (let rec scan i =
        i + nl <= hl && (String.equal (String.sub haystack i nl) needle || scan (i + 1))
      in
      scan 0)
;;

let self_hosted_example_marker = "Self-hosted OpenAI-compatible servers"
let official_client_example_marker = "Official Claude Code subscription runtime example"

let uncomment_example_region ~(marker : string) (content : string) : string =
  let rec walk acc inside = function
    | [] -> List.rev acc
    | line :: rest ->
      let inside =
        inside
        || (String.length line > 0 && line.[0] = '#' && line_contains ~needle:marker line)
      in
      if not inside
      then walk (line :: acc) false rest
      else if String.equal (String.trim line) ""
      then walk (line :: acc) true rest
      else if String.length line > 0 && line.[0] <> '#'
      then (* first live TOML line ends the region; the rest is verbatim *)
        List.rev_append acc (line :: rest)
      else (
        let body =
          if String.length line >= 2 && String.equal (String.sub line 0 2) "# "
          then String.sub line 2 (String.length line - 2)
          else if String.equal line "#"
          then ""
          else line
        in
        (* A table header, or a bare key followed by " = ". Requiring the key to
           be space-free keeps prose that happens to quote an assignment
           mid-sentence from being uncommented into the middle of a document. *)
        let looks_like_toml =
          (String.length body > 0 && body.[0] = '[')
          ||
          match String.index_opt body '=' with
          | Some i when i >= 2 && body.[i - 1] = ' ' ->
            let key = String.sub body 0 (i - 1) in
            String.length key > 0 && not (String.contains key ' ')
          | Some _ | None -> false
        in
        walk ((if looks_like_toml then body else line) :: acc) true rest)
  in
  String.concat "\n" (walk [] false (String.split_on_char '\n' content))
;;

let seed_runtime_toml () =
  let seed_path = Filename.concat (repo_root ()) "config/runtime.toml" in
  let ic = open_in_bin seed_path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let with_uncommented_seed ~marker f =
  let content = seed_runtime_toml () in
  if not
       (List.exists
          (fun line -> String.length line > 0 && line.[0] = '#' && line_contains ~needle:marker line)
          (String.split_on_char '\n' content))
  then failf "example heading moved; update this gate: %s" marker;
  let path = Filename.temp_file "seed_example_" ".toml" in
  Fun.protect
    ~finally:(fun () ->
       try Sys.remove path with
       | _ -> ())
    (fun () ->
       let oc = open_out path in
       output_string oc (uncomment_example_region ~marker content);
       close_out oc;
       match Runtime.load_list ~config_path:path with
       | Error msg ->
         failf "uncommented example region should load (%s): %s" marker msg
       | Ok (runtimes, _default, _assignments, _media_failover, _lanes) -> f runtimes)
;;

(* The three self-hosted stacks disagree on exactly the features a keeper turn
   depends on, and none of them has a catalog row, so each lands in
   runtime_adapter's no-catalog branch where the runtime.toml block is the whole
   declaration. That is what makes these assertions meaningful rather than a
   readback of the catalog. *)
let self_hosted_template_cases =
  [ ( "llama_server.llama-server-local"
    , 262144
      (* measured on llama.cpp build 10180: json_schema honoured exactly, two
         tool calls in one turn, tool_choice "required" answered in prose *)
    , true (* structured output *)
    , false (* required tool choice *)
    , true (* parallel tool calls *) )
  ; ( "vllm.vllm-served-model"
    , 262144
      (* vLLM docs: "required" rides the structured-outputs backend; parallel
         tool calls are parser- and model-dependent, so the row does not claim
         them *)
    , true
    , true
    , false )
  ; ( "mlx_server.mlx-served-model"
    , 262144
      (* mlx_lm.server takes no tool_choice and validates no JSON schema *)
    , false
    , false
    , false )
  ]
;;

let test_self_hosted_templates_resolve_when_enabled () =
  with_deployment_agent_core_model_catalog @@ fun _catalog ->
  with_uncommented_seed ~marker:self_hosted_example_marker
  @@ fun runtimes ->
  List.iter
    (fun (runtime_id, context, structured, required_choice, parallel_calls) ->
       match
         List.find_opt
           (fun (rt : Runtime.t) -> String.equal rt.Runtime.id runtime_id)
           runtimes
       with
       | None -> failf "uncommenting the example did not produce runtime %s" runtime_id
       | Some runtime ->
         (match
            Llm_provider.Provider_config.capabilities_for_config_model
              (agent_core_provider_config runtime)
          with
          | None -> failf "%s must resolve capabilities without a catalog row" runtime_id
          | Some caps ->
            check (option int) (runtime_id ^ " context") (Some context)
              caps.max_context_tokens;
            check bool (runtime_id ^ " structured output") structured
              caps.supports_structured_output;
            check bool (runtime_id ^ " required tool choice") required_choice
              caps.supports_required_tool_choice;
            check bool (runtime_id ^ " parallel tool calls") parallel_calls
              caps.supports_parallel_tool_calls))
    self_hosted_template_cases
;;

(* The Claude Code example has shipped commented since before this gate existed
   and was never parsed by anything; the Codex and Antigravity ones arrive the
   same way. A stale command name, a missing required provider field, or a key
   the parser no longer takes fails here now. *)
let test_commented_official_client_examples_load () =
  with_deployment_agent_core_model_catalog @@ fun _catalog ->
  with_uncommented_seed ~marker:official_client_example_marker
  @@ fun runtimes ->
  let ids = List.map (fun (rt : Runtime.t) -> rt.Runtime.id) runtimes in
  List.iter
    (fun expected ->
       if not (List.exists (String.equal expected) ids)
       then failf "uncommenting the examples did not produce %s" expected)
    [ "claude_code.claude-code-sonnet"
    ; "claude_code.claude-code-opus-high"
    ; "codex_subscription.codex-gpt-5-6"
    ; "antigravity_subscription.antigravity-gemini-3-7-flash-high"
    ]
;;

(* The capability probe on 2026-08-13 sent 36 requests to the kimi_coding
   models and all 36 came back carrying thinking while nothing declared it, so
   every one logged Thinking_returned_but_declared_unsupported (#28457). Two of
   those three models have since left the catalog entirely; this is the one
   that remains, and the declaration is what stops the drift from returning
   the moment a runtime binds it again. *)
let test_kimi_for_coding_declares_the_reasoning_it_returns () =
  with_deployment_agent_core_model_catalog @@ fun _catalog ->
  match
    Llm_provider.Capabilities.for_provider_model_id
      ~wire:None
      ~allow_bare_fallback:false
      ~provider_label:"kimi_code"
      ~model_id:"kimi-for-coding"
  with
  | None -> fail "kimi-for-coding missing from the deployment catalog"
  | Some caps ->
    check bool "declares reasoning" true
      caps.Llm_provider.Capabilities.supports_reasoning;
    check bool "declares extended thinking" true
      caps.Llm_provider.Capabilities.supports_extended_thinking

let test_repo_runtime_toml_loads () =
  with_deployment_agent_core_model_catalog @@ fun _catalog ->
  let path = Filename.concat (repo_root ()) "config/runtime.toml" in
  check bool "repo runtime.toml present" true (Sys.file_exists path);
  match Runtime.load_list ~config_path:path with
  | Error msg -> failf "repo runtime.toml should load: %s" msg
  | Ok
      ( runtimes
      , default
      , assignments
      , media_failover
      , lanes ) ->
    check bool "at least one runtime" true (List.length runtimes > 0);
    check string "default runtime" "ollama_cloud.deepseek-v4-flash"
      default.Runtime.id;
    (match Runtime_toml.parse_file path with
     | Error _ -> fail "repo runtime.toml exact-output lanes must parse"
     | Ok config ->
let lane_signatures =
  config.exact_output_lane_decls
  |> List.map (fun (lane : Runtime_schema.exact_output_lane_decl) ->
    lane.id, lane.slot_ids)
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
in
check
  (list string)
  "public seed exact-output lane ids"
  [ "board_attention_exact"
  ; "hitl_auto_judge"
  ; "librarian_exact"
  ; "verifier_exact"
  ]
  (List.map fst lane_signatures);
check
  (list (pair string (list string)))
  "Board exact-output lanes and opaque slot order"
  [ ( "board_attention_exact"
    , [ "glm-coding.glm-5-3"; "ollama_cloud.deepseek-v4-flash-0731" ] )
  ; ( "hitl_auto_judge"
    , [ "glm-coding.glm-5-3"; "ollama_cloud.deepseek-v4-flash-0731" ] )
  ]
  (List.filter
     (fun (lane_id, _) ->
       String.equal lane_id "board_attention_exact"
       || String.equal lane_id "hitl_auto_judge")
     lane_signatures);
(* RFC-0361 D7(a): the completion-authority judgement lane is the single
   provider-selection SSOT and failover follows declaration order. *)
check
  (option (list string))
  "verifier_exact slot order is frozen"
  (Some [ "glm-coding.glm-5-3"; "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731" ])
  (match
     List.find_opt
       (fun (lane_id, _) -> String.equal lane_id "verifier_exact")
       lane_signatures
   with
   | Some (_, slot_ids) -> Some slot_ids
   | None -> None);
List.iter
  (fun (lane : Runtime_schema.exact_output_lane_decl) ->
     check bool
       (Printf.sprintf "%s has at least one target" lane.id)
       true
       (not (List.is_empty lane.slot_ids)))
  config.exact_output_lane_decls);
    check (option (float 0.0)) "Ollama Cloud connect timeout override"
      (Some 600.0)
      (agent_core_provider_config default).connect_timeout_s;
    check int "public seed has no keeper assignments" 0
      (List.length assignments);
    let keeper_dispatch_ids =
      Runtime.For_testing.keeper_dispatch_runtime_ids
        ~default_runtime_id:default.id
        ~assignments
        ~verifier_exact_slot_ids:
          (* pinned to the seed by the verifier_exact lane check above *)
          [ "glm-coding.glm-5-turbo"; "kimi_coding.kimi-for-coding" ]
        ~media_failover
        ~lanes
    in
    List.iter
      (fun runtime_id ->
         match
           List.find_opt
             (fun (runtime : Runtime.t) -> String.equal runtime.id runtime_id)
             runtimes
         with
         | None -> failf "expected bounded Keeper runtime in seed: %s" runtime_id
         | Some runtime ->
           (match (agent_core_provider_config runtime).max_request_body_bytes with
            | Some cap when cap > 0 -> ()
            | None | Some _ ->
              failf
                "%s must declare a positive exact request body budget"
                runtime_id))
      keeper_dispatch_ids;
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
            String.equal runtime.id "glm-coding.glm-4-7-coding")
         runtimes
     with
     | None -> fail "expected GLM Coding Plan runtime in seed"
     | Some runtime ->
       check string "GLM Coding Plan model api name" "glm-4.7"
         runtime.model.api_name;
       check (option int) "GLM Coding Plan context" (Some 200000) runtime.model.max_context;
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
       check (option (float 0.0)) "DeepSeek keeps AGENT_CORE connect timeout default"
         None
         (agent_core_provider_config runtime).connect_timeout_s;
       (match runtime.model.capabilities with
        | Some caps ->
          check bool "DeepSeek Pro structured output disabled" false
            caps.supports_structured_output
        | None -> fail "expected DeepSeek Pro capabilities"));
    (match
       List.find_opt
         (fun (runtime : Runtime.t) ->
            String.equal runtime.id "deepseek.deepseek-v4-flash")
         runtimes
     with
     | None -> fail "expected DeepSeek Flash runtime in seed"
     | Some runtime ->
       (match runtime.model.capabilities with
        | Some caps ->
          check bool "DeepSeek Flash structured output disabled" false
            caps.supports_structured_output
        | None -> fail "expected DeepSeek Flash capabilities"));
    (match
       List.find_opt
         (fun (runtime : Runtime.t) ->
            String.equal runtime.id "ollama_cloud.minimax-m3")
         runtimes
     with
     | None -> fail "expected MiniMax M3 Ollama Cloud runtime in seed"
     | Some runtime ->
       check string "MiniMax M3 api name" "minimax-m3" runtime.model.api_name;
       check (option int) "MiniMax M3 context" (Some 524288) runtime.model.max_context;
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
         (agent_core_provider_config runtime).connect_timeout_s;
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
            String.equal runtime.id "ollama_cloud.kimi-k2-7-code")
         runtimes
     with
     | None -> fail "expected Kimi K2.7 Code Ollama Cloud runtime in seed"
     | Some runtime ->
       check string "Kimi K2.7 Code api name" "kimi-k2.7-code" runtime.model.api_name;
       (* Effective window, not the declaration: what matters is what the
          runtime resolves, and an override only holds while it stays under
          the model's catalog window (#28738). *)
       check (option int) "Kimi K2.7 Code context" (Some 262144)
         (Runtime.resolve_max_context_of_runtime runtime |> Option.map fst);
       (match runtime.model.capabilities with
        | Some caps ->
          check bool "Kimi K2.7 Code image input" true caps.supports_image_input;
          check bool "Kimi K2.7 Code multimodal input" true
            caps.supports_multimodal_inputs;
          (* ollama.com /v1 reasons inherently and takes no control field, so
             this model declares no thinking control. See the comment on
             [expected_thinking_format] above for the measurement. *)
          check bool "Kimi K2.7 Code thinking control" true
            (Runtime_schema.equal_thinking_control_format
               caps.thinking_control_format
               Runtime_schema.No_thinking_control)
        | None -> fail "expected Kimi K2.7 Code capabilities"))

(* The lane-resolution test below iterates the lanes a config declares, so it
   passes vacuously on a config that declares none of them. Startup does the
   opposite: it requires every id in
   Server_runtime_bootstrap.mandatory_exact_output_lane_ids to be present with a
   non-empty slot list and synthesizes nothing. Absence is therefore the failure
   mode no existing test could see — #25671 added hitl_auto_judge and main failed
   every push for ~29 hours because the boot path that would have caught it runs
   only on push-to-main (#25663). This asserts presence, against the same value
   startup reads. *)
let render_runtime_toml_errors (errors : Runtime_toml.parse_error list) =
  errors
  |> List.map (fun (error : Runtime_toml.parse_error) ->
    Printf.sprintf "%s: %s" error.path error.message)
  |> String.concat "; "
;;

let assert_mandatory_exact_output_lanes_declared ~label path =
  check bool (label ^ " exists") true (Sys.file_exists path);
  match Runtime_toml.parse_file path with
  | Error errors -> failf "%s should load: %s" label (render_runtime_toml_errors errors)
  | Ok (config : Runtime_schema.config) ->
    List.iter
      (fun lane_id ->
         match
           List.find_opt
             (fun (lane : Runtime_schema.exact_output_lane_decl) ->
                String.equal lane.id lane_id)
             config.exact_output_lane_decls
         with
         | None ->
           failf
             "%s must declare mandatory exact-output lane %s; startup raises \
              Config_error instead of synthesizing it"
             label
             lane_id
         | Some { slot_ids = []; _ } ->
           failf
             "%s declares mandatory exact-output lane %s with no slots; startup \
              requires at least one AGENT_CORE target ref"
             label
             lane_id
         | Some { slot_ids = _ :: _; _ } -> ())
      Server_runtime_bootstrap.mandatory_exact_output_lane_ids
;;

let boot_path_fixtures_root () =
  Filename.concat (repo_root ()) "scripts/fixtures"
;;

let release_evidence_fixture_dir () =
  Filename.concat (boot_path_fixtures_root ()) "release-evidence"
;;

(* Discovered, not enumerated: any scripts/fixtures/<name>/runtime.toml is a
   boot-path config and is checked without touching this test. Enumerating the
   sites by hand is what let four of them be patched in #25700 while the fifth
   drifted. *)
let discover_boot_path_fixture_runtime_tomls () =
  let root = boot_path_fixtures_root () in
  if not (Sys.file_exists root) then []
  else
    Sys.readdir root
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter_map (fun entry ->
      let candidate = Filename.concat (Filename.concat root entry) "runtime.toml" in
      if Sys.file_exists candidate then Some ("scripts/fixtures/" ^ entry ^ "/runtime.toml", candidate)
      else None)
;;

let test_repo_runtime_toml_declares_mandatory_exact_output_lanes () =
  assert_mandatory_exact_output_lanes_declared
    ~label:"config/runtime.toml"
    (Filename.concat (repo_root ()) "config/runtime.toml")
;;

let test_boot_path_fixtures_declare_mandatory_exact_output_lanes () =
  let fixtures = discover_boot_path_fixture_runtime_tomls () in
  (* Without this the scan below passes vacuously when discovery finds nothing —
     the same absence-is-invisible shape this whole test exists to reject. *)
  check bool "at least one boot-path fixture was discovered" true (fixtures <> []);
  List.iter
    (fun (label, path) -> assert_mandatory_exact_output_lanes_declared ~label path)
    fixtures
;;

(* release-evidence.sh boots the installed binary in a credential-less CI job,
   so the second startup gate (require_usable_mandatory_exact_output_lanes,
   which calls resolve_lane) only passes if the fixture's lane slots are
   admitted and resolved with no environment secret at all. getenv returns
   Ok None for every name here, which is stricter than CI: any fixture slot that
   grows an api_key_env fails this test instead of failing a push to main. *)
let test_release_evidence_fixture_lanes_resolve_without_credentials () =
  let fixture_dir = release_evidence_fixture_dir () in
  let overlay_path = Filename.concat fixture_dir "agent-core-models-overlay.toml" in
  let overlay_contents =
    try In_channel.with_open_bin overlay_path In_channel.input_all with
    | Sys_error detail ->
      failf "release-evidence smoke overlay cannot be read: %s" detail
  in
  let io : Exact_output.resolver_io = { getenv = (fun _ -> Ok None) } in
  let snapshot =
    match
      Exact_output.load_resolver_snapshot
        ~io
        ~catalog:
          (Exact_output.Embedded_with_overlay
             { source = overlay_path; contents = overlay_contents })
        ()
    with
    | Ok snapshot -> snapshot
    | Error _ -> fail "release-evidence smoke overlay should load"
  in
  match
    Runtime_toml.parse_file (Filename.concat fixture_dir "runtime.toml")
  with
  | Error errors ->
    failf
      "release-evidence smoke runtime.toml should load: %s"
      (render_runtime_toml_errors errors)
  | Ok (config : Runtime_schema.config) ->
    let default_runtime_id =
      match config.default_runtime_id with
      | Some runtime_id -> runtime_id
      | None -> fail "release-evidence smoke runtime.toml must declare a default runtime"
    in
    let default_binding =
      match
        List.find_opt
          (fun (binding : Runtime_schema.binding) ->
             String.equal
               (Runtime_schema.binding_key binding)
               default_runtime_id)
          config.bindings
      with
      | Some binding -> binding
      | None ->
        failf
          "release-evidence smoke default runtime %s must resolve to a binding"
          default_runtime_id
    in
    check
      bool
      "release-evidence smoke default runtime has a positive request-body cap"
      true
      (match default_binding.max_request_body_bytes with
       | Some cap -> cap > 0
       | None -> false);
    List.iter
      (fun lane_id ->
         match
           List.find_opt
             (fun (lane : Runtime_schema.exact_output_lane_decl) ->
                String.equal lane.id lane_id)
             config.exact_output_lane_decls
         with
         | None ->
           failf
             "release-evidence smoke runtime.toml must declare lane %s"
             lane_id
         | Some lane ->
           check bool
             (Printf.sprintf "lane %s has slots" lane_id)
             true
             (lane.slot_ids <> []);
           List.iter
             (fun target_ref ->
                match Exact_output.admit_target_ref snapshot target_ref with
                | Error _ ->
                  failf
                    "release-evidence smoke lane %s target %s must exist in the \
                     overlaid catalog"
                    lane_id
                    target_ref
                | Ok admitted_target ->
                  (match Exact_output.resolve_target admitted_target with
                   | Ok _ -> ()
                   | Error _ ->
                     failf
                       "release-evidence smoke lane %s target %s must resolve \
                        with no credential in the environment"
                       lane_id
                       target_ref))
             lane.slot_ids)
      Server_runtime_bootstrap.mandatory_exact_output_lane_ids
;;

let test_deployment_exact_output_catalog_admits_seed_lanes () =
  let root = repo_root () in
  let runtime_path = Filename.concat root "config/runtime.toml" in
  let overlay_path = Filename.concat root "config/agent-core-models-overlay.toml" in
  let overlay_contents =
    try In_channel.with_open_bin overlay_path In_channel.input_all with
    | Sys_error detail ->
      failf "deployment exact-output catalog cannot be read: %s" detail
  in
  let io : Exact_output.resolver_io =
    { getenv =
        (function
          | "ZAI_CODING_API_KEY" | "ZAI_API_KEY_SB" | "KIMI_API_KEY" ->
            Ok (Some "exact-output-seed-test")
          | _ -> Ok None)
    }
  in
  let snapshot =
    match
      Exact_output.load_resolver_snapshot
        ~io
        ~catalog:
          (Exact_output.Embedded_with_overlay
             { source = overlay_path; contents = overlay_contents })
        ()
    with
    | Ok snapshot -> snapshot
    | Error _ -> fail "deployment exact-output catalog should load"
  in
  let output_requirement =
    Exact_output.make_output_requirement
      ~schema:
        (`Assoc
           [ "type", `String "object"
           ; "properties", `Assoc []
           ; "additionalProperties", `Bool false
           ])
      ~minimum_guarantee:Exact_output.Json_syntax
  in
  let messages =
    [ Agent_core.Types.text_message
        Agent_core.Types.User
        "Return one JSON object."
    ]
  in
  match Runtime_toml.parse_file runtime_path with
  | Error _ -> fail "repo runtime.toml exact-output lanes must parse"
  | Ok config ->
    List.iter
      (fun (lane : Runtime_schema.exact_output_lane_decl) ->
         List.iter
           (fun target_ref ->
              match Exact_output.admit_target_ref snapshot target_ref with
              | Ok admitted_target ->
                (match Exact_output.resolve_target admitted_target with
                 | Error _ ->
                   failf
                     "exact-output lane %s target %s must resolve with fixture credentials"
                     lane.id
                     target_ref
                 | Ok target ->
                   (match
                      Exact_output.admit
                        ~target
                        ~messages
                        output_requirement
                    with
                    | Ok _ -> ()
                    | Error _ ->
                      failf
                        "exact-output lane %s target %s must satisfy Json_syntax"
                        lane.id
                        target_ref))
              | Error _ ->
                failf
                  "exact-output lane %s target %s must exist in the frozen catalog"
                  lane.id
                  target_ref)
           lane.slot_ids)
      config.exact_output_lane_decls

let test_toml_catalog_resolves_web_search_keys () =
  let doc =
    parse_or_fail
      "[web_search]\n\
       searxng_url = \"http://localhost:8888\"\n\
       provider = \"auto\"\n\
       provider_order = \"searxng,brave,tavily\"\n\
       fallbacks = \"tavily,exa\"\n\
       timeout_sec = 12\n\
       cache_ttl_sec = 45.5\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied web search overrides" 6 count;
  check (option string) "searxng url" (Some "http://localhost:8888")
    (List.assoc_opt "MASC_SEARXNG_URL" overrides);
  check (option string) "provider" (Some "auto")
    (List.assoc_opt "MASC_WEB_SEARCH_PROVIDER" overrides);
  check (option string) "provider order" (Some "searxng,brave,tavily")
    (List.assoc_opt "MASC_WEB_SEARCH_PROVIDER_ORDER" overrides);
  check (option string) "fallbacks" (Some "tavily,exa")
    (List.assoc_opt "MASC_WEB_SEARCH_FALLBACKS" overrides);
  check (option string) "timeout" (Some "12")
    (List.assoc_opt "MASC_WEB_SEARCH_TIMEOUT_SEC" overrides);
  check (option string) "cache ttl" (Some "45.5")
    (List.assoc_opt "MASC_WEB_SEARCH_CACHE_TTL_SEC" overrides);
  let preempt_searxng name =
    if String.equal name "MASC_SEARXNG_URL"
    then Some "http://operator.example"
    else None
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:preempt_searxng doc
  in
  check int "env preempts only searxng url" 5 count;
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
    check bool "default runtime resolves through atomic cache"
      true
      (match Runtime.get_default_runtime () with
       | Some rt -> Option.is_some (Runtime.get_runtime_by_id rt.id)
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

let test_runtime_toml_parses_optional_max_request_body_bytes () =
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
     max-request-body-bytes = 1048576\n\
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
    failf "runtime TOML should parse optional max-request-body-bytes:\n%s" rendered
  | Ok cfg ->
    (match cfg.Runtime_schema.bindings with
     | [ binding ] ->
       check (option int) "explicit max-request-body-bytes opt-in" (Some 1048576)
         binding.Runtime_schema.max_request_body_bytes
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

(* RFC-0382 §7: return-progress is a binding-level opt-in (like keep-alive /
   num-ctx) that asks an OpenAI-compat server to stream prompt_progress chunks
   during prefill. Omitted must stay None — only an explicit declaration may
   put the field on the wire. *)
let test_runtime_toml_parses_optional_return_progress () =
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
     return-progress = true\n\
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
    failf "runtime TOML should parse optional return-progress:\n%s" rendered
  | Ok cfg ->
    (match cfg.Runtime_schema.bindings with
     | [ binding ] ->
       check (option bool) "explicit return-progress opt-in" (Some true)
         binding.Runtime_schema.return_progress
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

(* An R1-style reasoning model can restate the same thought until the turn
   dies, and Ollama's own control for that is repeat_penalty over
   repeat_last_n tokens. Neither could be declared at all, so the remedy was
   unreachable from configuration. Binding-level like keep-alive / num-ctx,
   because both are Ollama options rather than a portable sampling knob. *)
let test_runtime_toml_parses_repetition_samplers () =
  let content =
    "[providers.local]\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://127.0.0.1:11434\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     repeat-penalty = 1.15\n\
     repeat-last-n = 1024\n\
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
    failf "runtime TOML should parse the repetition samplers:\n%s" rendered
  | Ok cfg ->
    (match cfg.Runtime_schema.bindings with
     | [ binding ] ->
       check (option int) "explicit repeat-last-n" (Some 1024)
         binding.Runtime_schema.repeat_last_n;
       (match binding.Runtime_schema.repeat_penalty with
        | Some value -> check bool "explicit repeat-penalty" true (Float.equal value 1.15)
        | None -> failf "repeat-penalty should be declared")
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

let test_runtime_toml_omitted_repetition_samplers_stay_none () =
  let content = "[providers.local]\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://127.0.0.1:11434\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n" in
  match Runtime_toml.parse_string content with
  | Error _ -> failf "runtime TOML without the samplers should still parse"
  | Ok cfg ->
    (match cfg.Runtime_schema.bindings with
     | [ binding ] ->
       check (option int) "omitted repeat-last-n stays None" None
         binding.Runtime_schema.repeat_last_n;
       check bool "omitted repeat-penalty stays None" true
         (Option.is_none binding.Runtime_schema.repeat_penalty)
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

(* 0 and below would silence the sampler while reading as "configured", so the
   declaration is rejected instead of being carried onto the wire. *)
let test_runtime_toml_rejects_non_positive_repeat_penalty () =
  let content = "[providers.local]\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://127.0.0.1:11434\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     repeat-penalty = 0.0\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n" in
  match Runtime_toml.parse_string content with
  | Ok _ -> failf "repeat-penalty = 0.0 should be rejected"
  | Error errs ->
    check bool "names the offending key" true
      (List.exists
         (fun (err : Runtime_toml.parse_error) ->
           String.equal err.path "local.sample.repeat-penalty")
         errs)

(* -1 is Ollama's "the whole context"; anything below it has no meaning. *)
let test_runtime_toml_rejects_repeat_last_n_below_minus_one () =
  let content = "[providers.local]\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://127.0.0.1:11434\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     repeat-last-n = -2\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n" in
  match Runtime_toml.parse_string content with
  | Ok _ -> failf "repeat-last-n = -2 should be rejected"
  | Error errs ->
    check bool "names the offending key" true
      (List.exists
         (fun (err : Runtime_toml.parse_error) ->
           String.equal err.path "local.sample.repeat-last-n")
         errs)

(* The samplers above are Ollama /api/chat [options] fields. Declared against a
   provider that speaks anything else there is no request field to carry them,
   and before this Gate the value was accepted, dropped, and never reported --
   so a deployment could "configure" the repetition remedy on an
   OpenAI-compatible lane and watch the loop continue. Probed 2026-08-25 against
   ollama.com/v1 with deepseek-v4-flash:0731 at seed 7: repeat_penalty=1.15
   returned 65 completion tokens against a 63-token baseline, i.e. ignored. *)
let test_runtime_toml_rejects_repetition_samplers_off_the_ollama_wire () =
  let content =
    "[providers.cloud]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://example.invalid/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [cloud.sample]\n\
     repeat-penalty = 1.15\n\
     repeat-last-n = 1024\n\
     \n\
     [runtime]\n\
     default = \"cloud.sample\"\n"
  in
  match Runtime_toml.parse_string content with
  | Ok _ ->
    failf "repetition samplers on an OpenAI-compatible provider should be rejected"
  | Error errs ->
    let named path =
      List.exists
        (fun (err : Runtime_toml.parse_error) -> String.equal err.path path)
        errs
    in
    check bool "names repeat-penalty" true (named "cloud.sample.repeat-penalty");
    check bool "names repeat-last-n" true (named "cloud.sample.repeat-last-n")

(* The same declaration on the wire that does carry it must keep parsing, so the
   Gate above is about the wire and not about the keys. *)
let test_runtime_toml_keeps_repetition_samplers_on_the_ollama_wire () =
  let content =
    "[providers.local]\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://127.0.0.1:11434\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     repeat-penalty = 1.15\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n"
  in
  match Runtime_toml.parse_string content with
  | Error _ -> failf "ollama-http must still accept the samplers"
  | Ok cfg ->
    (match cfg.Runtime_schema.bindings with
     | [ binding ] ->
       check bool "sampler survives" true
         (Option.is_some binding.Runtime_schema.repeat_penalty)
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

(* Measured 2026-08-25 over 1516 turns on ollama_cloud deepseek-v4-flash:0731:
   output_tokens <= 2048 on 1392 turns, 2048..8192 on 38, then exactly 65536 on
   86 -- the provider's own cap, reached only by generations that had collapsed
   into single-token repetition. Nothing at all landed in 8192..65535. Without a
   declared budget AGENT_CORE omits the wire field and every collapse runs to that
   cap, so the value has to be declarable per binding. *)
let test_runtime_toml_parses_max_tokens () =
  let content =
    "[providers.cloud]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://example.invalid/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1048576\n\
     \n\
     [cloud.sample]\n\
     max-tokens = 16384\n\
     \n\
     [runtime]\n\
     default = \"cloud.sample\"\n"
  in
  match Runtime_toml.parse_string content with
  | Error errs ->
    failf
      "max-tokens should parse: %s"
      (String.concat
         "; "
         (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errs))
  | Ok cfg ->
    (match cfg.Runtime_schema.bindings with
     | [ binding ] ->
       check (option int) "declared max-tokens" (Some 16384)
         binding.Runtime_schema.max_tokens;
       (* The declaration is worthless unless it survives into the config the
          request builder reads, which is the step that was missing entirely. *)
       (match Runtime_adapter.binding_to_provider_config cfg binding with
        | Error reason -> failf "provider_config should build: %s" reason
        | Ok provider_config ->
          check (option int) "reaches Provider_config" (Some 16384)
            provider_config.Llm_provider.Provider_config.max_tokens)
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

let test_runtime_toml_omitted_max_tokens_stays_none () =
  let content =
    "[providers.cloud]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://example.invalid/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [cloud.sample]\n\
     \n\
     [runtime]\n\
     default = \"cloud.sample\"\n"
  in
  match Runtime_toml.parse_string content with
  | Error _ -> failf "a binding without max-tokens must still parse"
  | Ok cfg ->
    (match cfg.Runtime_schema.bindings with
     | [ binding ] ->
       check (option int) "omitted max-tokens stays None" None
         binding.Runtime_schema.max_tokens
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

(* 0 reads as "configured" while asking for no output at all. Reject it here
   rather than letting each envelope fail differently at dispatch. *)
let test_runtime_toml_rejects_non_positive_max_tokens () =
  let content =
    "[providers.cloud]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://example.invalid/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [cloud.sample]\n\
     max-tokens = 0\n\
     \n\
     [runtime]\n\
     default = \"cloud.sample\"\n"
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> failf "max-tokens = 0 should be rejected"
  | Error errs ->
    check bool "names the offending key" true
      (List.exists
         (fun (err : Runtime_toml.parse_error) ->
           String.equal err.path "cloud.sample.max-tokens")
         errs)

let test_runtime_toml_omitted_max_request_body_bytes_is_none () =
  (* Undeclared must stay None rather than acquiring a default. AGENT_CORE reads None as
     "no ceiling declared" and passes every size; a default here would silently
     become a product-wide cap nobody chose. *)
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
     default = \"local.sample\"\n"
  in
  match Runtime_toml.parse_string content with
  | Error _ -> failf "runtime TOML without the knob should still parse"
  | Ok cfg ->
    (match cfg.Runtime_schema.bindings with
     | [ binding ] ->
       check (option int) "omitted max-request-body-bytes stays None" None
         binding.Runtime_schema.max_request_body_bytes
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

let test_keeper_dispatch_runtime_graph_enumeration () =
  let lanes =
    [ Runtime_lane.make ~id:"default-a" [ "lane-a"; "lane-b" ]
    ; Runtime_lane.make ~id:"dormant-lane" [ "lane-c"; "lane-b" ]
    ; Runtime_lane.make ~id:"cross-e" [ "cross-a"; "lane-b" ]
    ]
  in
  let actual =
    Runtime.For_testing.keeper_dispatch_runtime_ids
      ~default_runtime_id:"default-a"
      ~assignments:[ "keeper-a", "assigned-b" ]
      ~verifier_exact_slot_ids:[ "verifier-a"; "lane-b" ]
      ~media_failover:[ "media-c"; "lane-a" ]
      ~lanes
  in
  check
    (list string)
    "routed lane candidates, special routes, verifier_exact slots, and media \
     failover are deduplicated without admitting a dormant lane"
    (* [cross-e] is declared but nothing routes to it: no assignment, no
       verifier_exact slot, no media failover entry names it. #29197 removed
       the cross_verifier route that used to pull it in, so its member
       [cross-a] is no longer enumerated — same reason [dormant-lane] never
       was. *)
    [ "lane-a"; "lane-b"; "assigned-b"; "media-c"; "verifier-a" ]
    actual
;;

(* [edit_config_text] exists so a caller does not have to load runtime.toml
   itself: loading outside the lock and then committing loses any write that
   landed in between, and the server and the TUI edit different tables of this
   one file. What that buys is only real if the edit is handed the file's
   current text, which is what the first check reads.

   The fixture is the repo's own runtime.toml rather than a hand-written
   minimal one, because the second thing this has to answer is whether the
   [\[tui\]] table the TUI writes there makes the config invalid. The schema
   models no such table; a hand-made fixture would not prove that the file the
   write actually lands on still loads. *)
let test_edit_config_text_reads_the_file_and_commits_the_edit () =
  let source =
    Fs_compat.load_file (Filename.concat (repo_root ()) "config/runtime.toml")
  in
  let snapshot = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "edit_config_text_" ".toml" in
  let oc = open_out path in
  output_string oc source;
  close_out oc;
  let handed = ref None in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       match
         Runtime.edit_config_text ~runtime_config_path:path (fun content ->
           handed := Some content;
           content ^ "\n[tui]\ntheme = \"gruvbox-dark\"\n")
       with
       | Error detail ->
         failf "a [tui] table must not make runtime.toml invalid: %s" detail
       | Ok _receipt ->
         check bool "the edit was handed the file's own text" true
           (match !handed with
            | Some seen -> String.equal seen source
            | None -> false);
         check bool "the committed file carries the edit" true
           (String_util.contains_substring
              (Fs_compat.load_file path)
              "theme = \"gruvbox-dark\""))
;;

let test_runtime_config_validation_rejects_uncapped_keeper_candidate () =
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [models.lane]\n\
     api-name = \"lane\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     max-request-body-bytes = 65536\n\
     \n\
     [local.lane]\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n\
     \n\
     [runtime.lanes.\"local.sample\"]\n\
     candidates = [\"local.lane\"]\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "uncapped_runtime_" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       match Runtime.save_config_text ~runtime_config_path:path content with
       | Ok _receipt ->
         fail "uncapped Keeper lane candidate must fail runtime config validation"
       | Error detail ->
         check bool "typed config diagnostic names the cap" true
           (String_util.contains_substring detail "max-request-body-bytes");
         check bool "typed config diagnostic names the candidate" true
           (String_util.contains_substring detail "local.lane"))
;;

(* The Agent_core rule above bounds the serialized request body, and stops
   there. An official-client turn never builds that body: it hands its
   conversation to a spawned vendor client that owns its own context window and
   refuses an oversized one in a typed terminal, which the shrink sequence
   retries with less. Requiring a declared max-prompt-bytes there made the
   provider's own window a boot-time obligation on the operator, so a
   deployment could not choose to let the provider decide — and the ceiling it
   demanded was in wire bytes, which is not the unit the window is in.

   This pins the removal in both directions: the official-client side must
   load undeclared, and the Agent_core side must still reject. Without the
   second half, deleting the whole check would also pass. *)
let test_runtime_config_validation_admits_undeclared_official_client_seed () =
  let content ~bound ~agent_core_cap =
    Printf.sprintf
      "[providers.local]\n\
       protocol = \"openai-compatible-http\"\n\
       endpoint = \"http://127.0.0.1:1/v1\"\n\
       \n\
       [providers.subscription]\n\
       protocol = \"claude-code\"\n\
       command = \"/usr/bin/true\"\n\
       is-non-interactive = true\n\
       \n\
       [models.sample]\n\
       api-name = \"sample\"\n\
       max-context = 1024\n\
       \n\
       [models.seeded]\n\
       api-name = \"seeded\"\n\
       max-context = 1024\n%s\
       \n\
       [local.sample]\n%s\
       \n\
       [subscription.seeded]\n\
       \n\
       [runtime]\n\
       default = \"local.sample\"\n\
       \n\
       [runtime.assignments]\n\
       \"probe\" = \"subscription.seeded\"\n"
      bound
      agent_core_cap
  in
  let declared_agent_core_cap = "max-request-body-bytes = 65536\n" in
  let attempt text =
    let snapshot = Runtime.For_testing.snapshot () in
    let path = Filename.temp_file "official_seed_" ".toml" in
    let oc = open_out path in
    output_string oc text;
    close_out oc;
    Fun.protect
      ~finally:(fun () ->
        Runtime.For_testing.restore snapshot;
        try Sys.remove path with
        | Sys_error _ -> ())
      (fun () -> Runtime.save_config_text ~runtime_config_path:path text)
  in
  (match
     attempt (content ~bound:"" ~agent_core_cap:declared_agent_core_cap)
   with
   | Ok _receipt -> ()
   | Error detail ->
     failf
       "an official-client Keeper runtime with no max-prompt-bytes must load: %s"
       detail);
  (* Declaring it stays legal — the key still exists for operators who want the
     seed bounded; it is simply no longer an admission condition. *)
  (match
     attempt
       (content
          ~bound:"max-prompt-bytes = 131072\n"
          ~agent_core_cap:declared_agent_core_cap)
   with
   | Ok _receipt -> ()
   | Error detail -> failf "a declared seed bound must still load: %s" detail);
  (* Control. The Agent_core half of this validator must still reject, or the
     two assertions above would also pass with the whole check deleted. The
     remediation assertion is kept from #28175: a diagnostic naming a
     syntactically plausible but unconsumed table would satisfy a bare key
     substring while startup stayed stuck. *)
  match attempt (content ~bound:"" ~agent_core_cap:"") with
  | Ok _receipt ->
    fail "an Agent_core Keeper runtime with no max-request-body-bytes must be rejected"
  | Error detail ->
    check bool "the diagnostic names the Agent_core key" true
      (String_util.contains_substring detail "max-request-body-bytes");
    check bool
      "the remediation points at the binding table that owns the key"
      true
      (String_util.contains_substring
         detail
         "[local.sample].max-request-body-bytes");
    check bool "the diagnostic does not demand the seed key" false
      (String_util.contains_substring detail "max-prompt-bytes")
;;

let test_runtime_config_validation_allows_uncapped_dormant_lane_candidate () =
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [models.dormant]\n\
     api-name = \"dormant\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     max-request-body-bytes = 65536\n\
     \n\
     [local.dormant]\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n\
     \n\
     [runtime.lanes.dormant]\n\
     candidates = [\"local.dormant\"]\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "dormant_uncapped_runtime_" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       match Runtime.save_config_text ~runtime_config_path:path content with
       | Ok _receipt -> ()
       | Error detail ->
         failf
           "uncapped dormant lane must not block unrelated Keeper routing: %s"
           detail)
;;

let test_runtime_toml_rejects_non_positive_max_request_body_bytes () =
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
       max-request-body-bytes = %d\n\
       \n\
       [runtime]\n\
       default = \"local.sample\"\n"
      n
  in
  List.iter
    (fun n ->
       match Runtime_toml.parse_string (template n) with
       | Ok _ -> failf "max-request-body-bytes = %d should be rejected" n
       | Error errs ->
         let rendered =
           errs
           |> List.map (fun (err : Runtime_toml.parse_error) ->
             Printf.sprintf "%s: %s" err.path err.message)
           |> String.concat "\n"
         in
         check bool (Printf.sprintf "error mentions the knob for %d" n) true
           (String_util.contains_substring rendered "max-request-body-bytes"))
    [ 0; -1 ]

let test_runtime_toml_separates_wizard_default_from_runtime_default_marker () =
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [models.other]\n\
     api-name = \"other\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     is-default = true\n\
     \n\
     [local.other]\n\
     wizard-default = true\n\
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
    failf "runtime TOML should parse wizard-default separately:\n%s" rendered
  | Ok cfg ->
    let binding id =
      cfg.Runtime_schema.bindings
      |> List.find_opt (fun (binding : Runtime_schema.binding) ->
        String.equal (Runtime_schema.binding_key binding) id)
      |> function
      | Some binding -> binding
      | None -> failf "missing binding %s" id
    in
    let runtime_default = binding "local.sample" in
    let wizard_default = binding "local.other" in
    check bool "is-default remains runtime/default marker" true
      runtime_default.Runtime_schema.is_default;
    check bool "is-default does not imply wizard-default" false
      runtime_default.Runtime_schema.wizard_default;
    check bool "wizard-default does not imply is-default" false
      wizard_default.Runtime_schema.is_default;
    check bool "wizard-default parsed separately" true
      wizard_default.Runtime_schema.wizard_default

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
  let path = Filename.temp_file "agent_core-models" ".toml" in
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
       | Error msg -> failf "fake AGENT_CORE model catalog should load: %s" msg
       | Ok catalog ->
         Llm_provider.Model_catalog.set_global catalog;
         f ())

let with_model_catalog_content content f =
  let path = Filename.temp_file "agent_core-provider-qualified-models" ".toml" in
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
       | Error msg -> failf "provider-qualified AGENT_CORE model catalog should load: %s" msg
       | Ok catalog ->
         Llm_provider.Model_catalog.set_global catalog;
         f ())

let test_runtime_locality_uses_provider_schema () =
  let content =
    "[providers.local]\n\
     display-name = \"Local Ollama\"\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://127.0.0.1:11434\"\n\
     \n\
     [providers.remote]\n\
     display-name = \"Remote API\"\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://api.example.com/v1\"\n\
     \n\
     [providers.remote.credentials]\n\
     type = \"env\"\n\
     key = \"REMOTE_API_KEY\"\n\
     \n\
     [models.chat]\n\
     api-name = \"chat\"\n\
     max-context = 1024\n\
     \n\
     [models.remote]\n\
     api-name = \"remote\"\n\
     max-context = 1024\n\
     \n\
     [local.chat]\n\
     \n\
     [remote.remote]\n\
     \n\
     [runtime]\n\
     default = \"local.chat\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_temp_runtime_toml content @@ fun path ->
       match Runtime.init_default ~config_path:path with
       | Error msg -> failf "runtime init_default should load: %s" msg
       | Ok () ->
         check (option bool) "loopback no-auth runtime is local" (Some true)
           (Runtime.is_local_runtime_id "local.chat");
         check (option bool) "remote credentialed runtime is not local" (Some false)
           (Runtime.is_local_runtime_id "remote.remote");
         check (option bool) "unknown runtime locality is unknown" None
           (Runtime.is_local_runtime_id "missing.runtime"))

let test_runtime_capability_gate_uses_provider_qualified_catalog () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"shared-thinking\"\n\
     provider_name = \"ollama_cloud\"\n\
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
     max-request-body-bytes = 65536\n\
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

let test_runtime_toml_enabled_defaults_true () =
  let runtime_toml =
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
     default = \"local.sample\"\n"
  in
  match Runtime_toml.parse_string runtime_toml with
  | Error errors ->
    failf "enabled defaults should parse: %s"
      (errors
       |> List.map (fun (error : Runtime_toml.parse_error) -> error.message)
       |> String.concat "; ")
  | Ok cfg ->
    (match cfg.Runtime_schema.providers, cfg.Runtime_schema.bindings with
     | [ provider ], [ binding ] ->
       check bool "provider enabled by default" true provider.enabled;
       check bool "binding enabled by default" true binding.enabled
     | providers, bindings ->
       failf
         "expected one provider and one binding, got %d and %d"
         (List.length providers)
         (List.length bindings))
;;

let test_runtime_provider_disable_excludes_its_bindings () =
  let runtime_toml =
    "[providers.active]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [providers.dormant]\n\
     enabled = false\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:2/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [active.sample]\n\
     [dormant.sample]\n\
     \n\
     [runtime]\n\
     default = \"active.sample\"\n"
  in
  with_temp_runtime_toml runtime_toml (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "disabled provider should not block active runtime: %s" msg
    | Ok (runtimes, _, _, _, _) ->
      check (list string) "materialized runtime ids" [ "active.sample" ]
        (List.map (fun (runtime : Runtime.t) -> runtime.id) runtimes))
;;

let test_runtime_binding_disable_excludes_only_that_binding () =
  let runtime_toml =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.good]\n\
     api-name = \"good\"\n\
     max-context = 1024\n\
     \n\
     [models.disabled]\n\
     api-name = \"disabled\"\n\
     max-context = 1024\n\
     \n\
     [local.good]\n\
     [local.disabled]\n\
     enabled = false\n\
     \n\
     [runtime]\n\
     default = \"local.good\"\n"
  in
  with_temp_runtime_toml runtime_toml (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "disabled binding should not block active runtime: %s" msg
    | Ok (runtimes, _, _, _, _) ->
      check (list string) "materialized runtime ids" [ "local.good" ]
        (List.map (fun (runtime : Runtime.t) -> runtime.id) runtimes));
  let referenced_runtime_toml =
    runtime_toml
    ^ "\n[runtime.assignments]\nkeeper_a = \"local.disabled\"\n"
  in
  with_temp_runtime_toml referenced_runtime_toml (fun path ->
    match Runtime.load_list ~config_path:path with
    | Ok _ -> failf "assignment to explicitly disabled runtime should be rejected"
    | Error msg ->
      check bool "error mentions assignment table" true
        (String_util.contains_substring msg "[runtime.assignments].keeper_a");
      check bool "error mentions disabled runtime id" true
        (String_util.contains_substring msg "local.disabled");
      check bool "error identifies configured disable" true
        (String_util.contains_substring msg "disabled by runtime.toml"))
;;

(* verifier_exact slots are read twice: the exact registry admits them against
   the AGENT_CORE catalog, and completion-authority judgement dispatches them
   through resolve_assignment, which knows only configured runtimes and lanes.
   A slot that satisfies the catalog and names no configured route used to
   load, then fail at every judgement — 113 of them on 2026-09-02. *)
let exact_lane_runtime_toml ~lane ~slot =
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
     \n\
     [runtime]\n\
     default = \"local.sample\"\n\
     \n\
     [runtime.exact_output_lanes.%s]\n\
     slots = [\"local.sample\", %S]\n"
    lane
    slot
;;

let test_verifier_exact_slot_must_name_a_configured_route () =
  with_temp_runtime_toml
    (exact_lane_runtime_toml ~lane:"verifier_exact" ~slot:"local.absent")
    (fun path ->
       match Runtime.load_list ~config_path:path with
       | Ok _ ->
         failf "a verifier_exact slot naming no configured runtime should be rejected"
       | Error msg ->
         check bool "error names the lane's slots" true
           (String_util.contains_substring
              msg
              "[runtime.exact_output_lanes.verifier_exact].slots");
         check bool "error names the unresolved id" true
           (String_util.contains_substring msg "local.absent"))
;;

(* The sibling lanes dispatch through the registry alone, so a catalog-only
   target id is correct for them — hitl_auto_judge holds one today
   (glm-coding.glm-5.3-flash-nothink, which is no configured runtime). Load
   must not reject it, or the check above takes the fleet down with it. *)
let test_sibling_exact_lanes_keep_catalog_only_slots () =
  List.iter
    (fun lane ->
       with_temp_runtime_toml
         (exact_lane_runtime_toml ~lane ~slot:"local.absent")
         (fun path ->
            match Runtime.load_list ~config_path:path with
            | Ok _ -> ()
            | Error msg ->
              failf "%s must accept a catalog-only slot id, got: %s" lane msg))
    [ "hitl_auto_judge"; "librarian_exact"; "board_attention_exact" ]
;;

(* masc#28404. Same config the test above proves must still boot: [local.sample]
   is routed and capped, [local.dormant] is declared, materialized, and cannot
   carry a keeper turn. Boot staying up is correct; the runtime being blocked
   with nothing anywhere saying so is the defect. Seven live runtimes were in
   this state on 2026-08-12 and finding them took a script that re-parsed the
   TOML, because the runtime list reported them exactly like the assignable
   ones. *)
let test_declared_uncapped_runtime_reports_its_dispatch_blocker () =
  let runtime_toml =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [models.dormant]\n\
     api-name = \"dormant\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     max-request-body-bytes = 65536\n\
     \n\
     [local.dormant]\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n"
  in
  with_temp_runtime_toml runtime_toml (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg ->
      failf "an unassigned uncapped runtime must not fail the load: %s" msg
    | Ok (runtimes, _, _, _, _) ->
      check (list string) "both runtimes materialize"
        [ "local.sample"; "local.dormant" ]
        (List.map (fun (runtime : Runtime.t) -> runtime.id) runtimes);
      (match Runtime.keeper_dispatch_blocked runtimes with
       | [ (blocked, reason) ] ->
         check string "the uncapped runtime is the blocked one" "local.dormant"
           blocked.id;
         check bool "reason names the table to edit" true
           (String_util.contains_substring reason "[local.dormant]");
         check bool "reason names the missing field" true
           (String_util.contains_substring reason "max-request-body-bytes")
       | blocked ->
         failf
           "expected exactly the uncapped runtime to be blocked; got [%s]"
           (String.concat "; "
              (List.map (fun ((r : Runtime.t), _) -> r.id) blocked)));
      (* The routed runtime is judged by the same predicate, so a projection
         that reported everything blocked would fail here rather than read as a
         fleet-wide outage. *)
      check bool "the routed runtime is dispatchable" true
        (match
           List.find_opt
             (fun (runtime : Runtime.t) -> String.equal runtime.id "local.sample")
             runtimes
         with
         | Some runtime ->
           Runtime.keeper_dispatch_readiness runtime = Runtime.Dispatchable
         | None -> false))
;;

(* An official-client runtime declares no body cap by design — the spawned
   vendor client owns its own context window — so it must not be reported as
   blocked. Without this, the projection would tell operators to add a field
   that boot validation deliberately does not require of it. *)
let test_official_client_runtime_is_dispatchable_without_a_body_cap () =
  let runtime_toml =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [providers.claude_code]\n\
     protocol = \"claude-code\"\n\
     command = \"claude\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [models.official]\n\
     api-name = \"claude-sonnet-5\"\n\
     max-context = 200000\n\
     \n\
     [local.sample]\n\
     max-request-body-bytes = 65536\n\
     \n\
     [claude_code.official]\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n"
  in
  with_temp_runtime_toml runtime_toml (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "official-client runtime should load: %s" msg
    | Ok (runtimes, _, _, _, _) ->
      check (list string) "no runtime is reported blocked" []
        (List.map
           (fun ((runtime : Runtime.t), _) -> runtime.id)
           (Runtime.keeper_dispatch_blocked runtimes)))
;;

(* masc#28403. The runtime this declares — [local.typo] — cannot exist, because
   no [models.typo] row does. Nothing references it, which is the whole point:
   before this was a load error the only way a dangling binding surfaced was an
   assignment / route / lane naming it, so an unreferenced one vanished in
   silence. A live [local_llama_server.qwen3-6-35b-uncensored] binding did
   exactly that for an unknown length of time, and was found only by parsing the
   TOML with a separate script. *)
let test_binding_naming_an_undeclared_model_fails_the_load () =
  let runtime_toml =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.good]\n\
     api-name = \"good\"\n\
     max-context = 1024\n\
     \n\
     [local.good]\n\
     [local.typo]\n\
     \n\
     [runtime]\n\
     default = \"local.good\"\n"
  in
  with_temp_runtime_toml runtime_toml (fun path ->
    match Runtime.load_list ~config_path:path with
    | Ok (runtimes, _, _, _, _) ->
      failf
        "binding naming an undeclared model must fail the load; got runtimes [%s]"
        (String.concat "; " (List.map (fun (r : Runtime.t) -> r.id) runtimes))
    | Error msg ->
      check bool "error names the dangling binding" true
        (String_util.contains_substring msg "local.typo");
      check bool "error names the missing model row" true
        (String_util.contains_substring msg "[models.typo]"))
;;

(* The other half of masc#28403: the binding namespace is now the set of
   declared providers, not "every top-level table that is not reserved". Both
   tables below exist in the live runtime.toml and are read by other parsers;
   under the old exclusion rule each parsed as a binding whose provider did not
   exist, which is why an unresolved binding had to be dropped quietly for boot
   to survive at all. If this test fails with a dangling-binding error, the
   namespace has been re-opened and the check above is load-bearing for config
   sections it was never meant to judge. *)
let test_non_provider_namespaces_are_not_bindings () =
  let runtime_toml =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.good]\n\
     api-name = \"good\"\n\
     max-context = 1024\n\
     \n\
     [local.good]\n\
     \n\
     [voice.local_playback]\n\
     enabled = true\n\
     \n\
     [fusion.presets]\n\
     quorum = \"three\"\n\
     \n\
     [runtime]\n\
     default = \"local.good\"\n"
  in
  with_temp_runtime_toml runtime_toml (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "non-provider namespaces must not be bindings: %s" msg
    | Ok (runtimes, _, _, _, _) ->
      check (list string) "only the declared provider binds a runtime"
        [ "local.good" ]
        (List.map (fun (runtime : Runtime.t) -> runtime.id) runtimes))
;;

(* RFC-0206 §2.1 is unchanged by the above: a binding MASC is told not to run is
   still excluded rather than fatal. Only a dangling reference — a runtime that
   cannot exist — is fatal, so this asserts the two classes stayed apart rather
   than the load simply becoming stricter. *)
let test_deliberate_disable_is_still_a_tolerated_drop () =
  let runtime_toml =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [providers.dormant]\n\
     enabled = false\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:2/v1\"\n\
     \n\
     [models.good]\n\
     api-name = \"good\"\n\
     max-context = 1024\n\
     \n\
     [local.good]\n\
     [local.off]\n\
     enabled = false\n\
     [dormant.good]\n\
     \n\
     [models.off]\n\
     api-name = \"off\"\n\
     max-context = 1024\n\
     \n\
     [runtime]\n\
     default = \"local.good\"\n"
  in
  with_temp_runtime_toml runtime_toml (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "deliberate disables must not fail the load: %s" msg
    | Ok (runtimes, _, _, _, _) ->
      check (list string) "disabled binding and disabled provider are excluded"
        [ "local.good" ]
        (List.map (fun (runtime : Runtime.t) -> runtime.id) runtimes))
;;

(* [Provider_not_declared] is unreachable from TOML once the namespace is closed
   — a table under an undeclared provider is no longer read as a binding at all
   — so it is exercised at its own boundary rather than left as a variant no
   test constructs. *)
let test_of_binding_reports_an_undeclared_provider () =
  let cfg =
    { Runtime_schema.providers = []
    ; models = []
    ; bindings = []
    ; default_runtime_id = None
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    ; exact_output_lane_decls = []
    ; exec_ssh_endpoints = []
    ; egress_allowlists = []
    }
  in
  let binding =
    { Runtime_schema.provider_id = "absent"
    ; model_id = "whatever"
    ; enabled = true
    ; is_default = false
    ; wizard_default = false
    ; max_concurrent = None
    ; max_request_body_bytes = None
    ; max_tokens = None
    ; price_input = None
    ; price_output = None
    ; keep_alive = None
    ; num_ctx = None
  ; repeat_penalty = None
  ; repeat_last_n = None
    ; return_progress = None
    }
  in
  match Runtime.of_binding cfg binding with
  | Ok _ -> fail "binding with an undeclared provider must not materialize"
  | Error (Runtime.Provider_not_declared id) ->
    check string "reports the provider it could not find" "absent" id
  | Error other ->
    failf
      "expected Provider_not_declared, got %s"
      (Runtime.string_of_drop_reason other)
;;

let test_runtime_toml_rejects_non_boolean_enabled () =
  let runtime_toml =
    "[providers.local]\n\
     enabled = \"no\"\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     enabled = 0\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n"
  in
  match Runtime_toml.parse_string runtime_toml with
  | Ok _ -> failf "non-boolean enabled fields should be rejected"
  | Error errors ->
    let rendered =
      errors
      |> List.map (fun (error : Runtime_toml.parse_error) ->
        Printf.sprintf "%s: %s" error.path error.message)
      |> String.concat "\n"
    in
    check bool "provider enabled path" true
      (String_util.contains_substring rendered "providers.local.enabled");
    check bool "binding enabled path" true
      (String_util.contains_substring rendered "local.sample.enabled")
;;

(* One validator now decides every [runtime] field that names a routing target
   (keeper assignments, the route ids, media_failover entries), so the properties
   that were spread across three functions are asserted together.

   Two things can break in a merge like this and neither shows up as a type error.
   The diagnostics can collapse into one generic message, leaving the operator
   without the field that is wrong; and the two resolution domains can collapse
   into one, which would pass any "does the id resolve" test while admitting a
   lane id at a site whose consumer looks only among runtimes — a config that
   loads and then cannot route. *)
let routing_reference_base =
  "[providers.local]\n\
   protocol = \"openai-compatible-http\"\n\
   endpoint = \"http://127.0.0.1:1/v1\"\n\
   \n\
   [models.good]\n\
   api-name = \"chat\"\n\
   max-context = 1024\n\
   \n\
   [local.good]\n\
   \n\
   [runtime]\n\
   default = \"local.good\"\n"

let load_error_of_runtime_toml ~what content =
  with_temp_runtime_toml content (fun path ->
    match Runtime.load_list ~config_path:path with
    | Ok _ -> failf "%s should be rejected at load" what
    | Error msg -> msg)

let test_every_routing_field_names_itself_in_its_diagnostic () =
  let assignment =
    load_error_of_runtime_toml
      ~what:"an assignment to an unknown runtime"
      (routing_reference_base ^ "\n[runtime.assignments]\nkeeper_a = \"local.typo\"\n")
  in
  check bool "assignment diagnostic names the keeper's table entry" true
    (String_util.contains_substring assignment "[runtime.assignments].keeper_a = \"local.typo\"");
  let media =
    load_error_of_runtime_toml
      ~what:"a media_failover entry naming an unknown runtime"
      (routing_reference_base ^ "media_failover = [\"local.typo\"]\n")
  in
  (* A list field renders as an entry rather than an equality: [runtime]
     .media_failover = "local.typo" would tell the operator the list equals one id. *)
  check bool "media_failover diagnostic names an entry, not an equality" true
    (String_util.contains_substring media "[runtime].media_failover entry \"local.typo\"")

let test_routing_reference_domains_stay_distinct () =
  let lane = "\n[runtime.lanes.safe]\ncandidates = [\"local.good\"]\n" in
  (* An assignment resolves among runtimes only. runtime.mli documents the
     assignment snapshot as ids that resolve to a configured runtime, so admitting
     a lane here would load a config the assignment consumer cannot look up. *)
  let assignment =
    load_error_of_runtime_toml
      ~what:"an assignment naming a lane"
      (routing_reference_base ^ lane ^ "\n[runtime.assignments]\nkeeper_a = \"safe\"\n")
  in
  check bool "assignment refuses a lane id" true
    (String_util.contains_substring assignment "[runtime.assignments].keeper_a = \"safe\"");
  (* Keeper_vision_tool resolves media_failover entries among runtimes
     (keeper_vision_tool.ml:82-89), so the same refusal applies. *)
  let media =
    load_error_of_runtime_toml
      ~what:"a media_failover entry naming a lane"
      (routing_reference_base ^ "media_failover = [\"safe\"]\n" ^ lane)
  in
  check bool "media_failover refuses a lane id" true
    (String_util.contains_substring media "[runtime].media_failover entry \"safe\"")

let test_strict_init_rejects_assigned_runtime_absent_from_agent_core_catalog () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"chat\"\n\
     base = \"ollama\"\n\
     max_context_tokens = 1024\n"
  in
  let runtime_toml =
    "[providers.ollama]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.good]\n\
     api-name = \"chat\"\n\
     max-context = 1024\n\
     \n\
     [models.missing]\n\
     api-name = \"missing-from-agent_core-catalog\"\n\
     max-context = 1024\n\
     \n\
     [ollama.good]\n\
     max-request-body-bytes = 65536\n\
     \n\
     [ollama.missing]\n\
     \n\
     [runtime]\n\
     default = \"ollama.good\"\n\
     \n\
     [runtime.assignments]\n\
     keeper_a = \"ollama.missing\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_model_catalog_content catalog @@ fun () ->
       with_temp_runtime_toml runtime_toml (fun path ->
         match Runtime.init_default_strict ~config_path:path with
         | Ok () ->
           failf "strict runtime init should reject assigned uncatalogued runtime"
         | Error msg ->
           check bool "error mentions AGENT_CORE catalog gate" true
             (String_util.contains_substring msg "absent from the AGENT_CORE capability catalog");
           check bool "error mentions assigned runtime id" true
             (String_util.contains_substring msg "ollama.missing")))

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
         (* The label is the declared [providers.custom] table name, not the
            wire kind: the adapter stamps [Provider_config.provider_id], so the
            missing-row diagnostic tells the operator which catalog
            [provider_name] to add instead of the generic "openai_compat". *)
         check string "provider label" "custom" missing.provider_label;
         check string "model id" "missing-family-123" missing.model_id;
         check bool "diagnostic names AGENT_CORE catalog file" true
           (String_util.contains_substring
              (Runtime.strict_init_error_to_string
                 (Runtime.Missing_catalog_models report))
              "agent-core-models-overlay.toml");
         check bool "diagnostic reports provider label" true
           (String_util.contains_substring
              (Runtime.strict_init_error_to_string
                 (Runtime.Missing_catalog_models report))
              "provider_label=custom"))

let test_server_degraded_init_rejects_referenced_uncatalogued_runtimes () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"good\"\n\
     provider_name = \"ollama\"\n\
     base = \"ollama\"\n\
     max_context_tokens = 1024\n"
  in
  let runtime_toml =
    "[providers.ollama]\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://127.0.0.1:11434\"\n\
     \n\
     [models.good]\n\
     api-name = \"good\"\n\
     max-context = 1024\n\
     \n\
     [models.missing]\n\
     api-name = \"missing-from-agent_core-catalog\"\n\
     max-context = 1024\n\
     \n\
     [ollama.good]\n\
     \n\
     [ollama.missing]\n\
     \n\
     [runtime]\n\
     default = \"ollama.good\"\n\
     media_failover = [\"ollama.missing\", \"ollama.good\"]\n\
     \n\
     [runtime.assignments]\n\
     keeper_a = \"ollama.missing\"\n\
     keeper_b = \"ollama.good\"\n\
     \n\
     [runtime.lanes.safe]\n\
     candidates = [\"ollama.missing\", \"ollama.good\"]\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_model_catalog_content catalog @@ fun () ->
       with_temp_runtime_toml runtime_toml @@ fun path ->
       match Runtime.init_default_degraded_report ~config_path:path with
       | Ok Runtime.Initialized -> fail "expected referenced missing runtime to fail"
       | Ok (Runtime.Initialized_degraded _) ->
         fail "referenced missing runtime must not degrade into fallback routing"
       | Error (Runtime.Missing_catalog_models report) ->
         failf
           "expected routing-reference config error, got missing catalog report: %s"
           (Runtime.strict_init_error_to_string (Runtime.Missing_catalog_models report))
       | Error (Runtime.Runtime_config_error msg) ->
         check bool "diagnostic names keeper assignment" true
           (String_util.contains_substring msg "[runtime.assignments].keeper_a");
         check bool "diagnostic names media failover" true
           (String_util.contains_substring msg "[runtime].media_failover");
         check bool "diagnostic names lane candidates" true
           (String_util.contains_substring msg "[runtime.lanes].candidates.safe");
         check bool "diagnostic rejects fallback erasure" true
           (String_util.contains_substring msg "default fallback"))

let test_server_degraded_init_disables_unreferenced_uncatalogued_runtimes () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"good\"\n\
     provider_name = \"ollama\"\n\
     base = \"ollama\"\n\
     max_context_tokens = 1024\n"
  in
  (* [models.missing] intentionally has no max-context override. Degraded
     startup must remove its missing catalog binding before validating the
     surviving runtimes' effective context windows. *)
  let runtime_toml =
    "[providers.ollama]\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://127.0.0.1:11434\"\n\
     \n\
     [models.good]\n\
     api-name = \"good\"\n\
     max-context = 1024\n\
     \n\
     [models.missing]\n\
     api-name = \"missing-from-agent_core-catalog\"\n\
     \n\
     [ollama.good]\n\
     max-request-body-bytes = 65536\n\
     \n\
     [ollama.missing]\n\
     \n\
     [runtime]\n\
     default = \"ollama.good\"\n\
     media_failover = [\"ollama.good\"]\n\
     \n\
     [runtime.assignments]\n\
     keeper_b = \"ollama.good\"\n\
     \n\
     [runtime.lanes.safe]\n\
     candidates = [\"ollama.good\"]\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_model_catalog_content catalog @@ fun () ->
       with_temp_runtime_toml runtime_toml @@ fun path ->
       match Runtime.init_default_degraded_report ~config_path:path with
       | Error err ->
         failf
           "server degraded init should disable only unreferenced catalog gaps: %s"
           (Runtime.strict_init_error_to_string err)
       | Ok Runtime.Initialized -> fail "expected degraded startup outcome"
       | Ok (Runtime.Initialized_degraded degradation) ->
         check string "configured default"
           "ollama.good"
           degradation.configured_default_runtime_id;
         check string "effective default"
           "ollama.good"
           degradation.effective_default_runtime_id;
         check (list string) "active runtime ids"
           [ "ollama.good" ]
           (Runtime.get_runtime_ids ());
         check (list string) "no dropped assignment"
           []
           (List.map
              (fun (entry : Runtime.dropped_runtime_assignment) -> entry.keeper_name)
              degradation.dropped_assignments);
         check (option string) "catalog-known assignment preserved"
           (Some "ollama.good")
           (Runtime.runtime_id_for_keeper "keeper_b");
         check (list string) "media failover keeps known ids only"
           [ "ollama.good" ]
           (Runtime.media_failover ());
         (match Runtime.get_lane_by_id "safe" with
          | None -> fail "lane should remain with its known candidate"
          | Some lane ->
            check (list string) "lane candidates keep known ids only"
              [ "ollama.good" ]
              (Runtime_lane.ordered_candidates lane));
         check bool "runtime records startup degradation" true
           (Runtime.startup_degraded ());
         let json =
           Runtime.startup_degradation_to_yojson (Runtime.startup_degradation ())
         in
         let rendered = Yojson.Safe.to_string json in
         check bool "json is operator-visible degraded" true
           (String_util.contains_substring rendered "\"status\":\"degraded\"");
         check bool "json names disabled runtime" true
           (String_util.contains_substring rendered "ollama.missing"))

let test_server_degraded_init_rejects_uncatalogued_default () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"good\"\n\
     provider_name = \"ollama\"\n\
     base = \"ollama\"\n\
     max_context_tokens = 1024\n"
  in
  let runtime_toml =
    "[providers.ollama]\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://127.0.0.1:11434\"\n\
     \n\
     [models.good]\n\
     api-name = \"good\"\n\
     max-context = 1024\n\
     \n\
     [models.missing]\n\
     api-name = \"missing-from-agent_core-catalog\"\n\
     max-context = 1024\n\
     \n\
     [ollama.good]\n\
     \n\
     [ollama.missing]\n\
     \n\
     [runtime]\n\
     default = \"ollama.missing\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_model_catalog_content catalog @@ fun () ->
       with_temp_runtime_toml runtime_toml @@ fun path ->
       match Runtime.init_default_degraded_report ~config_path:path with
       | Ok Runtime.Initialized -> fail "expected missing default catalog row"
       | Ok (Runtime.Initialized_degraded _) ->
         fail "missing configured default must not pick another effective default"
       | Error (Runtime.Missing_catalog_models report) ->
         failf
           "expected default-specific config error, got missing catalog report: %s"
           (Runtime.strict_init_error_to_string
              (Runtime.Missing_catalog_models report))
       | Error (Runtime.Runtime_config_error msg) ->
         check bool "error names runtime default" true
           (String_util.contains_substring msg "[runtime].default");
         check bool "error names missing default runtime" true
           (String_util.contains_substring msg "ollama.missing");
         check bool "error rejects alternate default routing" true
           (String_util.contains_substring msg "default fallback"))

let test_runtime_toml_max_concurrent_flows_to_provider_config () =
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
        , _media_failover
        , _lanes ) ->
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
          check
            (option int)
            (Printf.sprintf "%s provider_config max_concurrent_requests" id)
            expected
            (agent_core_provider_config rt).max_concurrent_requests;
          let selected_provider_config =
            Runtime_candidate.of_provider_config (agent_core_provider_config rt)
            |> Runtime_candidate.provider_cfg
          in
          check
            (option int)
            (Printf.sprintf "%s selected provider config admission" id)
            expected
            selected_provider_config.max_concurrent_requests
      in
      expect "local.no-cap" None;
      expect "local.capped" (Some 5))

(* Under the Reasoning_effort dialect the wire field comes from the declared
   effort, not from enable_thinking, so a model row that names an effort has
   to reach the materialized provider config. It did not: only the
   official-client path read spec.reasoning_effort, which left an HTTP model
   whose endpoint honours the control reasoning on every turn with no way to
   say otherwise. *)
let test_runtime_toml_reasoning_effort_flows_to_provider_config () =
  with_fake_runtime_model_catalog @@ fun () ->
  let content =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.undeclared]\n\
     api-name = \"undeclared\"\n\
     max-context = 1024\n\
     \n\
     [models.quiet]\n\
     api-name = \"quiet\"\n\
     max-context = 1024\n\
     reasoning-effort = \"none\"\n\
     \n\
     [local.undeclared]\n\
     \n\
     [local.quiet]\n\
     \n\
     [runtime]\n\
     default = \"local.undeclared\"\n"
  in
  with_temp_runtime_toml content (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error msg -> failf "runtime TOML should materialize: %s" msg
    | Ok (runtimes, _default, _assignments, _media_failover, _lanes) ->
      let effort id =
        match
          List.find_opt (fun (rt : Runtime.t) -> String.equal rt.id id) runtimes
        with
        | None -> failf "expected runtime %s" id
        | Some rt ->
          Option.map
            Llm_provider.Reasoning_effort.to_string
            (agent_core_provider_config rt).reasoning_effort
      in
      check (option string) "declared effort reaches the provider config"
        (Some "none") (effort "local.quiet");
      check (option string) "omitted effort stays absent" None
        (effort "local.undeclared"))

let test_load_allows_a_lane_that_mixes_checkpoint_owners () =
  with_fake_runtime_model_catalog @@ fun () ->
  let base =
    "[providers.local]\n\
     display-name = \"Local\"\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://localhost:11434\"\n\
     \n\
     [providers.subscription]\n\
     display-name = \"Claude Code Subscription\"\n\
     protocol = \"claude-code\"\n\
     command = \"/usr/bin/true\"\n\
     is-non-interactive = true\n\
     \n\
     [models.chat]\n\
     api-name = \"chat\"\n\
     max-context = 1024\n\
     \n\
     [models.other]\n\
     api-name = \"other\"\n\
     max-context = 1024\n\
     \n\
     [models.sonnet]\n\
     api-name = \"sonnet\"\n\
     max-context = 1024\n\
     \n\
     [local.chat]\n\
     \n\
     [local.other]\n\
     \n\
     [subscription.sonnet]\n\
     \n\
     [runtime]\n\
     default = \"local.chat\"\n"
  in
  with_temp_runtime_toml
    (base
     ^ "\n\
        [runtime.lanes.\"subscription.sonnet\"]\n\
        candidates = [\"subscription.sonnet\", \"local.chat\"]\n")
    (fun path ->
      match Runtime.load_list ~config_path:path with
      | Ok _ -> ()
      | Error msg -> failf "a mixed-owner failover lane must load: %s" msg)

let test_structured_judge_runtime_key_is_rejected () =
  match
    Runtime_toml.parse_string
      "[runtime]\ndefault = \"local.chat\"\nstructured_judge = \"local.judge\"\n"
  with
  | Ok _ -> fail "[runtime].structured_judge must be rejected as an unknown key"
  | Error errors ->
    check bool "removed key is named in the parse error" true
      (List.exists
         (fun (error : Runtime_toml.parse_error) ->
            String.equal error.path "runtime.structured_judge"
            && String_util.contains_substring error.message "unknown [runtime] key")
         errors)

let test_save_config_text_commits_exact_registry_with_runtime_state () =
  with_fake_runtime_model_catalog @@ fun () ->
  let snapshot =
    Exact_output_fixture.resolver_snapshot
      ~source:"runtime raw-save exact replacement"
      [ { id = "slot-a"; base_url = "http://127.0.0.1:9" }
      ; { id = "slot-b"; base_url = "http://127.0.0.1:10" }
      ; { id = "local.chat"; base_url = "http://127.0.0.1:11" }
      ; { id = "local.libr"; base_url = "http://127.0.0.1:12" }
      ]
  in
  ignore
    (Exact_output_fixture.publish_registry
       ~lane_id:"auxiliary_exact"
       ~slot_ids:[ "slot-a" ]
       snapshot
      : Runtime_exact_output_registry.t);
  let content ~default slot =
    Printf.sprintf
      "[providers.local]\n\
       display-name = \"Local\"\n\
       protocol = \"ollama-http\"\n\
       endpoint = \"http://localhost:11434\"\n\
       \n\
       [models.chat]\n\
       provider = \"local\"\n\
       provider-model-id = \"chat\"\n\
       max-context = 1024\n\
       \n\
       [models.libr]\n\
       provider = \"local\"\n\
       provider-model-id = \"libr\"\n\
       max-context = 1024\n\
       \n\
       [local.chat]\n\
       max-request-body-bytes = 65536\n\
       \n\
       [local.libr]\n\
       max-request-body-bytes = 65536\n\
       \n\
       [runtime]\n\
       default = \"%s\"\n\
       \n\
       [runtime.exact_output_lanes.auxiliary_exact]\n\
       slots = [\"%s\"]\n"
      default
      slot
  in
  let registry_exn () =
    match Runtime_exact_output_registry.current () with
    | Ok registry -> registry
    | Error error ->
      failf
        "exact-output registry must be published: %s"
        (Runtime_exact_output_registry.publication_error_to_string error)
  in
  let slots_exn ~lane_id registry =
    match
      Runtime_exact_output_registry.resolve_lane registry ~lane_id
    with
    | Ok resolved ->
      List.map
        (fun (slot : Runtime_exact_output_registry.selected_slot) -> slot.slot_id)
        resolved.selected_slots
    | Error error ->
      failf
        "exact-output lane %S must exist: %s"
        lane_id
         (Runtime_exact_output_registry.lane_resolution_error_to_string error)
  in
  let lane_is_unconfigured ~lane_id registry =
    match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
    | Error
        (Runtime_exact_output_registry.Exact_lane_unconfigured
           { lane_id = actual_lane_id }) ->
      String.equal lane_id actual_lane_id
    | Error _ | Ok _ -> false
  in
  let lane_has_no_admitted_slots ~lane_id registry =
    match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
    | Error
        (Runtime_exact_output_registry.No_admitted_lane_slots
           { lane_id = actual_lane_id }) ->
      String.equal lane_id actual_lane_id
    | Error _ | Ok _ -> false
  in
  let baseline = content ~default:"local.chat" "slot-a" in
  with_temp_runtime_toml baseline (fun path ->
    (match Runtime.save_config_text ~runtime_config_path:path baseline with
     | Error detail -> failf "baseline exact save failed: %s" detail
     | Ok _receipt -> ());
    let stable_registry = registry_exn () in
    let degraded = content ~default:"local.libr" "missing-slot" in
    (match Runtime.save_config_text ~runtime_config_path:path degraded with
     | Error detail ->
       failf "optional unbound exact target must not reject raw save: %s" detail
     | Ok _receipt -> ());
    check string "degraded save commits file" degraded (Fs_compat.load_file path);
    check string "degraded save commits runtime cache" "local.libr"
      (Runtime.get_default_runtime_id ());
    let after_degraded = registry_exn () in
    check bool "degraded save republishes the registry" true
      (not (after_degraded == stable_registry));
    check bool "degraded save leaves optional lane without admitted slots" true
      (lane_has_no_admitted_slots
         ~lane_id:"auxiliary_exact"
         after_degraded);
    check bool "degraded save does not synthesize HITL lane" true
      (lane_is_unconfigured ~lane_id:"hitl_auto_judge" after_degraded);
    let replacement = content ~default:"local.chat" "slot-b" in
    let failed_path = path ^ ".directory" in
    Unix.mkdir failed_path 0o755;
    Fun.protect
      ~finally:(fun () -> Unix.rmdir failed_path)
      (fun () ->
         (match Runtime.save_config_text ~runtime_config_path:failed_path replacement with
          | Ok _receipt -> fail "directory target must reject atomic runtime save"
          | Error detail ->
            check bool "write failure is surfaced" true
              (String_util.contains_substring detail "save_file_atomic"));
         check string "write failure preserves runtime cache" "local.libr"
           (Runtime.get_default_runtime_id ());
         let after_write_failure = registry_exn () in
         check bool "write failure preserves the published registry" true
           (after_write_failure == after_degraded);
         check bool "write failure preserves no-admitted lane" true
           (lane_has_no_admitted_slots
              ~lane_id:"auxiliary_exact"
              after_write_failure);
         check bool "write failure does not synthesize HITL lane" true
           (lane_is_unconfigured
              ~lane_id:"hitl_auto_judge"
              after_write_failure));
    (match Runtime.save_config_text ~runtime_config_path:path replacement with
     | Error detail -> failf "valid exact replacement failed: %s" detail
     | Ok _receipt -> ());
    check string "valid save commits file" replacement (Fs_compat.load_file path);
    check string "valid save commits runtime cache" "local.chat"
      (Runtime.get_default_runtime_id ());
    let replaced = registry_exn () in
    check bool "valid save republishes the registry" true
      (not (replaced == after_degraded));
    check (list string) "valid save commits registry slots" [ "slot-b" ]
      (slots_exn ~lane_id:"auxiliary_exact" replaced);
    check bool "valid save does not synthesize HITL lane" true
      (lane_is_unconfigured ~lane_id:"hitl_auto_judge" replaced))

let test_unknown_capability_key_rejected_at_load () =
  let content =
    "[providers.capcheck]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [providers.capcheck.capabilities]\n\
     supports-teleport = true\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [capcheck.sample]\n\
     \n\
     [runtime]\n\
     default = \"capcheck.sample\"\n"
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> fail "an unknown capabilities key must be rejected at load"
  | Error errors ->
    check
      bool
      "the rejection names the offending key path"
      true
      (List.exists
         (fun (e : Runtime_toml.parse_error) ->
            String.equal
              e.path
              "providers.capcheck.capabilities.supports-teleport")
         errors)

(* PR-6 (bugs #14/#15/#36): [model.max-context] is now optional — a runtime
   can resolve its effective context window from the runtime.toml override,
   the AGENT_CORE capability catalog, or the override clamped by the catalog cap.
   The four cases below cover [Runtime.resolve_max_context_of_runtime]'s
   full match; the fifth covers the assignment-document default-rider join
   (bug #14) that [Server_dashboard_runtime_resolved_json.assignment_json]
   depends on. *)

let test_runtime_max_context_capability_only_uses_catalog_cap () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"cap-only-model\"\n\
     provider_name = \"ollama_cloud\"\n\
     base = \"ollama_cloud\"\n\
     max_context_tokens = 4096\n"
  in
  let runtime_toml =
    "[providers.ollama_cloud]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://ollama.com/v1\"\n\
     \n\
     [models.capenly]\n\
     api-name = \"cap-only-model\"\n\
     \n\
     [ollama_cloud.capenly]\n\
     \n\
     [runtime]\n\
     default = \"ollama_cloud.capenly\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_model_catalog_content catalog @@ fun () ->
       with_temp_runtime_toml runtime_toml (fun path ->
         match Runtime.init_default ~config_path:path with
         | Error msg -> failf "capability-only max-context should load: %s" msg
         | Ok () ->
           (match Runtime.get_runtime_by_id "ollama_cloud.capenly" with
            | None -> fail "expected ollama_cloud.capenly runtime"
            | Some rt ->
              check (option (pair int string)) "capability-derived max-context"
                (Some (4096, "capability"))
                (Runtime.resolve_max_context_of_runtime rt
                 |> Option.map (fun (n, source) ->
                   n, Runtime.max_context_source_to_string source)))))

let test_runtime_max_context_override_below_cap_wins_as_override () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"override-under-cap\"\n\
     provider_name = \"ollama_cloud\"\n\
     base = \"ollama_cloud\"\n\
     max_context_tokens = 8192\n"
  in
  let runtime_toml =
    "[providers.ollama_cloud]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://ollama.com/v1\"\n\
     \n\
     [models.underprovision]\n\
     api-name = \"override-under-cap\"\n\
     max-context = 2048\n\
     \n\
     [ollama_cloud.underprovision]\n\
     \n\
     [runtime]\n\
     default = \"ollama_cloud.underprovision\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_model_catalog_content catalog @@ fun () ->
       with_temp_runtime_toml runtime_toml (fun path ->
         match Runtime.init_default ~config_path:path with
         | Error msg -> failf "override-below-cap should load: %s" msg
         | Ok () ->
           (match Runtime.get_runtime_by_id "ollama_cloud.underprovision" with
            | None -> fail "expected ollama_cloud.underprovision runtime"
            | Some rt ->
              check (option (pair int string)) "override wins under the catalog cap"
                (Some (2048, "override"))
                (Runtime.resolve_max_context_of_runtime rt
                 |> Option.map (fun (n, source) ->
                   n, Runtime.max_context_source_to_string source)))))

let test_runtime_max_context_override_above_cap_is_clamped () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"override-over-cap\"\n\
     provider_name = \"ollama_cloud\"\n\
     base = \"ollama_cloud\"\n\
     max_context_tokens = 8192\n"
  in
  let runtime_toml =
    "[providers.ollama_cloud]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://ollama.com/v1\"\n\
     \n\
     [models.overprovision]\n\
     api-name = \"override-over-cap\"\n\
     max-context = 16384\n\
     \n\
     [ollama_cloud.overprovision]\n\
     \n\
     [runtime]\n\
     default = \"ollama_cloud.overprovision\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_model_catalog_content catalog @@ fun () ->
       with_temp_runtime_toml runtime_toml (fun path ->
         match Runtime.init_default ~config_path:path with
         | Error msg -> failf "override-above-cap should load (clamped): %s" msg
         | Ok () ->
           (match Runtime.get_runtime_by_id "ollama_cloud.overprovision" with
            | None -> fail "expected ollama_cloud.overprovision runtime"
            | Some rt ->
              check (option (pair int string))
                "override above the catalog cap is clamped to the cap"
                (Some (8192, "override_clamped_by_capability"))
                (Runtime.resolve_max_context_of_runtime rt
                 |> Option.map (fun (n, source) ->
                   n, Runtime.max_context_source_to_string source)));
           let meta =
             match
               Masc_test_deps.meta_of_json_fixture
                 (`Assoc
                    [ "name", `String "direct-cap-clamp"
                    ; "trace_id", `String "test-direct-cap-clamp"
                    ])
             with
             | Ok meta -> { meta with max_context_override = Some 128000 }
             | Error detail -> failf "direct meta fixture failed: %s" detail
           in
           match
             Keeper_unified_turn_pre_dispatch.build_runtime_execution
               ~meta
               ~runtime_id:(Keeper_meta_contract.runtime_id_of_meta meta)
           with
           | Error error ->
             failf
               "direct runtime execution should resolve: %s"
               (Agent_core.Error.to_string error)
           | Ok execution ->
             check int
               "direct first attempt receives the provider-effective budget"
               8192
               execution.max_context;
             check int
               "direct execution preserves the resolved effective budget"
               8192
               execution.max_context_resolution.effective_budget;
             check (option int)
               "direct execution retains the requested override for diagnostics"
               (Some 128000)
               execution.max_context_resolution.requested_override))

(* #28765: the observed incident shape — a 1,048,576-window lane entry
   point whose sticky-reordered sibling has a 203,000 window. The turn
   budget must be the smallest candidate window, because the prompt is
   shaped once and any candidate can serve it. *)
let test_lane_budget_is_bound_by_smallest_candidate_window () =
  let catalog =
    "[[models]]\n\
     id_prefix = \"lane-big\"\n\
     provider_name = \"ollama_cloud\"\n\
     base = \"ollama_cloud\"\n\
     max_context_tokens = 1048576\n\
     \n\
     [[models]]\n\
     id_prefix = \"lane-small\"\n\
     provider_name = \"ollama_cloud\"\n\
     base = \"ollama_cloud\"\n\
     max_context_tokens = 203000\n"
  in
  let runtime_toml =
    "[providers.ollama_cloud]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"https://ollama.com/v1\"\n\
     \n\
     [models.bigwin]\n\
     api-name = \"lane-big\"\n\
     max-context = 1048576\n\
     \n\
     [models.smallwin]\n\
     api-name = \"lane-small\"\n\
     max-context = 203000\n\
     \n\
     [ollama_cloud.bigwin]\n\
     [ollama_cloud.smallwin]\n\
     \n\
     [runtime.lanes.\"ollama_cloud.bigwin\"]\n\
     candidates = [\"ollama_cloud.bigwin\", \"ollama_cloud.smallwin\"]\n\
     \n\
     [runtime]\n\
     default = \"ollama_cloud.bigwin\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_model_catalog_content catalog @@ fun () ->
       with_temp_runtime_toml runtime_toml (fun path ->
         match Runtime.init_default ~config_path:path with
         | Error msg -> failf "lane fixture should load: %s" msg
         | Ok () ->
           let meta =
             match
               Masc_test_deps.meta_of_json_fixture
                 (`Assoc
                    [ "name", `String "lane-min-budget"
                    ; "trace_id", `String "test-lane-min-budget"
                    ])
             with
             | Ok meta -> meta
             | Error detail -> failf "lane meta fixture failed: %s" detail
           in
           match
             Keeper_unified_turn_pre_dispatch.build_runtime_execution
               ~meta
               ~runtime_id:"ollama_cloud.bigwin"
           with
           | Error error ->
             failf
               "lane execution should resolve: %s"
               (Agent_core.Error.to_string error)
           | Ok execution ->
             check int
               "turn budget is the smallest lane candidate window"
               203000
               execution.max_context;
             check int
               "stored resolution is the binding candidate's"
               203000
               execution.max_context_resolution.effective_budget;
             check string
               "execution keeps the entry-point runtime id"
               "ollama_cloud.bigwin"
               execution.runtime_id))

let test_runtime_max_context_missing_both_sources_rejected_at_load () =
  let runtime_toml =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.nocap]\n\
     api-name = \"nocap\"\n\
     \n\
     [local.nocap]\n\
     \n\
     [runtime]\n\
     default = \"local.nocap\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_temp_runtime_toml runtime_toml (fun path ->
         match Runtime.load_list ~config_path:path with
         | Ok _ ->
           fail
             "runtime with no max-context override and no capability catalog \
              row should be rejected at load (fail-closed, no silent \
              default)"
         | Error msg ->
           check bool "load error names the max-context field" true
             (String_util.contains_substring msg "max-context")))

let test_runtime_assignment_default_rider_resolves_to_default_runtime () =
  let runtime_toml =
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.good]\n\
     api-name = \"chat\"\n\
     max-context = 1024\n\
     \n\
     [local.good]\n\
     \n\
     [runtime]\n\
     default = \"local.good\"\n"
  in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       with_temp_runtime_toml runtime_toml (fun path ->
         match Runtime.init_default ~config_path:path with
         | Error msg -> failf "runtime init_default should load: %s" msg
         | Ok () ->
           (* Bug #14: a keeper absent from [runtime.assignments] is not
              "unrouted" — it rides [runtime].default. The resolved document's
              assignment join ([Server_dashboard_runtime_resolved_json
              .assignment_json]) depends on exactly this fallback pair. *)
           check (option string) "unassigned keeper has no explicit assignment"
             None
             (Runtime.runtime_id_for_keeper "keeper_with_no_assignment");
           check string
             "unassigned keeper's default rider resolves to [runtime].default"
             "local.good"
             (Runtime.get_default_runtime_id ())))

let codex_app_server_runtime_toml ?credential ?(options = "") () =
  let credential = Option.value credential ~default:"" in
  Printf.sprintf
    "[providers.codex]\n\
     protocol = \"codex-app-server\"\n\
     command = \"codex\"\n\
     is-non-interactive = true\n\
     %s\n\
     %s\n\
     [models.codex]\n\
     api-name = \"gpt-5.6-sol\"\n\
     max-context = 400000\n\
     \n\
     [codex.codex]\n\
     \n\
     [runtime]\n\
     default = \"codex.codex\"\n"
    options
    credential
;;

let test_codex_app_server_materializes_as_turn_runtime () =
  with_temp_runtime_toml (codex_app_server_runtime_toml ()) (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error error -> failf "codex-app-server runtime should load: %s" error
    | Ok (runtimes, default, _, _, _) ->
      check int "one runtime" 1 (List.length runtimes);
      check string "default id" "codex.codex" default.id;
      (match default.execution with
       | Runtime_execution.Agent_core _
       | Runtime_execution.Claude_code _ ->
         fail "codex-app-server was incorrectly materialized as agent_core"
       | Runtime_execution.Codex_app_server config ->
         check string "cli path" "codex" config.cli_path;
         check (option string) "model" (Some "gpt-5.6-sol") config.model
       | Runtime_execution.Antigravity_cli _ ->
         fail "codex-app-server was incorrectly materialized as antigravity-cli"))
;;

let antigravity_cli_runtime_toml ?credential ?(options = "") () =
  let credential = Option.value credential ~default:"" in
  Printf.sprintf
    "[providers.antigravity]\n\
     protocol = \"antigravity-cli\"\n\
     command = \"agy\"\n\
     is-non-interactive = true\n\
     %s\n\
     %s\n\
     [models.gemini]\n\
     api-name = \"gemini-3.6-flash-high\"\n\
     max-context = 128000\n\
     \n\
     [antigravity.gemini]\n\
     \n\
     [runtime]\n\
     default = \"antigravity.gemini\"\n"
    options
    credential
;;

let antigravity_file_credential =
  "[providers.antigravity.credentials]\n\
   type = \"file\"\n\
   path = \"/tmp/antigravity-oauth-token\""
;;

let test_antigravity_cli_materializes_typed_process_options () =
  let options =
    "agent = \"fixture-agent\"\n\
     effort = \"high\"\n\
     timeout-s = 45.0"
  in
  with_temp_runtime_toml
    (antigravity_cli_runtime_toml
       ~credential:antigravity_file_credential
       ~options
       ())
    (fun path ->
       match Runtime.load_list ~config_path:path with
       | Error error -> failf "antigravity-cli runtime should load: %s" error
       | Ok (runtimes, default, _, _, _) ->
         check int "one runtime" 1 (List.length runtimes);
         check string "default id" "antigravity.gemini" default.id;
         (match default.execution with
          | Runtime_execution.Antigravity_cli config ->
            check string "cli path" "agy" config.cli_path;
            check string "model" "gemini-3.6-flash-high" config.model;
            check (option string) "agent" (Some "fixture-agent") config.agent;
            check bool
              "effort"
              true
              (config.effort = Some Runtime_antigravity.High);
            check string
              "OAuth source"
              "/tmp/antigravity-oauth-token"
              config.oauth_source;
            check (float 0.0) "timeout" 45.0 config.timeout_s
          | Runtime_execution.Agent_core _
          | Runtime_execution.Codex_app_server _
          | Runtime_execution.Claude_code _ ->
            fail "antigravity-cli was materialized through the wrong execution owner"))
;;

let test_antigravity_cli_add_dirs_reach_the_execution_config () =
  let options =
    "timeout-s = 45.0\nadd-dirs = [\"/srv/repos\", \"/srv/shared\"]"
  in
  with_temp_runtime_toml
    (antigravity_cli_runtime_toml
       ~credential:antigravity_file_credential
       ~options
       ())
    (fun path ->
       match Runtime.load_list ~config_path:path with
       | Error error -> failf "antigravity-cli with add-dirs should load: %s" error
       | Ok (_, default, _, _, _) ->
         (match default.execution with
          | Runtime_execution.Antigravity_cli config ->
            check (list string) "add-dirs reach the execution config"
              [ "/srv/repos"; "/srv/shared" ] config.add_dirs
          | Runtime_execution.Agent_core _
          | Runtime_execution.Codex_app_server _
          | Runtime_execution.Claude_code _ ->
            fail "antigravity-cli was materialized through the wrong execution owner"))
;;

(* A relative entry would resolve against the CLI's own cwd — the keeper base
   path — and silently name a path inside the base the operator did not mean,
   so it is rejected at load. *)
let test_antigravity_cli_add_dirs_reject_relative_entries () =
  with_temp_runtime_toml
    (antigravity_cli_runtime_toml
       ~credential:antigravity_file_credential
       ~options:"timeout-s = 45.0\nadd-dirs = [\"repos\"]"
       ())
    (fun path ->
       match Runtime.load_list ~config_path:path with
       | Ok _ -> fail "a relative add-dirs entry must be rejected at load"
       | Error error ->
         check bool "diagnostic names the absolute-path requirement" true
           (String_util.contains_substring error "absolute paths"))
;;

let test_antigravity_cli_requires_explicit_timeout () =
  with_temp_runtime_toml
    (antigravity_cli_runtime_toml
       ~credential:antigravity_file_credential
       ())
    (fun path ->
    match Runtime.load_list ~config_path:path with
    | Ok _ -> fail "antigravity-cli silently defaulted timeout-s"
    | Error error ->
      check bool "diagnostic names required timeout" true
        (String_util.contains_substring error "timeout-s is required"))
;;

let test_antigravity_cli_requires_file_credentials () =
  let expect_rejected name ?credential () =
    with_temp_runtime_toml
      (antigravity_cli_runtime_toml
         ?credential
         ~options:"timeout-s = 45.0"
         ())
      (fun path ->
         match Runtime.load_list ~config_path:path with
         | Ok _ -> failf "antigravity-cli admitted %s credentials" name
         | Error error ->
           check bool (name ^ " diagnostic") true
             (String_util.contains_substring error "file credential"))
  in
  let env_credential =
    "[providers.antigravity.credentials]\n\
     type = \"env\"\n\
     key = \"GEMINI_API_KEY\""
  in
  let inline_credential =
    "[providers.antigravity.credentials]\n\
     type = \"inline\"\n\
     value = \"secret\""
  in
  expect_rejected "missing" ();
  expect_rejected "environment" ~credential:env_credential ();
  expect_rejected "inline" ~credential:inline_credential ()
;;

let test_antigravity_options_are_protocol_scoped () =
  with_temp_runtime_toml
    (codex_app_server_runtime_toml
       ~options:"agent = \"fixture-agent\""
       ())
    (fun path ->
       match Runtime.load_list ~config_path:path with
       | Ok _ -> fail "codex-app-server silently admitted an Antigravity option"
       | Error error ->
         check bool "diagnostic names scoped option" true
           (String_util.contains_substring
              error
              "agent is valid only for protocol antigravity-cli"))
;;

let test_antigravity_authority_fields_are_rejected () =
  with_temp_runtime_toml
    (antigravity_cli_runtime_toml
       ~credential:antigravity_file_credential
       ~options:"sandbox = false\ntimeout-s = 45.0"
       ())
    (fun path ->
       match Runtime.load_list ~config_path:path with
       | Ok _ -> fail "antigravity-cli admitted an operator authority override"
       | Error error ->
         check bool "diagnostic names unsupported field" true
           (String_util.contains_substring
              error
              "unsupported antigravity-cli provider field"))
;;

let test_codex_app_server_rejects_declared_credentials () =
  let credential =
    "[providers.codex.credentials]\n\
     type = \"env\"\n\
     key = \"OPENAI_API_KEY\""
  in
  with_temp_runtime_toml
    (codex_app_server_runtime_toml ~credential ())
    (fun path ->
       match Runtime.load_list ~config_path:path with
       | Ok _ -> fail "codex-app-server incorrectly admitted declared credentials"
       | Error error ->
         check bool "diagnostic names official subscription ownership" true
           (String_util.contains_substring
              error
              "official Codex client owns subscription login"))
;;

let () =
  run "runtime_config_validity"
    [ ( "runtime TOML gate",
        [ test_case "runtime.json is not a repo config source" `Quick
            test_runtime_json_not_in_repo_config;
          test_case "codex app-server is a distinct turn runtime" `Quick
            test_codex_app_server_materializes_as_turn_runtime;
          test_case "codex app-server rejects declared credentials" `Quick
            test_codex_app_server_rejects_declared_credentials;
          test_case "antigravity CLI options materialize" `Quick
            test_antigravity_cli_materializes_typed_process_options;
          test_case "antigravity add-dirs reach the execution config" `Quick
            test_antigravity_cli_add_dirs_reach_the_execution_config;
          test_case "antigravity add-dirs reject relative entries" `Quick
            test_antigravity_cli_add_dirs_reject_relative_entries;
          test_case "antigravity CLI requires explicit timeout" `Quick
            test_antigravity_cli_requires_explicit_timeout;
          test_case "antigravity CLI requires file credentials" `Quick
            test_antigravity_cli_requires_file_credentials;
          test_case "antigravity options are protocol-scoped" `Quick
            test_antigravity_options_are_protocol_scoped;
          test_case "antigravity authority fields are rejected" `Quick
            test_antigravity_authority_fields_are_rejected;
          test_case "deployment AGENT_CORE catalog covers live RunPod MTP runtime" `Quick
            test_deployment_agent_core_model_catalog_covers_live_runpod_mtp;
          test_case
            "deployment AGENT_CORE catalog covers GLM typed streaming reasoning"
            `Quick
            test_deployment_agent_core_model_catalog_covers_glm_streaming_reasoning;
          test_case
            "deployment AGENT_CORE catalog covers live RunPod RTX A6000 Gemma runtime"
            `Quick test_deployment_agent_core_model_catalog_covers_live_runpod_rtxa6000_gemma;
          test_case
            "deployment AGENT_CORE catalog covers local Gemma4 E2B QAT runtime"
            `Quick test_deployment_agent_core_model_catalog_covers_local_gemma4_e2b_qat;
          test_case
            "deployment AGENT_CORE catalog preserves typed thinking/replay axes"
            `Quick test_deployment_agent_core_model_catalog_preserve_axes_resolve;
          test_case
            "repo runtime bindings resolve through AGENT_CORE provider configs"
            `Quick test_repo_runtime_bindings_resolve_through_agent_core_provider_config;
          test_case
            "deployment AGENT_CORE catalog modality priority strings resolve"
            `Quick test_deployment_agent_core_model_catalog_modality_priorities_resolve;
          test_case "exact-output lane config is ordered and rejects duplicates" `Quick
            test_exact_output_lane_config_is_ordered_and_rejects_duplicates;
          test_case "exact-output lane cli_slots parse in order" `Quick
            test_exact_output_lane_cli_slots_parse_in_order;
          test_case "exact-output lane rejects unknown keys" `Quick
            test_exact_output_lane_rejects_unknown_key;
          test_case "lane rejects unknown keys" `Quick
            test_lane_rejects_unknown_key;
          test_case "repo runtime.toml loads through runtime parser" `Quick
            test_repo_runtime_toml_loads;
          test_case "kimi-for-coding declares the reasoning it returns" `Quick
            test_kimi_for_coding_declares_the_reasoning_it_returns;
          test_case "repo-runtime-toml-declares-no-clamped-max-context" `Quick
            test_repo_runtime_toml_declares_no_clamped_max_context;
          test_case "self-hosted server templates resolve when enabled" `Quick
            test_self_hosted_templates_resolve_when_enabled;
          test_case "commented official-client examples load" `Quick
            test_commented_official_client_examples_load;
          test_case
            "deployment exact-output catalog admits repo seed lanes"
            `Quick
            test_deployment_exact_output_catalog_admits_seed_lanes;
          test_case
            "removed [runtime].structured_judge key is unknown"
            `Quick test_structured_judge_runtime_key_is_rejected;
          test_case
            "save_config_text commits exact registry with runtime state"
            `Quick test_save_config_text_commits_exact_registry_with_runtime_state;
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
            "runtime capability gate uses provider-qualified AGENT_CORE catalog rows"
            `Quick test_runtime_capability_gate_uses_provider_qualified_catalog;
          test_case "runtime locality uses provider schema" `Quick
            test_runtime_locality_uses_provider_schema;
          test_case
            "runtime capability gate reports missing catalog models"
            `Quick test_runtime_capability_gate_reports_missing_catalog_models;
          test_case
            "server degraded init rejects referenced uncatalogued runtimes"
            `Quick test_server_degraded_init_rejects_referenced_uncatalogued_runtimes;
          test_case
            "server degraded init disables unreferenced uncatalogued runtimes"
            `Quick test_server_degraded_init_disables_unreferenced_uncatalogued_runtimes;
          test_case
            "server degraded init rejects uncatalogued default"
            `Quick test_server_degraded_init_rejects_uncatalogued_default;
          test_case "runtime enabled defaults true" `Quick
            test_runtime_toml_enabled_defaults_true;
          test_case "disabled provider excludes all of its bindings" `Quick
            test_runtime_provider_disable_excludes_its_bindings;
          test_case "disabled binding is excluded and rejected when referenced" `Quick
            test_runtime_binding_disable_excludes_only_that_binding;
          test_case "verifier_exact slot must name a configured route" `Quick
            test_verifier_exact_slot_must_name_a_configured_route;
          test_case "sibling exact lanes keep catalog-only slots" `Quick
            test_sibling_exact_lanes_keep_catalog_only_slots;
          test_case "unreferenced binding naming an undeclared model fails the load"
            `Quick test_binding_naming_an_undeclared_model_fails_the_load;
          test_case "non-provider top-level namespaces are not bindings" `Quick
            test_non_provider_namespaces_are_not_bindings;
          test_case "deliberate disables stay tolerated drops" `Quick
            test_deliberate_disable_is_still_a_tolerated_drop;
          test_case "of_binding reports an undeclared provider" `Quick
            test_of_binding_reports_an_undeclared_provider;
          test_case "runtime enabled fields require booleans" `Quick
            test_runtime_toml_rejects_non_boolean_enabled;
          test_case
            "every routing field names itself in its diagnostic"
            `Quick test_every_routing_field_names_itself_in_its_diagnostic;
          test_case
            "routing reference domains stay distinct"
            `Quick test_routing_reference_domains_stay_distinct;
          test_case
            "strict init rejects assigned runtime absent from AGENT_CORE catalog"
            `Quick test_strict_init_rejects_assigned_runtime_absent_from_agent_core_catalog;
          test_case "atomic runtime getters are consistent after init" `Quick
            test_runtime_atomic_getters_are_consistent_after_init;
          test_case "max-concurrent is optional opt-in" `Quick
            test_runtime_toml_parses_optional_max_concurrent;
          test_case "wizard-default is separate from runtime default marker" `Quick
            test_runtime_toml_separates_wizard_default_from_runtime_default_marker;
          test_case "non-positive max-concurrent is rejected" `Quick
            test_runtime_toml_rejects_non_positive_max_concurrent;
          test_case "max-concurrent flows from binding to provider config" `Quick
            test_runtime_toml_max_concurrent_flows_to_provider_config;
          test_case "reasoning-effort flows from model row to provider config" `Quick
            test_runtime_toml_reasoning_effort_flows_to_provider_config;
          test_case "max-request-body-bytes is optional opt-in" `Quick
            test_runtime_toml_parses_optional_max_request_body_bytes;
          test_case "return-progress is optional opt-in" `Quick
            test_runtime_toml_parses_optional_return_progress;
          test_case "omitted max-request-body-bytes stays None" `Quick
            test_runtime_toml_omitted_max_request_body_bytes_is_none;
          test_case "repetition samplers are optional opt-in" `Quick
            test_runtime_toml_parses_repetition_samplers;
          test_case "omitted repetition samplers stay None" `Quick
            test_runtime_toml_omitted_repetition_samplers_stay_none;
          test_case "non-positive repeat-penalty is rejected" `Quick
            test_runtime_toml_rejects_non_positive_repeat_penalty;
          test_case "repeat-last-n below -1 is rejected" `Quick
            test_runtime_toml_rejects_repeat_last_n_below_minus_one;
          test_case "repetition samplers off the ollama wire are rejected" `Quick
            test_runtime_toml_rejects_repetition_samplers_off_the_ollama_wire;
          test_case "repetition samplers on the ollama wire still parse" `Quick
            test_runtime_toml_keeps_repetition_samplers_on_the_ollama_wire;
          test_case "max-tokens parses and reaches Provider_config" `Quick
            test_runtime_toml_parses_max_tokens;
          test_case "omitted max-tokens stays None" `Quick
            test_runtime_toml_omitted_max_tokens_stays_none;
          test_case "non-positive max-tokens is rejected" `Quick
            test_runtime_toml_rejects_non_positive_max_tokens;
          test_case
            "keeper dispatch graph enumeration"
            `Quick test_keeper_dispatch_runtime_graph_enumeration;
          test_case
            "runtime config rejects uncapped keeper candidate"
            `Quick test_runtime_config_validation_rejects_uncapped_keeper_candidate;
          test_case
            "runtime config admits an undeclared official-client seed"
            `Quick
            test_runtime_config_validation_admits_undeclared_official_client_seed;
          test_case
            "runtime config allows uncapped dormant lane candidate"
            `Quick
            test_runtime_config_validation_allows_uncapped_dormant_lane_candidate;
          test_case
            "declared uncapped runtime reports its dispatch blocker"
            `Quick test_declared_uncapped_runtime_reports_its_dispatch_blocker;
          test_case
            "official-client runtime is dispatchable without a body cap"
            `Quick test_official_client_runtime_is_dispatchable_without_a_body_cap;
          test_case "non-positive max-request-body-bytes is rejected" `Quick
            test_runtime_toml_rejects_non_positive_max_request_body_bytes;
          test_case
            "unknown capabilities key is rejected at load"
            `Quick test_unknown_capability_key_rejected_at_load;
          test_case
            "max-context: capability-only source uses the catalog cap"
            `Quick test_runtime_max_context_capability_only_uses_catalog_cap;
          test_case
            "max-context: override below the catalog cap wins as override"
            `Quick test_runtime_max_context_override_below_cap_wins_as_override;
          test_case
            "max-context: override above the catalog cap is clamped"
            `Quick test_runtime_max_context_override_above_cap_is_clamped;
          test_case
            "max-context: lane budget is bound by the smallest candidate window"
            `Quick test_lane_budget_is_bound_by_smallest_candidate_window;
          test_case
            "max-context: missing both sources is rejected at load"
            `Quick test_runtime_max_context_missing_both_sources_rejected_at_load;
          test_case
            "assignments: unassigned keeper rides [runtime].default"
            `Quick test_runtime_assignment_default_rider_resolves_to_default_runtime;
          test_case
            "repo runtime.toml declares every mandatory exact-output lane"
            `Quick test_repo_runtime_toml_declares_mandatory_exact_output_lanes;
          test_case
            "every discovered boot-path fixture declares the mandatory exact-output lanes"
            `Quick test_boot_path_fixtures_declare_mandatory_exact_output_lanes;
          test_case
            "release-evidence smoke lanes resolve with no credential present"
            `Quick test_release_evidence_fixture_lanes_resolve_without_credentials
        ; test_case
            "reasoning-effort parses into the typed variant"
            `Quick test_model_reasoning_effort_parses_into_the_typed_variant
        ; test_case
            "reasoning-effort rejects an unknown value at load"
            `Quick test_model_reasoning_effort_rejects_unknown_value_at_load
        ; test_case
            "a model without reasoning-effort leaves it unset"
            `Quick test_model_without_reasoning_effort_leaves_it_unset
        ; test_case
            "turn-timeout-s parses as a positive float"
            `Quick test_model_turn_timeout_parses_as_a_positive_float
        ; test_case
            "turn-timeout-s admits zero and rejects negative"
            `Quick test_model_turn_timeout_admits_zero_and_rejects_negative
        ; test_case
            "a model without turn-timeout-s leaves it unset"
            `Quick test_model_without_turn_timeout_leaves_it_unset
        ; test_case
            "wall-clock-ceiling-s parses as a positive float"
            `Quick test_model_wall_clock_ceiling_parses_as_a_positive_float
        ; test_case
            "wall-clock-ceiling-s rejects zero and negative"
            `Quick test_model_wall_clock_ceiling_rejects_zero_and_negative
        ; test_case
            "a model without wall-clock-ceiling-s leaves it unset"
            `Quick test_model_without_wall_clock_ceiling_leaves_it_unset
        ; test_case
            "load allows a lane that mixes checkpoint owners"
            `Quick test_load_allows_a_lane_that_mixes_checkpoint_owners
        ; test_case
            "edit_config_text edits the file's own text and commits it"
            `Quick test_edit_config_text_reads_the_file_and_commits_the_edit
        ] )
    ]
