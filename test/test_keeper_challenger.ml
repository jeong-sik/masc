(* Tests for Keeper_challenger A1 Dialectical Verification.
   Validates challenger eligibility gates, outcome variant API,
   and the is_challenger_eligible persona gate. *)

open Alcotest

module C = Masc_mcp.Keeper_challenger
module CO = Masc_mcp.Keeper_challenger_outcome
module KPA = Masc_mcp.Keeper_persona_authoring

(* ------------------------------------------------------------------ *)
(* Keeper_challenger_outcome — variant API                            *)
(* ------------------------------------------------------------------ *)

let test_outcome_accept () =
  let o = CO.Accept in
  check bool "Accept is not No_challenger" false (o = CO.No_challenger);
  check bool "Accept is not Veto" false
    (match o with CO.Veto _ -> true | _ -> false)

let test_outcome_no_challenger () =
  check bool "No_challenger ctor" true (CO.No_challenger = CO.No_challenger)

let test_outcome_veto_fields () =
  let reason : CO.veto_reason =
    { rule = "scope_violation"
    ; detail = "keeper attempted write outside declared scope"
    ; challenger_cascade = "challenger"
    }
  in
  let o = CO.Veto reason in
  match o with
  | CO.Veto r ->
    check string "rule" "scope_violation" r.rule;
    check string "challenger_cascade" "challenger" r.challenger_cascade
  | _ -> fail "expected Veto"

(* ------------------------------------------------------------------ *)
(* Keeper_challenger — different_provider_tier                         *)
(* ------------------------------------------------------------------ *)

let test_different_tier_true () =
  check bool "codex_cli vs claude_code" true
    (C.different_provider_tier "codex_cli:gpt-5.3" "claude_code:auto")

let test_different_tier_false_same_prefix () =
  check bool "codex_cli vs codex_cli" false
    (C.different_provider_tier "codex_cli:gpt-5.3" "codex_cli:gpt-4")

let test_different_tier_no_colon () =
  check bool "bare names equal" false
    (C.different_provider_tier "challenger" "challenger")

let test_different_tier_no_colon_different () =
  check bool "bare names unequal" true
    (C.different_provider_tier "big_three" "challenger")

(* ------------------------------------------------------------------ *)
(* Keeper_challenger — should_run_challenger                           *)
(* ------------------------------------------------------------------ *)

let with_env_restore keys f =
  let prev = List.map (fun k -> k, Sys.getenv_opt k) keys in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (k, v) ->
          match v with
          | Some s -> Unix.putenv k s
          | None -> Unix.putenv k "")
        prev)
    f

let test_should_run_challenger_flag_off () =
  with_env_restore [ "MASC_CHALLENGER_ENABLED" ] (fun () ->
    Unix.putenv "MASC_CHALLENGER_ENABLED" "0";
    check bool "flag off -> no run" false
      (C.should_run_challenger ~keeper_cascade:"codex_cli:auto"
         ~challenger_cascade:"claude_code:auto"))

let test_should_run_challenger_flag_on_same_tier () =
  with_env_restore [ "MASC_CHALLENGER_ENABLED" ] (fun () ->
    Unix.putenv "MASC_CHALLENGER_ENABLED" "1";
    check bool "same tier -> no run" false
      (C.should_run_challenger ~keeper_cascade:"codex_cli:auto"
         ~challenger_cascade:"codex_cli:gpt-4"))

let test_should_run_challenger_flag_on_different_tier () =
  with_env_restore [ "MASC_CHALLENGER_ENABLED" ] (fun () ->
    Unix.putenv "MASC_CHALLENGER_ENABLED" "1";
    check bool "different tier -> run" true
      (C.should_run_challenger ~keeper_cascade:"codex_cli:auto"
         ~challenger_cascade:"claude_code:auto"))

let test_should_run_challenger_empty_cascade () =
  with_env_restore [ "MASC_CHALLENGER_ENABLED" ] (fun () ->
    Unix.putenv "MASC_CHALLENGER_ENABLED" "1";
    check bool "empty challenger cascade -> no run" false
      (C.should_run_challenger ~keeper_cascade:"codex_cli:auto"
         ~challenger_cascade:""))

(* ------------------------------------------------------------------ *)
(* Keeper_challenger — evaluate returns No_challenger when flag off    *)
(* ------------------------------------------------------------------ *)

let test_evaluate_no_challenger_when_flag_off () =
  with_env_restore [ "MASC_CHALLENGER_ENABLED" ] (fun () ->
    Unix.putenv "MASC_CHALLENGER_ENABLED" "0";
    let outcome =
      C.evaluate ~keeper_name:"test-keeper" ~keeper_cascade:"codex_cli:auto"
        ~result_text:"ok" ()
    in
    check bool "No_challenger when flag off" true
      (outcome = CO.No_challenger))

(* ------------------------------------------------------------------ *)
(* Keeper_persona_authoring — is_challenger_eligible gate              *)
(* ------------------------------------------------------------------ *)

let test_eligible_cautious () =
  check bool "cautious is eligible" true
    (KPA.is_challenger_eligible ~risk_posture:(Some "cautious"))

let test_not_eligible_balanced () =
  check bool "balanced not eligible" false
    (KPA.is_challenger_eligible ~risk_posture:(Some "balanced"))

let test_not_eligible_high_autonomy () =
  check bool "high-autonomy not eligible" false
    (KPA.is_challenger_eligible ~risk_posture:(Some "high-autonomy"))

let test_not_eligible_none () =
  check bool "None not eligible" false
    (KPA.is_challenger_eligible ~risk_posture:None)

let test_not_eligible_unknown () =
  check bool "unknown not eligible" false
    (KPA.is_challenger_eligible ~risk_posture:(Some "conservative"))

(* ------------------------------------------------------------------ *)
(* Test suite registration                                             *)
(* ------------------------------------------------------------------ *)

let () =
  run "test_keeper_challenger"
    [ ( "outcome_variant"
      , [ test_case "accept" `Quick test_outcome_accept
        ; test_case "no_challenger" `Quick test_outcome_no_challenger
        ; test_case "veto_fields" `Quick test_outcome_veto_fields
        ] )
    ; ( "different_provider_tier"
      , [ test_case "different_true" `Quick test_different_tier_true
        ; test_case "same_prefix_false" `Quick test_different_tier_false_same_prefix
        ; test_case "no_colon_equal" `Quick test_different_tier_no_colon
        ; test_case "no_colon_different" `Quick test_different_tier_no_colon_different
        ] )
    ; ( "should_run_challenger"
      , [ test_case "flag_off" `Quick test_should_run_challenger_flag_off
        ; test_case "flag_on_same_tier" `Quick test_should_run_challenger_flag_on_same_tier
        ; test_case "flag_on_different_tier" `Quick test_should_run_challenger_flag_on_different_tier
        ; test_case "empty_cascade" `Quick test_should_run_challenger_empty_cascade
        ] )
    ; ( "evaluate"
      , [ test_case "no_challenger_when_flag_off" `Quick
            test_evaluate_no_challenger_when_flag_off
        ] )
    ; ( "persona_authoring_gate"
      , [ test_case "cautious_eligible" `Quick test_eligible_cautious
        ; test_case "balanced_not_eligible" `Quick test_not_eligible_balanced
        ; test_case "high_autonomy_not_eligible" `Quick test_not_eligible_high_autonomy
        ; test_case "none_not_eligible" `Quick test_not_eligible_none
        ; test_case "unknown_not_eligible" `Quick test_not_eligible_unknown
        ] )
    ]
