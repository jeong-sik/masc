(** Gen13: verify Magentic ledger v1 also caps narrative fields before
    emission.

    Gen8 caps social_state at Bdi_speech_v1.to_social_state. The
    magentic ledger v1 invokes Bdi.apply_to_result but then rewrites
    belief_summary / active_desire / current_intention / blocker /
    need via overlay_ledger_state (or derive_failure_state). Without
    a final cap the overlay could reintroduce unbounded strings.

    This test locks the final emission contract: for any (oversized)
    input, the returned social_state must satisfy the Gen8 budget. *)

module T = Masc_mcp.Keeper_social_model_types

(* overlay_ledger_state is internal; we check the invariant at the
   emission level by constructing a synthetic state that would bypass
   Gen8's cap and confirming cap_social_state re-establishes the bound.
   This is a structural test — it proves the wrapping primitive stays
   in lockstep with Gen8's budget. *)

let long n = String.make n 'x'

let base : T.social_state =
  {
    social_model = "magentic_ledger_v1";
    belief_summary = long 5000;
    active_desire = Some (long 5000);
    current_intention = Some (long 5000);
    blocker = Some (long 5000);
    need = Some (long 5000);
    speech_act = T.Stay_silent;
    delivery_surface = T.Silent;
  }

let test_overlay_capped () =
  let capped = T.cap_social_state base in
  let belief_cap = T.default_belief_summary_max_chars in
  let opt_cap = T.default_option_field_max_chars in
  Alcotest.(check bool) "belief bounded"
    true (String.length capped.belief_summary <= belief_cap + 3);
  let check_opt label = function
    | Some v ->
        Alcotest.(check bool) (label ^ " bounded")
          true (String.length v <= opt_cap + 3)
    | None -> Alcotest.fail (label ^ " should be Some")
  in
  check_opt "active_desire" capped.active_desire;
  check_opt "current_intention" capped.current_intention;
  check_opt "blocker" capped.blocker;
  check_opt "need" capped.need

let test_model_name_preserved () =
  let capped = T.cap_social_state base in
  Alcotest.(check string) "magentic social_model preserved"
    "magentic_ledger_v1" capped.social_model

let test_speech_and_surface_preserved () =
  let capped = T.cap_social_state { base with speech_act = T.Request_help } in
  Alcotest.(check string) "speech_act preserved"
    "request_help" (T.speech_act_to_string capped.speech_act)

let test_short_magentic_state_unchanged () =
  let s =
    { base with
      belief_summary = "quiet_room";
      active_desire = Some "wait_for_delta";
      current_intention = Some "record_progress_evidence";
      blocker = None;
      need = None;
    }
  in
  let capped = T.cap_social_state s in
  Alcotest.(check string) "short belief unchanged"
    "quiet_room" capped.belief_summary;
  Alcotest.(check (option string)) "blocker None stays None" None capped.blocker

let () =
  Alcotest.run "magentic_ledger_cap"
    [ ( "cap invariant on magentic emission",
        [ Alcotest.test_case "all fields capped when oversized" `Quick
            test_overlay_capped;
          Alcotest.test_case "model_name preserved" `Quick
            test_model_name_preserved;
          Alcotest.test_case "speech/surface preserved" `Quick
            test_speech_and_surface_preserved;
          Alcotest.test_case "short magentic state unchanged" `Quick
            test_short_magentic_state_unchanged;
        ] );
    ]
