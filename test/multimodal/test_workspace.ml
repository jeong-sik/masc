(* Cycle 24-25 / Tier A7 — Multimodal.Workspace tests. *)

module W = Multimodal.Workspace
module C = Multimodal.Create
module A = Multimodal.Artifact
module P = Multimodal.Payload
module Aid = Shared_types.Artifact_id

let make_doc id ts =
  C.create_doc ~id ~payload:(P.Blob_ref (Aid.to_string id))
    ~metadata:(`Assoc [ ("title", `String ("doc-" ^ Aid.to_string id)) ])
    ~created_by:"executor" ~created_at:ts ()

let make_image id ts =
  C.create_image ~id ~payload:(P.Streaming 0) ~created_by:"executor"
    ~created_at:ts ()

(* ─── empty / size / add ──────────────────────────────────────── *)

let test_empty () =
  assert (W.size W.empty = 0);
  assert (W.all W.empty = [])

let test_add_increments_size () =
  let id = Aid.generate () in
  let ws = W.add W.empty (A.Any (make_doc id 1.0)) in
  assert (W.size ws = 1)

let test_add_replaces_existing_id () =
  let id = Aid.generate () in
  let ws0 = W.add W.empty (A.Any (make_doc id 1.0)) in
  let ws = W.add ws0 (A.Any (make_doc id 2.0)) in
  assert (W.size ws = 1)

(* ─── find / remove ───────────────────────────────────────────── *)

let test_find_by_id_present () =
  let id = Aid.generate () in
  let ws = W.add W.empty (A.Any (make_doc id 1.0)) in
  match W.find_by_id ws id with
  | Some _ -> ()
  | None -> assert false

let test_find_by_id_missing () =
  let missing = Aid.generate () in
  assert (W.find_by_id W.empty missing = None)

let test_remove () =
  let id = Aid.generate () in
  let ws0 = W.add W.empty (A.Any (make_doc id 1.0)) in
  let ws = W.remove ws0 id in
  assert (W.size ws = 0);
  assert (W.find_by_id ws id = None)

let test_remove_missing_is_noop () =
  let id = Aid.generate () in
  let missing = Aid.generate () in
  let ws = W.add W.empty (A.Any (make_doc id 1.0)) in
  let ws' = W.remove ws missing in
  assert (W.size ws' = 1)

(* ─── list_by_kind_tag ────────────────────────────────────────── *)

let test_list_by_kind_tag () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let id3 = Aid.generate () in
  let ws0 = W.add W.empty (A.Any (make_doc id1 1.0)) in
  let ws1 = W.add ws0 (A.Any (make_image id2 2.0)) in
  let ws = W.add ws1 (A.Any (make_doc id3 3.0)) in
  assert (List.length (W.list_by_kind_tag ws A.Tag_doc) = 2);
  assert (List.length (W.list_by_kind_tag ws A.Tag_image) = 1);
  assert (List.length (W.list_by_kind_tag ws A.Tag_code) = 0)

(* ─── timeline ────────────────────────────────────────────────── *)

let test_timeline_sorts_by_created_at () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let id3 = Aid.generate () in
  let ws0 = W.add W.empty (A.Any (make_doc id3 30.0)) in
  let ws1 = W.add ws0 (A.Any (make_doc id1 10.0)) in
  let ws = W.add ws1 (A.Any (make_doc id2 20.0)) in
  let line = W.timeline ws in
  assert (List.length line = 3);
  let first = List.nth line 0 in
  let last = List.nth line 2 in
  assert (Aid.equal (A.any_id first) id1);
  assert (Aid.equal (A.any_id last) id3)

(* ─── search_metadata_key ─────────────────────────────────────── *)

let test_search_metadata_key_matches () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let ws0 = W.add W.empty (A.Any (make_doc id1 1.0)) in
  let ws = W.add ws0 (A.Any (make_image id2 2.0)) in
  assert (List.length (W.search_metadata_key ws "title") = 1);
  assert (List.length (W.search_metadata_key ws "nonexistent_key") = 0)

(* ─── DAG integration ─────────────────────────────────────────── *)

let test_add_edge_with_both_present () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let ws0 = W.add W.empty (A.Any (make_doc id1 1.0)) in
  let ws1 = W.add ws0 (A.Any (make_doc id2 2.0)) in
  let ws = W.add_edge ws1 ~from_id:id1 ~to_id:id2 in
  assert (W.origins_of ws id2 = [ id1 ]);
  assert (W.descendants_of ws id1 = [ id2 ])

let test_add_edge_missing_endpoint_is_noop () =
  let id1 = Aid.generate () in
  let id_missing = Aid.generate () in
  let ws0 = W.add W.empty (A.Any (make_doc id1 1.0)) in
  let ws = W.add_edge ws0 ~from_id:id1 ~to_id:id_missing in
  (* edge not added because id_missing is not present *)
  assert (W.descendants_of ws id1 = [])

(* ─── JSON ────────────────────────────────────────────────────── *)

let test_to_json_shape () =
  let id1 = Aid.generate () in
  let ws = W.add W.empty (A.Any (make_doc id1 1.0)) in
  match W.to_json ws with
  | `Assoc kv ->
      assert (List.mem_assoc "artifacts" kv);
      assert (List.mem_assoc "dag" kv);
      (match List.assoc "artifacts" kv with
       | `List xs -> assert (List.length xs = 1)
       | _ -> assert false)
  | _ -> assert false

let () =
  test_empty ();
  test_add_increments_size ();
  test_add_replaces_existing_id ();
  test_find_by_id_present ();
  test_find_by_id_missing ();
  test_remove ();
  test_remove_missing_is_noop ();
  test_list_by_kind_tag ();
  test_timeline_sorts_by_created_at ();
  test_search_metadata_key_matches ();
  test_add_edge_with_both_present ();
  test_add_edge_missing_endpoint_is_noop ();
  test_to_json_shape ();
  print_endline "test_workspace: all assertions passed"
