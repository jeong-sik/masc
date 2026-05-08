(** Proof_artifact_reader — Dereference proof-store:// artifact refs.

    Delegates to [Masc_mcp_cdal_runtime.Proof_store] which owns the canonical path layout.
    Eliminates the previous hardcoded directory layout mirror.

    @since CDAL eval content-based redesign *)

let resolve_path (config : Masc_mcp_cdal_runtime.Proof_store.config)
    (ref_ : Masc_mcp_cdal_runtime.Cdal_proof.artifact_ref) : (string, string) result =
  Masc_mcp_cdal_runtime.Proof_store.resolve_ref config ref_
  |> Result.map (fun r -> r.Masc_mcp_cdal_runtime.Proof_store.path)

let run_artifact_path (config : Masc_mcp_cdal_runtime.Proof_store.config)
    ~(run_id : string) ~(relative_path : string) : (string, string) result =
  let ref_ = Masc_mcp_cdal_runtime.Proof_store.make_ref ~run_id ~subpath:relative_path in
  resolve_path config ref_

let read_json = Masc_mcp_cdal_runtime.Proof_store.read_json

let read_jsonl = Masc_mcp_cdal_runtime.Proof_store.read_jsonl
