(** Proof_artifact_reader — Dereference proof-store:// artifact refs via OAS.

    This module is MASC's narrow adapter over [Masc_mcp_cdal_runtime.Proof_store].
    OAS owns the canonical proof-store scheme, layout validation, and JSON
    readers; MASC callers should avoid reconstructing those details here.

    @since CDAL eval content-based redesign *)

(** Resolve a proof-store:// artifact_ref to a filesystem path.
    Returns [Error] if the ref does not have the expected prefix. *)
val resolve_path
  :  Masc_mcp_cdal_runtime.Proof_store.config
  -> Masc_mcp_cdal_runtime.Cdal_proof.artifact_ref
  -> (string, string) result

(** Resolve a relative artifact path under a run directory.
    Returns [Error] when the run id or relative path attempts traversal. *)
val run_artifact_path
  :  Masc_mcp_cdal_runtime.Proof_store.config
  -> run_id:string
  -> relative_path:string
  -> (string, string) result

(** Read and parse a JSON artifact from the proof store.
    Returns [Error] if the file does not exist or is not valid JSON. *)
val read_json
  :  Masc_mcp_cdal_runtime.Proof_store.config
  -> Masc_mcp_cdal_runtime.Cdal_proof.artifact_ref
  -> (Yojson.Safe.t, string) result

(** Read and parse a JSONL artifact from the proof store.
    Returns [Error] if the file does not exist or contains invalid JSONL. *)
val read_jsonl
  :  Masc_mcp_cdal_runtime.Proof_store.config
  -> Masc_mcp_cdal_runtime.Cdal_proof.artifact_ref
  -> (Yojson.Safe.t list, string) result
