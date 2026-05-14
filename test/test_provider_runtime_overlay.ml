open Alcotest
module Overlay = Masc_mcp.Provider_runtime_overlay

let test_timeout_bounds_ollama_has_300s_floor () =
  let b = Overlay.timeout_bounds_of_kind Llm_provider.Provider_config.Ollama in
  check (option (float 0.001)) "ollama min 300s" (Some 300.0) b.min_timeout_s;
  check (option (float 0.001)) "ollama no max" None b.max_timeout_s
;;

let test_timeout_bounds_claude_code_has_120s_ceiling () =
  let b = Overlay.timeout_bounds_of_kind Llm_provider.Provider_config.Claude_code in
  check (option (float 0.001)) "claude_code no min" None b.min_timeout_s;
  check (option (float 0.001)) "claude_code max 120s" (Some 120.0) b.max_timeout_s
;;

let test_timeout_bounds_gemini_variants_share_ceiling () =
  let b_api = Overlay.timeout_bounds_of_kind Llm_provider.Provider_config.Gemini in
  let b_cli = Overlay.timeout_bounds_of_kind Llm_provider.Provider_config.Gemini_cli in
  check (option (float 0.001)) "Gemini max 180s" (Some 180.0) b_api.max_timeout_s;
  check (option (float 0.001)) "Gemini_cli max 180s" (Some 180.0) b_cli.max_timeout_s
;;

let test_timeout_bounds_kimi_cli_has_60s_ceiling () =
  let b = Overlay.timeout_bounds_of_kind Llm_provider.Provider_config.Kimi_cli in
  check (option (float 0.001)) "kimi_cli max 60s" (Some 60.0) b.max_timeout_s
;;

let test_timeout_bounds_unconstrained_kinds_have_no_bounds () =
  let unconstrained =
    [ Llm_provider.Provider_config.Anthropic
    ; Llm_provider.Provider_config.Kimi
    ; Llm_provider.Provider_config.OpenAI_compat
    ; Llm_provider.Provider_config.Glm
    ; Llm_provider.Provider_config.DashScope
    ; Llm_provider.Provider_config.Codex_cli
    ]
  in
  List.iter
    (fun kind ->
       let b = Overlay.timeout_bounds_of_kind kind in
       check (option (float 0.001)) "unconstrained min = None" None b.min_timeout_s;
       check (option (float 0.001)) "unconstrained max = None" None b.max_timeout_s)
    unconstrained
;;

let test_max_turns_hard_cap_uses_oas_provider_config () =
  check
    (option int)
    "claude_code hard cap"
    (Some 30)
    (Overlay.max_turns_hard_cap Llm_provider.Provider_config.Claude_code);
  check
    int
    "claude_code clamps requested turns"
    30
    (Overlay.clamp_max_turns Llm_provider.Provider_config.Claude_code 99);
  check
    int
    "ollama has no hard cap"
    99
    (Overlay.clamp_max_turns Llm_provider.Provider_config.Ollama 99)
;;

let () =
  run
    "provider_runtime_overlay"
    [ ( "timeout_bounds_of_kind"
      , [ test_case
            "ollama floors at 300s"
            `Quick
            test_timeout_bounds_ollama_has_300s_floor
        ; test_case
            "claude_code ceiling 120s"
            `Quick
            test_timeout_bounds_claude_code_has_120s_ceiling
        ; test_case
            "gemini variants share 180s ceiling"
            `Quick
            test_timeout_bounds_gemini_variants_share_ceiling
        ; test_case
            "kimi_cli ceiling 60s"
            `Quick
            test_timeout_bounds_kimi_cli_has_60s_ceiling
        ; test_case
            "unconstrained kinds report no bounds"
            `Quick
            test_timeout_bounds_unconstrained_kinds_have_no_bounds
        ] )
    ; ( "max_turns"
      , [ test_case
            "uses OAS Provider_config hard cap"
            `Quick
            test_max_turns_hard_cap_uses_oas_provider_config
        ] )
    ]
;;
