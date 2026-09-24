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

type prune_result =
  { deleted_count : int
  ; reclaimed_bytes : int
  ; remaining_count : int
  ; remaining_bytes : int
  }

(* Default capacity limits: 500 frames at ~20 KB average covers ~10 MB,
   providing sufficient recent temporal context for MSX/DOS/Browser vision
   lanes across turns without unbounded disk accumulation. Derived from disk census
   in task-1719 (top consumer msx-retro-mania.vision held 5,431 frames / 106.89 MB). *)
let default_max_entries = 500
let default_max_bytes = 20 * 1024 * 1024 (* 20 MB *)

let get_env_positive_int name default =
  match Sys.getenv_opt name with
  | None -> default
  | Some s ->
      match int_of_string_opt (String.trim s) with
      | Some n when n > 0 -> n
      | Some _ | None ->
          Log.Keeper.warn "vision: invalid %s=%S: must be a positive integer, using default %d" name s default;
          default

let resolved_max_entries ?max_entries () =
  match max_entries with
  | Some n when n >= 0 -> n
  | Some _ ->
      Log.Keeper.warn "vision: invalid max_entries: must be non-negative, using default %d" default_max_entries;
      default_max_entries
  | None -> get_env_positive_int "MASC_VISION_MAX_ARTIFACTS_PER_KEEPER" default_max_entries

let resolved_max_bytes ?max_bytes () =
  match max_bytes with
  | Some b when b >= 0 -> b
  | Some _ ->
      Log.Keeper.warn "vision: invalid max_bytes: must be non-negative, using default %d" default_max_bytes;
      default_max_bytes
  | None -> get_env_positive_int "MASC_VISION_MAX_BYTES_PER_KEEPER" default_max_bytes

let prune ?max_entries ?max_bytes ~dir () : (prune_result, string) result =
  let max_entries = resolved_max_entries ?max_entries () in
  let max_bytes = resolved_max_bytes ?max_bytes () in
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
          List.sort
            (fun (n1, _, _, m1) (n2, _, _, m2) ->
              let cmp = Float.compare m1 m2 in
              if cmp <> 0 then cmp else String.compare n1 n2)
            !items
        in
        let cur_entries = ref !total_entries in
        let cur_bytes = ref !total_bytes in
        let deleted = ref 0 in
        let reclaimed = ref 0 in
        let rec evict = function
          | [] -> ()
          | (_name, path, size, _mtime) :: rest ->
              if !cur_entries > max_entries || !cur_bytes > max_bytes then begin
                (try
                   Unix.unlink path;
                   decr cur_entries;
                   cur_bytes := !cur_bytes - size;
                   incr deleted;
                   reclaimed := !reclaimed + size
                 with
                 | Unix.Unix_error (Unix.ENOENT, _, _) ->
                     decr cur_entries;
                     cur_bytes := !cur_bytes - size
                 | Unix.Unix_error _ -> ());
                evict rest
              end
        in
        evict sorted;
        Ok
          { deleted_count = !deleted
          ; reclaimed_bytes = !reclaimed
          ; remaining_count = !cur_entries
          ; remaining_bytes = !cur_bytes
          }
      end
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Error (Printf.sprintf "Vision_artifact_store.prune: %s" (Printexc.to_string exn))

let store ?(auto_prune = true) ~dir (raw : string) : (handle, string) result =
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
            match prune ~dir () with
            | Ok { deleted_count; reclaimed_bytes; remaining_count; remaining_bytes } ->
                if deleted_count > 0 then
                  Log.Keeper.info "vision: prune %s: deleted %d frames (%d bytes), %d remaining (%d bytes)" dir deleted_count reclaimed_bytes remaining_count remaining_bytes
            | Error err ->
                Log.Keeper.warn "vision: prune %s failed: %s" dir err
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

let load ~dir (h : handle) : (string, load_error) result =
  if not (is_canonical h) then Error (Malformed_handle h)
  else
    let path = path_of ~dir h in
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
