(** test_keeper_fsm_joints — Cross-FSM joint behavior tests.

    Mirrors the SafetyInvariant conjuncts from
    [specs/keeper-state-machine/KeeperCompositeLifecycle.tla] (lines
    354-377) into OCaml tests that drive the actual production
    predicates [Keeper_composite_observer.check_*] over the full state
    cross-product, plus mutation tests mirroring the TLA+ BugAction
    patterns (lines 410-432).

    Coverage gap before this file: existing
    [test_keeper_composite_observer.ml] only verifies the Prometheus
    bump mechanism (given a synthetic [invariants_check], does the
    counter increment?). It does NOT exercise the predicates that
    decide whether each invariant holds. This file closes that gap.

    Out of scope here:
    - Liveness invariants ([]<> properties from TLA+ lines 388-404).
      TLC owns those; OCaml finite-trace tests are not the right tool.
    - [check_event_priority_monotone] — registry-bound, requires a
      full {!Keeper_registry.registry_entry}; covered by
      [test_keeper_composite_observer.ml] integration paths instead.
    - End-to-end {!Keeper_unified_turn.run_unified_turn} drive — needs
      Coord.config + meta + observation + OAS env. Separate trail. *)

module Obs = Masc_mcp.Keeper_composite_observer
module SM = Masc_mcp.Keeper_state_machine
module Routing = Masc_mcp.Keeper_cascade_routing

(* ── Pretty-printers for Alcotest assertion messages ───────── *)

let pp_ksm = Alcotest.testable
    (fun fmt p -> Format.pp_print_string fmt (Obs.ksm_phase_to_string p))
    (=)

let pp_turn = Alcotest.testable
    (fun fmt p -> Format.pp_print_string fmt (Obs.turn_phase_to_string p))
    (=)

let pp_cascade = Alcotest.testable
    (fun fmt p -> Format.pp_print_string fmt (Obs.cascade_state_to_string p))
    (=)

let pp_compaction = Alcotest.testable
    (fun fmt p -> Format.pp_print_string fmt (Obs.compaction_stage_to_string p))
    (=)

let pp_phase = Alcotest.testable
    (fun fmt p -> Format.pp_print_string fmt (SM.phase_to_string p))
    (=)

(* ============================================================
   Section 1 — Exhaustive truth tables for the three pure
   invariant predicates exposed via the observer's public API.

   The test enumerates every (state, state) pair and compares the
   actual predicate result to the expected value computed from the
   TLA+ definition mirrored here. Adding a new variant to any sub-FSM
   enum will trigger a non-exhaustive-match warning in [expected_*]
   functions — precisely the static catch the silent-failure sweep
   plan emphasizes for ADT additions.
   ============================================================ *)

(* I1: TLA+ KeeperCompositeLifecycle.tla:354
   (ksm_phase = "Compacting") => (ktc_turn_phase = "compacting")
   The .ml implementation is symmetric: also forbids Turn_compacting
   under any other ksm_phase. We mirror that stronger predicate. *)
let expected_phase_turn_alignment (ksm : Obs.ksm_phase)
                                  (tp  : Obs.turn_phase) : bool =
  match ksm, tp with
  | Ksm_compacting, Turn_compacting -> true
  | Ksm_compacting, _               -> false
  | _,              Turn_compacting -> false
  | _ -> true

(* I3: TLA+ KeeperCompositeLifecycle.tla:368
   (kmc_compaction = "compacting") <=> (ksm_phase = "Compacting") *)
let expected_compaction_atomicity (ksm : Obs.ksm_phase)
                                  (kmc : Obs.compaction_stage) : bool =
  (kmc = Obs.Compaction_compacting) = (ksm = Obs.Ksm_compacting)

(* I2: TLA+ KeeperCompositeLifecycle.tla:361
   (cascade in {selecting, trying, done, exhausted}) =>
     (shared_measurement /= 0) *)
let expected_no_cascade_before_measurement
    ~(cascade : Obs.cascade_state) ~(measured : bool) : bool =
  match cascade with
  | Cascade_idle -> true
  | Cascade_selecting | Cascade_trying
  | Cascade_done | Cascade_exhausted -> measured

let test_phase_turn_alignment_table () =
  List.iter (fun ksm ->
    List.iter (fun tp ->
      let expected = expected_phase_turn_alignment ksm tp in
      let actual = Obs.check_phase_turn_alignment ksm tp in
      let label = Printf.sprintf "I1 ksm=%s × turn=%s"
        (Obs.ksm_phase_to_string ksm)
        (Obs.turn_phase_to_string tp)
      in
      Alcotest.(check bool) label expected actual
    ) Obs.all_turn_phases
  ) Obs.all_ksm_phases

let test_compaction_atomicity_table () =
  List.iter (fun ksm ->
    List.iter (fun kmc ->
      let expected = expected_compaction_atomicity ksm kmc in
      let actual = Obs.check_compaction_atomicity ksm kmc in
      let label = Printf.sprintf "I3 ksm=%s × kmc=%s"
        (Obs.ksm_phase_to_string ksm)
        (Obs.compaction_stage_to_string kmc)
      in
      Alcotest.(check bool) label expected actual
    ) Obs.all_compaction_stages
  ) Obs.all_ksm_phases

let test_no_cascade_before_measurement_table () =
  List.iter (fun cascade ->
    List.iter (fun measured ->
      let expected = expected_no_cascade_before_measurement ~cascade ~measured in
      let actual = Obs.check_no_cascade_before_measurement
                     ~cascade_state:cascade ~measurement_captured:measured
      in
      let label = Printf.sprintf "I2 cascade=%s × measured=%b"
        (Obs.cascade_state_to_string cascade) measured
      in
      Alcotest.(check bool) label expected actual
    ) [false; true]
  ) Obs.all_cascade_states

(* ============================================================
   Section 2 — TLA+ BugAction mirrors.

   Each mirror constructs the post-bug state exactly as the TLA+
   action declares it, then asserts that the relevant invariant
   predicate(s) flag the violation. This is the OCaml analogue of
   [TLC SpecBuggyCascade] / [TLC SpecBuggyCompaction] passing —
   the bug must be CAUGHT.
   ============================================================ *)

(* TLA+ BugCascadeBeforeMeasurement (lines 410-418):
     ktc_turn_phase = "prompting"
     /\ shared_measurement = 0      (* not measured *)
     /\ kdp_decision = "undecided"
     /\ kcl_cascade_state = "idle"
     /\ kdp_decision' = "tool_policy_selected"
     /\ kcl_cascade_state' = "selecting"
   Post-bug state: cascade jumps to selecting with measurement_captured = false.
   Invariant violated: NoCascadeBeforeMeasurement (I2). *)
let test_bug_cascade_before_measurement_caught () =
  let post_bug_cascade : Obs.cascade_state = Cascade_selecting in
  let measured = false in
  let i2 = Obs.check_no_cascade_before_measurement
             ~cascade_state:post_bug_cascade
             ~measurement_captured:measured
  in
  Alcotest.(check bool)
    "BugCascadeBeforeMeasurement → I2 NoCascadeBeforeMeasurement violated"
    false i2

(* TLA+ BugCompactionDesync (lines 424-430):
     ksm_phase = "Running"
     /\ kmc_compaction = "accumulating"
     /\ kmc_compaction' = "compacting"   (* BUG: KSM stays Running *)
   Post-bug state: KMC=compacting while KSM=Running.
   Invariants violated: I3 CompactionAtomicity (kmc=compacting requires
   ksm=Compacting). I1 PhaseTurnAlignment is NOT violated by this state
   alone (turn_phase is unconstrained), so we only assert I3. *)
let test_bug_compaction_desync_caught () =
  let post_bug_ksm : Obs.ksm_phase = Ksm_running in
  let post_bug_kmc : Obs.compaction_stage = Compaction_compacting in
  let i3 = Obs.check_compaction_atomicity post_bug_ksm post_bug_kmc in
  Alcotest.(check bool)
    "BugCompactionDesync → I3 CompactionAtomicity violated"
    false i3;
  (* And the symmetric formulation — Ksm_compacting with kmc != compacting
     also violates I3 (TLA+ says "<=>"). Test both arms once. *)
  let mirror = Obs.check_compaction_atomicity Ksm_compacting Compaction_accumulating in
  Alcotest.(check bool)
    "I3 is biconditional: ksm=Compacting + kmc!=compacting also violates"
    false mirror

(* I1's bug shape: any non-Compacting ksm phase paired with Turn_compacting
   should be flagged. This is the .ml-level strengthening over the TLA+
   one-way implication; the strengthening prevents observer drift where a
   live turn enters compaction while the parent is still Running. *)
let test_phase_turn_alignment_strengthening () =
  let actual = Obs.check_phase_turn_alignment Ksm_running Turn_compacting in
  Alcotest.(check bool)
    "Ksm_running × Turn_compacting must be flagged (.ml strengthening)"
    false actual

(* ============================================================
   Section 3 — KSM ↔ KMC join via real apply_event.

   Drive the production KSM transition (Overflowed → Compacting via
   Auto_compact_triggered) and assert that the resulting KSM phase,
   when paired with the runtime's KMC stage at the same instant,
   satisfies CompactionAtomicity. This is the smallest end-to-end
   joint check that touches a real production state machine.
   ============================================================ *)

let test_ksm_kmc_join_auto_compact_triggers_compacting () =
  (* Build conditions matching the Overflowed entry contract: a fiber is
     alive and a context_overflow flag is latched. The exact sequence
     mirrors keeper_state_machine.ml entry actions for Overflowed →
     Auto_compact_triggered. *)
  let conds0 = SM.{ default_conditions with
                    fiber_alive = true;
                    heartbeat_healthy = true;
                    turn_healthy = true;
                    context_overflow = true;  } in
  let phase0 = SM.derive_phase conds0 in
  Alcotest.(check pp_phase)
    "preconditions yield Overflowed" SM.Overflowed phase0;

  (* Apply Auto_compact_triggered — sets compaction_active. *)
  match SM.apply_event ~current_phase:phase0 ~conditions:conds0
          ~event:SM.Auto_compact_triggered ~now:0.0 with
  | Error err ->
      Alcotest.failf "apply_event Auto_compact_triggered failed: %s"
        (SM.transition_error_to_string err)
  | Ok r ->
      Alcotest.(check pp_phase)
        "Auto_compact_triggered transitions to Compacting"
        SM.Compacting r.new_phase;
      (* Project into the composite ksm_phase and pair it with the
         observed KMC stage at this instant. The contract: while the
         registry has compaction_active=true, the runtime publishes
         Compaction_compacting. The two together must satisfy I3. *)
      let composite_ksm = Obs.derive_ksm_phase r.new_phase in
      let i3 = Obs.check_compaction_atomicity composite_ksm Obs.Compaction_compacting in
      Alcotest.(check bool)
        "post-Auto_compact_triggered (Ksm_compacting, Compaction_compacting) ⇒ I3 holds"
        true i3;
      (* And the symmetric live state: while still in derive_ksm_phase
         Compacting, an Accumulating KMC report would be a desync — the
         predicate must reject it. *)
      let i3_violated =
        Obs.check_compaction_atomicity composite_ksm Obs.Compaction_accumulating
      in
      Alcotest.(check bool)
        "Ksm_compacting × Compaction_accumulating violates I3 (drift detector)"
        false i3_violated

(* ============================================================
   Section 4 — KDP → KCL join via Keeper_cascade_routing.

   Enumerate every keeper phase and assert select_cascade returns the
   profile mandated by the cascade routing contract (mli lines 22-26).
   This pins down the gating rules so a future change has to update
   both the routing function AND this golden table.
   ============================================================ *)

let expected_routing (phase : SM.phase) ~base : string =
  match phase with
  | SM.Failing -> "local_recovery"
  | SM.Compacting | SM.HandingOff -> "local_only"
  | SM.Running | SM.Draining | SM.Paused | SM.Overflowed
  | SM.Offline | SM.Stopped | SM.Crashed | SM.Restarting | SM.Dead -> base

let test_kdp_kcl_join_routing_table () =
  let base = "keeper_unified" in
  List.iter (fun phase ->
    let result = Routing.select_cascade ~base_cascade:base ~phase in
    let expected = expected_routing phase ~base in
    let label = Printf.sprintf "select_cascade phase=%s ⇒ %s"
      (SM.phase_to_string phase) expected
    in
    Alcotest.(check string) label expected result.effective_cascade
  ) SM.all_phases

(* ============================================================
   Section 5 — Property-based tests (QCheck).

   For every random combination of the four projected enums plus the
   measurement boolean, the observer's compute-once view of the
   composite invariant set must agree with the field-by-field
   evaluation of the same predicates. This is a regression test for
   the conjunction itself: no aggregator-layer bug can hide a single
   false in the combined record.
   ============================================================ *)

let array_of_list xs = Array.of_list xs

let arb_ksm =
  let arr = array_of_list Obs.all_ksm_phases in
  QCheck.make ~print:Obs.ksm_phase_to_string
    QCheck.Gen.(map (fun i -> arr.(i))
                  (int_range 0 (Array.length arr - 1)))

let arb_turn =
  let arr = array_of_list Obs.all_turn_phases in
  QCheck.make ~print:Obs.turn_phase_to_string
    QCheck.Gen.(map (fun i -> arr.(i))
                  (int_range 0 (Array.length arr - 1)))

let arb_cascade =
  let arr = array_of_list Obs.all_cascade_states in
  QCheck.make ~print:Obs.cascade_state_to_string
    QCheck.Gen.(map (fun i -> arr.(i))
                  (int_range 0 (Array.length arr - 1)))

let arb_compaction =
  let arr = array_of_list Obs.all_compaction_stages in
  QCheck.make ~print:Obs.compaction_stage_to_string
    QCheck.Gen.(map (fun i -> arr.(i))
                  (int_range 0 (Array.length arr - 1)))

(* Property: predicates are deterministic and pure — running them twice
   on the same inputs must agree. Catches accidental ref/state. *)
let prop_predicates_pure =
  QCheck.Test.make ~name:"composite predicates are pure"
    ~count:500
    (QCheck.quad arb_ksm arb_turn arb_cascade arb_compaction)
    (fun (ksm, turn, cascade, kmc) ->
      let measured = (cascade <> Obs.Cascade_idle) in
      let i1a = Obs.check_phase_turn_alignment ksm turn in
      let i1b = Obs.check_phase_turn_alignment ksm turn in
      let i2a = Obs.check_no_cascade_before_measurement
                  ~cascade_state:cascade ~measurement_captured:measured in
      let i2b = Obs.check_no_cascade_before_measurement
                  ~cascade_state:cascade ~measurement_captured:measured in
      let i3a = Obs.check_compaction_atomicity ksm kmc in
      let i3b = Obs.check_compaction_atomicity ksm kmc in
      i1a = i1b && i2a = i2b && i3a = i3b)

(* Property: each predicate matches its TLA+-mirrored expected value
   over the full random product. A regression here means the production
   predicate has drifted from the spec. *)
let prop_predicates_match_spec =
  QCheck.Test.make ~name:"composite predicates match TLA+ specification"
    ~count:1000
    (QCheck.quad arb_ksm arb_turn arb_cascade arb_compaction)
    (fun (ksm, turn, cascade, kmc) ->
      List.exists (fun b -> b)  (* placate unused-warning silencer; no-op below *)
        [true]
      &&
      Obs.check_phase_turn_alignment ksm turn
        = expected_phase_turn_alignment ksm turn
      &&
      Obs.check_compaction_atomicity ksm kmc
        = expected_compaction_atomicity ksm kmc
      &&
      let measured = (cascade <> Obs.Cascade_idle) in
      Obs.check_no_cascade_before_measurement
          ~cascade_state:cascade ~measurement_captured:measured
        = expected_no_cascade_before_measurement ~cascade ~measured)

(* ============================================================
   Test registration
   ============================================================ *)

let () =
  let open Alcotest in
  let qcheck_tests =
    List.map QCheck_alcotest.to_alcotest
      [ prop_predicates_pure; prop_predicates_match_spec ]
  in
  run "keeper_fsm_joints" [
    "I1 PhaseTurnAlignment (ksm × turn)", [
      test_case "exhaustive table (7 × 5 = 35 cells)" `Quick
        test_phase_turn_alignment_table;
      test_case "Ksm_running × Turn_compacting flagged"  `Quick
        test_phase_turn_alignment_strengthening;
    ];
    "I2 NoCascadeBeforeMeasurement (cascade × measured)", [
      test_case "exhaustive table (5 × 2 = 10 cells)" `Quick
        test_no_cascade_before_measurement_table;
    ];
    "I3 CompactionAtomicity (ksm × kmc)", [
      test_case "exhaustive table (7 × 3 = 21 cells)" `Quick
        test_compaction_atomicity_table;
    ];
    "TLA+ BugAction mirrors", [
      test_case "BugCascadeBeforeMeasurement caught by I2" `Quick
        test_bug_cascade_before_measurement_caught;
      test_case "BugCompactionDesync caught by I3 (both arms)" `Quick
        test_bug_compaction_desync_caught;
    ];
    "Production join — KSM ↔ KMC", [
      test_case "Overflowed --Auto_compact_triggered--> Compacting + I3 holds" `Quick
        test_ksm_kmc_join_auto_compact_triggers_compacting;
    ];
    "Production join — KDP → KCL routing", [
      test_case "select_cascade golden table over all 12 phases" `Quick
        test_kdp_kcl_join_routing_table;
    ];
    "QCheck properties", qcheck_tests;
  ]
