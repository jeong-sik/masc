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
(* File I/O helpers                                                  *)
(* ================================================================ *)

let read_json_file path =
  if Sys.file_exists path then
    (try Ok (Yojson.Safe.from_file path)
     with exn -> Error (Printexc.to_string exn))
  else
    Error "not found"

(* ================================================================ *)
(* Load pipeline                                                     *)
(* ================================================================ *)

let load ~(store : Agent_sdk.Proof_store.config)
    (proof : Agent_sdk.Cdal_proof.t)
    : (loaded_bundle, load_error) result =
  let ( let* ) = Result.bind in
  (* 1. Compute manifest path and read *)
  let manifest_path =
    Agent_sdk.Proof_store.manifest_path store ~run_id:proof.run_id in
  let* manifest_json =
    read_json_file manifest_path
    |> Result.map_error (fun msg ->
      if msg = "not found" then Manifest_not_found manifest_path
      else Manifest_parse_error msg)
  in
  (* 2. Check schema version *)
  let () =
    ignore manifest_json  (* manifest was already loaded; proof carries version *)
  in
  if proof.schema_version <> Agent_sdk.Cdal_proof.schema_version_current then
    Error (Schema_unsupported proof.schema_version)
  else
  (* 3. Compute contract path and read *)
  let contract_path =
    Filename.concat
      (Filename.concat
         (Filename.concat store.root "proofs")
         proof.run_id)
      "contract.json"
  in
  let* contract_json =
    read_json_file contract_path
    |> Result.map_error (fun msg ->
      if msg = "not found" then Contract_not_found contract_path
      else Contract_parse_error msg)
  in
  (* 4. Decode contract with Agent_sdk *)
  let* contract =
    Agent_sdk.Risk_contract.of_yojson contract_json
    |> Result.map_error (fun msg -> Contract_parse_error msg)
  in
  (* 5. Recompute contract_id *)
  let recomputed_contract_id = Agent_sdk.Risk_contract.contract_id contract in
  Ok {
    proof;
    manifest_json;
    contract;
    contract_json;
    recomputed_contract_id;
  }
