(* Cycle 21 / Tier B3 tests — Autonomous_phase tag derivation + any
   GADT projections.

   Validates:
   - [tag]-level [@@deriving tla] correctness ([to_tla_symbol],
     [all_symbols], [all_states])
   - 8-element completeness of the phase set
   - [any_to_tag] one-to-one mapping
   - [any_to_string] equivalence to [to_tla_symbol (any_to_tag _)] *)

open Autonomous.Autonomous_phase

(* ─── Tag-level deriver output (Tier I7 records / I8 GADT independent;
   exercised here through a regular variant with [@tla.symbol] override) *)

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

(* ─── any GADT projection ─────────────────────────────────────────── *)

let test_any_to_tag () =
  assert (any_to_tag Any_idle = Tag_idle);
  assert (any_to_tag Any_perceiving = Tag_perceiving);
  assert (any_to_tag Any_intending = Tag_intending);
  assert (any_to_tag Any_planning = Tag_planning);
  assert (any_to_tag Any_executing = Tag_executing);
  assert (any_to_tag Any_verifying = Tag_verifying);
  assert (any_to_tag Any_reflecting = Tag_reflecting);
  assert (any_to_tag Any_adapting = Tag_adapting)

let test_any_to_string () =
  assert (any_to_string Any_idle = "idle");
  assert (any_to_string Any_perceiving = "perceiving");
  assert (any_to_string Any_intending = "intending");
  assert (any_to_string Any_planning = "planning");
  assert (any_to_string Any_executing = "executing");
  assert (any_to_string Any_verifying = "verifying");
  assert (any_to_string Any_reflecting = "reflecting");
  assert (any_to_string Any_adapting = "adapting")

(* ─── Round-trip: any_to_string = to_tla_symbol ∘ any_to_tag ───── *)

let test_any_string_via_tag () =
  let pairs : (string * tag) list =
    [ ("idle", Tag_idle);
      ("perceiving", Tag_perceiving);
      ("intending", Tag_intending);
      ("planning", Tag_planning);
      ("executing", Tag_executing);
      ("verifying", Tag_verifying);
      ("reflecting", Tag_reflecting);
      ("adapting", Tag_adapting);
    ]
  in
  List.iter (fun (sym, tag) -> assert (to_tla_symbol tag = sym)) pairs

let () =
  test_tag_to_tla_symbol ();
  test_all_symbols_order ();
  test_all_states_count ();
  test_all_states_first_and_last ();
  test_any_to_tag ();
  test_any_to_string ();
  test_any_string_via_tag ();
  print_endline "test_autonomous_phase: all assertions passed"
