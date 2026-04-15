open Alcotest

module Adapter = Masc_mcp.Provider_adapter

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

let test_resolve_direct_aliases () =
  let claude = Option.get (Adapter.resolve_direct_adapter "anthropic") in
  check string "claude alias" "claude-api" claude.canonical_name;
  let gemini = Option.get (Adapter.resolve_direct_adapter "google") in
  check string "gemini alias" "gemini-api" gemini.canonical_name;
  let codex = Option.get (Adapter.resolve_direct_adapter "openai") in
  check string "codex-api alias" "codex-api" codex.canonical_name

let test_resolve_cli_canonical_names () =
  let claude = Option.get (Adapter.resolve_direct_adapter "claude") in
  check string "claude canonical" "claude" claude.canonical_name;
  check string "claude runtime" "cli_agent"
    (Adapter.string_of_runtime_kind claude.runtime_kind);
  let gemini = Option.get (Adapter.resolve_direct_adapter "gemini") in
  check string "gemini canonical" "gemini" gemini.canonical_name;
  let codex = Option.get (Adapter.resolve_direct_adapter "codex") in
  check string "codex canonical" "codex" codex.canonical_name

let test_gemini_direct_auth_vertex_adc () =
  with_env "GOOGLE_CLOUD_PROJECT" (Some "demo-project") (fun () ->
      with_env "GOOGLE_CLOUD_LOCATION" (Some "asia-northeast3") (fun () ->
          with_env "GEMINI_API_KEY" None (fun () ->
              match Adapter.resolve_gemini_direct_auth () with
              | Adapter.Gemini_vertex_adc { project; location } ->
                  check string "project" "demo-project" project;
                  check string "location" "asia-northeast3" location
              | _ -> fail "expected vertex adc")))

let test_gemini_direct_auth_api_key_fallback () =
  with_env "GOOGLE_CLOUD_PROJECT" None (fun () ->
      with_env "GEMINI_API_KEY" (Some "dummy-key") (fun () ->
          match Adapter.resolve_gemini_direct_auth () with
          | Adapter.Gemini_api_key -> ()
          | _ -> fail "expected api key fallback"))

let test_gemini_direct_auth_missing () =
  with_env "GOOGLE_CLOUD_PROJECT" None (fun () ->
      with_env "GEMINI_API_KEY" None (fun () ->
          match Adapter.resolve_gemini_direct_auth () with
          | Adapter.Gemini_auth_missing message ->
              check bool "actionable message" true (String.length message > 0)
          | _ -> fail "expected missing auth"))

let test_vertex_base_url () =
  check string "vertex base url"
    "https://aiplatform.googleapis.com/v1/projects/demo/locations/global/endpoints/openapi"
    (Adapter.gemini_vertex_openai_base_url ~project:"demo" ~location:"global")

let test_default_cli_agent_name () =
  check string "default cli agent" "auto"
    (Adapter.default_cli_agent_name ())

let test_default_local_model_label () =
  with_env "MASC_DEFAULT_PROVIDER" (Some "test-provider") (fun () ->
      with_env "MASC_DEFAULT_MODEL" (Some "test-model") (fun () ->
          check string "default local label" "test-provider:test-model"
            (Adapter.default_local_model_label ())))

let test_default_model_provider_prefix_result () =
  with_env "MASC_DEFAULT_PROVIDER" (Some "test-provider") (fun () ->
      with_env "MASC_DEFAULT_MODEL" (Some "test-model") (fun () ->
          match Adapter.default_model_provider_prefix_result () with
          | Ok prefix -> check string "default provider prefix" "test-provider" prefix
          | Error msg -> fail msg))

let test_default_model_override_label_result () =
  with_env "MASC_DEFAULT_PROVIDER" (Some "gemini") (fun () ->
      with_env "MASC_DEFAULT_MODEL" (Some "gemini-2.5-pro") (fun () ->
          match Adapter.default_model_override_label_result "gemini-2.5-flash" with
          | Ok label ->
              check string "override keeps provider" "gemini:gemini-2.5-flash"
                label
          | Error msg -> fail msg))

let test_resolve_voice_aliases () =
  let elevenlabs = Option.get (Adapter.resolve_voice_adapter "elevenlabs") in
  check string "elevenlabs alias" "elevenlabs-direct" elevenlabs.canonical_name;
  let openai_compat = Option.get (Adapter.resolve_voice_adapter "openai_compat") in
  check string "openai compat alias" "voice-openai-compat"
    openai_compat.canonical_name

let test_voice_auth_env_resolution () =
  let elevenlabs = Option.get (Adapter.resolve_voice_adapter "elevenlabs-direct") in
  check (option string) "elevenlabs auth env"
    (Some "ELEVENLABS_API_KEY")
    (Adapter.voice_auth_env_name elevenlabs);
  let openai_compat = Option.get (Adapter.resolve_voice_adapter "voice-openai-compat") in
  check (option string) "endpoint override auth env"
    (Some "VOICE_PROXY_KEY")
    (Adapter.voice_auth_env_name ~endpoint_api_key_env:"VOICE_PROXY_KEY" openai_compat)

let test_stt_request_elevenlabs_direct () =
  let endpoint : Masc_mcp.Voice_config.endpoint =
    { id = "test-stt"; kind = Elevenlabs_direct;
      base_url = Some "https://api.elevenlabs.io/v1";
      mcp_url = None; health_url = None;
      api_key_env = Some "ELEVENLABS_API_KEY";
      enabled = true; timeout_seconds = Some 30.0; max_retries = Some 2 }
  in
  with_env "ELEVENLABS_API_KEY" (Some "test-key-123") (fun () ->
    match Adapter.voice_stt_request_for_endpoint endpoint
            ~api_key:"test-key-123" ~audio_file:"/tmp/test.wav"
            ~model:"scribe_v2" with
    | Ok req ->
        check string "url" "https://api.elevenlabs.io/v1/speech-to-text" req.url;
        check bool "has xi-api-key header" true
          (List.exists (fun (k, _) -> k = "xi-api-key") req.headers);
        check bool "model_id in form_fields" true
          (List.exists (fun (k, v) -> k = "model_id" && v = "scribe_v2")
             req.form_fields);
        let field_name, file_path = req.file_field in
        check string "file field name" "file" field_name;
        check string "file path" "/tmp/test.wav" file_path
    | Error err -> fail (Printf.sprintf "expected Ok, got Error: %s" err))

let test_stt_request_openai_compat () =
  let endpoint : Masc_mcp.Voice_config.endpoint =
    { id = "test-openai-stt"; kind = Openai_compat;
      base_url = Some "https://api.openai.com/v1";
      mcp_url = None; health_url = None;
      api_key_env = Some "OPENAI_API_KEY";
      enabled = true; timeout_seconds = Some 30.0; max_retries = Some 2 }
  in
  match Adapter.voice_stt_request_for_endpoint endpoint
          ~api_key:"sk-test" ~audio_file:"/tmp/test.wav"
          ~model:"whisper-1" with
  | Ok req ->
      check string "url" "https://api.openai.com/v1/audio/transcriptions" req.url;
      check bool "has Authorization header" true
        (List.exists (fun (k, _) -> k = "Authorization") req.headers);
      check bool "model in form_fields" true
        (List.exists (fun (k, v) -> k = "model" && v = "whisper-1")
           req.form_fields)
  | Error err -> fail (Printf.sprintf "expected Ok, got Error: %s" err)

let test_requires_discovery_llama () =
  check bool "llama requires discovery" true
    (Adapter.requires_discovery "llama");
  check bool "llamacpp requires discovery" true
    (Adapter.requires_discovery "llamacpp");
  check bool "LLAMA case insensitive" true
    (Adapter.requires_discovery "LLAMA")

let test_requires_discovery_cloud () =
  check bool "claude does not require discovery" false
    (Adapter.requires_discovery "claude");
  check bool "gemini does not require discovery" false
    (Adapter.requires_discovery "gemini");
  check bool "custom does not require discovery" false
    (Adapter.requires_discovery "custom")

let test_is_local_provider_llama () =
  check bool "llama is local" true
    (Adapter.is_local_provider "llama");
  check bool "llamacpp is local" true
    (Adapter.is_local_provider "llamacpp")

let test_is_local_provider_custom () =
  check bool "custom is local" true
    (Adapter.is_local_provider "custom");
  check bool "CUSTOM case insensitive" true
    (Adapter.is_local_provider "CUSTOM")

let test_is_local_provider_cloud () =
  check bool "claude is not local" false
    (Adapter.is_local_provider "claude");
  check bool "gemini is not local" false
    (Adapter.is_local_provider "gemini");
  check bool "unknown is not local" false
    (Adapter.is_local_provider "unknown-provider")

let test_make_local_label () =
  check string "make_local_label basic" "llama:qwen3.5"
    (Adapter.make_local_label "qwen3.5");
  check string "make_local_label preserves model id" "llama:some-model"
    (Adapter.make_local_label "some-model");
  (* Verify make_local_label uses the same prefix as the llama adapter *)
  check string "prefix matches cn_llama" Adapter.local_cascade_prefix
    Adapter.cn_llama

let test_default_local_fallback_label () =
  let label = Adapter.default_local_fallback_label () in
  check bool "fallback label contains colon" true
    (String.contains label ':');
  check bool "fallback label ends with :auto" true
    (let suffix = ":auto" in
     let slen = String.length label in
     let plen = String.length suffix in
     slen >= plen && String.sub label (slen - plen) plen = suffix)

let test_stt_request_mcp_rejected () =
  let endpoint : Masc_mcp.Voice_config.endpoint =
    { id = "test-mcp-stt"; kind = Voice_mcp;
      base_url = None; mcp_url = Some "http://localhost:8936";
      health_url = None; api_key_env = None;
      enabled = true; timeout_seconds = Some 5.0; max_retries = Some 1 }
  in
  match Adapter.voice_stt_request_for_endpoint endpoint
          ~api_key:"" ~audio_file:"/tmp/test.wav" ~model:"scribe_v2" with
  | Ok _ -> fail "expected Error for voice_mcp endpoint"
  | Error _ -> ()

let () =
  run "Provider Adapter"
    [
      ( "registry",
        [
          test_case "resolve direct aliases" `Quick test_resolve_direct_aliases;
          test_case "resolve cli canonicals" `Quick test_resolve_cli_canonical_names;
          test_case "gemini vertex adc" `Quick test_gemini_direct_auth_vertex_adc;
          test_case "gemini api key fallback" `Quick
            test_gemini_direct_auth_api_key_fallback;
          test_case "gemini missing auth" `Quick test_gemini_direct_auth_missing;
          test_case "vertex base url" `Quick test_vertex_base_url;
          test_case "default cli agent" `Quick test_default_cli_agent_name;
          test_case "default local model label" `Quick test_default_local_model_label;
          test_case "default provider prefix" `Quick
            test_default_model_provider_prefix_result;
          test_case "default override label" `Quick
            test_default_model_override_label_result;
          test_case "resolve voice aliases" `Quick test_resolve_voice_aliases;
          test_case "voice auth env resolution" `Quick
            test_voice_auth_env_resolution;
        ] );
      ( "local_provider",
        [
          test_case "requires_discovery llama" `Quick
            test_requires_discovery_llama;
          test_case "requires_discovery cloud" `Quick
            test_requires_discovery_cloud;
          test_case "is_local_provider llama" `Quick
            test_is_local_provider_llama;
          test_case "is_local_provider custom" `Quick
            test_is_local_provider_custom;
          test_case "is_local_provider cloud" `Quick
            test_is_local_provider_cloud;
          test_case "make_local_label" `Quick test_make_local_label;
          test_case "default_local_fallback_label" `Quick
            test_default_local_fallback_label;
        ] );
      ( "stt",
        [
          test_case "stt request elevenlabs direct" `Quick
            test_stt_request_elevenlabs_direct;
          test_case "stt request openai compat" `Quick
            test_stt_request_openai_compat;
          test_case "stt request mcp rejected" `Quick
            test_stt_request_mcp_rejected;
        ] );
    ]
