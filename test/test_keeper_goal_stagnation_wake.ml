(** RFC-0310 §3.3 — Goal_stagnation detection core.

    Pins [Keeper_goal_stagnation_wake.stagnation_of_goal], the pure predicate
    that decides whether a goal earns a one-shot stagnation wake. The full
    enqueue path (event queue + reaction-ledger episode dedup) rides on the
    same [Goal_store.goal] input; this file fixes the decision so a phase or
    threshold regression is caught without a base-path fixture. *)

open Alcotest

module SW = Masc.Keeper_goal_stagnation_wake

(* A fixed clock so staleness is deterministic. Derived through the same
   parser the producer uses, so the test never depends on hand-computed epoch
   arithmetic. *)
let now =
  match Masc_domain.parse_iso8601_opt "2026-07-08T02:00:00Z" with
  | Some ts -> ts
  | None -> Alcotest.fail "fixture clock failed to parse"

let goal ~phase ~updated_at : Goal_store.goal =
  { Goal_store.id = "goal-1"
  ; title = "Advance the wake redesign"
  ; metric = None
  ; target_value = None
  ; due_date = None
  ; priority = 3
  ; status = Goal_store.Active
  ; phase
  ; verifier_policy = None
  ; require_completion_approval = false
  ; active_verification_request_id = None
  ; parent_goal_id = None
  ; last_review_note = None
  ; last_review_at = None
  ; created_at = "2026-07-01T00:00:00Z"
  ; updated_at
  }

let threshold_sec = 3600.0

(* 3 hours before [now]: comfortably past the 1h threshold. *)
let stale_ts = "2026-07-07T23:00:00Z"

(* 5 minutes before [now]: well inside the threshold. *)
let fresh_ts = "2026-07-08T01:55:00Z"

let is_some = function Some _ -> true | None -> false

let test_stale_executing_goal_wakes () =
  let result =
    SW.stagnation_of_goal ~now ~threshold_sec
      (goal ~phase:Goal_phase.Executing ~updated_at:stale_ts)
  in
  (match result with
   | Some gs ->
     check string "stale_since carries the goal's updated_at" stale_ts
       gs.Keeper_event_queue.gs_stale_since;
     check string "goal id preserved" "goal-1" gs.gs_goal_id
   | None ->
     Alcotest.fail "a stale Executing goal must produce a stagnation episode")

let test_fresh_executing_goal_silent () =
  check bool "a freshly-touched Executing goal does not wake" false
    (is_some
       (SW.stagnation_of_goal ~now ~threshold_sec
          (goal ~phase:Goal_phase.Executing ~updated_at:fresh_ts)))

(* The phase gate: only Executing admits a self-directed stagnation wake.
   Terminal, operator-gated, and awaiting-verdict goals stay silent even when
   long stale, because waking the keeper cannot advance them. *)
let test_non_executing_phases_never_wake () =
  List.iter
    (fun phase ->
      check bool
        (Printf.sprintf "phase %s never wakes on staleness"
           (Goal_phase.to_string phase))
        false
        (is_some
           (SW.stagnation_of_goal ~now ~threshold_sec
              (goal ~phase ~updated_at:stale_ts))))
    [ Goal_phase.Awaiting_verification
    ; Goal_phase.Awaiting_approval
    ; Goal_phase.Blocked
    ; Goal_phase.Paused
    ; Goal_phase.Completed
    ; Goal_phase.Dropped
    ]

(* Fail closed: an unparseable updated_at is undecidable, so it does not wake
   (rather than treating the goal as infinitely stale). *)
let test_unparseable_timestamp_silent () =
  check bool "unparseable updated_at does not wake" false
    (is_some
       (SW.stagnation_of_goal ~now ~threshold_sec
          (goal ~phase:Goal_phase.Executing ~updated_at:"not-a-timestamp")))

(* Exhaustive witness: admits_self_directed_progress is true only for
   Executing across every declared phase. *)
let test_phase_predicate_exhaustive () =
  List.iter
    (fun phase ->
      let expected = phase = Goal_phase.Executing in
      check bool
        (Printf.sprintf "admits_self_directed_progress %s"
           (Goal_phase.to_string phase))
        expected
        (Goal_phase.admits_self_directed_progress phase))
    Goal_phase.all

let () =
  run
    "keeper goal stagnation wake"
    [ ( "stagnation_of_goal"
      , [ test_case "stale Executing goal wakes" `Quick
            test_stale_executing_goal_wakes
        ; test_case "fresh Executing goal stays silent" `Quick
            test_fresh_executing_goal_silent
        ; test_case "non-Executing phases never wake" `Quick
            test_non_executing_phases_never_wake
        ; test_case "unparseable timestamp stays silent" `Quick
            test_unparseable_timestamp_silent
        ; test_case "phase predicate exhaustive" `Quick
            test_phase_predicate_exhaustive
        ] )
    ]
