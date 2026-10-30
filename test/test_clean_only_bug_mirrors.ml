(** Tests mirroring TLA+ Bug Models for clean-only specs that gained
    buggy.cfg counterparts in this PR.

    Each test reconstructs the post-bug state declared in TLA+ and
    asserts that the corresponding invariant predicate flags the
    violation.  This is the OCaml analogue of [TLC SpecBuggy] reporting
    the invariant violated.

    Helper predicates are inlined here (not added to production
    modules) — the goal is spec parity verification, not runtime
    enforcement.  Where a production guard already exists (e.g.,
    Keeper_composite_observer), that pattern is preferred. *)

(* ============================================================
   2. KeeperTraceSpec / BugDerivePhaseMismatch
   ============================================================ *)

type derived_phase =
  | Phase_offline
  | Phase_running
  | Phase_failing
  | Phase_draining
  | Phase_paused
  | Phase_stopped
  | Phase_crashed
  | Phase_restarting
  | Phase_dead

(* TLA+ DerivePhaseAgreement == recorded_phase = DerivePhase *)
let check_derive_phase_agreement
    ~(recorded_phase : derived_phase)
    ~(derived_phase : derived_phase)
  =
  recorded_phase = derived_phase
;;

let test_bug_derive_phase_mismatch_caught () =
  let invariant_holds =
    check_derive_phase_agreement
      ~recorded_phase:Phase_running
      ~derived_phase:Phase_offline
  in
  Alcotest.(check bool)
    "DerivePhaseAgreement violated by BugDerivePhaseMismatch"
    false
    invariant_holds
;;

(* ── Test runner ─────────────────────────────────────────── *)
let () =
  Alcotest.run
    "Clean_only_bug_mirrors"
    [ ( "KeeperTraceSpec"
      , [ Alcotest.test_case
            "BugDerivePhaseMismatch caught"
            `Quick
            test_bug_derive_phase_mismatch_caught
        ] )
    ]
;;
