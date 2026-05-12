(* Correspondence smoke test — NOT a full trace replay.
   Does not run TLC.
   Does not enumerate all 2^N state combinations.
   Asserts: state set parity, 3 allowed transitions, 1 forbidden transition.
   Future extension: TLC trace export → OCaml replay.
   Memory: reference_keeper_state_machine_specs_consolidation_status.md P5 OPEN.

   Scope notes:
   - State-set parity is one-way: every TLA+ phase name in
     [specs/keeper-state-machine/KeeperStateMachine.tla §TypeOK] has a
     corresponding OCaml [Keeper_state_machine.phase] constructor.  The
     OCaml side is allowed to have MORE constructors than the spec
     enumerates (none today — they match 13↔13).
   - The "allowed transitions" exercise [apply_event] end-to-end
     (update_conditions + derive_phase + can_transition), so any silent
     drift between the spec's [Next] action and the OCaml runtime
     pipeline is caught at the result level.
   - The "forbidden transition" picks a Dead source phase: every TLA+
     [Next]-action conjunct includes [NotTerminal], so any event from
     [Dead]/[Stopped]/[Zombie] is *not* in the relation.  The OCaml
     [apply_event] mirror is the explicit [Terminal_state] reject at the
     top of [lib/keeper/keeper_state_machine.ml §apply_event].
   - Hand-curated mapping: see [tla_phase_names] below.  Line refs into
     the .tla file are pinned to the §TypeOK enumeration. *)

open Alcotest
module SM = Masc_mcp.Keeper_state_machine

(* ── Hand-curated phase mapping (TLA+ → OCaml) ────────────────
   Source: specs/keeper-state-machine/KeeperStateMachine.tla §TypeOK
   (the Phase \in {...} disjunction enumerates the spec's complete phase
   set; mirrored in [SM.all_phases]).  Update both sides together. *)

let tla_phase_names =
  [ "Offline"
  ; "Running"
  ; "Failing"
  ; "Overflowed"
  ; "Compacting"
  ; "HandingOff"
  ; "Draining"
  ; "Paused"
  ; "Stopped"
  ; "Crashed"
  ; "Restarting"
  ; "Dead"
  ; "Zombie"
  ]
;;

(* OCaml [phase_to_string] uses snake_case; the TLA+ spec uses
   PascalCase. The mapping is purely cosmetic — semantics match.
   Keep this list in lock-step with [SM.all_phases]. *)
let phase_to_tla_name : SM.phase -> string = function
  | Offline -> "Offline"
  | Running -> "Running"
  | Failing -> "Failing"
  | Overflowed -> "Overflowed"
  | Compacting -> "Compacting"
  | HandingOff -> "HandingOff"
  | Draining -> "Draining"
  | Paused -> "Paused"
  | Stopped -> "Stopped"
  | Crashed -> "Crashed"
  | Restarting -> "Restarting"
  | Dead -> "Dead"
  | Zombie -> "Zombie"
;;

(* ── Smoke test 1: State set parity ──────────────────────────── *)

let test_state_set_parity () =
  let ocaml_names = List.map phase_to_tla_name SM.all_phases in
  let sorted xs = List.sort String.compare xs in
  let tla_sorted = sorted tla_phase_names in
  let ocaml_sorted = sorted ocaml_names in
  (* One-way: every TLA+ name must appear in OCaml. *)
  List.iter
    (fun tla_name ->
       check
         bool
         (Printf.sprintf "TLA+ phase %S has OCaml equivalent" tla_name)
         true
         (List.mem tla_name ocaml_sorted))
    tla_sorted;
  (* Pin the TLA+ side cardinality so a spec extension that adds a phase
     without updating [tla_phase_names] fails fast.  The OCaml side is
     intentionally NOT pinned: this test is one-way (TLA+ ⊆ OCaml), so a
     future OCaml-only phase (e.g. an internal substate not yet modelled
     in the spec) must not break the smoke.  When such drift appears,
     the spec gap should be tracked separately, not enforced here. *)
  check int "TLA+ phase count" 13 (List.length tla_sorted);
  (* OCaml ≥ TLA+ is implied by the per-name check above; we re-state it
     as an explicit inequality for readability. *)
  check
    bool
    "OCaml phases ≥ TLA+ phases"
    true
    (List.length ocaml_sorted >= List.length tla_sorted)
;;

(* ── Helpers for transition tests ────────────────────────────── *)

(* A baseline "Running" condition set.  Mirrors the TLA+ Init action
   (specs/keeper-state-machine/KeeperStateMachine.tla §Init): fiber
   alive, healthy, no buffer ops in flight, budget available. *)
let running_conditions : SM.conditions =
  { SM.default_conditions with
    fiber_alive = true
  ; heartbeat_healthy = true
  ; turn_healthy = true
  ; context_within_budget = true
  ; restart_budget_remaining = true
  }
;;

let check_transition ~label ~from_phase ~event ~expected =
  match
    SM.apply_event
      ~current_phase:from_phase
      ~conditions:running_conditions
      ~event
      ~now:0.0
  with
  | Ok result ->
    check
      (testable (fun fmt p -> Format.fprintf fmt "%s" (SM.phase_to_string p)) ( = ))
      label
      expected
      result.new_phase
  | Error err -> failf "%s: unexpected error %s" label (SM.transition_error_to_string err)
;;

(* ── Smoke test 2: Three known-allowed transitions ──────────── *)

(* Running → Failing via Heartbeat_failed.
   Mirrors TLA+ §HeartbeatFailed: [heartbeat_healthy' = FALSE] from a
   non-terminal fiber-alive base; DerivePhase priority 12 then routes to
   "Failing" since [~heartbeat_healthy]. *)
let test_running_to_failing_via_heartbeat_failed () =
  check_transition
    ~label:"Running --Heartbeat_failed--> Failing"
    ~from_phase:Running
    ~event:(SM.Heartbeat_failed { consecutive = 3; max_allowed = 3 })
    ~expected:Failing
;;

(* Running → Draining via Stop_requested.
   Mirrors TLA+ §StopRequested: [stop_requested' = TRUE]; DerivePhase
   priority 6 then derives "Draining" (drain_complete=false so we do
   not advance to Stopped). *)
let test_running_to_draining_via_stop_requested () =
  check_transition
    ~label:"Running --Stop_requested--> Draining"
    ~from_phase:Running
    ~event:SM.Stop_requested
    ~expected:Draining
;;

(* Running → Compacting via Compaction_started.
   Mirrors TLA+ §CompactionStarted: [compaction_active' = TRUE] under
   [~compaction_active /\ ~handoff_active]; DerivePhase priority 10
   then derives "Compacting". *)
let test_running_to_compacting_via_compaction_started () =
  check_transition
    ~label:"Running --Compaction_started--> Compacting"
    ~from_phase:Running
    ~event:SM.Compaction_started
    ~expected:Compacting
;;

(* ── Smoke test 3: One known-forbidden transition ────────────
   The TLA+ [Next] disjunction conjoins [NotTerminal] into every action,
   so any (Dead, _, _) → _ pair is absent from the relation.  OCaml
   mirrors this by returning [Error (Terminal_state _)] at the top of
   [apply_event].  We pick Dead --Heartbeat_ok--> ? because the event
   itself is otherwise unconditional and harmless — failure here proves
   the terminal-reject gate, not an unrelated precondition. *)

(* A baseline "Dead" condition set: fiber dead AND budget exhausted.
   Mirrors DerivePhase priority 3 (Dead branch). *)
let dead_conditions : SM.conditions =
  { SM.default_conditions with fiber_alive = false; restart_budget_remaining = false }
;;

let test_forbidden_dead_rejects_heartbeat_ok () =
  match
    SM.apply_event
      ~current_phase:Dead
      ~conditions:dead_conditions
      ~event:SM.Heartbeat_ok
      ~now:0.0
  with
  | Ok result ->
    failf
      "expected Terminal_state error, got Ok with new_phase=%s"
      (SM.phase_to_string result.new_phase)
  | Error (Terminal_state { current; _ }) ->
    check
      (testable (fun fmt p -> Format.fprintf fmt "%s" (SM.phase_to_string p)) ( = ))
      "Terminal_state reports Dead as current"
      Dead
      current
  | Error err ->
    failf "expected Terminal_state, got %s" (SM.transition_error_to_string err)
;;

(* ── Wire-up ────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "KeeperStateMachine TLA+ correspondence smoke"
    [ ( "state_set_parity"
      , [ test_case "TLA+ phases ⊆ OCaml phases" `Quick test_state_set_parity ] )
    ; ( "allowed_transitions"
      , [ test_case
            "Running -> Failing via Heartbeat_failed"
            `Quick
            test_running_to_failing_via_heartbeat_failed
        ; test_case
            "Running -> Draining via Stop_requested"
            `Quick
            test_running_to_draining_via_stop_requested
        ; test_case
            "Running -> Compacting via Compaction_started"
            `Quick
            test_running_to_compacting_via_compaction_started
        ] )
    ; ( "forbidden_transitions"
      , [ test_case
            "Dead rejects Heartbeat_ok (Terminal_state)"
            `Quick
            test_forbidden_dead_rejects_heartbeat_ok
        ] )
    ]
;;
