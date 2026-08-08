(** Tests for Provider_registry (v0.69.0). *)

open Alcotest
open Llm_provider

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.putenv key "")
    f
;;

(* ── Registry CRUD ──────────────────────────────────── *)

let test_empty_registry () =
  let reg = Provider_registry.create_sync () in
  check int "empty has 0 entries" 0 (List.length (Provider_registry.all reg));
  check (option reject) "find on empty is None" None (Provider_registry.find reg "nope")
;;

let test_register_and_find () =
  let reg = Provider_registry.create_sync () in
  let entry : Provider_registry.entry =
    { name = "test-provider"
    ; defaults =
        { kind = OpenAI_compat
        ; base_url = "http://localhost:9999"
        ; api_key_env = ""
        ; request_path = "/v1/chat/completions"
        }
    ; max_context = Some 128_000
    ; capabilities = Capabilities.default_capabilities
    ; is_available = (fun () -> true)
    }
  in
  Provider_registry.register reg entry;
  (match Provider_registry.find reg "test-provider" with
   | Some e -> check string "name" "test-provider" e.name
   | None -> fail "should find registered provider");
  check int "1 entry" 1 (List.length (Provider_registry.all reg))
;;

let test_overwrite () =
  let reg = Provider_registry.create_sync () in
  let mk url : Provider_registry.entry =
    { name = "p"
    ; defaults =
        { kind = OpenAI_compat
        ; base_url = url
        ; api_key_env = ""
        ; request_path = "/v1/chat/completions"
        }
    ; max_context = Some 128_000
    ; capabilities = Capabilities.default_capabilities
    ; is_available = (fun () -> true)
    }
  in
  Provider_registry.register reg (mk "http://old");
  Provider_registry.register reg (mk "http://new");
  (match Provider_registry.find reg "p" with
   | Some e -> check string "updated url" "http://new" e.defaults.base_url
   | None -> fail "should exist");
  check int "still 1 entry" 1 (List.length (Provider_registry.all reg))
;;

let test_unregister () =
  let reg = Provider_registry.create_sync () in
  let entry : Provider_registry.entry =
    { name = "temp"
    ; defaults =
        { kind = OpenAI_compat
        ; base_url = "http://x"
        ; api_key_env = ""
        ; request_path = "/v1/chat/completions"
        }
    ; max_context = Some 128_000
    ; capabilities = Capabilities.default_capabilities
    ; is_available = (fun () -> true)
    }
  in
  Provider_registry.register reg entry;
  Provider_registry.unregister reg "temp";
  check (option reject) "gone" None (Provider_registry.find reg "temp");
  check int "0 entries" 0 (List.length (Provider_registry.all reg))
;;

let test_refresh_rejects_missing_endpoint_declarations () =
  check
    bool
    "no implicit active endpoint"
    true
    (Option.is_none (Provider_registry.current_llama_endpoint ()));
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match Provider_registry.refresh_llama_endpoints ~sw ~net:env#net ~endpoints:[] with
  | Error Provider_registry.No_endpoints_declared ->
    check
      int
      "missing declarations do not invent a fallback"
      0
      (List.length (Provider_registry.active_llama_endpoints ()))
  | Error (Provider_registry.No_healthy_endpoints _) ->
    fail "empty declarations cannot produce endpoint probe statuses"
  | Ok _ -> fail "empty declarations must be rejected"
;;

(* ── Availability ───────────────────────────────────── *)

let test_available_filter () =
  let reg = Provider_registry.create_sync () in
  let mk name avail : Provider_registry.entry =
    { name
    ; defaults =
        { kind = OpenAI_compat
        ; base_url = "http://x"
        ; api_key_env = ""
        ; request_path = "/v1/chat/completions"
        }
    ; max_context = Some 128_000
    ; capabilities = Capabilities.default_capabilities
    ; is_available = (fun () -> avail)
    }
  in
  Provider_registry.register reg (mk "up" true);
  Provider_registry.register reg (mk "down" false);
  let avail = Provider_registry.available reg in
  check int "only 1 available" 1 (List.length avail);
  check string "the up one" "up" (List.hd avail).name
;;

let test_command_in_path_finds_binary () =
  let tmp = Filename.temp_file "provider-registry" ".bin" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove tmp with
      | Sys_error _ -> ())
    (fun () ->
       let dir = Filename.dirname tmp in
       let name = Filename.basename tmp in
       check bool "binary found" true (Provider_registry.command_in_path ~path:dir name))
;;

let test_command_in_path_rejects_directory () =
  let dir = Filename.temp_file "provider-registry" ".dir" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () ->
       let parent = Filename.dirname dir in
       let name = Filename.basename dir in
       check
         bool
         "directory is not runnable"
         false
         (Provider_registry.command_in_path ~path:parent name))
;;

let test_command_in_path_misses_unknown_binary () =
  let dir = Filename.get_temp_dir_name () in
  check
    bool
    "missing binary"
    false
    (Provider_registry.command_in_path ~path:dir "provider-registry-missing-binary")
;;

(* ── Capability queries ─────────────────────────────── *)

let test_find_capable_tools () =
  let reg = Provider_registry.create_sync () in
  let mk name caps : Provider_registry.entry =
    { name
    ; defaults =
        { kind = OpenAI_compat
        ; base_url = "http://x"
        ; api_key_env = ""
        ; request_path = "/v1/chat/completions"
        }
    ; max_context = Some 128_000
    ; capabilities = caps
    ; is_available = (fun () -> true)
    }
  in
  Provider_registry.register
    reg
    (mk "with-tools" { Capabilities.default_capabilities with supports_tools = true });
  Provider_registry.register reg (mk "no-tools" Capabilities.default_capabilities);
  let capable =
    Provider_registry.find_capable reg (fun c -> c.Capabilities.supports_tools)
  in
  check int "1 with tools" 1 (List.length capable);
  check string "correct one" "with-tools" (List.hd capable).name
;;

let test_find_capable_composite () =
  let reg = Provider_registry.create_sync () in
  let mk name caps : Provider_registry.entry =
    { name
    ; defaults =
        { kind = OpenAI_compat
        ; base_url = "http://x"
        ; api_key_env = ""
        ; request_path = "/v1/chat/completions"
        }
    ; max_context = Some 128_000
    ; capabilities = caps
    ; is_available = (fun () -> true)
    }
  in
  Provider_registry.register
    reg
    (mk
       "full"
       { Capabilities.default_capabilities with
         supports_tools = true
       ; supports_reasoning = true
       });
  Provider_registry.register
    reg
    (mk "tools-only" { Capabilities.default_capabilities with supports_tools = true });
  Provider_registry.register reg (mk "none" Capabilities.default_capabilities);
  let need_both c = c.Capabilities.supports_tools && c.Capabilities.supports_reasoning in
  let capable = Provider_registry.find_capable reg need_both in
  check int "only full matches" 1 (List.length capable);
  check string "the full one" "full" (List.hd capable).name
;;

(* ── Default registry ───────────────────────────────── *)

(* Exact provider-name set: additions/removals in models.toml must update this
   list, and a mismatch reports the differing names instead of a bare count. *)
let expected_default_provider_names =
  [ "claude"
  ; "cohere"
  ; "dashscope"
  ; "deepseek"
  ; "gemini"
  ; "gemini-image"
  ; "gemini-speech"
  ; "glm"
  ; "glm-coding"
  ; "groq"
  ; "kimi"
  ; "mimo"
  ; "mistral"
  ; "nous"
  ; "ollama"
  ; "ollama_cloud"
  ; "openai-image"
  ; "openai-speech"
  ; "openrouter"
  ; "siliconflow"
  ; "xai"
  ; "zai-image"
  ]
;;

let test_default_provider_names () =
  let reg = Provider_registry.default () in
  let actual =
    Provider_registry.all reg
    |> List.map (fun (e : Provider_registry.entry) -> e.name)
    |> List.sort String.compare
  in
  check
    (list string)
    "default provider set"
    (List.sort String.compare expected_default_provider_names)
    actual;
  check
    bool
    "alibaba alias absent"
    false
    (Option.is_some (Provider_registry.find reg "alibaba"))
;;

let test_default_capabilities () =
  let reg = Provider_registry.default () in
  (match Provider_registry.find reg "claude" with
   | Some e ->
     check bool "claude has tools" true e.capabilities.supports_tools;
     check bool "claude has reasoning" true e.capabilities.supports_reasoning
   | None -> fail "claude should exist");
  match Provider_registry.find reg "nous" with
  | Some e ->
    check bool "llama has tools" true e.capabilities.supports_tools;
    check bool "llama has top_k" true e.capabilities.supports_top_k
  | None -> fail "llama should exist"
;;

let test_default_ollama_cloud_entry () =
  let reg = Provider_registry.default () in
  match Provider_registry.find reg "ollama_cloud" with
  | Some e ->
    check bool "kind is Ollama" true (e.defaults.kind = Provider_config.Ollama);
    check string "base_url" "https://ollama.com" e.defaults.base_url;
    check string "api_key_env" "OLLAMA_CLOUD_API_KEY" e.defaults.api_key_env;
    check string "request_path" "/api/chat" e.defaults.request_path;
    check
      bool
      "ollama_cloud uses ollama_cloud_capabilities"
      true
      (e.capabilities.thinking_control_format = Capabilities.Ollama_think);
    check
      bool
      "ollama_cloud does not support JSON mode"
      false
      e.capabilities.supports_response_format_json;
    check
      bool
      "ollama_cloud does not support provider schema"
      false
      e.capabilities.supports_structured_output
  | None -> fail "ollama_cloud should exist"
;;

let test_default_deepseek_entry () =
  let reg = Provider_registry.default () in
  match Provider_registry.find reg "deepseek" with
  | Some e ->
    check
      bool
      "kind is OpenAI_compat"
      true
      (e.defaults.kind = Provider_config.OpenAI_compat);
    check string "base_url" "https://api.deepseek.com" e.defaults.base_url;
    check string "api_key_env" "DEEPSEEK_API_KEY" e.defaults.api_key_env;
    check string "request_path" "/chat/completions" e.defaults.request_path
  | None -> fail "deepseek should exist"
;;

let test_default_deepseek_api_key_env () =
  let availability ~deepseek =
    with_env "DEEPSEEK_API_KEY" deepseek (fun () ->
      let reg = Provider_registry.default () in
      match Provider_registry.find reg "deepseek" with
      | Some e -> e.is_available ()
      | None -> fail "deepseek should exist")
  in
  check bool "no key unavailable" false (availability ~deepseek:"");
  check bool "documented key available" true (availability ~deepseek:"deepseek-secret")
;;

let test_default_mimo_entry () =
  with_env "MIMO_BASE_URL" "" (fun () ->
    let reg = Provider_registry.default () in
    match Provider_registry.find reg "mimo" with
    | Some e ->
      check
        bool
        "kind is OpenAI_compat"
        true
        (e.defaults.kind = Provider_config.OpenAI_compat);
      check
        string
        "base_url"
        "https://token-plan-sgp.xiaomimimo.com/v1"
        e.defaults.base_url;
      check string "api_key_env" "MIMO_API_KEY" e.defaults.api_key_env;
      check string "request_path" "/chat/completions" e.defaults.request_path;
      check (option int) "max_context" (Some 1_000_000) e.max_context;
      check bool "has reasoning" true e.capabilities.supports_reasoning;
      check bool "has JSON mode" true e.capabilities.supports_response_format_json;
      check
        bool
        "no native structured output"
        false
        e.capabilities.supports_structured_output
    | None -> fail "mimo should exist")
;;

let test_embedded_no_auth_rows_keep_explicit_empty_credentials () =
  let reg = Provider_registry.default () in
  let check_no_auth id expected_path =
    match Provider_registry.find reg id with
    | None -> failf "%s should exist" id
    | Some entry ->
      check string (id ^ " empty api_key_env") "" entry.defaults.api_key_env;
      check string (id ^ " request path") expected_path entry.defaults.request_path;
      check bool (id ^ " available without credential") true (entry.is_available ())
  in
  check_no_auth "nous" "/v1/chat/completions";
  check_no_auth "ollama" "/api/chat";
  match Provider_registry.find reg "gemini" with
  | Some entry ->
    check string "gemini explicit empty request path" "" entry.defaults.request_path
  | None -> fail "gemini should exist"
;;

let load_model_catalog_source source =
  let path = Filename.temp_file "provider-model-catalog" ".toml" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       let oc = open_out path in
       Fun.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () -> output_string oc source);
       Model_catalog.load_file path)
;;

let test_embedded_provider_rejects_padded_api_key_env () =
  let source value =
    Printf.sprintf
      {|[[providers]]
id = "padded-auth"
kind = "openai_compat"
base_url = "https://provider.example/v1"
request_path = "/chat/completions"
api_key_env = %S
capabilities_base = "openai_chat"
|}
      value
  in
  List.iter
    (fun value ->
       match load_model_catalog_source (source value) with
       | Error _ -> ()
       | Ok _ -> failf "padded api_key_env %S must be rejected" value)
    [ " PROVIDER_API_KEY"; "PROVIDER_API_KEY " ]
;;

let test_provider_name_is_wire_kind_projection () =
  let check_kind kind base_url =
    let config = Provider_config.make ~kind ~model_id:"test-model" ~base_url () in
    check
      string
      (Provider_config.string_of_provider_kind kind)
      (Provider_config.string_of_provider_kind kind)
      (Provider_registry.provider_name_of_config config)
  in
  List.iter
    (fun kind -> check_kind kind "https://provider-identity-must-not-come-from-url.test")
    Provider_config.all_provider_kinds
;;

let default_entry_base_url name =
  let reg = Provider_registry.default () in
  match Provider_registry.find reg name with
  | Some e -> e.defaults.base_url
  | None -> failf "%s should exist" name
;;

let test_default_endpoints_ignore_ambient_overrides () =
  with_env "LLM_ENDPOINTS" "http://127.0.0.1:18085" (fun () ->
    with_env "OLLAMA_HOST" "http://127.0.0.1:19134" (fun () ->
      with_env "KIMI_BASE_URL" "https://wrong-kimi.example" (fun () ->
        with_env "DEEPSEEK_BASE_URL" "https://wrong-deepseek.example" (fun () ->
          check
            string
            "nous declaration"
            Discovery.default_endpoint
            (default_entry_base_url "nous");
          check
            string
            "ollama declaration"
            Discovery.ollama_endpoint
            (default_entry_base_url "ollama");
          check
            string
            "kimi declaration"
            "https://api.kimi.com/coding"
            (default_entry_base_url "kimi");
          check
            string
            "deepseek declaration"
            "https://api.deepseek.com"
            (default_entry_base_url "deepseek")))))
;;

let test_default_max_context () =
  let reg = Provider_registry.default () in
  (match Provider_registry.find reg "nous" with
   | Some e -> check (option int) "llama 128K" (Some 128_000) e.max_context
   | None -> fail "llama should exist");
  (match Provider_registry.find reg "claude" with
   | Some e -> check (option int) "claude 200K" (Some 200_000) e.max_context
   | None -> fail "claude should exist");
  (match Provider_registry.find reg "gemini" with
   | Some e -> check (option int) "gemini 1M" (Some 1_000_000) e.max_context
   | None -> fail "gemini should exist");
  (match Provider_registry.find reg "glm" with
   | Some e -> check (option int) "glm 200K" (Some 200_000) e.max_context
   | None -> fail "glm should exist");
  (match Provider_registry.find reg "kimi" with
   | Some e -> check (option int) "kimi 256K" (Some 256_000) e.max_context
   | None -> fail "kimi should exist");
  (match Provider_registry.find reg "groq" with
   | Some e -> check (option int) "groq 128K" (Some 128_000) e.max_context
   | None -> fail "groq should exist");
  (match Provider_registry.find reg "deepseek" with
   | Some e ->
     check (option int) "deepseek provider capability 128K" (Some 128_000) e.max_context
   | None -> fail "deepseek should exist");
  (match Provider_registry.find reg "dashscope" with
   | Some e -> check (option int) "dashscope 128K" (Some 128_000) e.max_context
   | None -> fail "dashscope should exist");
  match Provider_registry.find reg "siliconflow" with
  | Some e -> check (option int) "siliconflow 128K" (Some 128_000) e.max_context
  | None -> fail "siliconflow should exist"
;;

let test_default_max_context_matches_capabilities () =
  let reg = Provider_registry.default () in
  Provider_registry.all reg
  |> List.iter (fun (entry : Provider_registry.entry) ->
    check
      (option int)
      (Printf.sprintf "%s registry context is capability declaration" entry.name)
      entry.capabilities.max_context_tokens
      entry.max_context)
;;

let test_default_zai_base_urls () =
  let reg = Provider_registry.default () in
  (match Provider_registry.find reg "glm" with
   | Some e ->
     check string "glm base_url" Zai_catalog.general_base_url e.defaults.base_url;
     check string "glm api_key_env" "ZAI_API_KEY" e.defaults.api_key_env
   | None -> fail "glm should exist");
  (match Provider_registry.find reg "glm-coding" with
   | Some e ->
     check string "glm-coding base_url" Zai_catalog.coding_base_url e.defaults.base_url;
     check string "glm-coding api_key_env" "ZAI_CODING_API_KEY" e.defaults.api_key_env
   | None -> fail "glm-coding should exist");
  match Provider_registry.find reg "kimi" with
  | Some e ->
    check string "kimi base_url" "https://api.kimi.com/coding" e.defaults.base_url;
    check string "kimi request_path" "/v1/messages" e.defaults.request_path
  | None -> fail "kimi should exist"
;;

let test_glm_coding_api_key_env_isolated () =
  let prev_general = Sys.getenv_opt "ZAI_API_KEY" in
  let prev_coding = Sys.getenv_opt "ZAI_CODING_API_KEY" in
  let restore key = function
    | Some v -> Unix.putenv key v
    | None -> Unix.putenv key ""
  in
  Fun.protect
    ~finally:(fun () ->
      restore "ZAI_API_KEY" prev_general;
      restore "ZAI_CODING_API_KEY" prev_coding)
    (fun () ->
       Unix.putenv "ZAI_API_KEY" "general-key";
       Unix.putenv "ZAI_CODING_API_KEY" "";
       let general_only = Provider_registry.default () in
       (match Provider_registry.find general_only "glm-coding" with
        | Some e ->
          check bool "general key does not enable coding lane" false (e.is_available ())
        | None -> fail "glm-coding should exist");
       Unix.putenv "ZAI_CODING_API_KEY" "coding-key";
       let coding = Provider_registry.default () in
       match Provider_registry.find coding "glm-coding" with
       | Some e -> check bool "coding key enables coding lane" true (e.is_available ())
       | None -> fail "glm-coding should exist")
;;

(* ── Provider catalog overlay ────────────────────────── *)

let with_provider_catalog json f =
  match Provider_catalog.of_json (Yojson.Safe.from_string json) with
  | Error msg -> fail msg
  | Ok catalog ->
    Provider_catalog.set_global catalog;
    Fun.protect ~finally:Provider_catalog.clear_global f
;;

let test_catalog_overlay_registers_exact_provider_id_only () =
  with_provider_catalog
    {|{
      "schema_version": 1,
      "providers": [
        {
          "id": "vllm-local",
          "aliases": ["Subscriber-Local"],
          "kind": "openai_compat",
          "base_url": "http://127.0.0.1:8000",
          "request_path": "/v1/chat/completions",
          "auth": {"type": "none"},
          "default_model": "local-model",
          "capabilities_base": "openai_chat",
          "capabilities": {
            "max_context_tokens": 131072,
            "supports_tools": true,
            "supports_tool_choice": true
          }
        }
      ]
    }|}
    (fun () ->
       let reg = Provider_registry.default () in
       (match Provider_registry.find reg "vllm-local" with
        | Some e ->
          check string "base url" "http://127.0.0.1:8000" e.defaults.base_url;
          check (option int) "max context" (Some 131_072) e.max_context;
          check bool "tools" true e.capabilities.supports_tools;
          check bool "tool choice" true e.capabilities.supports_tool_choice
        | None -> fail "catalog provider should be registered");
       check
         bool
         "catalog alias is not a registry key"
         false
         (Option.is_some (Provider_registry.find reg "Subscriber-Local")))
;;

let test_catalog_overlay_replaces_embedded_provider () =
  with_provider_catalog
    {|{
      "schema_version": 1,
      "providers": [
        {
          "id": "openrouter",
          "kind": "openai_compat",
          "base_url": "https://example.test/openrouter",
          "request_path": "/chat/completions",
          "auth": {"type": "api_key_env", "env": "OPENROUTER_API_KEY"},
          "capabilities_base": "openai_chat"
        }
      ]
    }|}
    (fun () ->
       let reg = Provider_registry.default () in
       match Provider_registry.find reg "openrouter" with
       | Some e ->
         check string "catalog wins" "https://example.test/openrouter" e.defaults.base_url
       | None -> fail "openrouter should still exist")
;;

let test_catalog_overlay_preserves_exact_provider_id () =
  with_provider_catalog
    {|{
      "schema_version": 1,
      "providers": [
        {
          "id": "Acme-Cloud",
          "kind": "openai_compat",
          "base_url": "https://acme.example/v1",
          "auth": {"type": "none"},
          "capabilities_base": "openai_chat"
        }
      ]
    }|}
    (fun () ->
       let reg = Provider_registry.default () in
       (match Provider_registry.find reg "Acme-Cloud" with
        | Some e -> check string "base url" "https://acme.example/v1" e.defaults.base_url
        | None -> fail "exact catalog provider id should be registered");
       check
         bool
         "lowercase reinterpretation is rejected"
         false
         (Option.is_some (Provider_registry.find reg "acme-cloud")))
;;

let test_catalog_overlay_without_context_keeps_none () =
  with_provider_catalog
    {|{
      "schema_version": 1,
      "providers": [
        {
          "id": "unknown-context",
          "kind": "openai_compat",
          "base_url": "https://unknown-context.example/v1",
          "auth": {"type": "none"}
        }
      ]
    }|}
    (fun () ->
       let reg = Provider_registry.default () in
       match Provider_registry.find reg "unknown-context" with
       | Some entry -> check (option int) "no invented context" None entry.max_context
       | None -> fail "unknown-context overlay should be registered")
;;

let test_catalog_rejects_empty_provider_id () =
  match
    Provider_catalog.of_json
      (Yojson.Safe.from_string
         {|{
           "schema_version": 1,
           "providers": [
             {"id": "  ", "kind": "openai_compat"}
           ]
         }|})
  with
  | Error _ -> ()
  | Ok _ -> fail "empty provider id should be rejected"
;;

let test_catalog_rejects_removed_transport_field () =
  match
    Provider_catalog.of_json
      (Yojson.Safe.from_string
         {|{
           "schema_version": 1,
           "providers": [
             {"id": "x", "kind": "openai_compat", "transport": "ftp"}
           ]
         }|})
  with
  | Error _ -> ()
  | Ok _ -> fail "removed transport field should be rejected"
;;

let test_catalog_rejects_unknown_auth_type () =
  match
    Provider_catalog.of_json
      (Yojson.Safe.from_string
         {|{
           "schema_version": 1,
           "providers": [
             {"id": "x", "kind": "openai_compat",
              "auth": {"type": "magick"}}
           ]
         }|})
  with
  | Error _ -> ()
  | Ok _ -> fail "unknown auth type should be rejected, not silently coerced to none"
;;

let test_catalog_rejects_unknown_capabilities_base () =
  match
    Provider_catalog.of_json
      (Yojson.Safe.from_string
         {|{
           "schema_version": 1,
           "providers": [
             {"id": "x", "kind": "openai_compat",
              "capabilities_base": "nonexistent_preset"}
           ]
         }|})
  with
  | Error _ -> ()
  | Ok _ ->
    fail "unknown capabilities_base should be rejected, not silently coerced to defaults"
;;

let test_catalog_rejects_unknown_thinking_control_format () =
  match
    Provider_catalog.of_json
      (Yojson.Safe.from_string
         {|{
           "schema_version": 1,
           "providers": [
             {"id": "x", "kind": "openai_compat",
              "capabilities": {"thinking_control_format": "telepathy"}}
           ]
         }|})
  with
  | Error _ -> ()
  | Ok _ ->
    fail "unknown thinking_control_format should be rejected, not silently coerced"
;;

let test_catalog_rejects_unknown_preserve_thinking_control_format () =
  match
    Provider_catalog.of_json
      (Yojson.Safe.from_string
         {|{
           "schema_version": 1,
           "providers": [
             {"id": "x", "kind": "openai_compat",
              "capabilities": {"preserve_thinking_control_format": "memory_palace"}}
           ]
         }|})
  with
  | Error _ -> ()
  | Ok _ ->
    fail
      "unknown preserve_thinking_control_format should be rejected, not silently coerced"
;;

let test_catalog_accepts_explicit_thinking_control_formats () =
  match
    Provider_catalog.of_json
      (Yojson.Safe.from_string
         {|{
           "schema_version": 1,
           "providers": [
             {"id": "kimi-k2", "kind": "openai_compat",
              "base_url": "https://kimi-k2.example",
              "capabilities": {"thinking_control_format": "thinking_object_only"}},
             {"id": "dashscope", "kind": "openai_compat",
              "base_url": "https://dashscope.example",
              "capabilities": {"thinking_control_format": "enable_thinking"}},
             {"id": "ollama-cloud", "kind": "ollama",
              "base_url": "https://ollama-cloud.example",
              "capabilities": {"thinking_control_format": "ollama_think"}},
             {"id": "openai-reasoning", "kind": "openai_compat",
              "base_url": "https://openai-reasoning.example",
              "capabilities": {"thinking_control_format": "reasoning_effort"}}
             ,
             {"id": "kimi-latest", "kind": "openai_compat",
              "base_url": "https://kimi-latest.example",
              "capabilities": {"thinking_control_format": "none",
                               "preserve_thinking_control_format": "always_preserved"}}
           ]
         }|})
  with
  | Error msg -> fail msg
  | Ok catalog ->
    let check_format id expected =
      match Provider_catalog.lookup catalog id with
      | Some entry ->
        check
          bool
          (id ^ " thinking_control_format")
          true
          (entry.capabilities.thinking_control_format = expected)
      | None -> fail (id ^ " should exist")
    in
    check_format "kimi-k2" Capabilities.Thinking_object_only;
    check_format "dashscope" Capabilities.Enable_thinking;
    check_format "ollama-cloud" Capabilities.Ollama_think;
    check_format "openai-reasoning" Capabilities.Reasoning_effort;
    (match Provider_catalog.lookup catalog "kimi-latest" with
     | Some entry ->
       check
         bool
         "kimi-latest always preserved"
         true
         (entry.capabilities.preserve_thinking_control_format
          = Capabilities.Always_preserved_thinking)
     | None -> fail "kimi-latest should exist")
;;

let test_catalog_rejects_duplicate_provider_id () =
  match
    Provider_catalog.of_json
      (Yojson.Safe.from_string
         {|{
           "schema_version": 1,
           "providers": [
             {"id": "dup", "kind": "openai_compat",
              "base_url": "http://first.example"},
             {"id": "dup", "kind": "openai_compat",
              "base_url": "http://second.example"}
           ]
         }|})
  with
  | Error _ -> ()
  | Ok _ -> fail "duplicate provider ids should be rejected"
;;

let test_catalog_lookup_case_insensitive () =
  match
    Provider_catalog.of_json
      (Yojson.Safe.from_string
         {|{
           "schema_version": 1,
           "providers": [
             {"id": "mixed-Case",
              "aliases": ["AlsoMixed"],
              "kind": "openai_compat",
              "base_url": "http://x.example"}
           ]
         }|})
  with
  | Error msg -> fail msg
  | Ok catalog ->
    check
      bool
      "id uppercase MIXED-CASE"
      true
      (Option.is_some (Provider_catalog.lookup catalog "MIXED-CASE"));
    check
      bool
      "id lowercase mixed-case"
      true
      (Option.is_some (Provider_catalog.lookup catalog "mixed-case"));
    check
      bool
      "alias uppercase ALSOMIXED"
      true
      (Option.is_some (Provider_catalog.lookup catalog "ALSOMIXED"));
    check
      bool
      "alias trim/whitespace"
      true
      (Option.is_some (Provider_catalog.lookup catalog "  alsomixed  "))
;;

let provider_catalog_entry ?(aliases = []) id : Provider_catalog.entry =
  { id
  ; aliases
  ; kind = OpenAI_compat
  ; base_url = "http://host.example"
  ; request_path = "/v1/chat/completions"
  ; api_key_env = ""
  ; auth = No_auth
  ; default_model = None
  ; max_context = None
  ; capabilities = Capabilities.default_capabilities
  ; credential_scope = None
  }
;;

let test_programmatic_catalog_rejects_invalid_aliases () =
  let entry = provider_catalog_entry ~aliases:[ "good-alias"; "" ] "host" in
  match Provider_catalog.of_entries [ entry ] with
  | Error _ -> ()
  | Ok _ -> fail "programmatic catalogs must reject empty aliases"
;;

let test_programmatic_catalog_rejects_duplicate_id_alias () =
  let first = provider_catalog_entry ~aliases:[ "shared" ] "first" in
  let second = provider_catalog_entry "shared" in
  match Provider_catalog.of_entries [ first; second ] with
  | Error _ -> ()
  | Ok _ -> fail "programmatic catalogs must reject duplicate ids and aliases"
;;

let test_catalog_aliases_are_not_registry_keys () =
  let entry = provider_catalog_entry ~aliases:[ "good-alias" ] "host" in
  match Provider_catalog.of_entries [ entry ] with
  | Error msg -> fail msg
  | Ok catalog ->
    Provider_catalog.set_global catalog;
    Fun.protect ~finally:Provider_catalog.clear_global (fun () ->
      let reg = Provider_registry.default () in
      check bool "id registered" true (Option.is_some (Provider_registry.find reg "host"));
      check
        bool
        "declared alias not registered"
        false
        (Option.is_some (Provider_registry.find reg "good-alias")))
;;

let test_catalog_load_file_and_lookup_alias () =
  let path = Filename.temp_file "provider-catalog" ".json" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       let oc = open_out path in
       Fun.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () ->
            output_string
              oc
              {|{
                "schema_version": 1,
                "providers": [
                  {
                    "id": "file-cloud",
                    "aliases": ["file-cloud-alias"],
                    "kind": "openai_compat",
                    "base_url": "https://file-cloud.example/v1",
                    "default_model": "file-model",
                    "auth": {"type": "none"}
                  }
                ]
              }|});
       match Provider_catalog.load_file path with
       | Error msg -> fail msg
       | Ok catalog ->
         (match Provider_catalog.lookup catalog "file-cloud-alias" with
          | Some entry ->
            check string "id" "file-cloud" entry.id;
            check (option string) "default model" (Some "file-model") entry.default_model
          | None -> fail "catalog alias should resolve"))
;;

let test_catalog_api_key_env_availability () =
  let env_name = "OAS_TEST_PROVIDER_CATALOG_API_KEY" in
  let json =
    Printf.sprintf
      {|{
        "schema_version": 1,
        "providers": [
          {
            "id": "cloud-api",
            "kind": "openai_compat",
            "base_url": "https://cloud-api.example/v1",
            "auth": {"type": "api_key_env", "env": "%s"},
            "capabilities_base": "openai_chat"
          }
        ]
      }|}
      env_name
  in
  let available_with value =
    with_env env_name value (fun () ->
      with_provider_catalog json (fun () ->
        let reg = Provider_registry.default () in
        match Provider_registry.find reg "cloud-api" with
        | Some entry -> entry.is_available ()
        | None -> fail "cloud-api should be registered"))
  in
  check bool "missing api key unavailable" false (available_with "");
  check bool "present api key available" true (available_with "secret")
;;

(* ── Types usage helpers ───────────────────────────── *)

let test_zero_api_usage () =
  let z = Types.zero_api_usage in
  check int "input 0" 0 z.input_tokens;
  check int "output 0" 0 z.output_tokens;
  check int "cache_creation 0" 0 z.cache_creation_input_tokens;
  check int "cache_read 0" 0 z.cache_read_input_tokens
;;

let test_usage_of_response_some () =
  let usage : Types.api_usage =
    { input_tokens = 100
    ; output_tokens = 50
    ; cache_creation_input_tokens = 10
    ; cache_read_input_tokens = 5
    ; cost_usd = None
    }
  in
  let resp : Types.api_response =
    { id = "r1"
    ; model = "m"
    ; stop_reason = EndTurn
    ; content = [ Text "ok" ]
    ; usage = Some usage
    ; telemetry = None
    }
  in
  match Types.usage_of_response resp with
  | Some u ->
    check int "input" 100 u.input_tokens;
    check int "output" 50 u.output_tokens
  | None -> fail "expected reported usage"
;;

let test_usage_of_response_none () =
  let resp : Types.api_response =
    { id = "r2"
    ; model = "m"
    ; stop_reason = EndTurn
    ; content = [ Text "ok" ]
    ; usage = None
    ; telemetry = None
    }
  in
  check (option reject) "missing usage preserved" None (Types.usage_of_response resp)
;;

(* ── Kind ↔ registry integrity ────────────────────────── *)

(** Minimal [Provider_config.t] construction for a given kind. URL contents
    cannot affect the projected wire-kind label. *)
let mk_config_for_kind kind =
  let base_url =
    match kind with
    | Provider_config.OpenAI_compat -> "http://127.0.0.1:8085"
    | _ -> "https://example.test"
  in
  Provider_config.make ~kind ~model_id:"test" ~base_url ()
;;

(** [provider_name_of_config] is only a closed typed projection. It must not
    reinterpret that label as a registry/vendor identity. *)
let test_every_kind_projects_exact_wire_label () =
  List.iter
    (fun kind ->
       let cfg = mk_config_for_kind kind in
       let name = Provider_registry.provider_name_of_config cfg in
       check string name (Provider_config.string_of_provider_kind kind) name)
    Provider_config.all_provider_kinds
;;

(* ── Suite ──────────────────────────────────────────── *)

let () =
  run
    "provider_registry"
    [ ( "crud"
      , [ test_case "empty" `Quick test_empty_registry
        ; test_case "register and find" `Quick test_register_and_find
        ; test_case "overwrite" `Quick test_overwrite
        ; test_case "unregister" `Quick test_unregister
        ] )
    ; ( "endpoint_refresh"
      , [ test_case
            "missing declarations rejected"
            `Quick
            test_refresh_rejects_missing_endpoint_declarations
        ] )
    ; ( "availability"
      , [ test_case "filter" `Quick test_available_filter
        ; test_case
            "command_in_path finds binary"
            `Quick
            test_command_in_path_finds_binary
        ; test_case
            "command_in_path rejects directory"
            `Quick
            test_command_in_path_rejects_directory
        ; test_case
            "command_in_path misses unknown binary"
            `Quick
            test_command_in_path_misses_unknown_binary
        ] )
    ; ( "capabilities"
      , [ test_case "find with tools" `Quick test_find_capable_tools
        ; test_case "composite predicate" `Quick test_find_capable_composite
        ] )
    ; ( "default"
      , [ test_case "default provider set" `Quick test_default_provider_names
        ; test_case "correct capabilities" `Quick test_default_capabilities
        ; test_case "ollama_cloud entry" `Quick test_default_ollama_cloud_entry
        ; test_case "deepseek entry" `Quick test_default_deepseek_entry
        ; test_case "deepseek api key env" `Quick test_default_deepseek_api_key_env
        ; test_case "mimo entry" `Quick test_default_mimo_entry
        ; test_case
            "explicit no-auth rows"
            `Quick
            test_embedded_no_auth_rows_keep_explicit_empty_credentials
        ; test_case
            "padded embedded credential declaration rejected"
            `Quick
            test_embedded_provider_rejects_padded_api_key_env
        ; test_case
            "provider_name_of_config projects wire kind"
            `Quick
            test_provider_name_is_wire_kind_projection
        ; test_case
            "endpoints ignore ambient overrides"
            `Quick
            test_default_endpoints_ignore_ambient_overrides
        ; test_case "max_context values" `Quick test_default_max_context
        ; test_case
            "max_context matches capabilities"
            `Quick
            test_default_max_context_matches_capabilities
        ; test_case "zai base urls" `Quick test_default_zai_base_urls
        ; test_case
            "glm coding api key env isolated"
            `Quick
            test_glm_coding_api_key_env_isolated
        ] )
    ; ( "provider_catalog"
      , [ test_case
            "overlay registers exact provider id only"
            `Quick
            test_catalog_overlay_registers_exact_provider_id_only
        ; test_case
            "overlay replaces embedded provider"
            `Quick
            test_catalog_overlay_replaces_embedded_provider
        ; test_case
            "overlay preserves exact provider id"
            `Quick
            test_catalog_overlay_preserves_exact_provider_id
        ; test_case
            "overlay without context keeps None"
            `Quick
            test_catalog_overlay_without_context_keeps_none
        ; test_case
            "rejects empty provider id"
            `Quick
            test_catalog_rejects_empty_provider_id
        ; test_case
            "rejects removed transport field"
            `Quick
            test_catalog_rejects_removed_transport_field
        ; test_case
            "rejects unknown auth type"
            `Quick
            test_catalog_rejects_unknown_auth_type
        ; test_case
            "rejects unknown capabilities_base"
            `Quick
            test_catalog_rejects_unknown_capabilities_base
        ; test_case
            "rejects unknown thinking_control_format"
            `Quick
            test_catalog_rejects_unknown_thinking_control_format
        ; test_case
            "rejects unknown preserve_thinking_control_format"
            `Quick
            test_catalog_rejects_unknown_preserve_thinking_control_format
        ; test_case
            "accepts explicit thinking_control_format values"
            `Quick
            test_catalog_accepts_explicit_thinking_control_formats
        ; test_case
            "rejects duplicate provider id"
            `Quick
            test_catalog_rejects_duplicate_provider_id
        ; test_case
            "lookup is case-insensitive"
            `Quick
            test_catalog_lookup_case_insensitive
        ; test_case
            "programmatic catalog rejects invalid aliases"
            `Quick
            test_programmatic_catalog_rejects_invalid_aliases
        ; test_case
            "programmatic catalog rejects duplicate id/alias"
            `Quick
            test_programmatic_catalog_rejects_duplicate_id_alias
        ; test_case
            "aliases are not registry keys"
            `Quick
            test_catalog_aliases_are_not_registry_keys
        ; test_case
            "load_file and lookup alias"
            `Quick
            test_catalog_load_file_and_lookup_alias
        ; test_case
            "api key env gates availability"
            `Quick
            test_catalog_api_key_env_availability
        ] )
    ; ( "kind_projection"
      , [ test_case
            "every kind projects exactly"
            `Quick
            test_every_kind_projects_exact_wire_label
        ] )
    ; ( "types_usage"
      , [ test_case "zero_api_usage" `Quick test_zero_api_usage
        ; test_case "usage_of_response some" `Quick test_usage_of_response_some
        ; test_case "usage_of_response none" `Quick test_usage_of_response_none
        ] )
    ]
;;
