(** Cdal_loader -- Load and validate a CDAL proof bundle from disk.

    @since CDAL Phase 1A *)

type loaded_bundle = {
  proof : Agent_sdk.Cdal_proof.t;
  manifest_json : Yojson.Safe.t;
  contract : Agent_sdk.Risk_contract.t;
  contract_json : Yojson.Safe.t;
  recomputed_contract_id : string;
}

type load_error =
  | Manifest_not_found of string
  | Manifest_parse_error of string
  | Contract_not_found of string
  | Contract_parse_error of string
  | Schema_unsupported of int
  | Ref_resolution_error of string

let load_error_to_string = function
  | Manifest_not_found path ->
    Printf.sprintf "manifest not found: %s" path
  | Manifest_parse_error msg ->
    Printf.sprintf "manifest parse error: %s" msg
  | Contract_not_found path ->
    Printf.sprintf "contract not found: %s" path
  | Contract_parse_error msg ->
    Printf.sprintf "contract parse error: %s" msg
  | Schema_unsupported v ->
    Printf.sprintf "unsupported schema version: %d (expected %d)"
      v Agent_sdk.Cdal_proof.schema_version_current
  | Ref_resolution_error msg ->
    Printf.sprintf "ref resolution error: %s" msg

(* ================================================================ *)
(* Load pipeline                                                     *)
(* ================================================================ *)

let contract_path_of_run store ~run_id =
  let ref_ = Agent_sdk.Proof_store.make_ref ~run_id ~subpath:"contract.json" in
  match Agent_sdk.Proof_store.resolve_ref store ref_ with
  | Ok resolved -> Ok resolved.path
  | Error e -> Error (Ref_resolution_error e)

let load ~(store : Agent_sdk.Proof_store.config)
    (proof : Agent_sdk.Cdal_proof.t)
    : (loaded_bundle, load_error) result =
  let ( let* ) = Result.bind in
  let manifest_path =
    Agent_sdk.Proof_store.manifest_path store ~run_id:proof.run_id in
  let* contract_path = contract_path_of_run store ~run_id:proof.run_id in
  let* (manifest_proof, manifest_json) =
    Agent_sdk.Proof_store.load_manifest store ~run_id:proof.run_id
    |> Result.map_error (fun msg ->
         if Sys.file_exists manifest_path then Manifest_parse_error msg
         else Manifest_not_found manifest_path)
  in
  if manifest_proof.schema_version <> Agent_sdk.Cdal_proof.schema_version_current then
    Error (Schema_unsupported manifest_proof.schema_version)
  else
  let* (contract, contract_json) =
    Agent_sdk.Proof_store.load_contract store ~run_id:proof.run_id
    |> Result.map_error (fun msg ->
         if Sys.file_exists contract_path then Contract_parse_error msg
         else Contract_not_found contract_path)
  in
  let recomputed_contract_id = Agent_sdk.Risk_contract.contract_id contract in
  Ok {
    proof = manifest_proof;
    manifest_json;
    contract;
    contract_json;
    recomputed_contract_id;
  }
