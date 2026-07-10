(* test/test_cap_blocker_structured_error.ml

   #9933: a blocker_info detail must preserve structured masc_oas_error
   JSON payloads. The pre-fix behaviour truncated at the narrative cap,
   slicing payloads like
   "Internal error: [masc_oas_error] {\"kind\":\"provider_timeout\",\
   \"budget_sec\":30.0,...}" mid-key and leaving operators with
   "budget_" as the trailing evidence.

   The cap is applied where the runtime builds [last_blocker.detail]
   (keeper_unified_metrics_failure).

   Pinned invariants:
   1. Structured payload <= structured cap -> identity (no ellipsis)
   2. Structured payload > structured cap -> truncated at the safety cap,
      not the narrative cap
   3. Plain narrative > narrative cap -> truncated at the narrative cap
   4. Plain narrative <= narrative cap -> identity
   5. Idempotence: cap(cap(s)) = cap(s) for every case *)

module T = Keeper_internal_error

let oas_error_payload_small =
  "[masc_oas_error] {\"kind\":\"provider_timeout\",\
   \"budget_sec\":30.0,\"keeper_turn_timeout_sec\":120.0,\
   \"estimated_input_tokens\":45000,\"source\":\"tool_list_build\"}"

let wrapped_oas_error_payload_small = "Internal error: " ^ oas_error_payload_small

let oas_error_payload_huge =
  let buf = Buffer.create 2500 in
  Buffer.add_string buf "[masc_oas_error] {\"kind\":\"provider_timeout\",\"extra\":\"";
  for _ = 1 to 2500 do Buffer.add_char buf 'x' done;
  Buffer.add_string buf "\"}";
  Buffer.contents buf

let narrative_short = "keeper cannot claim; tool_access mismatch on all 11 tasks"

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
  let result = T.cap_blocker_detail oas_error_payload_small in
  Alcotest.(check string)
    "small structured payload unchanged"
    oas_error_payload_small result;
  Alcotest.(check bool)
    "no ellipsis added to structured payload"
    false (ends_with_ellipsis result)

let test_huge_structured_payload_safety_capped () =
  let result = T.cap_blocker_detail oas_error_payload_huge in
  (* The payload is > structured cap, so it must be shorter than the
     input but still kept near the structured cap (otherwise we'd be
     applying the narrative budget). *)
  Alcotest.(check bool)
    "pathological payload truncated"
    true
    (String.length result < String.length oas_error_payload_huge);
  Alcotest.(check bool)
    "but kept at the structured cap, not the narrative cap"
    true
    (String.length result > T.blocker_detail_structured_max_chars / 2);
  Alcotest.(check bool) "ends with ellipsis" true
    (ends_with_ellipsis result)

let test_plain_narrative_short_preserved () =
  Alcotest.(check string)
    "short narrative unchanged"
    narrative_short (T.cap_blocker_detail narrative_short)

let test_wrapped_internal_error_preserved () =
  let result = T.cap_blocker_detail wrapped_oas_error_payload_small in
  Alcotest.(check string)
    "wrapped structured payload unchanged"
    wrapped_oas_error_payload_small result;
  Alcotest.(check bool)
    "no ellipsis added to wrapped structured payload"
    false (ends_with_ellipsis result)

let test_plain_narrative_long_truncated () =
  let result = T.cap_blocker_detail narrative_long in
  Alcotest.(check bool)
    "long narrative shorter than input"
    true (String.length result < String.length narrative_long);
  Alcotest.(check bool)
    "long narrative truncated near narrative cap (not structured cap)"
    true
    (String.length result < T.blocker_detail_structured_max_chars / 4);
  Alcotest.(check bool) "ends with ellipsis" true
    (ends_with_ellipsis result)

let test_idempotence () =
  let check label s =
    let once = T.cap_blocker_detail s in
    let twice = T.cap_blocker_detail once in
    Alcotest.(check string)
      (Printf.sprintf "idempotent: %s" label) once twice
  in
  check "small structured" oas_error_payload_small;
  check "wrapped structured" wrapped_oas_error_payload_small;
  check "huge structured" oas_error_payload_huge;
  check "short narrative" narrative_short;
  check "long narrative" narrative_long

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
    ]
