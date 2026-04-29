(* Create — Cycle 24-25 / Tier A7 first half.
   See create.mli for design rationale. *)

let provenance_of ?(origins = []) ~created_by ~created_at () : Provenance_stub.t =
  { Provenance_stub.origin_artifact_ids = origins; created_by; created_at }

let make_artifact (type a) ~(id : Shared_types.Artifact_id.t)
    ~(kind : a Artifact.kind) ~(payload : Payload.t)
    ?(metadata = `Null) ?origins ~created_by ~created_at () : a Artifact.t =
  {
    Artifact.id;
    kind;
    payload;
    metadata;
    provenance = provenance_of ?origins ~created_by ~created_at ();
  }

let create_code ~id ~payload ?metadata ?origins ~created_by ~created_at () =
  make_artifact ~id ~kind:Artifact.Code ~payload ?metadata ?origins
    ~created_by ~created_at ()

let create_image ~id ~payload ?metadata ?origins ~created_by ~created_at () =
  make_artifact ~id ~kind:Artifact.Image ~payload ?metadata ?origins
    ~created_by ~created_at ()

let create_audio ~id ~payload ?metadata ?origins ~created_by ~created_at () =
  make_artifact ~id ~kind:Artifact.Audio ~payload ?metadata ?origins
    ~created_by ~created_at ()

let create_doc ~id ~payload ?metadata ?origins ~created_by ~created_at () =
  make_artifact ~id ~kind:Artifact.Doc ~payload ?metadata ?origins
    ~created_by ~created_at ()

let create_with_blob_ref ~kind ~id ~blob_ref ?metadata ?origins
    ~created_by ~created_at () =
  make_artifact ~id ~kind ~payload:(Payload.Blob_ref blob_ref) ?metadata
    ?origins ~created_by ~created_at ()

let create_with_streaming ~kind ~id ~bytes_so_far ?metadata ?origins
    ~created_by ~created_at () =
  make_artifact ~id ~kind ~payload:(Payload.Streaming bytes_so_far) ?metadata
    ?origins ~created_by ~created_at ()

let create_with_lazy_payload ~kind ~id ~thunk ?metadata ?origins
    ~created_by ~created_at () =
  make_artifact ~id ~kind ~payload:(Payload.Lazy_payload thunk) ?metadata
    ?origins ~created_by ~created_at ()
