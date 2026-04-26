(** Proof_artifact_reader — Dereference proof-store:// artifact refs.

    @since CDAL eval content-based redesign *)

let prefix = "proof-store://"
let prefix_len = String.length prefix
let proofs_root (config : Oas.Proof_store.config) = Filename.concat config.root "proofs"

let validate_relative_path ~raw ~label =
  let segments = String.split_on_char '/' raw in
  let has_traversal =
    String.contains raw '\000' || List.exists (fun segment -> segment = "..") segments
  in
  if has_traversal
  then Error (Printf.sprintf "path traversal rejected in %s: %s" label raw)
  else Ok raw
;;

let run_artifact_path
      (config : Oas.Proof_store.config)
      ~(run_id : string)
      ~(relative_path : string)
  : (string, string) result
  =
  Result.bind (validate_relative_path ~raw:run_id ~label:"run_id") (fun clean_run_id ->
    Result.bind
      (validate_relative_path ~raw:relative_path ~label:"relative_path")
      (fun clean_relative_path ->
         Ok
           (Filename.concat
              (Filename.concat (proofs_root config) clean_run_id)
              clean_relative_path)))
;;

let resolve_path (config : Oas.Proof_store.config) (ref_ : Oas.Cdal_proof.artifact_ref)
  : (string, string) result
  =
  if String.length ref_ > prefix_len && String.sub ref_ 0 prefix_len = prefix
  then (
    let rel = String.sub ref_ prefix_len (String.length ref_ - prefix_len) in
    validate_relative_path ~raw:rel ~label:"artifact_ref"
    |> Result.map (fun clean_rel -> Filename.concat (proofs_root config) clean_rel))
  else Error (Printf.sprintf "invalid artifact ref: %s" ref_)
;;

let read_json (config : Oas.Proof_store.config) (ref_ : Oas.Cdal_proof.artifact_ref)
  : (Yojson.Safe.t, string) result
  =
  match resolve_path config ref_ with
  | Error e -> Error e
  | Ok path ->
    if Sys.file_exists path
    then (
      try Ok (Yojson.Safe.from_file path) with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Error (Printf.sprintf "JSON parse error in %s: %s" path (Printexc.to_string exn)))
    else Error (Printf.sprintf "artifact not found: %s" path)
;;
