(* Cycle 24 / Tier B9 — Multimodal_hydrator tests. *)

module H = Multimodal.Multimodal_hydrator
module A = Multimodal.Artifact
module P = Multimodal.Payload
module Pr = Multimodal.Provenance_stub
module Aid = Shared_types.Artifact_id

(* ─── DAG construction + edge dedupe ──────────────────────────── *)

let test_empty_dag () =
  assert (H.edges H.empty_dag = [])

let test_add_edge_appends () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let dag = H.add_edge H.empty_dag ~from_id:id1 ~to_id:id2 in
  let es = H.edges dag in
  assert (List.length es = 1);
  match es with
  | [ (a, b) ] ->
      assert (Aid.equal a id1);
      assert (Aid.equal b id2)
  | _ -> assert false

let test_add_edge_dedupes_same_pair () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let dag =
    H.empty_dag
    |> H.add_edge ~from_id:id1 ~to_id:id2
    |> H.add_edge ~from_id:id1 ~to_id:id2
  in
  assert (List.length (H.edges dag) = 1)

let test_add_edge_admits_distinct_pairs () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let id3 = Aid.generate () in
  let dag =
    H.empty_dag
    |> H.add_edge ~from_id:id1 ~to_id:id2
    |> H.add_edge ~from_id:id2 ~to_id:id3
    |> H.add_edge ~from_id:id1 ~to_id:id3
  in
  assert (List.length (H.edges dag) = 3)

(* ─── DAG queries ─────────────────────────────────────────────── *)

let test_origins_of () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let id3 = Aid.generate () in
  let dag =
    H.empty_dag
    |> H.add_edge ~from_id:id1 ~to_id:id3
    |> H.add_edge ~from_id:id2 ~to_id:id3
  in
  let origins = H.origins_of dag id3 in
  assert (List.length origins = 2);
  assert (List.exists (Aid.equal id1) origins);
  assert (List.exists (Aid.equal id2) origins)

let test_descendants_of () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let id3 = Aid.generate () in
  let dag =
    H.empty_dag
    |> H.add_edge ~from_id:id1 ~to_id:id2
    |> H.add_edge ~from_id:id1 ~to_id:id3
  in
  let descs = H.descendants_of dag id1 in
  assert (List.length descs = 2);
  assert (List.exists (Aid.equal id2) descs);
  assert (List.exists (Aid.equal id3) descs)

let test_origins_of_unknown_returns_empty () =
  let id = Aid.generate () in
  assert (H.origins_of H.empty_dag id = []);
  assert (H.descendants_of H.empty_dag id = [])

(* ─── DAG JSON round-trip ─────────────────────────────────────── *)

let test_dag_json_round_trip () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let dag =
    H.empty_dag |> H.add_edge ~from_id:id1 ~to_id:id2
  in
  match H.dag_of_json (H.dag_to_json dag) with
  | Ok back ->
      let es = H.edges back in
      assert (List.length es = 1);
      let from_id, to_id = List.hd es in
      assert (Aid.equal from_id id1);
      assert (Aid.equal to_id id2)
  | Error _ -> assert false

let test_dag_of_json_missing_edges_field_ok_empty () =
  match H.dag_of_json (`Assoc []) with
  | Ok dag -> assert (H.edges dag = [])
  | Error _ -> assert false

let test_dag_of_json_malformed_rejected () =
  match H.dag_of_json (`String "not-an-object") with
  | Error _ -> ()
  | Ok _ -> assert false

(* ─── Hydrate ─────────────────────────────────────────────────── *)

let make_doc_artifact id : A.doc A.t =
  {
    A.id;
    kind = A.Doc;
    payload = P.Blob_ref (Aid.to_string id ^ "-blob");
    metadata = `Null;
    provenance = Pr.empty ~created_by:"executor" ~created_at:1.0;
  }
[@@warning "-37"]

let test_hydrate_resolves_known_ids () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let store = [ (id1, A.Any (make_doc_artifact id1)); (id2, A.Any (make_doc_artifact id2)) ] in
  let fetch id =
    List.find_map
      (fun (k, v) -> if Aid.equal k id then Some v else None)
      store
  in
  let dag = H.add_edge H.empty_dag ~from_id:id1 ~to_id:id2 in
  let result = H.hydrate ~fetch_artifact:fetch ~dag ~ids:[ id1; id2 ] in
  assert (List.length result = 2);
  let h2 = List.nth result 1 in
  assert (List.length h2.origins = 1);
  assert (Aid.equal (List.hd h2.origins) id1);
  assert (h2.descendants = [])

let test_hydrate_skips_unknown_ids () =
  let id_known = Aid.generate () in
  let id_missing = Aid.generate () in
  let fetch id =
    if Aid.equal id id_known then
      Some (A.Any (make_doc_artifact id_known))
    else None
  in
  let result =
    H.hydrate ~fetch_artifact:fetch ~dag:H.empty_dag
      ~ids:[ id_missing; id_known ]
  in
  (* missing was skipped, only known artifact survives. *)
  assert (List.length result = 1);
  let h = List.hd result in
  assert (Aid.equal (A.any_id h.artifact) id_known)

let test_hydrate_empty_input () =
  let fetch _ = None in
  let result =
    H.hydrate ~fetch_artifact:fetch ~dag:H.empty_dag ~ids:[]
  in
  assert (result = [])

let () =
  test_empty_dag ();
  test_add_edge_appends ();
  test_add_edge_dedupes_same_pair ();
  test_add_edge_admits_distinct_pairs ();
  test_origins_of ();
  test_descendants_of ();
  test_origins_of_unknown_returns_empty ();
  test_dag_json_round_trip ();
  test_dag_of_json_missing_edges_field_ok_empty ();
  test_dag_of_json_malformed_rejected ();
  test_hydrate_resolves_known_ids ();
  test_hydrate_skips_unknown_ids ();
  test_hydrate_empty_input ();
  print_endline "test_multimodal_hydrator: all assertions passed"
