(* test/test_cascade_kimi_max_context_ssot.ml

   #9953: Verify [Cascade_config.make_kimi_config] resolves
   [max_context] from the OAS [Llm_provider.Capabilities] SSOT
   rather than a drifted local constant.

   Prior code hard-coded [256_000] in cascade_config, while the
   OAS capabilities SSOT records [262_144] — same "256k" concept
   in two encodings, causing per-turn [context_max] drift. *)

module CC = Masc_mcp.Cascade_config
module Caps = Llm_provider.Capabilities

let oas_kimi_max_context () =
  match Caps.kimi_capabilities.max_context_tokens with
  | Some n -> n
  | None -> Alcotest.fail "OAS kimi_capabilities missing max_context_tokens"
;;

(* Sanity: the OAS SSOT still publishes a numeric cap. This pins
   the reference the resolver reads from — if the OAS pin bumps
   and kimi max_context changes, this test documents the coupling. *)
let test_oas_ssot_publishes_max_context () =
  let n = oas_kimi_max_context () in
  Alcotest.(check bool) "positive" true (n > 0)
;;

(* Parse a kimi model string and verify the produced Provider_config
   reports the OAS SSOT value. *)
let test_parse_model_string_uses_oas_ssot () =
  let expected = oas_kimi_max_context () in
  Unix.putenv "KIMI_API_KEY" "sk-test-9953";
  match CC.parse_model_string "kimi:kimi-for-coding" with
  | None ->
    Alcotest.fail
      "parse_model_string returned None for 'kimi:kimi-for-coding' (expected a \
       Provider_config with max_context from OAS SSOT)"
  | Some cfg ->
    Alcotest.(check (option int))
      "make_kimi_config resolves max_context from OAS capabilities SSOT (no local \
       256_000 drift)"
      (Some expected)
      cfg.max_context
;;

(* Regression guard: the drifted constant must be gone. If a
   future refactor re-introduces a literal 256_000 in this
   resolver path, the [make_kimi_config] output would disagree
   with OAS and reopen #9953. *)
let test_no_local_256000_literal () =
  Unix.putenv "KIMI_API_KEY" "sk-test-9953";
  match CC.parse_model_string "kimi:auto" with
  | None -> Alcotest.fail "parse_model_string None for 'kimi:auto'"
  | Some cfg ->
    Alcotest.(check bool)
      "max_context must not be the legacy decimal literal 256_000"
      true
      (cfg.max_context <> Some 256_000)
;;

let () =
  Alcotest.run
    "cascade_kimi_max_context_ssot_9953"
    [ ( "oas_ssot"
      , [ Alcotest.test_case
            "publishes max_context"
            `Quick
            test_oas_ssot_publishes_max_context
        ] )
    ; ( "make_kimi_config"
      , [ Alcotest.test_case
            "uses OAS SSOT value"
            `Quick
            test_parse_model_string_uses_oas_ssot
        ; Alcotest.test_case
            "no legacy 256_000 literal"
            `Quick
            test_no_local_256000_literal
        ] )
    ]
;;
