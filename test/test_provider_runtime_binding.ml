open Agent_sdk

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f
;;

let with_provider_catalog json f =
  match Llm_provider.Provider_catalog.of_json (Yojson.Safe.from_string json) with
  | Error msg -> Alcotest.fail msg
  | Ok catalog ->
    Llm_provider.Provider_catalog.set_global catalog;
    Fun.protect ~finally:Llm_provider.Provider_catalog.clear_global f
;;

let with_model_catalog toml f =
  let path = Filename.temp_file "oas-provider-runtime-binding-models" ".toml" in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc toml);
  Fun.protect
    ~finally:(fun () ->
      Llm_provider.Model_catalog.clear_global ();
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       match Llm_provider.Model_catalog.load_file path with
       | Error msg -> Alcotest.fail msg
       | Ok catalog ->
         Llm_provider.Model_catalog.set_global catalog;
         f ())
;;

let catalog_json =
  {|
{
  "schema_version": 1,
  "providers": [
    {
      "id": "subscriber-local",
      "aliases": ["Subscriber-Alias"],
      "kind": "openai_compat",
      "base_url": "http://127.0.0.1:8123",
      "request_path": "/v1/chat/completions",
      "auth": {"type": "none"},
      "default_model": "local-model",
      "capabilities_base": "openai_chat",
      "capabilities": {
        "supports_tools": true,
        "supports_reasoning": true
      },
      "credential_scope": "test runtime"
    }
  ]
}
|}
;;

let catalog_variants_json =
  {|
{
  "schema_version": 1,
  "providers": [
    {
      "id": "custom-rich",
      "aliases": ["Rich-Alias"],
      "kind": "openai_compat",
      "base_url": "https://rich.example/v1/",
      "request_path": "/chat/completions",
      "auth": {"type": "setup_token_env", "env": "RICH_SETUP_TOKEN"},
      "default_model": "rich-default",
      "capabilities_base": "openai_chat"
    },
    {
      "id": "api-key-auth",
      "kind": "openai_compat",
      "base_url": "https://api-key.example/v1",
      "request_path": "/chat/completions",
      "auth": {"type": "api_key_env", "env": "API_KEY_AUTH"},
      "capabilities_base": "openai_chat"
    }
  ]
}
|}
;;

let shared_endpoint_catalog_json =
  {|
{
  "schema_version": 1,
  "providers": [
    {
      "id": "shared-alpha",
      "aliases": ["Alpha-Alias"],
      "kind": "openai_compat",
      "base_url": "https://shared.example/v1",
      "request_path": "/chat/completions",
      "auth": {"type": "none"},
      "capabilities_base": "openai_chat",
      "capabilities": {"supports_reasoning": false}
    },
    {
      "id": "shared-beta",
      "aliases": ["Beta-Alias"],
      "kind": "openai_compat",
      "base_url": "https://shared.example/v1",
      "request_path": "/chat/completions",
      "auth": {"type": "none"},
      "capabilities_base": "openai_chat",
      "capabilities": {"supports_reasoning": true}
    }
  ]
}
|}
;;

let auth_to_string = function
  | Provider_runtime_binding.No_auth -> "none"
  | Provider_runtime_binding.Api_key_env env -> "api_key_env:" ^ env
  | Provider_runtime_binding.Setup_token_env env -> "setup:" ^ env
;;

let expect_binding label =
  match Provider_runtime_binding.find label with
  | Some binding -> binding
  | None -> Alcotest.failf "expected provider binding for %S" label
;;

let expect_ok = function
  | Ok value -> value
  | Error err -> Alcotest.fail (Error.to_string err)
;;

let test_catalog_alias_default_and_capabilities () =
  with_provider_catalog catalog_json (fun () ->
    let binding = expect_binding " subscriber-alias " in
    Alcotest.(check string) "canonical id" "subscriber-local" binding.id;
    Alcotest.(check (list string)) "aliases" [ "subscriber-alias" ] binding.aliases;
    Alcotest.(check (option string))
      "default model"
      (Some "local-model")
      binding.default_model;
    Alcotest.(check bool) "supports tools" true binding.capabilities.supports_tools;
    Alcotest.(check (option string))
      "credential scope"
      (Some "test runtime")
      binding.credential_scope;
    Alcotest.(check string)
      "resolved default"
      "local-model"
      (expect_ok (Provider_runtime_binding.resolve_model binding ~requested_model:None));
    Alcotest.(check string)
      "requested model wins"
      "explicit-model"
      (expect_ok
         (Provider_runtime_binding.resolve_model
            binding
            ~requested_model:(Some " explicit-model "))))
;;

let test_catalog_to_provider_config () =
  with_provider_catalog catalog_json (fun () ->
    let binding = expect_binding "subscriber-local" in
    let cfg = expect_ok (Provider_runtime_binding.to_provider_config binding) in
    Alcotest.(check (option string))
      "canonical provider id"
      (Some "subscriber-local")
      cfg.provider_id;
    Alcotest.(check string) "model id" "local-model" cfg.model_id;
    Alcotest.(check string) "base url" "http://127.0.0.1:8123" cfg.base_url;
    Alcotest.(check string) "request path" "/v1/chat/completions" cfg.request_path;
    Alcotest.(check bool)
      "kind"
      true
      (cfg.kind = Llm_provider.Provider_config.OpenAI_compat))
;;

let test_explicit_provider_identity_selects_catalog_binding () =
  with_provider_catalog catalog_json (fun () ->
    [ "subscriber-local"; "Subscriber-Alias" ]
    |> List.iter (fun provider_id ->
      let cfg =
        Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat
          ~provider_id
          ~model_id:"local-model"
          ~base_url:"https://deliberately-different.example/v9"
          ~request_path:"/not-the-catalog-path"
          ()
      in
      match Provider_runtime_binding.binding_for_provider_config cfg with
      | Some binding ->
        Alcotest.(check string)
          (provider_id ^ " canonical binding")
          "subscriber-local"
          binding.id;
        Alcotest.(check string)
          (provider_id ^ " canonical provider id")
          "subscriber-local"
          (Provider_runtime_binding.provider_id_of_provider_config cfg)
      | None -> Alcotest.failf "expected explicit binding for %S" provider_id))
;;

let test_endpoint_only_config_does_not_select_catalog_facts () =
  with_provider_catalog catalog_json (fun () ->
    let cfg =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.OpenAI_compat
        ~model_id:"unlisted-local-model"
        ~base_url:"http://127.0.0.1:8123"
        ~request_path:"/v1/chat/completions"
        ()
    in
    Alcotest.(check bool)
      "endpoint does not select binding"
      true
      (Option.is_none (Provider_runtime_binding.binding_for_provider_config cfg));
    let caps = Provider_runtime_binding.capabilities_for_provider_config cfg in
    Alcotest.(check bool)
      "endpoint does not select catalog reasoning capability"
      false
      caps.supports_reasoning)
;;

let test_explicit_provider_id_selects_catalog_capabilities () =
  with_provider_catalog catalog_json (fun () ->
    let cfg =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.OpenAI_compat
        ~provider_id:"subscriber-local"
        ~model_id:"unlisted-local-model"
        ~base_url:"https://deliberately-different.example/v9"
        ~request_path:"/not-the-catalog-path"
        ()
    in
    let caps = Provider_runtime_binding.capabilities_for_provider_config cfg in
    Alcotest.(check bool) "catalog supports tools" true caps.supports_tools;
    Alcotest.(check bool)
      "explicit id selects catalog reasoning capability"
      true
      caps.supports_reasoning)
;;

let test_capabilities_for_provider_config_honors_override () =
  with_provider_catalog catalog_json (fun () ->
    let cfg =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.OpenAI_compat
        ~provider_id:"subscriber-alias"
        ~model_id:"unlisted-local-model"
        ~base_url:"https://deliberately-different.example/v9"
        ~request_path:"/not-the-catalog-path"
        ~supports_tool_choice_override:false
        ()
    in
    let caps = Provider_runtime_binding.capabilities_for_provider_config cfg in
    Alcotest.(check bool) "override disables tool choice" false caps.supports_tool_choice;
    Alcotest.(check bool)
      "override disables required tool choice"
      false
      caps.supports_required_tool_choice;
    Alcotest.(check bool)
      "override disables named tool choice"
      false
      caps.supports_named_tool_choice)
;;

let test_shared_endpoint_is_disambiguated_by_explicit_provider_id () =
  with_provider_catalog shared_endpoint_catalog_json (fun () ->
    let config provider_id =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.OpenAI_compat
        ~provider_id
        ~model_id:"shared-model"
        ~base_url:"https://shared.example/v1"
        ~request_path:"/chat/completions"
        ()
    in
    let alpha = config "shared-alpha" in
    let beta = config "Beta-Alias" in
    let alpha_binding =
      match Provider_runtime_binding.binding_for_provider_config alpha with
      | Some binding -> binding
      | None -> Alcotest.fail "expected explicit shared-alpha binding"
    in
    let beta_binding =
      match Provider_runtime_binding.binding_for_provider_config beta with
      | Some binding -> binding
      | None -> Alcotest.fail "expected explicit beta alias binding"
    in
    Alcotest.(check string) "alpha binding" "shared-alpha" alpha_binding.id;
    Alcotest.(check string) "beta alias canonical binding" "shared-beta" beta_binding.id;
    let alpha_caps = Provider_runtime_binding.capabilities_for_provider_config alpha in
    let beta_caps = Provider_runtime_binding.capabilities_for_provider_config beta in
    Alcotest.(check bool) "alpha provider capability" false alpha_caps.supports_reasoning;
    Alcotest.(check bool) "beta provider capability" true beta_caps.supports_reasoning)
;;

let test_unknown_explicit_provider_id_never_switches_by_endpoint () =
  with_provider_catalog catalog_json (fun () ->
    let cfg =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.OpenAI_compat
        ~provider_id:"Unknown-Explicit"
        ~model_id:"unlisted-local-model"
        ~base_url:"http://127.0.0.1:8123"
        ~request_path:"/v1/chat/completions"
        ()
    in
    Alcotest.(check bool)
      "unknown explicit id has no binding"
      true
      (Option.is_none (Provider_runtime_binding.binding_for_provider_config cfg));
    Alcotest.(check string)
      "unknown explicit id remains normalized and opaque"
      "unknown-explicit"
      (Provider_runtime_binding.provider_id_of_provider_config cfg);
    let caps = Provider_runtime_binding.capabilities_for_provider_config cfg in
    Alcotest.(check bool)
      "matching endpoint does not select another provider's capabilities"
      false
      caps.supports_reasoning)
;;

let test_local_openai_compat_capabilities_not_inflated_by_locality () =
  (* RFC-OAS-034: host locality must not grant the extended capability preset.
     A local OpenAI-compatible endpoint on a non-default port serving an
     uncatalogued model resolves to base openai_compat capabilities — reasoning
     and extended thinking are NOT inferred from the endpoint being local. Before
     the fix, [is_local -> "nous"] routed this to the extended preset. *)
  let cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"uncatalogued-local-model"
      ~base_url:"http://127.0.0.1:8199"
      ~request_path:"/v1/chat/completions"
      ()
  in
  let caps = Provider_runtime_binding.capabilities_for_provider_config cfg in
  Alcotest.(check bool) "no reasoning from locality" false caps.supports_reasoning;
  Alcotest.(check bool)
    "no extended thinking from locality"
    false
    caps.supports_extended_thinking;
  Alcotest.(check bool)
    "no reasoning budget from locality"
    false
    caps.supports_reasoning_budget
;;

let test_capabilities_host_invariant_local_vs_remote () =
  (* RFC-OAS-034: capability = f(runtime x model), not f(host). The same kind +
     uncatalogued model resolves to the same reasoning capability whether the
     endpoint is local (non-default port) or remote. *)
  let make base_url =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"uncatalogued-model"
      ~base_url
      ~request_path:"/v1/chat/completions"
      ()
  in
  let local =
    Provider_runtime_binding.capabilities_for_provider_config
      (make "http://127.0.0.1:8199")
  in
  let remote =
    Provider_runtime_binding.capabilities_for_provider_config
      (make "https://remote.example/v1")
  in
  Alcotest.(check bool)
    "reasoning capability is host-invariant"
    remote.supports_reasoning
    local.supports_reasoning;
  Alcotest.(check bool)
    "both resolve to base (no reasoning)"
    false
    local.supports_reasoning
;;

let test_catalog_structured_output_capability_projects_to_provider_config () =
  with_provider_catalog catalog_json (fun () ->
    let binding = expect_binding "subscriber-local" in
    let cfg =
      expect_ok
        (Provider_runtime_binding.to_provider_config
           ~model:"qwen/qwen3.6-35b-a3b"
           binding)
    in
    let schema = `Assoc [ "type", `String "object" ] in
    let cfg =
      { cfg with Llm_provider.Provider_config.response_format = Types.JsonSchema schema }
    in
    Alcotest.(check bool)
      "catalog endpoint accepts declared structured output"
      true
      (Result.is_ok (Llm_provider.Provider_config.validate_output_schema_request cfg)))
;;

let test_capabilities_for_provider_config_uses_provider_scoped_model_catalog () =
  with_model_catalog
    {|
[[providers]]
id = "ollama_cloud"
kind = "openai_compat"
base_url = "https://ollama.com/v1"
request_path = "/chat/completions"
api_key_env = "OLLAMA_CLOUD_API_KEY"
capabilities_base = "ollama_cloud"

[[models]]
id_prefix = "kimi-k2.6"
base = "kimi"
supports_tools = true
supports_tool_choice = true
thinking_control_format = "none"

[[models]]
id_prefix = "kimi-k2.6"
base = "ollama_cloud"
provider_name = "ollama_cloud"
supports_tools = true
supports_tool_choice = false
supports_reasoning = true
supports_extended_thinking = true
supports_reasoning_budget = true
thinking_control_format = "reasoning_effort"
reasoning_replay = "preserve_always"
|}
    (fun () ->
       let cfg =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~provider_id:"ollama_cloud"
           ~model_id:"kimi-k2.6"
           ~base_url:"https://ollama.com/v1"
           ~request_path:"/chat/completions"
           ()
       in
       let caps = Provider_runtime_binding.capabilities_for_provider_config cfg in
       Alcotest.(check bool)
         "ollama cloud row disables forced tool_choice"
         false
         caps.supports_tool_choice;
       Alcotest.(check bool)
         "ollama cloud row disables named forced tool_choice"
         false
         caps.supports_named_tool_choice;
       Alcotest.(check bool)
         "ollama cloud row uses reasoning_effort"
         true
         (caps.thinking_control_format = Llm_provider.Capabilities.Reasoning_effort);
       Alcotest.(check bool)
         "ollama cloud row preserves reasoning replay"
         true
         (caps.reasoning_replay_override = Llm_provider.Capabilities.Force_preserve_always))
;;

let test_capabilities_for_provider_config_uses_exact_provider_model_tuple () =
  with_provider_catalog
    {|
{
  "schema_version": 1,
  "providers": [
    {
      "id": "vllm-qwen3-mtp",
      "kind": "openai_compat",
      "base_url": "https://runpod.example.invalid/v1",
      "request_path": "/chat/completions",
      "auth": {"type": "none"},
      "capabilities_base": "openai_chat",
      "capabilities": {
        "supports_parallel_tool_calls": false,
        "supports_reasoning": false
      }
    }
  ]
}
|}
    (fun () ->
       with_model_catalog
         {|
[[models]]
id_prefix = "qwen36-35b-a3b-mtp"
base = "openai_chat"
provider_name = "vllm-qwen3-mtp"
supports_tools = true
supports_tool_choice = true
supports_parallel_tool_calls = true
supports_reasoning = true
supports_extended_thinking = true
supports_reasoning_budget = true
thinking_control_format = "chat_template_kwargs"
preserve_thinking_control_format = "chat_template_kwargs_preserve_thinking"
|}
         (fun () ->
            let cfg =
              Llm_provider.Provider_config.make
                ~kind:Llm_provider.Provider_config.OpenAI_compat
                ~provider_id:"vllm-qwen3-mtp"
                ~model_id:"qwen36-35b-a3b-mtp"
                ~base_url:"https://runpod.example.invalid/v1"
                ~request_path:"/chat/completions"
                ()
            in
            let caps = Provider_runtime_binding.capabilities_for_provider_config cfg in
            Alcotest.(check bool)
              "vllm-qwen3-mtp row keeps tools"
              true
              caps.supports_tools;
            Alcotest.(check bool)
              "exact model row overrides provider-level parallel tools"
              true
              caps.supports_parallel_tool_calls;
            Alcotest.(check bool)
              "exact model row overrides provider-level reasoning"
              true
              caps.supports_reasoning;
            Alcotest.(check bool)
              "vllm-qwen3-mtp row uses chat_template_kwargs"
              true
              (caps.thinking_control_format
               = Llm_provider.Capabilities.Chat_template_kwargs);
            let binding = expect_binding "vllm-qwen3-mtp" in
            let projected =
              expect_ok
                (Provider_runtime_binding.to_provider_config
                   ~model:"qwen36-35b-a3b-mtp"
                   binding)
            in
            Alcotest.(check (option string))
              "projection preserves exact provider id"
              (Some "vllm-qwen3-mtp")
              projected.provider_id;
            Alcotest.(check bool)
              "projection does not mask exact model row with provider override"
              true
              (Option.is_none projected.model_capabilities_override);
            let projected_caps =
              Provider_runtime_binding.capabilities_for_provider_config projected
            in
            Alcotest.(check bool)
              "projected config retains exact model reasoning"
              true
              projected_caps.supports_reasoning))
;;

let expect_tool_choice_ok label cfg =
  match Llm_provider.Provider_config.validate_tool_choice_request_typed cfg with
  | Ok () -> ()
  | Error rejection ->
    Alcotest.failf
      "%s unexpectedly rejected tool_choice: %s"
      label
      (Llm_provider.Provider_config.tool_choice_request_rejection_to_message rejection)
;;

let expect_named_tool_choice_rejected label cfg =
  match Llm_provider.Provider_config.validate_tool_choice_request_typed cfg with
  | Error (Llm_provider.Provider_config.Unsupported_named_tool_choice { tool_name; _ }) ->
    Alcotest.(check string) (label ^ " tool") "calc" tool_name
  | Error rejection ->
    Alcotest.failf
      "%s rejected named forced tool_choice with unexpected reason: %s"
      label
      (Llm_provider.Provider_config.tool_choice_request_rejection_to_message rejection)
  | Ok () -> Alcotest.failf "%s unexpectedly accepted named forced tool_choice" label
;;

let expect_required_tool_choice_rejected label cfg =
  match Llm_provider.Provider_config.validate_tool_choice_request_typed cfg with
  | Error (Llm_provider.Provider_config.Unsupported_required_tool_choice _) -> ()
  | Error rejection ->
    Alcotest.failf
      "%s rejected required forced tool_choice with unexpected reason: %s"
      label
      (Llm_provider.Provider_config.tool_choice_request_rejection_to_message rejection)
  | Ok () -> Alcotest.failf "%s unexpectedly accepted required forced tool_choice" label
;;

let request_tool_choice_field cfg =
  let body =
    Llm_provider.Backend_openai.build_request ~config:cfg ~messages:[] ()
    |> Yojson.Safe.from_string
  in
  match body with
  | `Assoc fields -> List.assoc_opt "tool_choice" fields
  | _ -> Alcotest.fail "expected request body object"
;;

let expect_named_tool_choice_serialized label cfg =
  match request_tool_choice_field cfg with
  | Some (`Assoc fields) ->
    Alcotest.(check string)
      (label ^ " type")
      "function"
      (Yojson.Safe.Util.to_string (List.assoc "type" fields));
    let function_json = List.assoc "function" fields in
    Alcotest.(check string)
      (label ^ " name")
      "calc"
      Yojson.Safe.Util.(function_json |> member "name" |> to_string)
  | Some json ->
    Alcotest.failf
      "%s expected named tool_choice object, got %s"
      label
      (Yojson.Safe.to_string json)
  | None -> Alcotest.failf "%s expected tool_choice in request body" label
;;

let expect_no_tool_choice_field label cfg =
  match request_tool_choice_field cfg with
  | None -> ()
  | Some json ->
    Alcotest.failf
      "%s unexpectedly serialized tool_choice: %s"
      label
      (Yojson.Safe.to_string json)
;;

let test_forced_tool_choice_provider_invariants () =
  with_model_catalog
    {|
[[providers]]
id = "ollama_cloud"
kind = "openai_compat"
base_url = "https://ollama.com/v1"
request_path = "/chat/completions"
api_key_env = "OLLAMA_CLOUD_API_KEY"
capabilities_base = "ollama_cloud"

[[models]]
id_prefix = "claude-opus-4-6"
base = "anthropic"
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
supports_named_tool_choice = true

[[models]]
id_prefix = "glm-5.1"
base = "glm"
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = false
supports_named_tool_choice = false

[[models]]
id_prefix = "minimax-m3"
base = "openai_chat"
provider_name = "minimax"
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false

[[models]]
id_prefix = "minimax-m3"
base = "ollama_cloud"
provider_name = "ollama_cloud"
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
|}
    (fun () ->
       let named = Types.Tool "calc" in
       let anthropic =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.Anthropic
           ~model_id:"claude-opus-4-6"
           ~base_url:"https://api.anthropic.com"
           ~tool_choice:named
           ()
       in
       expect_tool_choice_ok "anthropic named" anthropic;
       let minimax =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~provider_id:"minimax"
           ~model_id:"minimax-m3"
           ~base_url:"https://api.minimax.chat/v1"
           ~tool_choice:named
           ()
       in
       expect_named_tool_choice_rejected "minimax named" minimax;
       let minimax_any =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~provider_id:"minimax"
           ~model_id:"minimax-m3"
           ~base_url:"https://api.minimax.chat/v1"
           ~tool_choice:Types.Any
           ()
       in
       expect_required_tool_choice_rejected "minimax any" minimax_any;
       let minimax_auto =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~provider_id:"minimax"
           ~model_id:"minimax-m3"
           ~base_url:"https://api.minimax.chat/v1"
           ~tool_choice:Types.Auto
           ()
       in
       expect_tool_choice_ok "minimax auto" minimax_auto;
       expect_no_tool_choice_field "minimax auto" minimax_auto;
       let glm =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.Glm
           ~model_id:"glm-5.1"
           ~base_url:Llm_provider.Zai_catalog.coding_base_url
           ~tool_choice:named
           ()
       in
       expect_named_tool_choice_rejected "glm named" glm;
       let glm_any =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.Glm
           ~model_id:"glm-5.1"
           ~base_url:Llm_provider.Zai_catalog.coding_base_url
           ~tool_choice:Types.Any
           ()
       in
       expect_required_tool_choice_rejected "glm any" glm_any;
       let bare_zai_glm =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~model_id:"glm-5.1"
           ~base_url:Llm_provider.Zai_catalog.coding_base_url
           ~tool_choice:named
           ()
       in
       expect_named_tool_choice_rejected "bare zai glm named" bare_zai_glm;
       let bare_zai_glm_any =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~model_id:"glm-5.1"
           ~base_url:Llm_provider.Zai_catalog.coding_base_url
           ~tool_choice:Types.Any
           ()
       in
       expect_required_tool_choice_rejected "bare zai glm any" bare_zai_glm_any;
       let hosted_minimax_named =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~provider_id:"ollama_cloud"
           ~model_id:"minimax-m3"
           ~base_url:"https://ollama.com/v1"
           ~request_path:"/chat/completions"
           ~tool_choice:named
           ()
       in
       expect_named_tool_choice_rejected "ollama cloud minimax named" hosted_minimax_named;
       let hosted_minimax_any =
         Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~provider_id:"ollama_cloud"
           ~model_id:"minimax-m3"
           ~base_url:"https://ollama.com/v1"
           ~request_path:"/chat/completions"
           ~tool_choice:Types.Any
           ()
       in
       expect_required_tool_choice_rejected "ollama cloud minimax any" hosted_minimax_any)
;;

let test_all_includes_catalog_entry_once () =
  with_provider_catalog catalog_json (fun () ->
    let matches =
      Provider_runtime_binding.all ()
      |> List.filter (fun (binding : Provider_runtime_binding.t) ->
        String.equal binding.id "subscriber-local")
    in
    Alcotest.(check int) "catalog entry count" 1 (List.length matches))
;;

let test_catalog_auth_variants () =
  with_provider_catalog catalog_variants_json (fun () ->
    let cases =
      [ "rich-alias", "setup:RICH_SETUP_TOKEN", Some "rich-default"
      ; "api-key-auth", "api_key_env:API_KEY_AUTH", None
      ]
    in
    List.iter
      (fun (label, auth, default_model) ->
         let binding = expect_binding label in
         Alcotest.(check string) (label ^ " auth") auth (auth_to_string binding.auth);
         Alcotest.(check (option string))
           (label ^ " default model")
           default_model
           binding.default_model)
      cases)
;;

let test_find_empty_and_unknown_are_missing () =
  Alcotest.(check bool)
    "empty missing"
    true
    (Option.is_none (Provider_runtime_binding.find " "));
  Alcotest.(check bool)
    "unknown missing"
    true
    (Option.is_none (Provider_runtime_binding.find "not-a-provider"))
;;

let test_builtin_binding_requires_exact_model () =
  let binding = expect_binding "claude" in
  Alcotest.(check string) "builtin id" "claude" binding.id;
  Alcotest.(check bool)
    "builtin kind"
    true
    (binding.kind = Llm_provider.Provider_config.Anthropic);
  Alcotest.(check bool)
    "missing model rejected"
    true
    (Result.is_error
       (Provider_runtime_binding.resolve_model binding ~requested_model:None));
  Alcotest.(check string)
    "exact requested model"
    "claude-exact-model"
    (expect_ok
       (Provider_runtime_binding.resolve_model
          binding
          ~requested_model:(Some "claude-exact-model")))
;;

let test_builtin_nous_binding_uses_declared_default_endpoint () =
  with_env "LLM_ENDPOINTS" (Some "") (fun () ->
    with_env
      Llm_provider.Discovery.local_llm_url_env_var
      (Some "http://127.0.0.1:19014")
      (fun () ->
         let binding = expect_binding "nous" in
         Alcotest.(check string)
           "declared runtime binding base_url"
           Llm_provider.Discovery.default_endpoint
           binding.base_url))
;;

let test_embedded_mimo_binding_preserves_default_model () =
  let binding = expect_binding "mimo" in
  Alcotest.(check (option string))
    "embedded default model"
    (Some "mimo-v2.5-pro")
    binding.default_model;
  Alcotest.(check string)
    "resolved embedded default"
    "mimo-v2.5-pro"
    (expect_ok (Provider_runtime_binding.resolve_model binding ~requested_model:None))
;;

let test_registry_bindings_do_not_invent_model_defaults () =
  [ "gemini"; "glm"; "kimi"; "dashscope"; "deepseek"; "groq"; "openrouter" ]
  |> List.iter (fun provider_id ->
    let binding = expect_binding provider_id in
    Alcotest.(check bool)
      (provider_id ^ " missing model rejected")
      true
      (Result.is_error
         (Provider_runtime_binding.resolve_model binding ~requested_model:None)))
;;

let test_builtin_selectors_are_exact () =
  let cases =
    [ "claude", "claude"
    ; "kimi", "kimi"
    ; "gemini", "gemini"
    ; "glm", "glm"
    ; "dashscope", "dashscope"
    ]
  in
  List.iter
    (fun (input, expected_id) ->
       let binding = expect_binding input in
       Alcotest.(check string) input expected_id binding.id)
    cases;
  Alcotest.(check bool)
    "undeclared provider alias is absent"
    true
    (Option.is_none (Provider_runtime_binding.find "anthropic"));
  Alcotest.(check bool)
    "openai_compat is a kind, not a provider selector"
    true
    (Option.is_none (Provider_runtime_binding.find "openai_compat"))
;;

let test_unregistered_openai_compat_identity_remains_typed () =
  let cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"unlisted-model"
      ~base_url:"https://unlisted.example/v1"
      ~request_path:"/chat/completions"
      ()
  in
  Alcotest.(check string)
    "unmatched openai compat"
    "openai_compat"
    (Provider_runtime_binding.provider_id_of_provider_config cfg)
;;

let () =
  Alcotest.run
    "Provider_runtime_binding"
    [ ( "catalog"
      , [ Alcotest.test_case
            "alias default capabilities"
            `Quick
            test_catalog_alias_default_and_capabilities
        ; Alcotest.test_case "to provider config" `Quick test_catalog_to_provider_config
        ; Alcotest.test_case
            "explicit provider identity selects binding"
            `Quick
            test_explicit_provider_identity_selects_catalog_binding
        ; Alcotest.test_case
            "endpoint-only config does not select catalog facts"
            `Quick
            test_endpoint_only_config_does_not_select_catalog_facts
        ; Alcotest.test_case
            "explicit provider id selects catalog capabilities"
            `Quick
            test_explicit_provider_id_selects_catalog_capabilities
        ; Alcotest.test_case
            "capabilities honor tool_choice override"
            `Quick
            test_capabilities_for_provider_config_honors_override
        ; Alcotest.test_case
            "shared endpoint is disambiguated by provider id"
            `Quick
            test_shared_endpoint_is_disambiguated_by_explicit_provider_id
        ; Alcotest.test_case
            "unknown explicit id stays opaque"
            `Quick
            test_unknown_explicit_provider_id_never_switches_by_endpoint
        ; Alcotest.test_case
            "structured output projects to provider config"
            `Quick
            test_catalog_structured_output_capability_projects_to_provider_config
        ; Alcotest.test_case
            "provider-scoped model catalog capabilities"
            `Quick
            test_capabilities_for_provider_config_uses_provider_scoped_model_catalog
        ; Alcotest.test_case
            "exact provider/model tuple capabilities"
            `Quick
            test_capabilities_for_provider_config_uses_exact_provider_model_tuple
        ; Alcotest.test_case
            "forced tool_choice provider invariants"
            `Quick
            test_forced_tool_choice_provider_invariants
        ; Alcotest.test_case
            "all includes catalog once"
            `Quick
            test_all_includes_catalog_entry_once
        ; Alcotest.test_case "auth variants" `Quick test_catalog_auth_variants
        ; Alcotest.test_case
            "find empty and unknown"
            `Quick
            test_find_empty_and_unknown_are_missing
        ; Alcotest.test_case
            "local capabilities not inflated by locality"
            `Quick
            test_local_openai_compat_capabilities_not_inflated_by_locality
        ; Alcotest.test_case
            "capabilities host-invariant local vs remote"
            `Quick
            test_capabilities_host_invariant_local_vs_remote
        ] )
    ; ( "builtins"
      , [ Alcotest.test_case
            "builtin requires exact model"
            `Quick
            test_builtin_binding_requires_exact_model
        ; Alcotest.test_case
            "nous binding uses declared default endpoint"
            `Quick
            test_builtin_nous_binding_uses_declared_default_endpoint
        ; Alcotest.test_case
            "embedded MiMo binding preserves default model"
            `Quick
            test_embedded_mimo_binding_preserves_default_model
        ; Alcotest.test_case
            "non-Claude builtin defaults do not use Claude model"
            `Quick
            test_registry_bindings_do_not_invent_model_defaults
        ; Alcotest.test_case
            "builtin selectors are exact"
            `Quick
            test_builtin_selectors_are_exact
        ; Alcotest.test_case
            "unregistered OpenAI-compatible identity remains typed"
            `Quick
            test_unregistered_openai_compat_identity_remains_typed
        ] )
    ]
;;
