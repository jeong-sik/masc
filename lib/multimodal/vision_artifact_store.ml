type handle = string

let to_string h = h
let of_string s = s

(* Content hash = SHA-256 hex of the raw bytes. The full digest is kept rather
   than a truncated prefix because this is an identity, not a display label. *)
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

let store ~dir (raw : string) : (handle, string) result =
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
    (match Fs_compat.save_file_atomic (path_of ~dir h) raw with
     | Ok () -> Ok h
     | Error msg -> Error (Printf.sprintf "Vision_artifact_store.store: %s" msg))

type load_error =
  | Malformed_handle of string
  | Missing_artifact of string
  | Hash_mismatch of string
  | Read_failed of string

let load_error_to_string = function
  | Malformed_handle h -> Printf.sprintf
      "Vision_artifact_store.load: malformed handle (expected 64-char lowercase hex): %S" h
  | Missing_artifact path -> "Vision_artifact_store.load: not found: " ^ path
  | Hash_mismatch path -> "Vision_artifact_store.load: content hash mismatch for " ^ path
  | Read_failed detail -> "Vision_artifact_store.load: read failed: " ^ detail

let load ~dir (h : handle) : (string, load_error) result =
  if not (is_canonical h) then Error (Malformed_handle h)
  else
    let path = path_of ~dir h in
    try
      (* Use typed OS failures to distinguish an absent reference from a denied
         or broken store. The actual read retains Fs_compat's path checks. *)
      ignore (Unix.stat path);
      let bytes = Fs_compat.load_file path in
      if String.equal (hash bytes) h then Ok bytes
      else Error (Hash_mismatch path)
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Error (Missing_artifact path)
    | Unix.Unix_error (error, operation, _) ->
        Error (Read_failed (operation ^ ": " ^ Unix.error_message error))
    | Sys_error detail ->
        (* The file can disappear between the first stat and the read, whose
           filesystem adapter may report Sys_error rather than Unix_error.
           Recheck with typed OS errors; never classify from message text. *)
        (try
           ignore (Unix.stat path);
           Error (Read_failed detail)
         with
         | Unix.Unix_error (Unix.ENOENT, _, _) -> Error (Missing_artifact path)
         | Unix.Unix_error (error, operation, _) ->
             Error (Read_failed (operation ^ ": " ^ Unix.error_message error))
         | Sys_error recheck_detail -> Error (Read_failed recheck_detail))
    | End_of_file -> Error (Read_failed "unexpected end of file while reading artifact")
