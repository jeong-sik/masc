(* Multimodal.Artifact.provenance JSON round-trip tests.

   Pins (previously under the Provenance_stub module, folded back
   into Artifact since the stub never grew the planned DAG):

   - [provenance_empty ~created_by ~created_at] yields no origins.
   - [provenance_to_json] / [provenance_of_json] round-trip for
     empty + multi-origin records.
   - Garbage JSON returns [Error _]. *)

module Pr = Multimodal.Artifact
module Aid = Shared_types.Artifact_id

let test_empty_no_origins () =
  let p = Pr.provenance_empty ~created_by:"keeper-A" ~created_at:1700000000.0 in
  assert (p.Pr.origin_artifact_ids = []);
  assert (p.created_by = "keeper-A");
  assert (p.created_at = 1700000000.0)

let test_round_trip_empty () =
  let original =
    Pr.provenance_empty ~created_by:"keeper-B" ~created_at:1700000123.5
  in
  let restored = Pr.provenance_of_json (Pr.provenance_to_json original) in
  match restored with
  | Ok r ->
      assert (r.Pr.origin_artifact_ids = []);
      assert (r.created_by = "keeper-B");
      assert (r.created_at = 1700000123.5)
  | Error e ->
      Printf.eprintf "unexpected error: %s\n" e;
      assert false

let test_round_trip_with_origins () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let original : Pr.provenance =
    {
      origin_artifact_ids = [ id1; id2 ];
      created_by = "keeper-C";
      created_at = 1700000456.0;
    }
  in
  let restored = Pr.provenance_of_json (Pr.provenance_to_json original) in
  match restored with
  | Ok r ->
      assert (List.length r.Pr.origin_artifact_ids = 2);
      assert (r.created_by = "keeper-C");
      assert (r.created_at = 1700000456.0);
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
  match Pr.provenance_of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_missing_created_by () =
  let j = `Assoc [ ("created_at", `Float 1.0) ] in
  match Pr.provenance_of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_missing_created_at () =
  let j = `Assoc [ ("created_by", `String "k") ] in
  match Pr.provenance_of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_origin_artifact_ids_not_list () =
  let j =
    `Assoc
      [
        ("origin_artifact_ids", `String "wrong-type");
        ("created_by", `String "k");
        ("created_at", `Float 1.0);
      ]
  in
  match Pr.provenance_of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_origin_artifact_ids_invalid_member () =
  let j =
    `Assoc
      [
        ( "origin_artifact_ids",
          `List [ `Int 42 ] );
        ("created_by", `String "k");
        ("created_at", `Float 1.0);
      ]
  in
  match Pr.provenance_of_json j with
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
  match Pr.provenance_of_json j with
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
  match Pr.provenance_of_json j with
  | Error _ -> ()
  | Ok _ -> assert false

let test_of_json_origin_artifact_ids_omitted_defaults_to_empty () =
  let j =
    `Assoc
      [
        ("created_by", `String "k");
        ("created_at", `Float 1700000000.0);
      ]
  in
  match Pr.provenance_of_json j with
  | Ok r ->
      assert (r.Pr.origin_artifact_ids = []);
      assert (r.created_by = "k");
      assert (r.created_at = 1700000000.0)
  | Error e ->
      Printf.eprintf "unexpected error: %s\n" e;
      assert false

let test_of_json_created_at_int_accepted () =
  let j =
    `Assoc
      [
        ("created_by", `String "k");
        ("created_at", `Int 1700000000);
      ]
  in
  match Pr.provenance_of_json j with
  | Ok r -> assert (r.Pr.created_at = 1700000000.0)
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
