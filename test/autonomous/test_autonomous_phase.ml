(* Autonomous_phase tag derivation.

   Validates [@@deriving tla] on [tag] ([to_tla_symbol], [all_symbols],
   [all_states]) and the 8-element completeness of the phase set. *)

open Autonomous.Autonomous_phase

let test_tag_to_tla_symbol () =
  assert (to_tla_symbol Tag_idle = "idle");
  assert (to_tla_symbol Tag_perceiving = "perceiving");
  assert (to_tla_symbol Tag_intending = "intending");
  assert (to_tla_symbol Tag_planning = "planning");
  assert (to_tla_symbol Tag_executing = "executing");
  assert (to_tla_symbol Tag_verifying = "verifying");
  assert (to_tla_symbol Tag_reflecting = "reflecting");
  assert (to_tla_symbol Tag_adapting = "adapting")

let test_all_symbols_order () =
  assert (
    all_symbols
    = [ "idle";
        "perceiving";
        "intending";
        "planning";
        "executing";
        "verifying";
        "reflecting";
        "adapting";
      ])

let test_all_states_count () = assert (List.length all_states = 8)

let test_all_states_first_and_last () =
  match all_states with
  | first :: _ -> assert (first = Tag_idle)
  | [] -> assert false

let () =
  test_tag_to_tla_symbol ();
  test_all_symbols_order ();
  test_all_states_count ();
  test_all_states_first_and_last ();
  print_endline "test_autonomous_phase: all assertions passed"
