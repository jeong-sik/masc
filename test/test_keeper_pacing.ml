(** Pure-function unit tests for [Keeper_pacing] (RFC-0313 W1).

    Pins the schedule semantics the TLA+ spec
    (specs/keeper-state-machine/KeeperPacing.tla) verifies in the
    abstract: failure widens one runtime's revisit (bounded by the
    policy cap), success clears it, and a keeper always has a finite
    next-turn due time. *)

open Masc
module KP = Keeper_pacing

(* Fixture pin: mirrors Runtime_schema.pacing_default (base 30s, x2, cap
   3600s). The asserted schedules below are derived from these numbers. *)
let policy = { KP.base_sec = 30.0; multiplier = 2.0; cap_sec = 3600.0 }
let feq = Alcotest.(check (float 1e-6))

let revisit_exn t runtime_id =
  match KP.revisit_of ~runtime_id t with
  | Some r -> r
  | None -> Alcotest.failf "expected revisit entry for %s" runtime_id

let test_failure_widens_exponentially () =
  let t = KP.empty in
  let t = KP.on_failure ~policy ~runtime_id:"a" ~retry_after:None ~now:100.0 t in
  feq "first failure: base delay" 130.0 (revisit_exn t "a").eligible_at;
  let t = KP.on_failure ~policy ~runtime_id:"a" ~retry_after:None ~now:130.0 t in
  feq "second failure: doubled" 190.0 (revisit_exn t "a").eligible_at;
  let t = KP.on_failure ~policy ~runtime_id:"a" ~retry_after:None ~now:190.0 t in
  feq "third failure: doubled again" 310.0 (revisit_exn t "a").eligible_at;
  Alcotest.(check int) "consecutive tracked" 3 (revisit_exn t "a").consecutive

let test_delay_never_exceeds_cap () =
  let t =
    List.fold_left
      (fun t now -> KP.on_failure ~policy ~runtime_id:"a" ~retry_after:None ~now t)
      KP.empty
      [ 0.0; 1.0; 2.0; 3.0; 4.0; 5.0; 6.0; 7.0; 8.0; 9.0; 10.0 ]
  in
  let r = revisit_exn t "a" in
  Alcotest.(check bool)
    "eligible_at bounded by now + cap"
    true
    (r.eligible_at <= 10.0 +. policy.cap_sec)

let test_retry_after_wins_and_is_clamped () =
  let t = KP.on_failure ~policy ~runtime_id:"a" ~retry_after:(Some 300.0) ~now:0.0 KP.empty in
  feq "provider hint replaces computed delay" 300.0 (revisit_exn t "a").eligible_at;
  let t = KP.on_failure ~policy ~runtime_id:"b" ~retry_after:(Some 999999.0) ~now:0.0 KP.empty in
  feq "hint clamped to cap" policy.cap_sec (revisit_exn t "b").eligible_at;
  let t = KP.on_failure ~policy ~runtime_id:"c" ~retry_after:(Some (-5.0)) ~now:0.0 KP.empty in
  feq "negative hint clamped to zero" 0.0 (revisit_exn t "c").eligible_at

let test_failure_touches_only_that_runtime () =
  let t = KP.on_failure ~policy ~runtime_id:"a" ~retry_after:None ~now:0.0 KP.empty in
  Alcotest.(check bool) "other runtime has no entry" true (KP.revisit_of ~runtime_id:"b" t = None)

let test_success_clears_runtime () =
  let t = KP.on_failure ~policy ~runtime_id:"a" ~retry_after:None ~now:0.0 KP.empty in
  let t = KP.on_failure ~policy ~runtime_id:"b" ~retry_after:None ~now:0.0 t in
  let t = KP.on_success ~runtime_id:"a" t in
  Alcotest.(check bool) "cleared runtime eligible now" true (KP.revisit_of ~runtime_id:"a" t = None);
  Alcotest.(check bool) "other runtime keeps its revisit" true (KP.revisit_of ~runtime_id:"b" t <> None)

let test_next_turn_due_prefers_eligible_runtime () =
  let t = KP.on_failure ~policy ~runtime_id:"a" ~retry_after:None ~now:0.0 KP.empty in
  feq "unpaced catalog runtime is due now" 5.0 (KP.next_turn_due ~catalog:[ "a"; "b" ] ~now:5.0 t)

let test_next_turn_due_min_when_all_paced () =
  let t = KP.on_failure ~policy ~runtime_id:"a" ~retry_after:(Some 100.0) ~now:0.0 KP.empty in
  let t = KP.on_failure ~policy ~runtime_id:"b" ~retry_after:(Some 40.0) ~now:0.0 t in
  feq "min eligible_at wins" 40.0 (KP.next_turn_due ~catalog:[ "a"; "b" ] ~now:5.0 t);
  feq "expired deadline is due now" 45.0 (KP.next_turn_due ~catalog:[ "a"; "b" ] ~now:45.0 t)

let test_next_turn_due_always_finite () =
  feq "empty catalog is due now" 7.0 (KP.next_turn_due ~catalog:[] ~now:7.0 KP.empty);
  feq "empty state is due now" 7.0 (KP.next_turn_due ~catalog:[ "a" ] ~now:7.0 KP.empty)

let test_shadow_snapshot_isolated_by_keeper () =
  (* Keeper_pacing_shadow guards its table with Eio.Mutex.use_rw
     ~protect:true, which needs a fiber context even when uncontended —
     without Eio_main.run this raised
     Effect.Unhandled(Cancel.Get_context) on main (2026-07-07). *)
  Eio_main.run
  @@ fun _env ->
  let keeper_name = "test-keeper-pacing-shadow-isolated" in
  Alcotest.(check int)
    "unknown keeper snapshot is empty"
    0
    (List.length (Keeper_pacing_shadow.snapshot ~keeper_name))

let test_shadow_next_due_uses_observed_failures_only () =
  Eio_main.run
  @@ fun _env ->
  let keeper_name = "test-keeper-pacing-shadow-observed-failures-only" in
  Keeper_pacing_shadow.observe_failure
    ~keeper_name
    ~runtime_id:"observed-runtime"
    ~retry_after:(Some 30.0);
  match Keeper_pacing_shadow.next_due_remaining ~keeper_name with
  | Some remaining ->
    Alcotest.(check bool)
      "observed failure blocks despite unrelated catalog entries"
      true
      (remaining > 0.0)
  | None -> Alcotest.fail "observed pending failure should pace next turn"

let test_shadow_exact_runtime_ignores_other_failure () =
  Eio_main.run
  @@ fun _env ->
  let keeper_name = "test-keeper-pacing-shadow-exact-runtime" in
  Keeper_pacing_shadow.observe_failure
    ~keeper_name
    ~runtime_id:"failed-keeper-runtime"
    ~retry_after:(Some 30.0);
  Alcotest.(check bool)
    "unobserved judge runtime is immediately eligible"
    true
    (Option.is_none
       (Keeper_pacing_shadow.remaining_for_runtime
          ~keeper_name
          ~runtime_id:"structured-judge"));
  Keeper_pacing_shadow.observe_failure
    ~keeper_name
    ~runtime_id:"structured-judge"
    ~retry_after:(Some 30.0);
  match
    Keeper_pacing_shadow.remaining_for_runtime
      ~keeper_name
      ~runtime_id:"structured-judge"
  with
  | Some remaining ->
    Alcotest.(check bool)
      "judge failure paces the exact judge runtime"
      true
      (remaining > 0.0)
  | None -> Alcotest.fail "judge runtime failure did not retain pacing"

let test_failure_judgment_claim_uses_exact_judge_pacing () =
  Eio_main.run
  @@ fun _env ->
  let keeper_name = "test-failure-judgment-claim-pacing" in
  let judge_runtime_id =
    match Keeper_failure_judge.resolve_runtime_id () with
    | Ok runtime_id -> runtime_id
    | Error error ->
      Alcotest.failf
        "structured judge runtime fixture: %s"
        (Keeper_failure_judge.error_detail error)
  in
  Keeper_pacing_shadow.observe_failure
    ~keeper_name
    ~runtime_id:"unrelated-failed-runtime"
    ~retry_after:(Some 30.0);
  (match Keeper_failure_judge.claim_eligibility ~keeper_name with
   | Keeper_failure_judge.Claim_eligible -> ()
   | Keeper_failure_judge.Claim_deferred_by_runtime_pacing _ ->
     Alcotest.fail "unrelated runtime pacing deferred the judgment claim");
  Keeper_pacing_shadow.observe_failure
    ~keeper_name
    ~runtime_id:judge_runtime_id
    ~retry_after:(Some 30.0);
  match Keeper_failure_judge.claim_eligibility ~keeper_name with
  | Keeper_failure_judge.Claim_deferred_by_runtime_pacing
      { runtime_id; remaining_seconds } ->
    Alcotest.(check string) "exact judge runtime" judge_runtime_id runtime_id;
    Alcotest.(check bool) "positive remaining pacing" true (remaining_seconds > 0.0)
  | Keeper_failure_judge.Claim_eligible ->
    Alcotest.fail "paced judge runtime remained claim-eligible"

let () =
  Alcotest.run
    "keeper_pacing"
    [ ( "on_failure"
      , [ Alcotest.test_case "widens exponentially" `Quick test_failure_widens_exponentially
        ; Alcotest.test_case "delay capped" `Quick test_delay_never_exceeds_cap
        ; Alcotest.test_case "retry_after wins, clamped" `Quick test_retry_after_wins_and_is_clamped
        ; Alcotest.test_case "touches only that runtime" `Quick test_failure_touches_only_that_runtime
        ] )
    ; ( "on_success"
      , [ Alcotest.test_case "clears runtime" `Quick test_success_clears_runtime ] )
    ; ( "next_turn_due"
      , [ Alcotest.test_case "prefers eligible runtime" `Quick test_next_turn_due_prefers_eligible_runtime
        ; Alcotest.test_case "min when all paced" `Quick test_next_turn_due_min_when_all_paced
        ; Alcotest.test_case "always finite" `Quick test_next_turn_due_always_finite
        ] )
    ; ( "shadow"
      , [ Alcotest.test_case "snapshot isolated by keeper" `Quick test_shadow_snapshot_isolated_by_keeper
        ; Alcotest.test_case
            "next due uses observed failures only"
            `Quick
            test_shadow_next_due_uses_observed_failures_only
        ; Alcotest.test_case
            "exact runtime ignores other failure"
            `Quick
            test_shadow_exact_runtime_ignores_other_failure
        ; Alcotest.test_case
            "failure judgment claim pacing"
            `Quick
            test_failure_judgment_claim_uses_exact_judge_pacing
        ] )
    ]
