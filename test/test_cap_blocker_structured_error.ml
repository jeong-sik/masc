(* test/test_cap_blocker_structured_error.ml

   #9933: blocker field must preserve structured masc_oas_error
   JSON payloads. The pre-fix behaviour truncated at 200 chars,
   slicing payloads like
   "Internal error: [masc_oas_error] {\"kind\":\"oas_timeout_budget\",\
   \"budget_sec\":30.0,...}" mid-key and leaving operators with
   "budget_" as the trailing evidence.

   Pinned invariants:
   1. Structured payload ≤ 2000 chars → identity (no ellipsis)
   2. Structured payload > 2000 chars → truncated at the safety cap,
      not the narrative cap
   3. Plain narrative > 200 chars → truncated at the narrative cap
   4. Plain narrative ≤ 200 chars → identity
   5. Idempotence: cap(cap(s)) = cap(s) for every case
   6. cap_social_state routes blocker through cap_blocker but leaves
      every other option field on the narrative cap *)

module T = Masc_mcp.Keeper_social_model_types

let oas_error_payload_small =
  "[masc_oas_error] {\"kind\":\"oas_timeout_budget\",\
   \"budget_sec\":30.0,\"keeper_turn_timeout_sec\":120.0,\
   \"estimated_input_tokens\":45000,\"source\":\"tool_list_build\"}"

let wrapped_oas_error_payload_small = "Internal error: " ^ oas_error_payload_small

let oas_error_payload_huge =
  let buf = Buffer.create 2500 in
  Buffer.add_string buf "[masc_oas_error] {\"kind\":\"oas_timeout_budget\",\"extra\":\"";
  for _ = 1 to 2500 do Buffer.add_char buf 'x' done;
  Buffer.add_string buf "\"}";
  Buffer.contents buf

let narrative_short = "keeper cannot claim; preset mismatch on all 11 tasks"

let narrative_long =
  let buf = Buffer.create 400 in
  Buffer.add_string buf "keeper blocker narrative: ";
  for _ = 1 to 400 do Buffer.add_char buf 'a' done;
  Buffer.contents buf

let ends_with_ellipsis s =
  let needle = "…" in
  let nl = String.length needle in
  let sl = String.length s in
  sl >= nl && String.sub s (sl - nl) nl = needle

let test_small_structured_payload_preserved () =
  let result = T.cap_blocker oas_error_payload_small in
  Alcotest.(check string)
    "small structured payload unchanged"
    oas_error_payload_small result;
  Alcotest.(check bool)
    "no ellipsis added to structured payload"
    false (ends_with_ellipsis result)

let test_huge_structured_payload_safety_capped () =
  let result = T.cap_blocker oas_error_payload_huge in
  (* The payload is > 2000 chars, so it must be shorter than the
     input but still ≥ the narrative cap (otherwise we'd be
     applying the narrative budget). *)
  Alcotest.(check bool)
    "pathological payload truncated"
    true
    (String.length result < String.length oas_error_payload_huge);
  Alcotest.(check bool)
    "but kept above narrative budget"
    true
    (String.length result > T.default_option_field_max_chars * 2);
  Alcotest.(check bool) "ends with ellipsis" true
    (ends_with_ellipsis result)

let test_plain_narrative_short_preserved () =
  Alcotest.(check string)
    "short narrative unchanged"
    narrative_short (T.cap_blocker narrative_short)

let test_wrapped_internal_error_preserved () =
  let result = T.cap_blocker wrapped_oas_error_payload_small in
  Alcotest.(check string)
    "wrapped structured payload unchanged"
    wrapped_oas_error_payload_small result;
  Alcotest.(check bool)
    "no ellipsis added to wrapped structured payload"
    false (ends_with_ellipsis result)

let test_plain_narrative_long_truncated () =
  let result = T.cap_blocker narrative_long in
  Alcotest.(check bool)
    "long narrative shorter than input"
    true (String.length result < String.length narrative_long);
  Alcotest.(check bool)
    "long narrative truncated near option cap (not structured cap)"
    true
    (String.length result < T.masc_oas_error_max_chars / 4);
  Alcotest.(check bool) "ends with ellipsis" true
    (ends_with_ellipsis result)

let test_idempotence () =
  let check label s =
    let once = T.cap_blocker s in
    let twice = T.cap_blocker once in
    Alcotest.(check string)
      (Printf.sprintf "idempotent: %s" label) once twice
  in
  check "small structured" oas_error_payload_small;
  check "wrapped structured" wrapped_oas_error_payload_small;
  check "huge structured" oas_error_payload_huge;
  check "short narrative" narrative_short;
  check "long narrative" narrative_long

let test_cap_social_state_routes_blocker_through_cap_blocker () =
  let state : T.social_state = {
    social_model = "magentic_ledger_v1";
    speech_act = T.Stay_silent;
    delivery_surface = T.Silent;
    belief_summary = "bs";
    active_desire = Some "ad";
    current_intention = Some "ci";
    blocker = Some oas_error_payload_small;
    need = Some "nd";
  } in
  let capped = T.cap_social_state state in
  Alcotest.(check (option string))
    "blocker preserved through cap_social_state"
    (Some oas_error_payload_small)
    capped.blocker

let test_cap_social_state_narrative_fields_still_truncated () =
  let state : T.social_state = {
    social_model = "magentic_ledger_v1";
    speech_act = T.Stay_silent;
    delivery_surface = T.Silent;
    belief_summary = narrative_long;
    active_desire = Some narrative_long;
    current_intention = Some narrative_long;
    blocker = None;
    need = Some narrative_long;
  } in
  let capped = T.cap_social_state state in
  Alcotest.(check bool)
    "belief_summary truncated"
    true
    (String.length capped.belief_summary < String.length narrative_long);
  let check_opt label = function
    | None -> Alcotest.fail (Printf.sprintf "expected Some for %s" label)
    | Some s ->
      Alcotest.(check bool)
        (Printf.sprintf "%s truncated" label)
        true
        (String.length s < String.length narrative_long)
  in
  check_opt "active_desire" capped.active_desire;
  check_opt "current_intention" capped.current_intention;
  check_opt "need" capped.need

let () =
  Alcotest.run "cap_blocker_structured_error"
    [
      ( "structured payload",
        [
          Alcotest.test_case "small preserved" `Quick
            test_small_structured_payload_preserved;
          Alcotest.test_case "huge safety-capped" `Quick
            test_huge_structured_payload_safety_capped;
        ] );
      ( "plain narrative",
        [
          Alcotest.test_case "short preserved" `Quick
            test_plain_narrative_short_preserved;
          Alcotest.test_case "long truncated at narrative cap" `Quick
            test_plain_narrative_long_truncated;
          Alcotest.test_case "wrapped 'Internal error:' preserved" `Quick
            test_wrapped_internal_error_preserved;
        ] );
      ( "idempotence",
        [ Alcotest.test_case "four shapes" `Quick test_idempotence ] );
      ( "cap_social_state integration",
        [
          Alcotest.test_case "blocker via cap_blocker" `Quick
            test_cap_social_state_routes_blocker_through_cap_blocker;
          Alcotest.test_case "narrative fields unchanged policy" `Quick
            test_cap_social_state_narrative_fields_still_truncated;
        ] );
    ]
