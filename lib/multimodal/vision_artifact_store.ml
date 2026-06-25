type handle = string

let to_string h = h
let of_string s = s

(* Content hash = SHA-256 hex of the raw bytes. Same construction as
   [Review_artifact_store.component_hash] (which truncates to 16 chars); the
   full digest is kept here because this is an identity, not a display label. *)
let hash (raw : string) : handle = Digestif.SHA256.(digest_string raw |> to_hex)

let path_of ~dir (h : handle) = Filename.concat dir h

let store ~dir (raw : string) : (handle, string) result =
  let h = hash raw in
  Fs_compat.mkdir_p dir;
  match Fs_compat.save_file_atomic (path_of ~dir h) raw with
  | Ok () -> Ok h
  | Error msg -> Error (Printf.sprintf "Vision_artifact_store.store: %s" msg)

let load ~dir (h : handle) : (string, string) result =
  let path = path_of ~dir h in
  match Fs_compat.load_file_opt path with
  | None -> Error (Printf.sprintf "Vision_artifact_store.load: not found: %s" path)
  | Some bytes ->
    (* Verify content-addressing on read: stored bytes must hash back to the
       handle. Catches corruption and forged/wrong handles — fail closed rather
       than return mismatched bytes. *)
    if String.equal (hash bytes) h then Ok bytes
    else
      Error
        (Printf.sprintf
           "Vision_artifact_store.load: content hash mismatch for %s"
           path)
