(** Cdal_loader -- Load and validate a CDAL proof bundle from disk.

    @since CDAL Phase 1A *)

type loaded_bundle =
  { proof : Oas.Cdal_proof.t
  ; manifest_json : Yojson.Safe.t
  ; contract : Oas.Risk_contract.t
  ; contract_json : Yojson.Safe.t
  ; recomputed_contract_id : string
  }

type load_error =
  | Manifest_not_found of string
  | Manifest_parse_error of string
  | Contract_not_found of string
  | Contract_parse_error of string
  | Schema_unsupported of int
  | Ref_resolution_error of string

let load_error_to_string = function
  | Manifest_not_found path -> Printf.sprintf "manifest not found: %s" path
  | Manifest_parse_error msg -> Printf.sprintf "manifest parse error: %s" msg
  | Contract_not_found path -> Printf.sprintf "contract not found: %s" path
  | Contract_parse_error msg -> Printf.sprintf "contract parse error: %s" msg
  | Schema_unsupported v ->
    Printf.sprintf
      "unsupported schema version: %d (expected %d)"
      v
      Oas.Cdal_proof.schema_version_current
  | Ref_resolution_error msg -> Printf.sprintf "ref resolution error: %s" msg
;;

(* ================================================================ *)
(* File I/O helpers                                                  *)
(* ================================================================ *)

type read_error =
  | File_not_found
  | Parse_error of string

let read_json_file path =
  try Ok (Yojson.Safe.from_file path) with
  | Sys_error _ -> Error File_not_found
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Parse_error (Printexc.to_string exn))
;;

(* ================================================================ *)
(* Load pipeline                                                     *)
(* ================================================================ *)

let load ~(store : Oas.Proof_store.config) (proof : Oas.Cdal_proof.t)
  : (loaded_bundle, load_error) result
  =
  let open Result.Syntax in
  (* 1. Compute manifest path and read *)
  let manifest_path = Oas.Proof_store.manifest_path store ~run_id:proof.run_id in
  let* manifest_json =
    read_json_file manifest_path
    |> Result.map_error (function
      | File_not_found -> Manifest_not_found manifest_path
      | Parse_error msg -> Manifest_parse_error msg)
  in
  let* manifest_proof =
    Oas.Cdal_proof.of_json manifest_json
    |> Result.map_error (fun msg -> Manifest_parse_error msg)
  in
  (* 2. Check schema version from stored manifest *)
  if manifest_proof.schema_version <> Oas.Cdal_proof.schema_version_current
  then Error (Schema_unsupported manifest_proof.schema_version)
  else
    (* 3. Compute contract path via the local proof-store adapter. *)
    let* contract_path =
      Proof_artifact_reader.run_artifact_path
        store
        ~run_id:manifest_proof.run_id
        ~relative_path:"contract.json"
      |> Result.map_error (fun msg -> Ref_resolution_error msg)
    in
    let* contract_json =
      read_json_file contract_path
      |> Result.map_error (function
        | File_not_found -> Contract_not_found contract_path
        | Parse_error msg -> Contract_parse_error msg)
    in
    (* 4. Decode contract with Agent_sdk *)
    let* contract =
      Oas.Risk_contract.of_yojson contract_json
      |> Result.map_error (fun msg -> Contract_parse_error msg)
    in
    (* 5. Recompute contract_id *)
    let recomputed_contract_id = Oas.Risk_contract.contract_id contract in
    Ok
      { proof = manifest_proof
      ; manifest_json
      ; contract
      ; contract_json
      ; recomputed_contract_id
      }
;;
