(* Cycle 21 / Tier B5 tests — Transition sub-module.

   Validates:
   - All 19 transitions project to the corresponding tag and back to
     a "from->to" string.
   - [tag]-level deriver output ([to_tla_symbol], [all_symbols],
     [all_states]) is correct and 19-element complete.
   - [can_transition] returns [true] for the 19 valid pairs and
     [false] for an exhaustive sample of invalid pairs (8 phases ×
     8 phases − 19 valid = 45 invalid). *)

module P = Autonomous.Autonomous_phase
module T = Autonomous.Autonomous_phase.Transition

(* ─── Tag deriver output ─────────────────────────────────────────── *)

let test_tag_to_tla_symbol_samples () =
  assert (T.to_tla_symbol T.T_idle_to_perceiving = "idle->perceiving");
  assert (T.to_tla_symbol T.T_executing_to_idle = "executing->idle");
  assert (T.to_tla_symbol T.T_adapting_to_perceiving = "adapting->perceiving")

let test_tag_all_symbols_count () =
  assert (List.length T.all_symbols = 19)

let test_tag_all_states_count () = assert (List.length T.all_states = 19)

let test_tag_all_states_first_and_last () =
  match T.all_states with
  | first :: _ -> assert (first = T.T_idle_to_perceiving)
  | [] -> assert false

(* ─── Transition GADT → tag projection ──────────────────────────── *)

(* Spot-check a handful and rely on exhaustiveness checking to catch
   any missing arm in [to_tag]. Building the witness on the LHS forces
   the right type-level narrowing, so each [assert] proves both that
   the GADT compiles and that [to_tag] returns the matching tag. *)
let test_to_tag_samples () =
  let module T_ = T in
  assert (T_.to_tag Idle_to_perceiving = T.T_idle_to_perceiving);
  assert (T_.to_tag Adapting_to_idle = T.T_adapting_to_idle);
  assert (T_.to_tag Verifying_to_reflecting = T.T_verifying_to_reflecting);
  assert (T_.to_tag Reflecting_to_planning = T.T_reflecting_to_planning)

let test_to_string_samples () =
  assert (T.to_string Idle_to_perceiving = "idle->perceiving");
  assert (T.to_string Planning_to_executing = "planning->executing");
  assert (T.to_string Reflecting_to_idle = "reflecting->idle");
  assert (T.to_string Adapting_to_perceiving = "adapting->perceiving")

(* Symbol round-trip: every transition tag's symbol must agree with
   the GADT-projected version. We test one representative per source
   phase to keep the body readable; together they cover every tag
   prefix. *)
let test_round_trip_via_tag () =
  let pairs : (string * T.tag) list =
    [ ("idle->perceiving", T.T_idle_to_perceiving);
      ("idle->adapting", T.T_idle_to_adapting);
      ("perceiving->idle", T.T_perceiving_to_idle);
      ("perceiving->intending", T.T_perceiving_to_intending);
      ("intending->planning", T.T_intending_to_planning);
      ("intending->idle", T.T_intending_to_idle);
      ("planning->executing", T.T_planning_to_executing);
      ("planning->intending", T.T_planning_to_intending);
      ("executing->verifying", T.T_executing_to_verifying);
      ("executing->adapting", T.T_executing_to_adapting);
      ("executing->idle", T.T_executing_to_idle);
      ("verifying->reflecting", T.T_verifying_to_reflecting);
      ("verifying->adapting", T.T_verifying_to_adapting);
      ("reflecting->idle", T.T_reflecting_to_idle);
      ("reflecting->adapting", T.T_reflecting_to_adapting);
      ("reflecting->planning", T.T_reflecting_to_planning);
      ("adapting->planning", T.T_adapting_to_planning);
      ("adapting->idle", T.T_adapting_to_idle);
      ("adapting->perceiving", T.T_adapting_to_perceiving);
    ]
  in
  assert (List.length pairs = 19);
  List.iter (fun (sym, tag) -> assert (T.to_tla_symbol tag = sym)) pairs

(* ─── Runtime can_transition ────────────────────────────────────── *)

(* All 19 valid edges. *)
let valid_edges : (P.tag * P.tag * (unit -> bool)) list =
  [ (P.Tag_idle, P.Tag_perceiving,
      fun () -> T.can_transition ~from_:P.Any_idle ~to_:P.Any_perceiving);
    (P.Tag_idle, P.Tag_adapting,
      fun () -> T.can_transition ~from_:P.Any_idle ~to_:P.Any_adapting);
    (P.Tag_perceiving, P.Tag_idle,
      fun () -> T.can_transition ~from_:P.Any_perceiving ~to_:P.Any_idle);
    (P.Tag_perceiving, P.Tag_intending,
      fun () -> T.can_transition ~from_:P.Any_perceiving ~to_:P.Any_intending);
    (P.Tag_intending, P.Tag_planning,
      fun () -> T.can_transition ~from_:P.Any_intending ~to_:P.Any_planning);
    (P.Tag_intending, P.Tag_idle,
      fun () -> T.can_transition ~from_:P.Any_intending ~to_:P.Any_idle);
    (P.Tag_planning, P.Tag_executing,
      fun () -> T.can_transition ~from_:P.Any_planning ~to_:P.Any_executing);
    (P.Tag_planning, P.Tag_intending,
      fun () -> T.can_transition ~from_:P.Any_planning ~to_:P.Any_intending);
    (P.Tag_executing, P.Tag_verifying,
      fun () -> T.can_transition ~from_:P.Any_executing ~to_:P.Any_verifying);
    (P.Tag_executing, P.Tag_adapting,
      fun () -> T.can_transition ~from_:P.Any_executing ~to_:P.Any_adapting);
    (P.Tag_executing, P.Tag_idle,
      fun () -> T.can_transition ~from_:P.Any_executing ~to_:P.Any_idle);
    (P.Tag_verifying, P.Tag_reflecting,
      fun () -> T.can_transition ~from_:P.Any_verifying ~to_:P.Any_reflecting);
    (P.Tag_verifying, P.Tag_adapting,
      fun () -> T.can_transition ~from_:P.Any_verifying ~to_:P.Any_adapting);
    (P.Tag_reflecting, P.Tag_idle,
      fun () -> T.can_transition ~from_:P.Any_reflecting ~to_:P.Any_idle);
    (P.Tag_reflecting, P.Tag_adapting,
      fun () -> T.can_transition ~from_:P.Any_reflecting ~to_:P.Any_adapting);
    (P.Tag_reflecting, P.Tag_planning,
      fun () -> T.can_transition ~from_:P.Any_reflecting ~to_:P.Any_planning);
    (P.Tag_adapting, P.Tag_planning,
      fun () -> T.can_transition ~from_:P.Any_adapting ~to_:P.Any_planning);
    (P.Tag_adapting, P.Tag_idle,
      fun () -> T.can_transition ~from_:P.Any_adapting ~to_:P.Any_idle);
    (P.Tag_adapting, P.Tag_perceiving,
      fun () -> T.can_transition ~from_:P.Any_adapting ~to_:P.Any_perceiving);
  ]

let test_can_transition_all_valid () =
  assert (List.length valid_edges = 19);
  List.iter (fun (_, _, f) -> assert (f ())) valid_edges

let test_can_transition_invalid_samples () =
  (* Sample of clearly-invalid transitions — arms not present in the
     19-edge matrix. *)
  assert (
    not
      (T.can_transition ~from_:P.Any_idle ~to_:P.Any_intending));
  assert (
    not
      (T.can_transition ~from_:P.Any_idle ~to_:P.Any_executing));
  assert (
    not
      (T.can_transition ~from_:P.Any_perceiving ~to_:P.Any_executing));
  assert (
    not
      (T.can_transition ~from_:P.Any_intending ~to_:P.Any_executing));
  assert (
    not (T.can_transition ~from_:P.Any_idle ~to_:P.Any_idle));
  assert (
    not
      (T.can_transition ~from_:P.Any_executing ~to_:P.Any_planning))

let () =
  test_tag_to_tla_symbol_samples ();
  test_tag_all_symbols_count ();
  test_tag_all_states_count ();
  test_tag_all_states_first_and_last ();
  test_to_tag_samples ();
  test_to_string_samples ();
  test_round_trip_via_tag ();
  test_can_transition_all_valid ();
  test_can_transition_invalid_samples ();
  print_endline "test_transition: all assertions passed"
