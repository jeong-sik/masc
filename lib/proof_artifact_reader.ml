(** Proof_artifact_reader — Dereference proof-store:// artifact refs.

    @since CDAL eval content-based redesign *)

let resolve_path (config : Agent_sdk.Proof_store.config)
    (ref_ : Agent_sdk.Cdal_proof.artifact_ref) : (string, string) result =
  match Agent_sdk.Proof_store.resolve_ref config ref_ with
  | Ok resolved -> Ok resolved.path
  | Error e -> Error e

let read_json (config : Agent_sdk.Proof_store.config)
    (ref_ : Agent_sdk.Cdal_proof.artifact_ref)
    : (Yojson.Safe.t, string) result =
  Agent_sdk.Proof_store.read_json config ref_
