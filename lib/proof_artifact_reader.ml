(** Proof_artifact_reader — Dereference proof-store:// artifact refs.

    @since CDAL eval content-based redesign *)

let prefix = "proof-store://"
let prefix_len = String.length prefix

let resolve_path (config : Agent_sdk.Proof_store.config)
    (ref_ : Agent_sdk.Cdal_proof.artifact_ref) : (string, string) result =
  if String.length ref_ > prefix_len
     && String.sub ref_ 0 prefix_len = prefix then
    let rel = String.sub ref_ prefix_len (String.length ref_ - prefix_len) in
    (* Reject path traversal: no ".." components or null bytes. *)
    let segments = String.split_on_char '/' rel in
    let has_traversal =
      String.contains rel '\000'
      || List.exists (fun s -> s = "..") segments
    in
    if has_traversal then
      Error (Printf.sprintf "path traversal rejected: %s" ref_)
    else
      let proofs_root = Filename.concat config.root "proofs" in
      Ok (Filename.concat proofs_root rel)
  else
    Error (Printf.sprintf "invalid artifact ref: %s" ref_)

let read_json (config : Agent_sdk.Proof_store.config)
    (ref_ : Agent_sdk.Cdal_proof.artifact_ref)
    : (Yojson.Safe.t, string) result =
  match resolve_path config ref_ with
  | Error e -> Error e
  | Ok path ->
    if Sys.file_exists path then
      (try Ok (Yojson.Safe.from_file path)
       with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printf.sprintf "JSON parse error in %s: %s"
                            path (Printexc.to_string exn)))
    else
      Error (Printf.sprintf "artifact not found: %s" path)
