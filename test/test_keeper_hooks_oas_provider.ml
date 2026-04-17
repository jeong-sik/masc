open Alcotest

module Hooks = Masc_mcp.Keeper_hooks_oas

(* Verify provider_of_model handles the three patterns live costs.jsonl
   currently mixes: prefixed schemes, bare model ids emitted by some OAS
   transports, and truly unrecognised strings (should route to "unknown"
   rather than guess). *)
let cases_prefix = [
  "glm-coding:glm-5-turbo",                "glm-coding";
  "glm-coding:glm-5.1",                    "glm-coding";
  "glm:glm-5-turbo",                       "glm";
  "claude:claude-haiku-4-5-20251001",      "claude";
  "claude_code:haiku",                     "claude_code";
  "gemini:gemini-2.5-flash",               "gemini";
  "gemini_cli:gemini-2.5-flash",           "gemini_cli";
  "codex_cli:gpt-5.4",                     "codex_cli";
  "ollama:qwen3.5:35b-a3b-nvfp4",          "ollama";
]

let cases_bare = [
  "glm-5-turbo",                           "glm-coding";
  "glm-4.7",                               "glm-coding";
  "claude-haiku-4-5-20251001",             "claude";
  "gemini-2.5-flash",                      "gemini";
  "gpt-5.4",                               "openai";
  "qwen3.5:35b-a3b-nvfp4",                 "ollama";
  "llama-3.1-70b",                         "ollama";
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
          test_case "unknown routes to unknown" `Quick test_unknown ] )
    ]
