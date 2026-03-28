(** Cdal_loader -- Load and validate a CDAL proof bundle from disk.

    Reads manifest.json and contract.json from the proof store,
    verifies schema version, parses with Agent_sdk decoders,
    and recomputes the content-addressed contract_id.

    @since CDAL Phase 1A *)

(** Successfully loaded and validated bundle.
    [proof] is the decoded manifest proof, which is treated as the
    stored truth source for phase-1A replay. *)
type loaded_bundle = {
  proof : Agent_sdk.Cdal_proof.t;
  manifest_json : Yojson.Safe.t;
  contract : Agent_sdk.Risk_contract.t;
  contract_json : Yojson.Safe.t;
  recomputed_contract_id : string;
}

(** Load errors with structured context. *)
type load_error =
  | Manifest_not_found of string
  | Manifest_parse_error of string
  | Contract_not_found of string
  | Contract_parse_error of string
  | Schema_unsupported of int
  | Ref_resolution_error of string

(** Load a proof bundle from the proof store.

    Steps:
    1. Read and parse manifest.json
    2. Check schema_version = current
    3. Read and parse contract.json
    4. Decode with Agent_sdk types
    5. Recompute contract_id *)
val load :
  store:Agent_sdk.Proof_store.config ->
  Agent_sdk.Cdal_proof.t ->
  (loaded_bundle, load_error) result

(** Human-readable error description. *)
val load_error_to_string : load_error -> string
