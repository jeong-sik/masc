(** Unit tests for Runtime_lane_preference — a candidate's observed
    backpressure. The pure state functions take their clock as an argument;
    nothing here reads the process clock. *)

module State = Runtime_lane_preference_state

let test_rate_limit_hint_expires_exactly () =
  let noted = State.note_rate_limit ~noted_at:10. ~retry_after:(Some 5.) None in
  Alcotest.(check bool) "before provider reset retains observation" true
    (Option.is_some (State.observe_rate_limit ~now:14.999 noted));
  Alcotest.(check bool) "at provider reset drops observation" true
    (Option.is_none (State.observe_rate_limit ~now:15. noted))
;;

let test_rate_limit_without_hint_has_no_synthetic_expiry () =
  let noted = State.note_rate_limit ~noted_at:10. ~retry_after:None None in
  match State.observe_rate_limit ~now:1_000_000. noted with
  | Some (State.Unknown_scope_rate_limit { retry_after = None; noted_at }) ->
      Alcotest.(check (float 0.)) "original observation retained" 10. noted_at
  | Some (State.Unknown_scope_rate_limit _) | None ->
      Alcotest.fail "no-hint rate limit acquired an invented deadline"
;;

let test_rate_limit_invalid_hints_do_not_create_deadlines () =
  List.iter (fun seconds ->
    let noted = State.note_rate_limit ~noted_at:10. ~retry_after:(Some seconds) None in
    match State.observe_rate_limit ~now:1000. noted with
    | Some (State.Unknown_scope_rate_limit { retry_after = None; _ }) -> ()
    | Some (State.Unknown_scope_rate_limit _) | None ->
        Alcotest.fail "invalid provider delay became usable")
    [Float.nan; Float.infinity; Float.neg_infinity; -1.]
;;

let test_rate_limit_delayed_observation_keeps_newer_hint () =
  let newer = State.note_rate_limit ~noted_at:20. ~retry_after:(Some 3.) None in
  let delayed = State.note_rate_limit ~noted_at:10. ~retry_after:None newer in
  Alcotest.(check bool) "old response cannot replace newer expiry" true
    (Option.is_none (State.observe_rate_limit ~now:23. delayed))
;;

(* The cell on a materialized candidate: a rate limit is held until its hint
   elapses or a success clears it; a success on a clear cell changes nothing. *)
let test_a_candidate_cell_holds_the_observation_until_success () =
  let candidate =
    Runtime_lane_preference.create_candidate
      ~binding:(Runtime_lane_preference.Http_binding_unavailable "fixture")
  in
  Alcotest.(check bool) "fresh cell observes nothing" true
    (Option.is_none
       (Runtime_lane_preference.candidate_backpressure ~now:0. ~candidate));
  Runtime_lane_preference.note_rate_limit ~candidate ~retry_after:None;
  Alcotest.(check bool) "a no-hint rate limit is held" true
    (Option.is_some
       (Runtime_lane_preference.candidate_backpressure ~now:1e12 ~candidate));
  Runtime_lane_preference.note_candidate_success ~candidate;
  Alcotest.(check bool) "a success clears it" true
    (Option.is_none
       (Runtime_lane_preference.candidate_backpressure ~now:1e12 ~candidate))
;;

let () =
  Alcotest.run "runtime_lane_preference"
    [ ( "candidate backpressure"
      , [ Alcotest.test_case "hint expires at provider boundary" `Quick
            test_rate_limit_hint_expires_exactly
        ; Alcotest.test_case "no synthetic expiry" `Quick
            test_rate_limit_without_hint_has_no_synthetic_expiry
        ; Alcotest.test_case "invalid hints remain unknown" `Quick
            test_rate_limit_invalid_hints_do_not_create_deadlines
        ; Alcotest.test_case "delayed observation retains newer hint" `Quick
            test_rate_limit_delayed_observation_keeps_newer_hint
        ; Alcotest.test_case "a candidate cell holds the observation until success" `Quick
            test_a_candidate_cell_holds_the_observation_until_success
        ] )
    ]
