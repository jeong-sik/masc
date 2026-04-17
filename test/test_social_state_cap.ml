(** Verify cap_social_state bounds narrative fields.

    Gen8 persistence-layer guard parallel to Gen7 cap_snapshot. Gen7
    (#7676) capped keeper_state_snapshot; this caps social_state so
    previous_state carried across turns by BDI speech v1 cannot grow
    monotonically when speech_act=Stay_silent preserves state. *)

module T = Masc_mcp.Keeper_social_model_types

let long n = String.make n 'x'

let base : T.social_state =
  {
    social_model = "bdi_speech_v1";
    belief_summary = "quiet_room";
    active_desire = None;
    current_intention = None;
    blocker = None;
    need = None;
    speech_act = T.Stay_silent;
    delivery_surface = T.Silent;
  }

let test_short_unchanged () =
  let c = T.cap_social_state base in
  Alcotest.(check string) "belief_summary unchanged" "quiet_room" c.belief_summary;
  Alcotest.(check (option string)) "blocker stays None" None c.blocker

let test_belief_capped () =
  let s = { base with belief_summary = long 1000 } in
  let c = T.cap_social_state ~belief_max_chars:100 s in
  (* 100 ASCII chars + "…" (3 UTF-8 bytes). *)
  Alcotest.(check bool) "belief near cap"
    true (String.length c.belief_summary <= 103);
  Alcotest.(check bool) "ellipsis appended"
    true (String.length c.belief_summary > 100)

let test_option_fields_capped () =
  let s =
    { base with
      active_desire = Some (long 500);
      current_intention = Some (long 500);
      blocker = Some (long 500);
      need = Some (long 500);
    }
  in
  let c = T.cap_social_state ~option_max_chars:50 s in
  let check_opt label = function
    | Some v ->
        Alcotest.(check bool)
          (label ^ " near cap") true (String.length v <= 53)
    | None -> Alcotest.fail (label ^ " should be Some")
  in
  check_opt "active_desire" c.active_desire;
  check_opt "current_intention" c.current_intention;
  check_opt "blocker" c.blocker;
  check_opt "need" c.need

let test_none_fields_stay_none () =
  let s = { base with belief_summary = long 600 } in
  let c = T.cap_social_state s in
  Alcotest.(check (option string)) "active_desire stays None" None c.active_desire;
  Alcotest.(check (option string)) "blocker stays None" None c.blocker

let test_idempotent () =
  let s =
    { base with
      belief_summary = long 1000;
      blocker = Some (long 1000);
    }
  in
  let c1 = T.cap_social_state s in
  let c2 = T.cap_social_state c1 in
  Alcotest.(check string) "belief idempotent" c1.belief_summary c2.belief_summary;
  Alcotest.(check (option string)) "blocker idempotent" c1.blocker c2.blocker

let test_speech_and_surface_pass_through () =
  let s =
    { base with
      belief_summary = long 800;
      speech_act = T.Request_help;
      delivery_surface = T.Board_post;
    }
  in
  let c = T.cap_social_state s in
  Alcotest.(check string) "speech_act preserved"
    "request_help" (T.speech_act_to_string c.speech_act);
  Alcotest.(check string) "delivery_surface preserved"
    "board_post" (T.delivery_surface_to_string c.delivery_surface)

let () =
  Alcotest.run "social_state_cap"
    [ ( "cap_social_state",
        [ Alcotest.test_case "short state unchanged" `Quick test_short_unchanged;
          Alcotest.test_case "belief_summary capped" `Quick test_belief_capped;
          Alcotest.test_case "option fields capped" `Quick
            test_option_fields_capped;
          Alcotest.test_case "None fields stay None" `Quick
            test_none_fields_stay_none;
          Alcotest.test_case "cap is idempotent" `Quick test_idempotent;
          Alcotest.test_case "speech/surface pass through" `Quick
            test_speech_and_surface_pass_through;
        ] );
    ]
