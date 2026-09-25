type handle = string
let ( let* ) = Result.bind

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
let frames_dir ~dir = Filename.concat dir "frames"

type prune_result =
  { deleted_count : int
  ; reclaimed_bytes : int
  ; remaining_count : int
  ; remaining_bytes : int
  }

(* Frames are an unviewed short-term cache, unlike the kept vision root and
   generated chat media. Task-1719 measured 5,431 MSX frames / 106.89 MiB;
   the 500-entry boundary covers that source's recent frames, while the
   independent 20-MiB byte boundary also caps larger DOS/browser captures.
   A successfully analyzed frame is copied to the kept root before success. *)
let default_max_entries = 500
let default_max_bytes = 20 * 1024 * 1024 (* 20 MB *)

let resolve_limit ~name ?custom default =
  match custom with
  | Some n when n < 0 -> Error (name ^ " must be non-negative")
  | Some n -> Ok n
  | None -> Ok default

let prune_internal ?max_entries ?max_bytes ~protected_handle ~dir () :
    (prune_result, string) result =
  let* max_entries = resolve_limit ~name:"max_entries" ?custom:max_entries default_max_entries in
  let* max_bytes = resolve_limit ~name:"max_bytes" ?custom:max_bytes default_max_bytes in
  if not (Sys.file_exists dir && Sys.is_directory dir) then
    Ok { deleted_count = 0; reclaimed_bytes = 0; remaining_count = 0; remaining_bytes = 0 }
  else
    try
      let filenames = Sys.readdir dir in
      let items = ref [] in
      let total_entries = ref 0 in
      let total_bytes = ref 0 in
      Array.iter
        (fun name ->
          if is_canonical name then begin
            let path = Filename.concat dir name in
            (try
               let stat = Unix.lstat path in
               if stat.Unix.st_kind = Unix.S_REG then begin
                 items := (name, path, stat.Unix.st_size, stat.Unix.st_mtime) :: !items;
                 incr total_entries;
                 total_bytes := !total_bytes + stat.Unix.st_size
               end
             with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
          end)
        filenames;
      if !total_entries <= max_entries && !total_bytes <= max_bytes then
        Ok
          { deleted_count = 0
          ; reclaimed_bytes = 0
          ; remaining_count = !total_entries
          ; remaining_bytes = !total_bytes
          }
      else begin
        (* Sort by mtime ascending (oldest first). If mtimes are equal, sort by name for determinism. *)
        let sorted =
          (* A successful [store] must keep the handle it just wrote even if
             another file has a future mtime or equal-resolution timestamp.
             The current frame fits the validated limits on its own. *)
          List.filter (fun (name, _, _, _) -> Some name <> protected_handle) !items
          |>
          List.sort
            (fun (n1, _, _, m1) (n2, _, _, m2) ->
              let cmp = Float.compare m1 m2 in
              if cmp <> 0 then cmp else String.compare n1 n2)
        in
        let cur_entries = ref !total_entries in
        let cur_bytes = ref !total_bytes in
        let deleted = ref 0 in
        let reclaimed = ref 0 in
        let rec evict = function
          | [] -> Ok ()
          | (_name, path, size, _mtime) :: rest ->
              if !cur_entries > max_entries || !cur_bytes > max_bytes then
                (match
                   try Unix.unlink path; Ok `Deleted with
                   | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok `Already_absent
                   | Unix.Unix_error (err, fn, arg) ->
                       Error
                         (Printf.sprintf "unlink %s failed: %s (%s %s)"
                            path (Unix.error_message err) fn arg)
                 with
                 | Error _ as error -> error
                 | Ok outcome ->
                     decr cur_entries;
                     cur_bytes := !cur_bytes - size;
                     if outcome = `Deleted then begin
                       incr deleted;
                       reclaimed := !reclaimed + size
                     end;
                     evict rest)
              else Ok ()
        in
        (match evict sorted with
         | Error _ as error -> error
         | Ok () ->
             Ok
               { deleted_count = !deleted
               ; reclaimed_bytes = !reclaimed
               ; remaining_count = !cur_entries
               ; remaining_bytes = !cur_bytes
               })
      end
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Error (Printf.sprintf "Vision_artifact_store.prune: %s" (Printexc.to_string exn))

let prune ?max_entries ?max_bytes ~dir () =
  prune_internal ?max_entries ?max_bytes ~protected_handle:None ~dir ()

let store ~auto_prune ?max_entries ?max_bytes ~dir (raw : string) : (handle, string) result =
  let* max_entries = resolve_limit ~name:"max_entries" ?custom:max_entries default_max_entries in
  let* max_bytes = resolve_limit ~name:"max_bytes" ?custom:max_bytes default_max_bytes in
  let* () =
    if auto_prune && max_entries = 0 then Error "max_entries must be positive when storing a pruned frame"
    else if auto_prune && (max_bytes = 0 || max_bytes < String.length raw) then
      Error "max_bytes must hold the frame being stored"
    else Ok ()
  in
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
    (* Verify bytes on every store: a handle or cached stat cannot establish
       that the destination still exists and contains this image. A failed
       comparison falls through to the existing atomic repair/write path. *)
    let already_stored =
      match Fs_compat.load_owned_regular_file_prefix
              ~ownership_root:dir ~max_bytes:(String.length raw) path with
      | Ok (Some existing) ->
          not existing.truncated && String.equal existing.content raw
      | Ok None | Error _ -> false
    in
    if already_stored then begin
      (* A re-store hands this handle out again: refresh mtime to now so the
         next prune does not evict a file the caller is actively re-using. *)
      (try Unix.utimes path 0.0 0.0 with Unix.Unix_error _ -> ());
      Ok h
    end
    else
      match Fs_compat.save_file_atomic path raw with
      | Ok () ->
          if auto_prune then begin
            match prune_internal ~max_entries ~max_bytes
                    ~protected_handle:(Some h) ~dir () with
            | Ok { deleted_count; reclaimed_bytes; remaining_count; remaining_bytes } ->
                if deleted_count > 0 then
                  Log.Misc.info "vision: prune %s: deleted %d frames (%d bytes), %d remaining (%d bytes)" dir deleted_count reclaimed_bytes remaining_count remaining_bytes
            | Error err ->
                Log.Misc.warn "vision: prune %s failed: %s" dir err
          end;
          Ok h
      | Error msg -> Error (Printf.sprintf "Vision_artifact_store.store: %s" msg)

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

let load_from_path (path : string) (h : handle) : (string, load_error) result =
  try
    (* Use typed OS failures to distinguish an absent reference from a denied
       or broken store. The actual read retains Fs_compat's path checks. *)
    (* See Missing_artifact below: stat probes existence; metadata is unused. *)
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
         (* See the ENOENT branch below: only continued existence is needed. *)
         ignore (Unix.stat path);
         Error (Read_failed detail)
       with
       | Unix.Unix_error (Unix.ENOENT, _, _) -> Error (Missing_artifact path)
       | Unix.Unix_error (error, operation, _) ->
           Error (Read_failed (operation ^ ": " ^ Unix.error_message error))
       | Sys_error recheck_detail -> Error (Read_failed recheck_detail))
  | End_of_file -> Error (Read_failed "unexpected end of file while reading artifact")

let load ~dir (h : handle) : (string, load_error) result =
  if not (is_canonical h) then Error (Malformed_handle h)
  else
    let primary_path = path_of ~dir h in
    let frame_path = path_of ~dir:(frames_dir ~dir) h in
    match load_from_path primary_path h with
    | Ok bytes -> Ok bytes
    | Error (Missing_artifact _) ->
        (match load_from_path frame_path h with
         | Ok bytes -> Ok bytes
         | Error (Missing_artifact _) -> Error (Missing_artifact primary_path)
         | Error (Malformed_handle _ | Hash_mismatch _ | Read_failed _) as e -> e)
    | Error (Hash_mismatch _ | Read_failed _ as primary_error) ->
        (match load_from_path frame_path h with
         | Ok bytes ->
             Log.Misc.warn
               "vision: root artifact %s is unreadable; using verified frame copy"
               primary_path;
             Ok bytes
         | Error _ -> Error primary_error)
    | Error (Malformed_handle _) as error -> error
