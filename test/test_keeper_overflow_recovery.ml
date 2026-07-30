(** Unit tests for the [Overflowed] phase and explicit compaction lifecycle.

    Scenarios mirror the five cases in the MASC-1 plan:
    1. Happy path — Running → Overflowed → Compacting → Running
    2. Compact failed → executable again for durable Lane retry
    3. Operator clear — Overflowed → Running without passing Compacting
    4. Two consecutive overflows in one fiber lifecycle
    5. Heartbeat failure while Overflowed is preserved through recovery *)

open Alcotest

module SM = Keeper_state_machine

(** Conditions for a healthy Running keeper. *)
let running_conds : SM.conditions =
  { SM.default_conditions with
    fiber_alive = true;
    heartbeat_healthy = true;
    turn_healthy = true;
    dead_tombstone_latched = false;
  }

let overflow_event ?(limit = Some 200_000) () =
  SM.Context_overflow_detected { limit_tokens = limit }

let test_provider_overflow_trigger_roundtrip () =
  let trigger = Compaction_trigger.Provider_overflow { limit_tokens = Some 200_000 } in
  check string "typed trigger label" "provider_overflow" (Compaction_trigger.to_label trigger);
  List.iter
    (fun expected ->
       match
         Compaction_trigger.of_detail_json (Compaction_trigger.to_detail_json expected)
       with
       | Ok actual when actual = expected -> ()
       | Ok _ | Error _ -> fail "typed compaction trigger did not round-trip")
    [ trigger
    ; Compaction_trigger.Provider_overflow { limit_tokens = None }
    ; Compaction_trigger.Request_body_over_capacity
        { actual_bytes = 1_048_577; limit_bytes = 1_048_576 }
    ; Compaction_trigger.Request_body_refused_by_provider { status = 413 }
    ; Compaction_trigger.Serving_input_capacity
        (Compaction_trigger.Boundary_unknown
           { input_tokens = 524_299
           ; accepted_through = 524_298
           ; rejected_from = None
           })
    ; Compaction_trigger.Serving_input_capacity
        (Compaction_trigger.Boundary_unknown
           { input_tokens = 524_299
           ; accepted_through = 524_298
           ; rejected_from = Some 524_300
           })
    ; Compaction_trigger.Serving_input_capacity
        (Compaction_trigger.Input_rejected
           { input_tokens = 524_300
           ; accepted_through = 524_298
           ; rejected_from = 524_299
           })
    ; Compaction_trigger.Manual
    ];
  let decode_serving ~reason ~input_tokens ~accepted_through ~rejected_from =
    Compaction_trigger.of_detail_json
      (`Assoc
        [ "kind", `String "serving_input_capacity"
        ; "reason", `String reason
        ; "input_tokens", `Int input_tokens
        ; "accepted_through", `Int accepted_through
        ; "rejected_from", `Int rejected_from
        ])
  in
  (match
     decode_serving
       ~reason:"boundary_unknown"
       ~input_tokens:524_300
       ~accepted_through:524_298
       ~rejected_from:524_299
   with
   | Error
       (Compaction_trigger.Invalid_boundary_unknown
          { input_tokens = 524_300; rejected_from = 524_299 } as error) ->
     check
       string
       "boundary_unknown diagnostic states its valid side"
       "serving input capacity boundary_unknown requires rejected_from > input_tokens, got input=524300 rejected=524299"
       (Compaction_trigger.decode_error_to_string error)
   | Ok _ | Error _ ->
     fail "boundary_unknown admitted a rejection at or below the measured input");
  match
    decode_serving
      ~reason:"input_rejected"
      ~input_tokens:524_300
      ~accepted_through:524_298
      ~rejected_from:524_301
  with
  | Error
      (Compaction_trigger.Invalid_input_rejected_boundary
         { input_tokens = 524_300
         ; accepted_through = 524_298
         ; rejected_from = Some 524_301
         } as error) ->
    check
      string
      "input_rejected diagnostic states its valid interval"
      "serving input capacity input_rejected requires accepted_through < rejected_from <= input_tokens, got input=524300 accepted=524298 rejected=524301"
      (Compaction_trigger.decode_error_to_string error)
  | Ok _ | Error _ ->
    fail "input_rejected admitted a boundary above the measured input"
;;

let test_request_body_over_capacity_rejects_non_refusals () =
  let decode fields =
    Compaction_trigger.of_detail_json
      (`Assoc (("kind", `String "request_body_over_capacity") :: fields))
  in
  (* The label asserts actual > limit. A record that satisfies the field shape but
     not the comparison describes a request that fit, so decoding it would put a
     capacity trigger in front of a compaction that had no capacity reason. *)
  (match decode [ "actual_bytes", `Int 100; "limit_bytes", `Int 100 ] with
   | Error
       (Compaction_trigger.Request_body_within_capacity
          { actual_bytes = 100; limit_bytes = 100 }) -> ()
   | Ok _ | Error _ -> fail "an equal-size request body was admitted as over capacity");
  (match decode [ "actual_bytes", `Int 200 ] with
   | Error (Compaction_trigger.Missing_request_body_bytes "limit_bytes") -> ()
   | Ok _ | Error _ -> fail "a trigger missing limit_bytes was admitted");
  (match decode [ "actual_bytes", `Int 0; "limit_bytes", `Int 10 ] with
   | Error (Compaction_trigger.Invalid_request_body_bytes "actual_bytes") -> ()
   | Ok _ | Error _ -> fail "a zero-byte body was admitted as a measurement");
  match
    decode
      [ "actual_bytes", `Int 200; "limit_bytes", `Int 100; "limit_tokens", `Int 5 ]
  with
  | Error (Compaction_trigger.Unknown_field "limit_tokens") -> ()
  | Ok _ | Error _ -> fail "the token field was accepted on the byte axis"
;;

let test_retired_trigger_kinds_are_rejected () =
  let decode kind =
    Compaction_trigger.of_detail_json (`Assoc [ "kind", `String kind ])
  in
  List.iter
    (fun kind ->
       match decode kind with
       | Error (Compaction_trigger.Unknown_kind actual)
         when String.equal actual kind -> ()
       | Ok _ | Error _ -> failf "retired trigger %s was not explicitly rejected" kind)
    [ "ratio"; "messages"; "tokens" ];
  match
    Compaction_trigger.of_detail_json
      (`Assoc [ "kind", `String "provider_overflow" ])
  with
  | Error Compaction_trigger.Missing_provider_limit -> ()
  | Ok _ | Error _ -> fail "provider overflow without limit_tokens was admitted"
;;

let test_malformed_trigger_details_are_typed_errors () =
  let check_error message expected json =
    match Compaction_trigger.of_detail_json json with
    | Error actual when actual = expected -> ()
    | Ok _ | Error _ -> fail message
  in
  check_error
    "non-object trigger detail was admitted"
    Compaction_trigger.Expected_object
    (`String "manual");
  check_error
    "missing trigger kind was admitted"
    Compaction_trigger.Missing_kind
    (`Assoc []);
  check_error
    "unknown manual field was admitted"
    (Compaction_trigger.Unknown_field "limit_tokens")
    (`Assoc [ "kind", `String "manual"; "limit_tokens", `Null ]);
  check_error
    "unknown provider field was admitted"
    (Compaction_trigger.Unknown_field "extra")
    (`Assoc
      [ "kind", `String "provider_overflow"
      ; "limit_tokens", `Int 200_000
      ; "extra", `Null
      ]);
  check_error
    "duplicate trigger kind was admitted"
    (Compaction_trigger.Duplicate_field "kind")
    (`Assoc [ "kind", `String "manual"; "kind", `String "manual" ]);
  check_error
    "duplicate provider limit was admitted"
    (Compaction_trigger.Duplicate_field "limit_tokens")
    (`Assoc
      [ "kind", `String "provider_overflow"
      ; "limit_tokens", `Int 200_000
      ; "limit_tokens", `Int 200_000
      ]);
  check_error
    "non-string trigger kind was admitted"
    Compaction_trigger.Invalid_kind
    (`Assoc [ "kind", `Int 1 ]);
  List.iter
    (fun limit ->
       check_error
         "invalid provider limit was admitted"
         Compaction_trigger.Invalid_provider_limit
         (`Assoc [ "kind", `String "provider_overflow"; "limit_tokens", limit ]))
    [ `Int 0; `Int (-1); `String "200000" ]
;;

let apply_ok phase conds ev =
  match SM.apply_event ~current_phase:phase ~conditions:conds ~event:ev
          ~now:0.0
  with
  | Ok tr -> tr
  | Error err ->
    failf
      "apply_event rejected: %s (phase=%s event=%s)"
      (SM.transition_error_to_string err)
      (SM.phase_to_string phase)
      (SM.event_to_string ev)

let check_phase expected actual msg =
  check string msg (SM.phase_to_string expected) (SM.phase_to_string actual)

(* ── Scenario 1: happy path ───────────────────────────────── *)

let test_happy_path () =
  (* Running → overflow detected *)
  let tr1 = apply_ok SM.Running running_conds (overflow_event ()) in
  check_phase SM.Overflowed tr1.new_phase "overflow → Overflowed";
  check bool "context_overflow latched" true
    tr1.updated_conditions.context_overflow;
  (* Durable Lane work is not synthesized as an FSM entry effect. *)
  let has_start_compaction =
    List.exists (function SM.Start_compaction -> true | _ -> false)
      tr1.entry_actions
  in
  check bool "Overflowed does not synthesize compaction work" false has_start_compaction;
  (* The Lane executor explicitly starts compaction. *)
  let tr2 =
    apply_ok SM.Overflowed tr1.updated_conditions SM.Compaction_started
  in
  check_phase SM.Compacting tr2.new_phase "compaction start → Compacting";
  (* Compaction completes → Running (context_overflow cleared) *)
  let tr3 =
    apply_ok SM.Compacting tr2.updated_conditions
      SM.Compaction_completed
  in
  check_phase SM.Running tr3.new_phase "compaction done → Running";
  check bool "context_overflow cleared" false
    tr3.updated_conditions.context_overflow

(* ── Scenario 2: compact failure remains recoverable ──────── *)

let test_compact_failure_releases_lane () =
  (* Running → overflow → Overflowed *)
  let tr1 = apply_ok SM.Running running_conds (overflow_event ()) in
  (* The Lane executor explicitly starts compaction. *)
  let tr2 =
    apply_ok SM.Overflowed tr1.updated_conditions SM.Compaction_started
  in
  (* Compaction fails — the pending source remains available for exact retry. *)
  let tr3 =
    apply_ok SM.Compacting tr2.updated_conditions
      (SM.Compaction_failed { reason = "oas_error" })
  in
  check_phase SM.Running tr3.new_phase
    "compact failed, buffer latch released → Running";
  check bool "context_overflow latch released" false
    tr3.updated_conditions.context_overflow;
  check bool "failure does not synthesize operator pause" false
    tr3.updated_conditions.operator_paused

(* ── Scenario 3: operator clear bypasses Compacting ───────── *)

let test_operator_clear_returns_to_running () =
  let tr1 = apply_ok SM.Running running_conds (overflow_event ()) in
  check_phase SM.Overflowed tr1.new_phase "overflow → Overflowed";
  let tr2 =
    apply_ok SM.Overflowed tr1.updated_conditions
      (SM.Operator_clear_requested
         { preserve_system = true; reason = "manual test" })
  in
  check_phase SM.Running tr2.new_phase
    "operator clear drops context → Running";
  check bool "context_overflow cleared" false
    tr2.updated_conditions.context_overflow;
  check bool "compaction_active not touched" false
    tr2.updated_conditions.compaction_active

(* ── Scenario 4: two consecutive overflows in one fiber ───── *)

let test_two_consecutive_overflows () =
  (* Run one full overflow/compact/running cycle. *)
  let tr1 = apply_ok SM.Running running_conds (overflow_event ()) in
  let tr2 =
    apply_ok SM.Overflowed tr1.updated_conditions SM.Compaction_started
  in
  let tr3 =
    apply_ok SM.Compacting tr2.updated_conditions
      SM.Compaction_completed
  in
  check_phase SM.Running tr3.new_phase "cycle 1 back to Running";
  (* Second overflow should be handled cleanly after the successful cycle. *)
  let tr4 = apply_ok SM.Running tr3.updated_conditions (overflow_event ()) in
  check_phase SM.Overflowed tr4.new_phase "cycle 2 → Overflowed";
  let tr5 =
    apply_ok SM.Overflowed tr4.updated_conditions SM.Compaction_started
  in
  check_phase SM.Compacting tr5.new_phase "cycle 2 compaction → Compacting"

(* ── Scenario 5: heartbeat failure during Overflowed ──────── *)

let test_heartbeat_failure_preserved_through_overflow () =
  (* Overflowed with a subsequent heartbeat failure: the heartbeat flag
     must stick so the keeper surfaces Failing once the overflow is
     resolved. No event is lost. *)
  let tr1 = apply_ok SM.Running running_conds (overflow_event ()) in
  check_phase SM.Overflowed tr1.new_phase "overflow → Overflowed";
  let tr2 =
    apply_ok SM.Overflowed tr1.updated_conditions
      (SM.Heartbeat_failed { consecutive = 1 })
  in
  (* Phase stays Overflowed because context_overflow still wins in the
     priority ladder, but heartbeat_healthy is now false. *)
  check_phase SM.Overflowed tr2.new_phase
    "Overflowed outranks heartbeat failure";
  check bool "heartbeat unhealthy latched" false
    tr2.updated_conditions.heartbeat_healthy;
  (* Compaction finishes → overflow cleared. Heartbeat failure now
     surfaces as Failing.  This confirms no event is swallowed. *)
  let tr3 =
    apply_ok SM.Overflowed tr2.updated_conditions SM.Compaction_started
  in
  check_phase SM.Compacting tr3.new_phase "compact starts";
  let tr4 =
    apply_ok SM.Compacting tr3.updated_conditions
      SM.Compaction_completed
  in
  (* context_overflow cleared, heartbeat_healthy=false remains → Failing *)
  check_phase SM.Failing tr4.new_phase
    "post-compact, heartbeat failure surfaces as Failing"

let () =
  run "keeper_overflow_recovery" [
    "overflow-lifecycle",
    [ test_case "provider overflow trigger codec" `Quick
        test_provider_overflow_trigger_roundtrip;
      test_case "retired trigger kinds rejected" `Quick
        test_retired_trigger_kinds_are_rejected;
      test_case "request body over capacity rejects non-refusals" `Quick
        test_request_body_over_capacity_rejects_non_refusals;
      test_case "malformed trigger details are typed errors" `Quick
        test_malformed_trigger_details_are_typed_errors;
      test_case "happy path" `Quick test_happy_path;
      test_case "compact failure releases Lane" `Quick
        test_compact_failure_releases_lane;
      test_case "operator clear returns to Running" `Quick
        test_operator_clear_returns_to_running;
      test_case "two consecutive overflows" `Quick
        test_two_consecutive_overflows;
      test_case "heartbeat failure preserved through overflow" `Quick
        test_heartbeat_failure_preserved_through_overflow;
    ]
  ]
