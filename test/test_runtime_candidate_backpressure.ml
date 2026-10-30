(** Unit tests for Runtime_candidate_backpressure — a candidate's observed
    backpressure. The pure state functions take their clock as an argument;
    nothing here reads the process clock. *)

module State = Runtime_candidate_backpressure_state

let keeper_a = State.keeper_recorder ~keeper_name:"keeper-a"
let keeper_b = State.keeper_recorder ~keeper_name:"keeper-b"

let rate_limit_after ~now state = (State.observe ~now state).State.rate_limit

let test_rate_limit_hint_expires_exactly () =
  let noted = State.note_rate_limit ~noted_at:10. ~retry_after:(Some 5.) State.empty in
  Alcotest.(check bool) "before provider reset retains observation" true
    (Option.is_some (rate_limit_after ~now:14.999 noted));
  Alcotest.(check bool) "at provider reset drops observation" true
    (Option.is_none (rate_limit_after ~now:15. noted))
;;

let test_rate_limit_without_hint_has_no_synthetic_expiry () =
  let noted = State.note_rate_limit ~noted_at:10. ~retry_after:None State.empty in
  match rate_limit_after ~now:1_000_000. noted with
  | Some (State.Unknown_scope_rate_limit { retry_after = None; noted_at }) ->
      Alcotest.(check (float 0.)) "original observation retained" 10. noted_at
  | Some (State.Unknown_scope_rate_limit _) | None ->
      Alcotest.fail "no-hint rate limit acquired an invented deadline"
;;

let test_rate_limit_invalid_hints_do_not_create_deadlines () =
  List.iter (fun seconds ->
    let noted = State.note_rate_limit ~noted_at:10. ~retry_after:(Some seconds) State.empty in
    match rate_limit_after ~now:1000. noted with
    | Some (State.Unknown_scope_rate_limit { retry_after = None; _ }) -> ()
    | Some (State.Unknown_scope_rate_limit _) | None ->
        Alcotest.fail "invalid provider delay became usable")
    [Float.nan; Float.infinity; Float.neg_infinity; -1.; 0.]
;;

let test_rate_limit_delayed_observation_keeps_newer_hint () =
  let newer = State.note_rate_limit ~noted_at:20. ~retry_after:(Some 3.) State.empty in
  let delayed = State.note_rate_limit ~noted_at:10. ~retry_after:None newer in
  Alcotest.(check bool) "old response cannot replace newer expiry" true
    (Option.is_none (rate_limit_after ~now:23. delayed))
;;

(* RFC-0458 §3.4: a failed attempt names no time, so no clock ends it. *)
let test_failed_attempt_has_no_expiry () =
  let noted =
    State.note_failed_attempt ~noted_at:10. ~failure:State.Provider_timeout
      ~recorded_by:keeper_a State.empty
  in
  match (State.observe ~now:1e12 noted).State.failed_attempt with
  | Some (State.Failed_attempt { noted_at; failure = State.Provider_timeout; recorded_by = _ }) ->
      Alcotest.(check (float 0.)) "original observation retained" 10. noted_at
  | Some (State.Failed_attempt { failure = State.Server_error | State.Provider_capacity | State.Network_transient; _ })
  | None ->
      Alcotest.fail "a failed attempt was ended or rewritten by the clock"
;;

let test_failed_attempt_delayed_observation_keeps_newer () =
  let newer =
    State.note_failed_attempt ~noted_at:20. ~failure:State.Network_transient
      ~recorded_by:keeper_a State.empty
  in
  let delayed =
    State.note_failed_attempt ~noted_at:10. ~failure:State.Server_error
      ~recorded_by:keeper_b newer
  in
  match delayed.State.failed_attempt with
  | Some (State.Failed_attempt { noted_at; failure = State.Network_transient; recorded_by }) ->
      Alcotest.(check (float 0.)) "newer observation kept" 20. noted_at;
      Alcotest.(check bool) "an older failure does not take over the recorder" true
        (State.same_recorder recorded_by keeper_a)
  | Some (State.Failed_attempt { failure = State.Server_error | State.Provider_capacity | State.Provider_timeout; _ })
  | None ->
      Alcotest.fail "an older failure replaced a newer one"
;;

(* RFC-0458 §3.4 (2026-09-23): the Keeper that saw the candidate fail last is
   the recorder, because its next cycle is the one that tries it again. *)
let test_a_newer_failure_names_its_own_recorder () =
  let first =
    State.note_failed_attempt ~noted_at:10. ~failure:State.Provider_timeout
      ~recorded_by:keeper_a State.empty
  in
  let renewed =
    State.note_failed_attempt ~noted_at:20. ~failure:State.Server_error
      ~recorded_by:keeper_b first
  in
  match renewed.State.failed_attempt with
  | Some (State.Failed_attempt { noted_at; recorded_by; failure = _ }) ->
      Alcotest.(check (float 0.)) "the newer failure is held" 20. noted_at;
      Alcotest.(check bool) "it names the Keeper that saw it" true
        (State.same_recorder recorded_by keeper_b);
      Alcotest.(check bool) "not the earlier one" false
        (State.same_recorder recorded_by keeper_a)
  | None -> Alcotest.fail "the newer failure was dropped"
;;

(* The two observations answer different questions, so neither erases the
   other: a timeout noted after a hinted 429 must not take away the provider's
   time, and that time running out must not take away the timeout. *)
let test_a_rate_limit_and_a_failed_attempt_are_held_independently () =
  let both =
    State.empty
    |> State.note_rate_limit ~noted_at:10. ~retry_after:(Some 5.)
    |> State.note_failed_attempt ~noted_at:12. ~failure:State.Server_error ~recorded_by:keeper_a
  in
  Alcotest.(check bool) "the later failure keeps the hinted rate limit" true
    (Option.is_some (rate_limit_after ~now:14. both));
  let after_hint = State.observe ~now:15. both in
  Alcotest.(check bool) "the hint ends the rate limit" true
    (Option.is_none after_hint.State.rate_limit);
  Alcotest.(check bool) "the failed attempt outlives the hint" true
    (Option.is_some after_hint.State.failed_attempt);
  Alcotest.(check bool) "a cell with a failed attempt is not empty" false
    (State.is_empty after_hint)
;;

(* The cell on a materialized candidate: each observation is held until its
   hint elapses or a success clears it; a success clears both. *)
let test_a_candidate_cell_holds_the_observation_until_success () =
  let candidate =
    Runtime_candidate_backpressure.create_candidate
      ~binding:(Runtime_candidate_backpressure.Http_binding_unavailable "fixture")
  in
  Alcotest.(check bool) "fresh cell observes nothing" true
    (Option.is_none
       (Runtime_candidate_backpressure.candidate_backpressure ~now:0. ~candidate));
  Runtime_candidate_backpressure.note_rate_limit ~candidate ~retry_after:None;
  Alcotest.(check bool) "a no-hint rate limit is held" true
    (Option.is_some
       (Runtime_candidate_backpressure.candidate_backpressure ~now:1e12 ~candidate));
  Runtime_candidate_backpressure.note_candidate_success ~candidate;
  Alcotest.(check bool) "a success clears it" true
    (Option.is_none
       (Runtime_candidate_backpressure.candidate_backpressure ~now:1e12 ~candidate));
  Runtime_candidate_backpressure.note_failed_attempt ~candidate
    ~failure:Runtime_candidate_backpressure.Provider_timeout
    ~recorded_by:(Runtime_candidate_backpressure.keeper_recorder ~keeper_name:"keeper-a");
  Runtime_candidate_backpressure.note_rate_limit ~candidate ~retry_after:(Some 1.);
  Alcotest.(check bool) "a timeout is held after the rate-limit hint elapses" true
    (Option.is_some
       (Runtime_candidate_backpressure.candidate_backpressure ~now:1e12 ~candidate));
  Runtime_candidate_backpressure.note_candidate_success ~candidate;
  Alcotest.(check bool) "a success clears both" true
    (Option.is_none
       (Runtime_candidate_backpressure.candidate_backpressure ~now:1e12 ~candidate))
;;

(* A 429 carrying [Retry-After: 0] names no wait, the same as a 429 with no
   hint. The candidate stays demoted until it answers; the next read must not
   put it back at the head of the walk. *)
let test_a_zero_second_hint_holds_the_rate_limit_until_success () =
  let candidate =
    Runtime_candidate_backpressure.create_candidate
      ~binding:(Runtime_candidate_backpressure.Http_binding_unavailable "fixture")
  in
  Runtime_candidate_backpressure.note_rate_limit ~candidate ~retry_after:(Some 0.);
  Alcotest.(check bool) "a zero-second hint is held like an unstated one" true
    (Option.is_some
       (Runtime_candidate_backpressure.candidate_backpressure ~now:1e12 ~candidate));
  Runtime_candidate_backpressure.note_candidate_success ~candidate;
  Alcotest.(check bool) "a success clears it" true
    (Option.is_none
       (Runtime_candidate_backpressure.candidate_backpressure ~now:1e12 ~candidate))
;;

let () =
  Alcotest.run "runtime_candidate_backpressure"
    [ ( "candidate backpressure"
      , [ Alcotest.test_case "hint expires at provider boundary" `Quick
            test_rate_limit_hint_expires_exactly
        ; Alcotest.test_case "no synthetic expiry" `Quick
            test_rate_limit_without_hint_has_no_synthetic_expiry
        ; Alcotest.test_case "invalid hints remain unknown" `Quick
            test_rate_limit_invalid_hints_do_not_create_deadlines
        ; Alcotest.test_case "delayed observation retains newer hint" `Quick
            test_rate_limit_delayed_observation_keeps_newer_hint
        ; Alcotest.test_case "a failed attempt has no expiry" `Quick
            test_failed_attempt_has_no_expiry
        ; Alcotest.test_case "a delayed failed attempt keeps the newer one" `Quick
            test_failed_attempt_delayed_observation_keeps_newer
        ; Alcotest.test_case "a newer failure names its own recorder" `Quick
            test_a_newer_failure_names_its_own_recorder
        ; Alcotest.test_case "rate limit and failed attempt are independent" `Quick
            test_a_rate_limit_and_a_failed_attempt_are_held_independently
        ; Alcotest.test_case "a candidate cell holds the observation until success" `Quick
            test_a_candidate_cell_holds_the_observation_until_success
        ; Alcotest.test_case "a zero-second hint holds until success" `Quick
            test_a_zero_second_hint_holds_the_rate_limit_until_success
        ] )
    ]
;;
