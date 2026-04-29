(* Cycle 24 / Tier B8 — Multimodal.Artifact tests. *)

module A = Multimodal.Artifact
module P = Multimodal.Payload
module Pr = Multimodal.Provenance_stub
module Aid = Shared_types.Artifact_id

(* ─── kind / kind_tag mirror ──────────────────────────────────── *)

let test_kind_tag_symbols () =
  assert (A.kind_tag_to_string A.Tag_code = "code");
  assert (A.kind_tag_to_string A.Tag_image = "image");
  assert (A.kind_tag_to_string A.Tag_audio = "audio");
  assert (A.kind_tag_to_string A.Tag_doc = "doc")

let test_all_kind_tags () =
  assert (List.length A.all_kind_tags = 4);
  let symbols = List.map A.kind_tag_to_string A.all_kind_tags in
  assert (symbols = [ "code"; "image"; "audio"; "doc" ])

let test_kind_to_tag_round_trip () =
  assert (A.kind_to_tag A.Code = A.Tag_code);
  assert (A.kind_to_tag A.Image = A.Tag_image);
  assert (A.kind_to_tag A.Audio = A.Tag_audio);
  assert (A.kind_to_tag A.Doc = A.Tag_doc)

let test_any_kind_to_tag () =
  assert (A.any_kind_to_tag (A.Any_kind A.Code) = A.Tag_code);
  assert (A.any_kind_to_tag (A.Any_kind A.Image) = A.Tag_image);
  assert (A.any_kind_to_tag (A.Any_kind A.Audio) = A.Tag_audio);
  assert (A.any_kind_to_tag (A.Any_kind A.Doc) = A.Tag_doc)

let test_kind_to_string () =
  assert (A.kind_to_string A.Code = "code");
  assert (A.any_kind_to_string (A.Any_kind A.Image) = "image")

(* ─── Payload variant ─────────────────────────────────────────── *)

let test_payload_blob_ref_round_trip () =
  let p = P.Blob_ref "blob-abc" in
  let json = P.to_json p in
  match P.of_json json with
  | Ok (P.Blob_ref s) -> assert (s = "blob-abc")
  | _ -> assert false

let test_payload_streaming_round_trip () =
  let p = P.Streaming 4096 in
  match P.of_json (P.to_json p) with
  | Ok (P.Streaming n) -> assert (n = 4096)
  | _ -> assert false

let test_payload_lazy_lossy_round_trip () =
  let p = P.Lazy_payload (fun () -> "hello") in
  match P.of_json (P.to_json p) with
  | Ok (P.Lazy_payload f) ->
      (* Round-trip is lossy by construction — closure rebuilt. *)
      assert (f () = "")
  | _ -> assert false

let test_payload_unknown_kind_rejected () =
  let bogus = `Assoc [ ("kind", `String "magic") ] in
  match P.of_json bogus with
  | Error _ -> ()
  | Ok _ -> assert false

(* ─── Provenance_stub ─────────────────────────────────────────── *)

let test_provenance_empty_round_trip () =
  let pr = Pr.empty ~created_by:"vincent" ~created_at:1234.5 in
  match Pr.of_json (Pr.to_json pr) with
  | Ok p ->
      assert (p.Pr.origin_artifact_ids = []);
      assert (p.created_by = "vincent");
      assert (Float.abs (p.created_at -. 1234.5) < 1e-6)
  | Error _ -> assert false

let test_provenance_with_origins_round_trip () =
  let id1 = Aid.generate () in
  let id2 = Aid.generate () in
  let pr =
    {
      Pr.origin_artifact_ids = [ id1; id2 ];
      created_by = "executor";
      created_at = 9999.0;
    }
  in
  match Pr.of_json (Pr.to_json pr) with
  | Ok p ->
      assert (List.length p.Pr.origin_artifact_ids = 2);
      assert (
        Aid.equal (List.hd p.origin_artifact_ids) id1)
  | Error _ -> assert false

(* ─── Artifact record ─────────────────────────────────────────── *)

let make_image_artifact () : A.image A.t =
  let id = Aid.generate () in
  {
    A.id;
    kind = A.Image;
    payload = P.Blob_ref "img-blob-1";
    metadata = `Assoc [ ("width", `Int 800); ("height", `Int 600) ];
    provenance = Pr.empty ~created_by:"executor" ~created_at:1.0;
  }
[@@warning "-37"]

let test_artifact_to_json () =
  let a = make_image_artifact () in
  let json = A.to_json a in
  match json with
  | `Assoc kv ->
      let kind = List.assoc "kind" kv in
      assert (kind = `String "image");
      assert (List.mem_assoc "id" kv);
      assert (List.mem_assoc "payload" kv);
      assert (List.mem_assoc "metadata" kv);
      assert (List.mem_assoc "provenance" kv)
  | _ -> assert false

let test_any_artifact_existential () =
  let a = make_image_artifact () in
  let any = A.Any a in
  assert (A.any_kind_of any = A.Any_kind A.Image);
  let id_back = A.any_id any in
  assert (Aid.equal id_back a.A.id);
  let json = A.any_to_json any in
  let json_b = A.to_json a in
  assert (json = json_b)

let test_homogeneous_list_of_any () =
  let a_img = make_image_artifact () in
  let a_code : A.code A.t =
    let id = Aid.generate () in
    {
      A.id;
      kind = A.Code;
      payload = P.Streaming 0;
      metadata = `Null;
      provenance = Pr.empty ~created_by:"executor" ~created_at:2.0;
    }
  in
  let xs = [ A.Any a_img; A.Any a_code ] in
  let kinds = List.map A.any_kind_of xs in
  assert (kinds = [ A.Any_kind A.Image; A.Any_kind A.Code ]);
  let symbols =
    List.map (fun a -> A.any_kind_to_string (A.any_kind_of a)) xs
  in
  assert (symbols = [ "image"; "code" ])

let () =
  test_kind_tag_symbols ();
  test_all_kind_tags ();
  test_kind_to_tag_round_trip ();
  test_any_kind_to_tag ();
  test_kind_to_string ();
  test_payload_blob_ref_round_trip ();
  test_payload_streaming_round_trip ();
  test_payload_lazy_lossy_round_trip ();
  test_payload_unknown_kind_rejected ();
  test_provenance_empty_round_trip ();
  test_provenance_with_origins_round_trip ();
  test_artifact_to_json ();
  test_any_artifact_existential ();
  test_homogeneous_list_of_any ();
  print_endline "test_artifact: all assertions passed"
