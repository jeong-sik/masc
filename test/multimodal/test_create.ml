(* Cycle 24-25 / Tier A7 — Multimodal.Create tests. *)

module C = Multimodal.Create
module A = Multimodal.Artifact
module P = Multimodal.Payload
module Pr = Multimodal.Provenance_stub
module Aid = Shared_types.Artifact_id

(* ─── kind-specific factories ─────────────────────────────────── *)

let test_create_code_returns_code_kind () =
  let id = Aid.generate () in
  let a =
    C.create_code ~id ~payload:(P.Blob_ref "code-blob") ~created_by:"executor"
      ~created_at:1.0 ()
  in
  match a.A.kind with A.Code -> () | _ -> assert false

let test_create_image_returns_image_kind () =
  let id = Aid.generate () in
  let a =
    C.create_image ~id ~payload:(P.Streaming 512) ~created_by:"executor"
      ~created_at:2.0 ()
  in
  match a.A.kind with A.Image -> () | _ -> assert false

let test_create_audio_returns_audio_kind () =
  let id = Aid.generate () in
  let a =
    C.create_audio ~id
      ~payload:(P.Lazy_payload (fun () -> ""))
      ~created_by:"scholar" ~created_at:3.0 ()
  in
  match a.A.kind with A.Audio -> () | _ -> assert false

let test_create_doc_returns_doc_kind () =
  let id = Aid.generate () in
  let a =
    C.create_doc ~id ~payload:(P.Blob_ref "doc-blob") ~created_by:"verifier"
      ~created_at:4.0 ()
  in
  match a.A.kind with A.Doc -> () | _ -> assert false

(* ─── Provenance defaults ─────────────────────────────────────── *)

let test_origins_default_to_empty_list () =
  let id = Aid.generate () in
  let a =
    C.create_code ~id ~payload:(P.Blob_ref "x") ~created_by:"executor"
      ~created_at:1.0 ()
  in
  assert (a.A.provenance.Pr.origin_artifact_ids = [])

let test_origins_when_supplied () =
  let parent = Aid.generate () in
  let id = Aid.generate () in
  let a =
    C.create_code ~id ~payload:(P.Blob_ref "x") ~origins:[ parent ]
      ~created_by:"executor" ~created_at:1.0 ()
  in
  assert (List.length a.A.provenance.Pr.origin_artifact_ids = 1);
  assert (Aid.equal (List.hd a.A.provenance.Pr.origin_artifact_ids) parent)

let test_metadata_default_is_null () =
  let id = Aid.generate () in
  let a =
    C.create_code ~id ~payload:(P.Blob_ref "x") ~created_by:"executor"
      ~created_at:1.0 ()
  in
  assert (a.A.metadata = `Null)

let test_metadata_when_supplied () =
  let id = Aid.generate () in
  let meta = `Assoc [ ("lang", `String "ocaml") ] in
  let a =
    C.create_code ~id ~payload:(P.Blob_ref "x") ~metadata:meta
      ~created_by:"executor" ~created_at:1.0 ()
  in
  assert (a.A.metadata = meta)

(* ─── Payload-shape shortcuts ─────────────────────────────────── *)

let test_create_with_blob_ref () =
  let id = Aid.generate () in
  let a =
    C.create_with_blob_ref ~kind:A.Image ~id ~blob_ref:"blob-x"
      ~created_by:"executor" ~created_at:1.0 ()
  in
  match a.A.payload with
  | P.Blob_ref s -> assert (s = "blob-x")
  | _ -> assert false

let test_create_with_streaming () =
  let id = Aid.generate () in
  let a =
    C.create_with_streaming ~kind:A.Audio ~id ~bytes_so_far:1024
      ~created_by:"executor" ~created_at:1.0 ()
  in
  match a.A.payload with
  | P.Streaming n -> assert (n = 1024)
  | _ -> assert false

let test_create_with_lazy_payload () =
  let id = Aid.generate () in
  let a =
    C.create_with_lazy_payload ~kind:A.Code ~id
      ~thunk:(fun () -> "thunked")
      ~created_by:"executor" ~created_at:1.0 ()
  in
  match a.A.payload with
  | P.Lazy_payload f -> assert (f () = "thunked")
  | _ -> assert false

let () =
  test_create_code_returns_code_kind ();
  test_create_image_returns_image_kind ();
  test_create_audio_returns_audio_kind ();
  test_create_doc_returns_doc_kind ();
  test_origins_default_to_empty_list ();
  test_origins_when_supplied ();
  test_metadata_default_is_null ();
  test_metadata_when_supplied ();
  test_create_with_blob_ref ();
  test_create_with_streaming ();
  test_create_with_lazy_payload ();
  print_endline "test_create: all assertions passed"
