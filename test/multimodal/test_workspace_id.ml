(* Cycle 25 / Tier B10 — Multimodal.Workspace_id tests. *)

module W = Multimodal.Workspace_id

(* ─── generation ───────────────────────────────────────────────── *)

let test_generate_is_36_chars () =
  let w = W.generate () in
  assert (String.length (W.to_string w) = 36)

let test_generate_is_lowercase () =
  let s = W.to_string (W.generate ()) in
  assert (s = String.lowercase_ascii s)

let test_generate_two_distinct () =
  (* 122-bit randomness in the v7 tail; collisions are statistical
     non-events. *)
  let a = W.generate () in
  let b = W.generate () in
  assert (not (W.equal a b))

let test_generate_round_trip_to_string () =
  let w = W.generate () in
  match W.of_string (W.to_string w) with
  | Ok parsed -> assert (W.equal w parsed)
  | Error e -> failwith ("round-trip failed: " ^ e)

(* ─── of_string validation ────────────────────────────────────── *)

let test_of_string_empty_rejected () =
  match W.of_string "" with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_string_too_long_rejected () =
  let s = String.make 65 'a' in
  match W.of_string s with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_string_max_length_boundary_uuid_only () =
  (* 64 chars is the ceiling — but a 64-char string still has to pass
     UUID v7 shape validation (36 chars), so it must fail there too. *)
  let s = String.make 64 'a' in
  match W.of_string s with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_string_wrong_length_rejected () =
  match W.of_string "not-a-uuid" with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_string_missing_dashes_rejected () =
  (* 36 chars but no dashes. *)
  let s = String.make 36 'a' in
  match W.of_string s with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_string_wrong_version_rejected () =
  (* UUID v4 shape — version digit '4' instead of '7'. *)
  match W.of_string "00000000-0000-4000-8000-000000000000" with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_string_invalid_variant_rejected () =
  (* Variant nibble 'c' not in {8,9,a,b}. *)
  match W.of_string "00000000-0000-7000-c000-000000000000" with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_string_non_hex_in_body_rejected () =
  match W.of_string "0000000z-0000-7000-8000-000000000000" with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_string_uppercase_normalised () =
  (* Mixed-case valid v7 — generator emits lowercase, but parser
     accepts and normalises. *)
  match W.of_string "01890E2A-4C8E-7B21-9F3C-0123456789AB" with
  | Ok w ->
      let s = W.to_string w in
      assert (s = String.lowercase_ascii s)
  | Error e -> failwith ("expected lowercase normalisation: " ^ e)

(* ─── compare / equal ─────────────────────────────────────────── *)

let test_compare_reflexive () =
  let w = W.generate () in
  assert (W.compare w w = 0);
  assert (W.equal w w)

let test_compare_total_order () =
  let a = W.generate () in
  let b = W.generate () in
  let cab = W.compare a b in
  let cba = W.compare b a in
  assert ((cab = 0 && cba = 0) || (cab > 0 && cba < 0) || (cab < 0 && cba > 0))

(* ─── JSON round-trip ─────────────────────────────────────────── *)

let test_to_json_emits_string () =
  let w = W.generate () in
  match W.to_json w with
  | `String s -> assert (s = W.to_string w)
  | _ -> assert false

let test_json_round_trip () =
  let w = W.generate () in
  match W.of_json (W.to_json w) with
  | Ok parsed -> assert (W.equal w parsed)
  | Error e -> failwith ("json round-trip failed: " ^ e)

let test_of_json_rejects_non_string () =
  match W.of_json (`Int 42) with
  | Error _ -> ()
  | Ok _ -> assert false

(* ─── runner ──────────────────────────────────────────────────── *)

let () =
  test_generate_is_36_chars ();
  test_generate_is_lowercase ();
  test_generate_two_distinct ();
  test_generate_round_trip_to_string ();
  test_of_string_empty_rejected ();
  test_of_string_too_long_rejected ();
  test_of_string_max_length_boundary_uuid_only ();
  test_of_string_wrong_length_rejected ();
  test_of_string_missing_dashes_rejected ();
  test_of_string_wrong_version_rejected ();
  test_of_string_invalid_variant_rejected ();
  test_of_string_non_hex_in_body_rejected ();
  test_of_string_uppercase_normalised ();
  test_compare_reflexive ();
  test_compare_total_order ();
  test_to_json_emits_string ();
  test_json_round_trip ();
  test_of_json_rejects_non_string ();
  print_endline "test_workspace_id: OK"
