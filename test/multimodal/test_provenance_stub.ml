(* Cycle 24 / Tier B8 — Multimodal.Provenance_stub JSON round-trip tests.

   Pins:

   - [empty ~created_by ~created_at] yields the documented shape
     (no origin artifacts).
   - [to_json]/[of_json] round-trip for empty + multi-origin
     records.
   - Garbage JSON returns [Error _]. *)

module Pr = Multimodal.Provenance_stub
module Aid = Shared_types.Artifact_id

let test_empty_no_origins () =
  let p = Pr.empty ~created_by:"keeper-A" ~created_at:1700000000.0 in
  assert (p.origin_artifact_ids = []);
  assert (p.created_by = "keeper-A");
  assert (p.created_at = 1700000000.0)

let test_round_trip_empty () =
  let original =
    Pr.empty ~created_by:"keeper-B" ~created_at:1700000123.5
  in
  let restored = Pr.of_json (Pr.to_json original) in
  match restored with
  | Ok r ->
      assert (r.origin_artifact_ids = []);
      assert (r.created_by = "keeper-B");
      assert (r.created_at = 1700000123.5)
  | Error e ->
      Printf.eprintf "unexpected error: %s\n" e;
      assert false

let test_round_trip_with_origins () =
  (* [Aid.of_string] requires a 36-char UUID, so use [Aid.generate]
     for fixture data and pin only the count + string round-trip
     through [to_string], not the literal value. *)
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let original =
    {
      Pr.origin_artifact_ids = [ id1; id2 ];
      created_by = "keeper-C";
      created_at = 1700000456.0;
    }
  in
  let restored = Pr.of_json (Pr.to_json original) in
  match restored with
  | Ok r ->
      assert (List.length r.origin_artifact_ids = 2);
      assert (r.created_by = "keeper-C");
      assert (r.created_at = 1700000456.0);
      (* Serialised form survives intact when restored. *)
      let want1 = Aid.to_string id1 in
      let want2 = Aid.to_string id2 in
      let got1 = List.nth r.origin_artifact_ids 0 |> Aid.to_string in
      let got2 = List.nth r.origin_artifact_ids 1 |> Aid.to_string in
      assert (got1 = want1);
      assert (got2 = want2)
  | Error e ->
      Printf.eprintf "unexpected error: %s\n" e;
      assert false

let test_of_json_garbage () =
  let j = `String "not_an_object" in
  match Pr.of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_missing_created_by () =
  let j = `Assoc [ ("created_at", `Float 1.0) ] in
  match Pr.of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_missing_created_at () =
  (* Symmetric to missing_created_by — Copilot review caught
     the [created_at] branch was untested. *)
  let j = `Assoc [ ("created_by", `String "k") ] in
  match Pr.of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_origin_artifact_ids_not_list () =
  (* "origin_artifact_ids" present but not a JSON list. *)
  let j =
    `Assoc
      [
        ("origin_artifact_ids", `String "wrong-type");
        ("created_by", `String "k");
        ("created_at", `Float 1.0);
      ]
  in
  match Pr.of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_origin_artifact_ids_invalid_member () =
  (* "origin_artifact_ids" is a list, but a member is not a
     valid Artifact_id JSON shape. *)
  let j =
    `Assoc
      [
        ( "origin_artifact_ids",
          `List [ `Int 42 (* not a string-shaped Aid *) ] );
        ("created_by", `String "k");
        ("created_at", `Float 1.0);
      ]
  in
  match Pr.of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_created_by_wrong_type () =
  let j =
    `Assoc
      [
        ("created_by", `Int 42);
        ("created_at", `Float 1.0);
      ]
  in
  match Pr.of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_created_at_wrong_type () =
  let j =
    `Assoc
      [
        ("created_by", `String "k");
        ("created_at", `String "not-a-number");
      ]
  in
  match Pr.of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_origin_artifact_ids_omitted_defaults_to_empty () =
  (* Copilot review: of_json has a separate branch
     [None -> Ok []] for an omitted [origin_artifact_ids] key.
     Without a positive test that behavior could change
     silently.  Pin: omitted key produces an empty origin list,
     not an error. *)
  let j =
    `Assoc
      [
        ("created_by", `String "k");
        ("created_at", `Float 1700000000.0);
      ]
  in
  match Pr.of_json j with
  | Ok r ->
      assert (r.origin_artifact_ids = []);
      assert (r.created_by = "k");
      assert (r.created_at = 1700000000.0)
  | Error e ->
      Printf.eprintf "unexpected error: %s\n" e;
      assert false

let test_of_json_created_at_int_accepted () =
  (* Implementation accepts both `Float and `Int for created_at
     (line 46: float_of_int i).  Pin that behavior. *)
  let j =
    `Assoc
      [
        ("created_by", `String "k");
        ("created_at", `Int 1700000000);
      ]
  in
  match Pr.of_json j with
  | Ok r -> assert (r.created_at = 1700000000.0)
  | Error e ->
      Printf.eprintf "unexpected error: %s\n" e;
      assert false

let () =
  test_empty_no_origins ();
  test_round_trip_empty ();
  test_round_trip_with_origins ();
  test_of_json_garbage ();
  test_of_json_missing_created_by ();
  test_of_json_missing_created_at ();
  test_of_json_origin_artifact_ids_not_list ();
  test_of_json_origin_artifact_ids_invalid_member ();
  test_of_json_created_by_wrong_type ();
  test_of_json_created_at_wrong_type ();
  test_of_json_origin_artifact_ids_omitted_defaults_to_empty ();
  test_of_json_created_at_int_accepted ();
  print_endline "test_provenance_stub: all assertions passed"
