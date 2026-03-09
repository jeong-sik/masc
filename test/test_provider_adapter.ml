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

let test_resolve_cli_aliases () =
  let claude = Option.get (Adapter.resolve_cli_adapter "claude-code") in
  check string "claude cli alias" "claude" claude.meta.canonical_name;
  let gemini = Option.get (Adapter.resolve_cli_adapter "gemini-cli") in
  check string "gemini cli alias" "gemini" gemini.meta.canonical_name;
  check string "gemini prompt transport" "arg:-p"
    (Adapter.string_of_prompt_transport gemini.prompt_transport)

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
  check string "default cli agent" "claude"
    (Adapter.default_cli_agent_name ())

let test_default_local_model_label () =
  with_env "OLLAMA_DEFAULT_MODEL" (Some "my-local-model") (fun () ->
      check string "default local label" "ollama:my-local-model"
        (Adapter.default_local_model_label ()))

let () =
  run "Provider Adapter"
    [
      ( "registry",
        [
          test_case "resolve direct aliases" `Quick test_resolve_direct_aliases;
          test_case "resolve cli aliases" `Quick test_resolve_cli_aliases;
          test_case "gemini vertex adc" `Quick test_gemini_direct_auth_vertex_adc;
          test_case "gemini api key fallback" `Quick
            test_gemini_direct_auth_api_key_fallback;
          test_case "gemini missing auth" `Quick test_gemini_direct_auth_missing;
          test_case "vertex base url" `Quick test_vertex_base_url;
          test_case "default cli agent" `Quick test_default_cli_agent_name;
          test_case "default local model label" `Quick test_default_local_model_label;
        ] );
    ]
