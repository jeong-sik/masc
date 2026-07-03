module R = Keeper_latched_reason

let check_reason label expected actual =
  Alcotest.(check bool) label true (R.equal expected actual)
;;

let expect_ok label = function
  | Ok value -> value
  | Error err -> Alcotest.failf "%s expected Ok, got Error %s" label err
;;

let expect_error label = function
  | Ok value -> Alcotest.failf "%s expected Error, got %a" label R.pp value
  | Error err -> Alcotest.(check bool) (label ^ " has message") true (String.length err > 0)
;;

let round_trippable =
  [ ( "no progress loop"
    , R.No_progress_loop
        { consecutive_idle_cycles = 4; detector_kind = `Consecutive_no_progress } )
  ; ( "completion contract violation"
    , R.Completion_contract_violation
        { reason_code = `No_tool_use_block
        ; raw_error_summary = "missing keeper tool result: retry"
        } )
  ; "idle detected", R.Idle_detected { consecutive_idle_turns = 3 }
  ; "runtime all providers failed", R.Runtime_exhausted R.All_providers_failed
  ; "runtime no providers", R.Runtime_exhausted R.No_providers_available
  ; ( "runtime structural timeout"
    , R.Runtime_exhausted (R.Structural_attempt_timeout { stage = "provider_connect" }) )
  ; "runtime unspecified", R.Runtime_exhausted R.Unspecified_runtime
  ; ( "turn budget exhausted"
    , R.Turn_budget_exhausted
        { detail =
            { dimension = `Wall_clock_seconds
            ; source = `User_config
            }
        ; used = 95
        ; limit = 90
        } )
  ; "stale storm", R.Stale_storm
  ; "provider timeout loop", R.Provider_timeout_loop { consecutive_timeouts = 2 }
  ; "operator paused", R.Operator_paused { operator_actor = "dashboard:play" }
  ; "dead tombstone", R.Dead_tombstone
  ]
;;

let test_wire_round_trip () =
  List.iter
    (fun (label, reason) ->
       let wire = R.to_wire reason in
       let parsed = expect_ok label (R.of_wire wire) in
       check_reason (label ^ " wire round-trip") reason parsed)
    round_trippable
;;

let test_wire_parse_fail_closed () =
  [ "no_progress_loop:cycles=4:detector=surprise"
  ; "turn_budget_exhausted:dim=turns:used=nope:limit=10:source=oas_sdk"
  ; "turn_budget_exhausted:dim=turns:used=10:limit=10:source=unknown"
  ; "runtime_exhausted:unknown"
  ; "completion_contract_violation"
  ; "completion_contract_violation:code=galactic:summary=\"raw text\""
  ; "completion_contract_violation:code=unspecified:summary=raw_text"
  ]
  |> List.iter (fun wire -> expect_error wire (R.of_wire wire))
;;

let test_stable_json_round_trip () =
  List.iter
    (fun (label, reason) ->
       let json = R.Stable.to_yojson reason in
       let parsed = expect_ok label (R.Stable.of_yojson json) in
       check_reason (label ^ " json round-trip") reason parsed)
    round_trippable
;;

let test_stable_json_rejects_unknown_tags () =
  expect_error
    "unknown dimension"
    (R.Stable.of_yojson
       (`Assoc
           [ "kind", `String "turn_budget_exhausted"
           ; "dimension", `String "galactic"
           ; "used", `Int 10
           ; "limit", `Int 10
           ; "source", `String "oas_sdk"
           ]));
  expect_error
    "unknown kind"
    (R.Stable.of_yojson (`Assoc [ "kind", `String "new_future_reason" ]))
;;

(* ── Polymorphic-variant differentiation via [equal] ────────── *)

let test_poly_variants_distinguish_via_equal () =
  (* Polymorphic-variant fields are not directly comparable without
     a helper. [equal] is the canonical typed equality; it must
     distinguish same-tag from different-tag values for every
     polymorphic-variant field. *)
  let base =
    R.Turn_budget_exhausted
      { detail = { dimension = `Turns; source = `Oas_sdk }; used = 10; limit = 10 }
  in
  let with_different_dim =
    R.Turn_budget_exhausted
      { detail =
          { dimension = `Wall_clock_seconds
          ; source = `Oas_sdk
          }
      ; used = 10
      ; limit = 10
      }
  in
  let with_different_source =
    R.Turn_budget_exhausted
      { detail = { dimension = `Turns; source = `User_config }; used = 10; limit = 10 }
  in
  let with_different_used =
    R.Turn_budget_exhausted
      { detail = { dimension = `Turns; source = `Oas_sdk }; used = 11; limit = 10 }
  in
  let with_different_limit =
    R.Turn_budget_exhausted
      { detail = { dimension = `Turns; source = `Oas_sdk }; used = 10; limit = 11 }
  in
  Alcotest.(check bool) "Turns = Turns (reflexive)" true (R.equal base base);
  Alcotest.(check bool)
    "Turns ≠ Wall_clock_seconds (dim differs)"
    false
    (R.equal base with_different_dim);
  Alcotest.(check bool)
    "Oas_sdk ≠ User_config (source differs)"
    false
    (R.equal base with_different_source);
  Alcotest.(check bool)
    "used differs"
    false
    (R.equal base with_different_used);
  Alcotest.(check bool)
    "limit differs"
    false
    (R.equal base with_different_limit);
  (* contract_violation_detail: reason_code is a closed polymorphic
     variant *)
  let cc_base =
    R.Completion_contract_violation
      { reason_code = `No_tool_use_block; raw_error_summary = "x" }
  in
  let cc_diff_code =
    R.Completion_contract_violation
      { reason_code = `No_keeper_tool_returned; raw_error_summary = "x" }
  in
  let cc_diff_summary =
    R.Completion_contract_violation
      { reason_code = `No_tool_use_block; raw_error_summary = "y" }
  in
  Alcotest.(check bool)
    "Completion_contract reason_code differs"
    false
    (R.equal cc_base cc_diff_code);
  Alcotest.(check bool)
    "Completion_contract raw_error_summary differs"
    false
    (R.equal cc_base cc_diff_summary);
  (* no_progress_loop detector_kind *)
  let npl_base =
    R.No_progress_loop
      { consecutive_idle_cycles = 3; detector_kind = `Consecutive_idle_turns }
  in
  let npl_diff_detector =
    R.No_progress_loop
      { consecutive_idle_cycles = 3; detector_kind = `Both }
  in
  Alcotest.(check bool)
    "no_progress_loop detector_kind differs"
    false
    (R.equal npl_base npl_diff_detector)
;;

(* ── Hash determinism ───────────────────────────────────────── *)

let test_hash_is_deterministic () =
  List.iter
    (fun (label, reason) ->
       let h1 = R.hash reason in
       let h2 = R.hash reason in
       Alcotest.(check int) (label ^ " hash deterministic") h1 h2)
    round_trippable
;;

(* ── Completion-contract payload quoting ────────────────────── *)

let test_completion_contract_payload_quoting () =
  (* raw_error_summary may contain colons, equals signs, and double
     quotes. The wire format uses : as a separator, so the producer
     must preserve these byte-for-byte. *)
  let payload_summary = "raw text with : colon and \"quotes\" and =equals=" in
  let reason =
    R.Completion_contract_violation
      { reason_code = `Unspecified; raw_error_summary = payload_summary }
  in
  let wire = R.to_wire reason in
  match R.of_wire wire with
  | Ok (R.Completion_contract_violation { raw_error_summary; _ }) ->
    Alcotest.(check string)
      "raw_error_summary byte-identical after wire round-trip"
      payload_summary
      raw_error_summary
  | Ok other ->
    Alcotest.failf
      "wire round-trip changed constructor: %a"
      R.pp
      other
  | Error err ->
    Alcotest.failf "of_wire rejected colon-bearing payload: %s" err
;;

(* ── Completion-contract unknown reason_code fails closed ───── *)

let test_completion_contract_unknown_reason_code_fails_closed () =
  (* [reason_code] is part of the typed latch reason, so a producer-side
     tag drift must not silently land in [`Unspecified]. Operators still
     get the original wire in the Error message. *)
  expect_error
    "unknown completion_contract reason_code"
    (R.of_wire "completion_contract_violation:code=galactic:summary=\"raw text\"")
;;

let () =
  Alcotest.run
    "keeper_latched_reason"
    [ ( "wire"
      , [ Alcotest.test_case "typed reasons round-trip" `Quick test_wire_round_trip
        ; Alcotest.test_case "payload preserves colon + quote" `Quick
            test_completion_contract_payload_quoting
        ; Alcotest.test_case "unknown reason_code fails closed" `Quick
            test_completion_contract_unknown_reason_code_fails_closed
        ; Alcotest.test_case
            "malformed wires fail closed"
            `Quick
            test_wire_parse_fail_closed
        ] )
    ; ( "stable json"
      , [ Alcotest.test_case
            "typed reasons round-trip"
            `Quick
            test_stable_json_round_trip
        ; Alcotest.test_case
            "unknown tags fail closed"
            `Quick
            test_stable_json_rejects_unknown_tags
        ] )
    ; ( "polymorphic-variant equality"
      , [ Alcotest.test_case "poly variants distinguish via equal" `Quick
            test_poly_variants_distinguish_via_equal ] )
    ; ( "structural hashing"
      , [ Alcotest.test_case "hash is deterministic" `Quick test_hash_is_deterministic ] )
    ]
;;
