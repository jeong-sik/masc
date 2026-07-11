type handle = string

let to_string h = h
let of_string s = s

(* Content hash = SHA-256 hex of the raw bytes. Same construction as
   [Review_artifact_store.component_hash] (which truncates to 16 chars); the
   full digest is kept here because this is an identity, not a display label. *)
let hash (raw : string) : handle = Digestif.SHA256.(digest_string raw |> to_hex)

(* A handle is the lowercase-hex SHA-256 of stored bytes: exactly 64 hex chars.
   [store] only ever produces such strings, but [of_string] re-wraps arbitrary
   persisted strings, so a corrupted/forged checkpoint could carry a handle like
   "../../etc/passwd". Validate the shape before using a handle as a path segment
   so [load] cannot read outside [dir] (path-traversal fail-closed). *)
let is_canonical (h : handle) : bool =
  String.length h = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       h

let path_of ~dir (h : handle) = Filename.concat dir h

let store_with writer ~dir (raw : string) : (handle, string) result =
  let h = hash raw in
  (* [Fs_compat.mkdir_p] returns unit and raises on failure (EACCES, ENOSPC, a
     parent path component that is a regular file, test-isolation breach). Honor
     the [.mli]'s "Error on I/O failure" contract by converting those to [Error]
     — a total function. Eio cancellation is not an I/O error: re-raise it so the
     fiber unwinds. *)
  match
    (try
       Fs_compat.mkdir_p dir;
       Ok ()
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "Vision_artifact_store.store: mkdir %s: %s"
            dir
            (Printexc.to_string exn)))
  with
  | Error _ as e -> e
  | Ok () ->
    let path = path_of ~dir h in
    let report = writer path raw in
    Fs_compat.Durable_mutation.fold_report report
      ~not_committed:(fun report ->
        Error
          (Printf.sprintf
             "Vision_artifact_store.store: %s"
             (Fs_compat.Durable_mutation.report_to_string report)))
      ~committed_not_durable:(fun report ->
        Log.Misc.warn
          "vision artifact committed with sync debt path=%s detail=%s"
          path
          (Fs_compat.Durable_mutation.report_to_string report);
        Ok h)
      ~durable:(fun report ->
        (match report.diagnostics with
         | [] -> ()
         | _ ->
           Log.Misc.warn
             "vision artifact durable with cleanup diagnostics path=%s detail=%s"
             path
             (Fs_compat.Durable_mutation.report_to_string report));
        Ok h)

let store_blocking = store_with Fs_compat.save_file_atomic_blocking

let store_eio ~dir raw =
  Eio.Cancel.protect (fun () ->
    Eio_unix.run_in_systhread ~label:"vision-artifact-store" (fun () ->
      store_blocking ~dir raw))
;;

let load ~dir (h : handle) : (string, string) result =
  if not (is_canonical h) then
    Error
      (Printf.sprintf
         "Vision_artifact_store.load: malformed handle (expected 64-char \
          lowercase hex): %S"
         h)
  else
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
