(** Proof_artifact_reader — Dereference proof-store:// artifact refs.

    Delegates to [Agent_sdk.Proof_store] which owns the canonical path layout.
    Eliminates the previous hardcoded directory layout mirror.

    @since CDAL eval content-based redesign *)

let resolve_path (config : Agent_sdk.Proof_store.config)
    (ref_ : Agent_sdk.Cdal_proof.artifact_ref) : (string, string) result =
  Agent_sdk.Proof_store.resolve_ref config ref_
  |> Result.map (fun r -> r.Agent_sdk.Proof_store.path)

let run_artifact_path (config : Agent_sdk.Proof_store.config)
    ~(run_id : string) ~(relative_path : string) : (string, string) result =
  let ref_ = Agent_sdk.Proof_store.make_ref ~run_id ~subpath:relative_path in
  resolve_path config ref_

let read_json = Agent_sdk.Proof_store.read_json

let read_jsonl = Agent_sdk.Proof_store.read_jsonl
