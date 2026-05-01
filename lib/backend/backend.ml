(** Backend: OCaml 5.x Eio-native storage backend

    Direct-style async I/O using Eio.

    This module provides the same interface as Backend, but uses:
    - Eio.Path for file operations
    - Eio.Mutex for concurrency control
    - Direct style (no let*/>>= needed)

    Migration path: Backend.FileSystemBackend -> Backend.FileSystem

    Compact Protocol v4: Transparent zstd compression with Dictionary
    - Uses trained multi-format dictionary for 32-2048 byte messages
    - Dictionary achieves ~70% compression vs ~6% standard zstd on small data
    - Automatically compresses data >32 bytes on save
    - Automatically decompresses on load (ZSTD/ZSTDD header detection)
*)

(** {1 Compression} *)

module Compression = Backend_compression

(** {1 Types} *)

(* Types are shared with Backend_pg via Backend_types
   to avoid circular dependency. Re-exported here for API compatibility. *)
include Backend_types

(** {1 FileSystem Backend (Eio)} *)

module FileSystem = struct
  type t = {
    config: config;
    fs: Eio.Fs.dir_ty Eio.Path.t;
    mutex: Eio.Mutex.t;
    key_index: (string, unit) Hashtbl.t;
    key_index_mu: Mutex.t;
    (** Domain-safe mutex for [key_index].
        Uses [Stdlib.Mutex] (not [Eio.Mutex]) so that
        Executor_pool workers on non-Eio domains can safely
        read/write the shared hashtable. *)
    mutable key_index_promise: unit Eio.Promise.or_exn option;
    clock: float Eio.Time.clock_ty Eio.Resource.t option;
  }

  (** Create a new FileSystem backend *)
  let create ~fs ?clock config =
    let path = Eio.Path.(fs / config.base_path) in
    (* Ensure base directory exists *)
    (try Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 path
     with Eio.Cancel.Cancelled _ as e -> raise e
        | e ->
            Log.legacy_traceln ~level:Log.Warn ~module_name:"Backend"
              (Printf.sprintf "[WARN] mkdirs base failed: %s"
                 (Printexc.to_string e)));
    {
      config;
      fs = path;
      mutex = Eio.Mutex.create ();
      key_index = Hashtbl.create 256;
      key_index_mu = Mutex.create ();
      key_index_promise = None;
      clock;
    }

  (** {2 Domain-safe key_index helpers}

      All access to [t.key_index] MUST go through these helpers so that
      Executor_pool workers (which lack Eio context) can safely touch
      the shared hashtable.  Uses [Stdlib.Mutex] + [Fun.protect]. *)

  let ki_replace t k v =
    Mutex.lock t.key_index_mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.key_index_mu)
      (fun () -> Hashtbl.replace t.key_index k v)

  let ki_remove t k =
    Mutex.lock t.key_index_mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.key_index_mu)
      (fun () -> Hashtbl.remove t.key_index k)

  let ki_length t =
    Mutex.lock t.key_index_mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.key_index_mu)
      (fun () -> Hashtbl.length t.key_index)

  let ki_iter t f =
    let entries =
      Mutex.lock t.key_index_mu;
      Fun.protect ~finally:(fun () -> Mutex.unlock t.key_index_mu) (fun () ->
        Hashtbl.fold (fun k v acc -> (k, v) :: acc) t.key_index [])
    in
    List.iter (fun (k, v) -> f k v) entries

  let ki_replace_bulk t entries =
    Mutex.lock t.key_index_mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.key_index_mu) (fun () ->
      List.iter (fun (k, v) -> Hashtbl.replace t.key_index k v) entries)

  (** {2 Key Validation} *)

  let validate_key key =
    if String.length key = 0 then
      Error (InvalidKey "Empty key not allowed")
    else if String.contains key '\x00' then
      Error (InvalidKey "NUL byte not allowed")
    else if String.contains key '/' then
      Error (InvalidKey "Slash not allowed (use ':' as separator)")
    else if key.[0] = ':' then
      Error (InvalidKey "Key cannot start with ':'")
    else if key.[String.length key - 1] = ':' then
      Error (InvalidKey "Key cannot end with ':'")
    else
      (* Check segments *)
      let segments = String.split_on_char ':' key in
      let rec check_segments = function
        | [] -> Ok key
        | seg :: rest ->
            if seg = "" then
              Error (InvalidKey "Consecutive colons not allowed")
            else if seg = "." || seg = ".." then
              Error (InvalidKey "Path traversal detected")
            else if Base.String.is_prefix seg ~prefix:".." then
              Error (InvalidKey "Path traversal detected")
            else
              (* Blocklist: reject only dangerous characters, allow UTF-8 *)
              let has_dangerous = String.exists (fun c ->
                let code = Char.code c in
                code = 0 || code < 32 ||       (* null/control chars *)
                c = '/' || c = '\\' ||         (* path separators *)
                c = ':' ||                     (* key separator *)
                c = '*' || c = '?' ||          (* wildcards *)
                c = '"' || c = '\'' ||         (* quotes *)
                c = '<' || c = '>' || c = '|'  (* shell metacharacters *)
              ) seg in
              if has_dangerous then
                Error (InvalidKey (Printf.sprintf "Invalid character in key segment '%s'" seg))
              else
                check_segments rest
      in
      check_segments segments

  let key_to_path t key =
    match validate_key key with
    | Error e -> Error e
    | Ok safe_key ->
        let path_part = String.map (function ':' -> '/' | c -> c) safe_key in
        Ok Eio.Path.(t.fs / path_part)

  (** Run a blocking file operation in a system thread.
      FileSystem backend requires Eio context — no fallback. *)
  let run_blocking_file_op f =
    Eio_unix.run_in_systhread f

  let with_locked_rw_fd path_str f =
    run_blocking_file_op (fun () ->
        let fd = File_lock_eio.acquire_flock_retry ~lock_path:path_str
            ~mode:[ Unix.O_RDWR; Unix.O_CREAT ] ~perm:0o644
            ~max_attempts:100 ~caller:"backend_eio" ()
        in
        Common.protect ~module_name:"backend_eio" ~finally_label:"finalizer"
          ~finally:(fun () ->
            (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
            Unix.close fd)
        @@ fun () -> f fd)

  (** Write all bytes to fd, retrying on partial writes.
      Raises [Unix.Unix_error] if a zero-length write occurs (disk full). *)
  let write_all_substring fd s ofs len =
    let rec loop ofs remaining =
      if remaining > 0 then begin
        let written = Unix.write_substring fd s ofs remaining in
        if written = 0 then
          raise (Unix.Unix_error (Unix.EIO, "write_all_substring", "zero-length write"));
        loop (ofs + written) (remaining - written)
      end
    in
    loop ofs len

  (** {2 Core Operations} *)

  let _ensure_parent_dir ?(log_errors = false) path =
    match Eio.Path.split path with
    | Some (parent, _) ->
        (try Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 parent
         with Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
              if log_errors then
                Log.legacy_traceln ~level:Log.Warn ~module_name:"Backend"
                  (Printf.sprintf "[WARN] mkdirs failed: %s"
                     (Printexc.to_string exn))
              else
                raise exn)
    | None -> ()

  let _compress = Compression.compress_with_header
  let _decompress = Compression.decompress_auto

  let has_zstd_header content =
    Base.String.is_prefix content ~prefix:"ZSTD"

  let decompress_with_context ~context content =
    let had_header = has_zstd_header content in
    let decompressed = _decompress content in
    if had_header && String.equal decompressed content then
      Log.Backend.warn "[EioFS] decompress fallback for %s" context;
    decompressed

  (** Get value by key (auto-decompresses ZSTD if detected) *)
  let get t key =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match key_to_path t key with
      | Error e -> Error e
        | Ok path ->
          try
            let content = Eio.Path.load path in
            (* Compact Protocol v4: Auto-decompress if ZSTD header present *)
            let decompressed = decompress_with_context ~context:key content in
            Ok decompressed
          with
          | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
              Error (NotFound key)
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
              Error (IOError (Printexc.to_string exn))
    )

  (** Set value (auto-compresses with ZSTD if beneficial).

      Writes go through a sibling [.tmp-atomic] file and are then
      [Eio.Path.rename]d into place. Without this indirection a reader
      that opens the target file while [Eio.Path.save ~Or_truncate] is
      still streaming bytes observes a truncated payload — that was the
      source of the [JSON parse error: Unexpected end of input] storm
      on [backlog.json] (62 occurrences in one hour, 2026-04-18) that
      dropped the stale-claims GC into its read-failure skip branch
      and blocked claim lifecycle transitions.

      The mutex inside [t] already serialises writers against each
      other; this change adds atomicity against concurrent readers. *)
  let set t key value =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match validate_key key with
      | Error e -> Error e
      | Ok safe_key ->
          let path_part =
            String.map (function ':' -> '/' | c -> c) safe_key
          in
          let path = Eio.Path.(t.fs / path_part) in
          let tmp_path =
            Eio.Path.(t.fs / (path_part ^ ".tmp-atomic"))
          in
          try
            _ensure_parent_dir ~log_errors:true path;
            let compressed = _compress value in
            Eio.Path.save ~create:(`Or_truncate 0o644) tmp_path compressed;
            Eio.Path.rename tmp_path path;
            ki_replace t key ();
            Ok ()
          with
          | Eio.Cancel.Cancelled _ as exn ->
              (try Eio.Path.unlink tmp_path with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Backend.warn "backend atomic write: unlink tmp failed: %s" (Printexc.to_string exn));
              raise exn
          | exn ->
              (try Eio.Path.unlink tmp_path with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Backend.warn "backend atomic write: unlink tmp failed: %s" (Printexc.to_string exn));
              Error (IOError (Printexc.to_string exn))
    )

  (** Delete key *)
  let delete t key =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match key_to_path t key with
      | Error e -> Error e
      | Ok path ->
          try
            Eio.Path.unlink path;
            ki_remove t key;
            Ok ()
          with
          | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
              Error (NotFound key)
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
              Error (IOError (Printexc.to_string exn))
    )

  (** List keys with prefix *)
  let starts_with ~prefix value = String.starts_with ~prefix value


  let rec collect_keys_under ~requested_prefix ~logical_prefix path acc =
    match Eio.Path.kind ~follow:true path with
    | `Directory ->
        Eio.Path.read_dir path
        |> List.fold_left
             (fun acc name ->
               let child_prefix =
                 if logical_prefix = "" then name else logical_prefix ^ ":" ^ name
               in
               collect_keys_under ~requested_prefix ~logical_prefix:child_prefix
                 Eio.Path.(path / name) acc)
             acc
    | `Regular_file ->
        if requested_prefix = ""
           || starts_with ~prefix:requested_prefix logical_prefix
        then
          logical_prefix :: acc
        else
          acc
    | _ -> acc

  let validate_prefix prefix =
    if prefix = "" then
      Ok ()
    else
      let len = String.length prefix in
      let key =
        if prefix.[len - 1] = ':' then
          String.sub prefix 0 (len - 1)
        else
          prefix
      in
      match validate_key key with
      | Ok _ -> Ok ()
      | Error e -> Error e

  let prefix_scan_root t ~prefix =
    match validate_prefix prefix with
    | Error e -> Error e
    | Ok () ->
        let segments = String.split_on_char ':' prefix in
        let complete_segments =
          if prefix <> "" && prefix.[String.length prefix - 1] = ':' then
            List.filter (fun segment -> segment <> "") segments
          else
            match List.rev segments with
            | [] | [ _ ] -> []
            | _partial :: parents_rev -> List.rev parents_rev
        in
        let path =
          List.fold_left (fun path segment -> Eio.Path.(path / segment)) t.fs
            complete_segments
        in
        let logical_prefix = String.concat ":" complete_segments in
        Ok (path, logical_prefix)

  let list_keys_by_prefix_scan t ~prefix =
    match prefix_scan_root t ~prefix with
    | Error e -> Error e
    | Ok (scan_root, logical_prefix) -> (
        try
          let keys =
            collect_keys_under ~requested_prefix:prefix ~logical_prefix
              scan_root []
          in
          ki_replace_bulk t (List.map (fun key -> (key, ())) keys);
          Ok (List.sort_uniq String.compare keys)
        with
        | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok []
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> Error (IOError (Printexc.to_string exn)))

  let ensure_key_index t =
    (* Domain-safe check-and-populate.  Stdlib.Mutex serializes the
       check of key_index length + key_index_promise so that two
       Executor_pool domains cannot both start a population traverse.
       The mutex is released BEFORE Eio.Promise.await (which needs Eio
       fiber context and would deadlock under a held Stdlib.Mutex). *)
    let action =
      Mutex.lock t.key_index_mu;
      Fun.protect ~finally:(fun () -> Mutex.unlock t.key_index_mu) (fun () ->
        (* Direct Hashtbl access — already inside key_index_mu lock.
           ki_length would deadlock (non-reentrant mutex). *)
        if Hashtbl.length t.key_index > 0 then `Done
        else match t.key_index_promise with
          | Some p -> `Wait p
          | None ->
            let p, r = Eio.Promise.create () in
            t.key_index_promise <- Some p;
            `Populate r)
    in
    match action with
    | `Done -> ()
    | `Wait p ->
      let result =
        match t.clock with
        | Some clock -> (
            match
              Fiber.first
                (fun () -> `Ok (Eio.Promise.await p))
                (fun () ->
                  Eio.Time.sleep clock 30.0;
                  `Timeout)
            with
            | `Ok r -> r
            | `Timeout ->
                Log.Backend.warn "key_index populate wait timed out after 30s";
                Ok ())
        | None -> Eio.Promise.await p
      in
      (match result with
       | Ok () -> ()
       | Error (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | Error exn ->
           Log.Backend.debug "key_index populate wait failed: %s"
             (Printexc.to_string exn))
    | `Populate r ->
      (try
         let keys =
           collect_keys_under ~requested_prefix:"" ~logical_prefix:"" t.fs []
         in
         ki_replace_bulk t (List.map (fun k -> (k, ())) keys);
         let len = ki_length t in
         if len > 0 then
           Log.Backend.info "key_index populated: %d keys" len;
         Eio.Promise.resolve_ok r ()
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Mutex.lock t.key_index_mu;
         Fun.protect ~finally:(fun () -> Mutex.unlock t.key_index_mu) (fun () ->
           t.key_index_promise <- None);
         Eio.Promise.resolve_error r exn;
         match exn with
         | Eio.Cancel.Cancelled _ -> raise exn
         | _ ->
           Log.Backend.warn "key_index population failed: %s"
             (Printexc.to_string exn))

  (** Check if key exists (in-memory index first, filesystem fallback) *)
  let exists t key =
    match validate_key key with
    | Error _ -> false
    | Ok _ ->
      (* Verify the real filesystem even on index hits so raw rm_rf/reset
         cannot leave stale positives in the in-memory key index. *)
      match key_to_path t key with
      | Error _ -> false
      | Ok path ->
          (try
             match Eio.Path.kind ~follow:true path with
             | `Regular_file ->
                 ki_replace t key ();
                 true
             | _ ->
                 ki_remove t key;
                 false
           with Eio.Cancel.Cancelled _ as e -> raise e
              | _ ->
             ki_remove t key;
             false)

  let list_keys t ~prefix =
    if prefix = "" then begin
      ensure_key_index t;
      let result = ref [] in
      ki_iter t (fun k () -> result := k :: !result);
      Ok (List.sort_uniq String.compare !result)
    end else
      list_keys_by_prefix_scan t ~prefix

  (** Set if not exists (atomic, auto-compresses) *)
  let set_if_not_exists t key value =
    (* Compact Protocol v4: Compress before saving *)
    let compressed = _compress value in
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match key_to_path t key with
      | Error e -> Error e
      | Ok path ->
          try
            (* Check if exists first *)
            match Eio.Path.kind ~follow:true path with
            | `Regular_file -> Error (AlreadyExists key)
            | _ ->
                _ensure_parent_dir ~log_errors:true path;
                (* Write with exclusive create *)
                Eio.Path.save ~create:(`Exclusive 0o644) path compressed;
                ki_replace t key ();
                Ok true
          with
          | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
              (* Parent doesn't exist, create it *)
              _ensure_parent_dir path;
              Eio.Path.save ~create:(`Exclusive 0o644) path compressed;
              ki_replace t key ();
              Ok true
          | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) ->
              Error (AlreadyExists key)
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
              Error (IOError (Printexc.to_string exn))
    )

  (** {2 Lock Operations} *)

  type lock_info = {
    owner: string;
    acquired_at: float;
    expires_at: float;
  }

  let lock_info_to_json info =
    Yojson.Safe.to_string (`Assoc [
      ("owner", `String info.owner);
      ("acquired_at", `Float info.acquired_at);
      ("expires_at", `Float info.expires_at);
    ])

  let lock_info_of_json json =
    let trimmed = String.trim json in
    if trimmed = "" then
      None
    else
    try
      let module U = Yojson.Safe.Util in
      let j = Yojson.Safe.from_string trimmed in
      let parse_float = function
        | `Float f -> Some f
        | `Int i -> Some (float_of_int i)
        | `Intlit s -> float_of_string_opt s
        | `String s -> float_of_string_opt s
        | _ -> None
      in
      let parse_string = function
        | `String s -> Some s
        | _ -> None
      in
      match
        (parse_string (U.member "owner" j),
         parse_float (U.member "acquired_at" j),
         parse_float (U.member "expires_at" j))
      with
      | Some owner, Some acquired_at, Some expires_at ->
          Some { owner; acquired_at; expires_at }
      | _ -> None
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Log.Misc.error "parse_lock_info failed: %s" (Printexc.to_string e);
      None

  let acquire_lock t ~key ~owner ~ttl_seconds =
    let lock_key = "locks:" ^ key in
    let now = Time_compat.now () in
    let info = {
      owner;
      acquired_at = now;
      expires_at = now +. float_of_int ttl_seconds;
    } in
    match set_if_not_exists t lock_key (lock_info_to_json info) with
    | Ok true -> Ok true
    | Ok false -> Ok false
    | Error (AlreadyExists _) ->
        (* Check if expired *)
        (match get t lock_key with
         | Ok json ->
             (match lock_info_of_json json with
              | Some existing when existing.expires_at < now ->
                  (* Expired, try to take over *)
                  (match set t lock_key (lock_info_to_json info) with
                   | Ok () -> Ok true
                   | Error e -> Error e)
              | Some _ -> Ok false
              | None ->
                  (* Invalid lock metadata, overwrite to recover *)
                  (match set t lock_key (lock_info_to_json info) with
                   | Ok () -> Ok true
                   | Error e -> Error e))
         | Error _ -> Ok false)
    | Error e -> Error e

  let release_lock t ~key ~owner =
    let lock_key = "locks:" ^ key in
    match get t lock_key with
    | Ok json ->
        (match lock_info_of_json json with
         | Some info when info.owner = owner ->
             (match delete t lock_key with
              | Ok () -> Ok true
              | Error _ -> Ok false)
         | _ -> Ok false)  (* Not owner or invalid *)
    | Error (NotFound _) -> Ok true  (* Already released *)
    | Error e -> Error e

  let extend_lock t ~key ~owner ~ttl_seconds =
    let lock_key = "locks:" ^ key in
    match get t lock_key with
    | Ok json ->
        (match lock_info_of_json json with
         | Some info when info.owner = owner ->
             let now = Time_compat.now () in
             let new_info = { info with expires_at = now +. float_of_int ttl_seconds } in
             (match set t lock_key (lock_info_to_json new_info) with
              | Ok () -> Ok true
              | Error e -> Error e)
         | _ -> Ok false)
    | Error e -> Error e

  (** {2 Atomic Operations (Cross-Process Safe)} *)

  (** Atomically increment a counter stored in a file.
      Uses Unix.lockf with non-blocking retry for cross-process synchronization.
      Returns the NEW value after increment.

      This is safe for multiple processes accessing the same file.
      Uses F_TLOCK (try lock) to avoid blocking Eio's event loop.
  *)
  let atomic_increment t key =
    match key_to_path t key with
    | Error e -> Error e
    | Ok path ->
        try
          (* Ensure parent directory exists *)
          (match Eio.Path.split path with
           | Some (parent, _) ->
               (try Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 parent
                with Eio.Cancel.Cancelled _ as e -> raise e
                   | e ->
                       Log.legacy_traceln ~level:Log.Warn ~module_name:"Backend"
                         (Printf.sprintf "[WARN] mkdirs failed: %s"
                            (Printexc.to_string e)))
           | None -> ());

          let path_str = Eio.Path.native_exn path in
          with_locked_rw_fd path_str @@ fun fd ->
          let _ = Unix.lseek fd 0 Unix.SEEK_SET in
          let buf = Bytes.create 32 in
          let n = Unix.read fd buf 0 32 in
          let current =
            if n = 0 then 0
            else
              Safe_ops.int_of_string_with_default ~default:0
                (String.trim (Bytes.sub_string buf 0 n))
          in
          let new_value = current + 1 in
          let new_str = string_of_int new_value in
          let _ = Unix.lseek fd 0 Unix.SEEK_SET in
          Unix.ftruncate fd 0;
          write_all_substring fd new_str 0 (String.length new_str);
          Ok new_value
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Error (IOError (Printf.sprintf "atomic_increment failed: %s" (Printexc.to_string exn)))

  (** Atomically get the current counter value without incrementing *)
  (** Atomically get the current counter value without incrementing.
      Reads the file without locking — the counter is a small integer
      written atomically by [atomic_increment] (which holds an exclusive
      lock).  A lockless read avoids EBADF on Linux where [F_TLOCK] on
      an [O_RDONLY] fd is rejected per POSIX. *)
  let atomic_get t key =
    match key_to_path t key with
    | Error e -> Error e
    | Ok path ->
        try
          let path_str = Eio.Path.native_exn path in
          run_blocking_file_op (fun () ->
            try
              let fd = Unix.openfile path_str [ Unix.O_RDONLY ] 0o644 in
              Common.protect ~module_name:"backend_eio" ~finally_label:"finalizer"
                ~finally:(fun () -> Unix.close fd)
              @@ fun () ->
              let buf = Bytes.create 32 in
              let n = Unix.read fd buf 0 32 in
              if n = 0 then Ok 0
              else
                Ok
                  (Safe_ops.int_of_string_with_default ~default:0
                     (String.trim (Bytes.sub_string buf 0 n)))
            with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok 0)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Error (IOError (Printf.sprintf "atomic_get failed: %s" (Printexc.to_string exn)))

  (** Atomically update a file with a transform function.
      The transform receives [Some content] if file exists, [None] if not.
      Returns [Ok new_content] on success.

      This is safe for multiple processes accessing the same file.
      Uses F_TLOCK (try lock) to avoid blocking Eio's event loop.
  *)
  let atomic_update t key ~f =
    match key_to_path t key with
    | Error e -> Error e
    | Ok path ->
        try
          (* Ensure parent directory exists *)
          (match Eio.Path.split path with
           | Some (parent, _) ->
               (try Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 parent
                with Eio.Cancel.Cancelled _ as e -> raise e
                   | e ->
                       Log.legacy_traceln ~level:Log.Warn ~module_name:"Backend"
                         (Printf.sprintf "[WARN] mkdirs failed: %s"
                            (Printexc.to_string e)))
           | None -> ());

          let path_str = Eio.Path.native_exn path in
          with_locked_rw_fd path_str @@ fun fd ->
          let _ = Unix.lseek fd 0 Unix.SEEK_SET in
          let stat = Unix.fstat fd in
          let size = stat.Unix.st_size in
          let current =
            if size = 0 then None
            else begin
              let buf = Bytes.create size in
              let n = Unix.read fd buf 0 size in
              if n = 0 then None
              else
                let raw = Bytes.sub_string buf 0 n in
                Some (decompress_with_context ~context:path_str raw)
            end
          in
          let new_content = f current in
          let compressed = _compress new_content in
          let _ = Unix.lseek fd 0 Unix.SEEK_SET in
          Unix.ftruncate fd 0;
          write_all_substring fd compressed 0 (String.length compressed);
          Ok new_content
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Error (IOError (Printf.sprintf "atomic_update failed: %s" (Printexc.to_string exn)))

  (** {2 Health Check} *)

  let health_check t =
    let test_key = "_health_check_" ^ t.config.node_id in
    let test_value = string_of_float (Time_compat.now ()) in
    match set t test_key test_value with
    | Ok () ->
        (match delete t test_key with
         | Ok () -> Ok { latency_ms = 0.0; is_healthy = true }
         | Error _ -> Ok { latency_ms = 0.0; is_healthy = false })
    | Error e -> Error e

end

(** {1 Memory Backend (for testing)} *)

module Memory = struct
  type t = {
    data: (string, string) Hashtbl.t;
    mutex: Eio.Mutex.t;
  }

  (** Eio_guard-based dual-mode mutex for pre/post Eio runtime.
      Skips locking when Eio runtime is not yet active (e.g. unit tests). *)
  let with_lock t f = Eio_guard.with_mutex t.mutex f

  let create () = {
    data = Hashtbl.create 64;
    mutex = Eio.Mutex.create ();
  }

  (* Shared instances keyed by base_path — ensures multiple configs for the
     same directory share state (matching FileSystem backend semantics).
     Used by tests that create multiple Coord.default_config for one tmpdir. *)
  let shared_instances : (string, t) Hashtbl.t = Hashtbl.create 8

  let get_or_create ~base_path =
    match Hashtbl.find_opt shared_instances base_path with
    | Some t -> t
    | None ->
      let t = create () in
      Hashtbl.replace shared_instances base_path t;
      t

  let get t key =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.data key with
      | Some v -> Ok v
      | None -> Error (NotFound key)
    )

  let set t key value =
    with_lock t (fun () ->
      Hashtbl.replace t.data key value;
      Ok ()
    )

  let exists t key =
    with_lock t (fun () ->
      Hashtbl.mem t.data key
    )

  let delete t key =
    with_lock t (fun () ->
      if Hashtbl.mem t.data key then begin
        Hashtbl.remove t.data key;
        Ok ()
      end else
        Error (NotFound key)
    )

  let list_keys t ~prefix =
    with_lock t (fun () ->
      let keys = Hashtbl.fold (fun k _ acc ->
        if String.length k >= String.length prefix &&
           String.sub k 0 (String.length prefix) = prefix then
          k :: acc
        else acc
      ) t.data [] in
      Ok keys
    )

  let get_all t ~prefix =
    with_lock t (fun () ->
      let pairs = Hashtbl.fold (fun k v acc ->
        if String.starts_with ~prefix k then
          (k, v) :: acc
        else acc
      ) t.data [] in
      Ok pairs
    )

  let set_if_not_exists t key value =
    with_lock t (fun () ->
      if Hashtbl.mem t.data key then
        Ok false
      else begin
        Hashtbl.replace t.data key value;
        Ok true
      end
    )

  let clear t =
    with_lock t (fun () ->
      Hashtbl.clear t.data
    )
end

(** {1 Unified Backend} *)

type backend =
  | FS of FileSystem.t
  | Mem of Memory.t

let get = function
  | FS t -> FileSystem.get t
  | Mem t -> Memory.get t

let set = function
  | FS t -> FileSystem.set t
  | Mem t -> Memory.set t

let exists = function
  | FS t -> FileSystem.exists t
  | Mem t -> Memory.exists t

let delete = function
  | FS t -> FileSystem.delete t
  | Mem t -> Memory.delete t

let list_keys = function
  | FS t -> FileSystem.list_keys t ~prefix:""
  | Mem t -> Memory.list_keys t ~prefix:""

let set_if_not_exists backend key value =
  match backend with
  | FS t -> FileSystem.set_if_not_exists t key value
  | Mem t -> Memory.set_if_not_exists t key value

let acquire_lock backend ~key ~owner ~ttl_seconds =
  match backend with
  | FS t -> FileSystem.acquire_lock t ~key ~owner ~ttl_seconds
  | Mem _ -> Ok true  (* In-memory is single-process *)

let release_lock backend ~key ~owner =
  match backend with
  | FS t -> FileSystem.release_lock t ~key ~owner
  | Mem _ -> Ok true

let extend_lock backend ~key ~owner ~ttl_seconds =
  match backend with
  | FS t -> FileSystem.extend_lock t ~key ~owner ~ttl_seconds
  | Mem _ -> Ok true
