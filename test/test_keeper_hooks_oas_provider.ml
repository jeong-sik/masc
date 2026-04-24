open Alcotest

module Hooks = Masc_mcp.Keeper_hooks_oas

(* Verify provider_of_model accepts explicit provider labels and typed OAS
   provider_kind telemetry, but does not guess from bare model-id strings. *)
let cases_prefix = [
  "glm-coding:glm-5-turbo",                "glm-coding";
  "glm-coding:glm-5.1",                    "glm-coding";
  "glm:glm-5-turbo",                       "glm";
  "claude:claude-haiku-4-5-20251001",      "claude";
  "claude_code:haiku",                     "claude_code";
  "gemini:gemini-2.5-flash",               "gemini";
  "gemini_cli:gemini-2.5-flash",           "gemini_cli";
  "codex_cli:gpt-5.4",                     "codex_cli";
  "openai:gpt-5.4",                        "openai";
  "kimi:kimi-k2.5",                        "kimi";
  "kimi_cli:kimi-for-coding",              "kimi_cli";
  "ollama:qwen3.5:35b-a3b-nvfp4",          "ollama";
]

let cases_bare = [
  "glm-5-turbo",                           "unknown";
  "glm-4.7",                               "unknown";
  "claude-haiku-4-5-20251001",             "unknown";
  "gemini-2.5-flash",                      "unknown";
  "gpt-5.4",                               "unknown";
  "qwen3.5:35b-a3b-nvfp4",                 "unknown";
  "llama-3.1-70b",                         "unknown";
]

let cases_typed_bare = [
  ( "claude-haiku-4-5-20251001",
    Llm_provider.Provider_kind.Anthropic,
    "claude" );
  ( "gemini-2.5-flash",
    Llm_provider.Provider_kind.Gemini,
    "gemini" );
  ( "gpt-5.4",
    Llm_provider.Provider_kind.OpenAI_compat,
    "openai" );
  ( "kimi-for-coding",
    Llm_provider.Provider_kind.Kimi_cli,
    "kimi_cli" );
]

let cases_unknown = [
  "",                                      "unknown";
  "definitely-not-a-real-model",           "unknown";
  "mystery-xyz-4",                         "unknown";
]

let test_prefix () =
  List.iter
    (fun (input, want) ->
      let got = Hooks.provider_of_model input in
      check string ("prefix: " ^ input) want got)
    cases_prefix

let test_bare () =
  List.iter
    (fun (input, want) ->
      let got = Hooks.provider_of_model input in
      check string ("bare: " ^ input) want got)
    cases_bare

let test_typed_bare () =
  List.iter
    (fun (input, provider_kind, want) ->
      let got = Hooks.provider_of_model ~provider_kind input in
      check string ("typed bare: " ^ input) want got)
    cases_typed_bare

let test_unknown () =
  List.iter
    (fun (input, want) ->
      let got = Hooks.provider_of_model input in
      check string ("unknown: " ^ input) want got)
    cases_unknown

let () =
  run "keeper_hooks_oas/provider_of_model"
    [ ( "provider_classification",
        [ test_case "prefixed schemes" `Quick test_prefix;
          test_case "bare model ids" `Quick test_bare;
          test_case "typed bare model ids" `Quick test_typed_bare;
          test_case "unknown routes to unknown" `Quick test_unknown ] )
    ]
