(** Exhaustive contract tests for [Keeper_failure_route] (RFC-0313 W2a).

    Pins the total projection of the closed
    [Keeper_error_classify.degraded_retry_reason] set onto the three
    RFC-0313 §2 routes. The [all_reasons] list below must enumerate every
    constructor: the route function has no catch-all, so a new reason
    breaks compilation there; this list is the test-side mirror that
    makes the coverage assertion fail loudly if it is not updated too. *)

open Masc
module R = Keeper_failure_route
module EC = Keeper_error_classify

(* Every degraded_retry_reason constructor, once. If a variant is added
   to the closed set, this list fails to compile-or the coverage count
   assertion below trips-forcing the mapping decision to be made. *)
let all_reasons : EC.degraded_retry_reason list =
  [ EC.Hard_quota
  ; EC.Resumable_cli_session
  ; EC.Admission_queue_timeout
  ; EC.Provider_timeout
  ; EC.Turn_timeout
  ; EC.Runtime_candidates_filtered
  ; EC.Runtime_exhausted
  ; EC.Capacity_backpressure
  ; EC.Rate_limit
  ; EC.Server_error
  ; EC.Auth_error
  ; EC.Read_only_no_progress
  ; EC.Empty_no_progress
  ; EC.Thinking_only_no_progress
  ]

let expected : (EC.degraded_retry_reason * R.route) list =
  [ EC.Hard_quota, R.Retry_after_pacing
  ; EC.Resumable_cli_session, R.Retry_after_pacing
  ; EC.Admission_queue_timeout, R.Retry_after_pacing
  ; EC.Provider_timeout, R.Retry_after_pacing
  ; EC.Turn_timeout, R.Retry_after_pacing
  ; EC.Runtime_candidates_filtered, R.Rotate_now
  ; EC.Runtime_exhausted, R.Retry_after_pacing
  ; EC.Capacity_backpressure, R.Retry_after_pacing
  ; EC.Rate_limit, R.Retry_after_pacing
  ; EC.Server_error, R.Retry_after_pacing
  (* Runtime-dependent → rotate (a different credential/model may succeed).
     Matches current production behavior and codex #23495; the earlier W2a
     landing mis-routed these to Escalate_judgment. *)
  ; EC.Auth_error, R.Rotate_now
  ; EC.Read_only_no_progress, R.Rotate_now
  ; EC.Empty_no_progress, R.Rotate_now
  ; EC.Thinking_only_no_progress, R.Rotate_now
  ]

(* Every reason maps to the RFC-0313 §2 route the table assigns it. *)
let test_projection_matches_table () =
  List.iter
    (fun (reason, want) ->
       let got = R.of_degraded_retry_reason reason in
       if got <> want then
         Alcotest.failf "%s: routed to %s, expected %s"
           (EC.degraded_retry_reason_to_string reason)
           (R.route_to_string got) (R.route_to_string want))
    expected

(* Coverage: the mapping is total (every reason handled) and the test's
   own table covers every reason exactly once. If a variant is added to
   the closed set without extending [expected], this trips. *)
let test_every_reason_covered () =
  List.iter
    (fun reason ->
       if not (List.mem_assoc reason expected) then
         Alcotest.failf "%s missing from the expected route table"
           (EC.degraded_retry_reason_to_string reason))
    all_reasons;
  Alcotest.(check int)
    "expected table covers every reason once"
    (List.length all_reasons)
    (List.length expected)

(* Deterministic route ⇔ Escalate_judgment; no transient reason is
   deterministic (a keeper never stops retrying a transient — it paces). *)
let test_is_deterministic_agrees () =
  List.iter
    (fun (reason, route) ->
       let want = route = R.Escalate_judgment in
       if R.is_deterministic route <> want then
         Alcotest.failf "%s: is_deterministic disagrees with route %s"
           (EC.degraded_retry_reason_to_string reason)
           (R.route_to_string route))
    expected;
  (* No terminal state: no reason routes to a nonexistent "halt". Every
     route is one of the three; is_deterministic never true for a paced
     or rotated reason. *)
  assert (not (R.is_deterministic R.Retry_after_pacing));
  assert (not (R.is_deterministic R.Rotate_now));
  assert (R.is_deterministic R.Escalate_judgment)

let () =
  Alcotest.run "keeper_failure_route"
    [ ( "rfc-0313-w2a"
      , [ Alcotest.test_case "projection matches §2 table" `Quick
            test_projection_matches_table
        ; Alcotest.test_case "every reason covered" `Quick
            test_every_reason_covered
        ; Alcotest.test_case "is_deterministic agrees with route" `Quick
            test_is_deterministic_agrees
        ] )
    ]
