(* Autonomous_phase.Transition tag derivation.

   Validates [@@deriving tla] on [Transition.tag] ([to_tla_symbol],
   [all_symbols], [all_states]) and the 19-element completeness of the
   transition set. *)

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

(* Every transition tag renders its "from->to" symbol. *)
let test_every_tag_symbol () =
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

let () =
  test_tag_to_tla_symbol_samples ();
  test_tag_all_symbols_count ();
  test_tag_all_states_count ();
  test_tag_all_states_first_and_last ();
  test_every_tag_symbol ();
  print_endline "test_transition: all assertions passed"
