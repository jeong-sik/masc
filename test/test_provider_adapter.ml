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

let () =
  run "Provider Adapter"
    [
      ( "registry",
        [
          test_case "resolve direct aliases" `Quick test_resolve_direct_aliases;
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
    ]
