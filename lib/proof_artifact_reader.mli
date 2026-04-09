(** Proof_artifact_reader — Dereference proof-store:// artifact refs.

    Resolves [proof-store://{run_id}/{subpath}] references to filesystem
    paths under [{config.root}/proofs/] and reads their JSON content.

    @since CDAL eval content-based redesign *)

(** Resolve a proof-store:// artifact_ref to a filesystem path.
    Returns [Error] if the ref does not have the expected prefix. *)
val resolve_path :
  Agent_sdk.Proof_store.config ->
  Agent_sdk.Cdal_proof.artifact_ref ->
  (string, string) result

(** Root directory for proof-store artifacts under the configured store. *)
val proofs_root : Agent_sdk.Proof_store.config -> string

(** Resolve a relative artifact path under a run directory.
    Returns [Error] when the run id or relative path attempts traversal. *)
val run_artifact_path :
  Agent_sdk.Proof_store.config ->
  run_id:string ->
  relative_path:string ->
  (string, string) result

(** Read and parse a JSON artifact from the proof store.
    Returns [Error] if the file does not exist or is not valid JSON. *)
val read_json :
  Agent_sdk.Proof_store.config ->
  Agent_sdk.Cdal_proof.artifact_ref ->
  (Yojson.Safe.t, string) result
