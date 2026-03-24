(** Backend Module - Storage abstraction for MASC (facade) *)

include Backend_core

module FileSystemBackend : BACKEND = struct
  type t = {
    base_path: string;
    pubsub: Backend_core.Pubsub_mem.t;
    mutex: Eio.Mutex.t;
  }

  (* Once-only flag to avoid log spam in test contexts where every call
     after the first Effect.Unhandled triggers Poisoned. *)
  let poisoned_warned = Atomic.make false

  let with_lock t f =
    (* Eio.Mutex requires an Eio runtime (Cancel context).
       When called outside Eio_main.run (e.g. unit tests without Eio),
       Effect.Unhandled is raised. A prior failure may also leave the mutex
       in a Poisoned state (Eio__Eio_mutex.Poisoned).
       In both cases, run the function unprotected — safe because test
       contexts are single-fiber with no contention. *)
    match
      Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> f ())
    with
    | result -> result
    | exception Effect.Unhandled _ ->
        f ()
    | exception Eio__Eio_mutex.Poisoned _ ->
        (* Mutex poisoned by a prior Effect.Unhandled failure (no Eio context).
           Safe to run unprotected in single-fiber test contexts. *)
        if not (Atomic.exchange poisoned_warned true) then
          Log.Backend.warn "Eio.Mutex poisoned, running unprotected (non-Eio context)";
        f ()

  (* Security: validate key with strict allowlist (parse, don't sanitize) *)
  let validate_key key =
    (* Reject empty keys *)
    if String.length key = 0 then
      raise (Invalid_argument "Empty key not allowed");

    (* Reject NUL bytes (C string truncation attack) *)
    if String.contains key '\x00' then
      raise (Invalid_argument "NUL byte not allowed in key");

    (* Reject '/' anywhere (we use ':' as path separator) *)
    if String.contains key '/' then
      raise (Invalid_argument "Slash not allowed in key (use ':' as separator)");

    (* Reject keys starting or ending with ':' (would create absolute/trailing path) *)
    if key.[0] = ':' then
      raise (Invalid_argument "Key cannot start with ':'");
    if key.[String.length key - 1] = ':' then
      raise (Invalid_argument "Key cannot end with ':'");

    (* Reject consecutive colons (empty path segment) *)
    if String.length key >= 2 then begin
      for i = 0 to String.length key - 2 do
        if key.[i] = ':' && key.[i+1] = ':' then
          raise (Invalid_argument "Consecutive colons not allowed")
      done
    end;

    (* Check each segment for path traversal and allowlist *)
    let segments = String.split_on_char ':' key in
    List.iter (fun seg ->
      (* Reject . and .. segments *)
      if seg = "." || seg = ".." then
        raise (Invalid_argument "Path traversal detected (. or ..)");
      (* Reject segments starting with .. *)
      if String.length seg >= 2 && String.sub seg 0 2 = ".." then
        raise (Invalid_argument "Path traversal detected");
      (* Blocklist: reject only dangerous characters for path safety *)
      (* Allow UTF-8 (bytes >= 0x80) and most printable ASCII *)
      String.iter (fun c ->
        let code = Char.code c in
        let dangerous =
          code = 0 ||                    (* null byte *)
          code < 32 ||                   (* control characters *)
          c = '/' || c = '\\' ||         (* path separators *)
          c = ':' ||                     (* key separator (should be split already) *)
          c = '*' || c = '?' ||          (* wildcards *)
          c = '"' || c = '\'' ||         (* quotes *)
          c = '<' || c = '>' || c = '|'  (* shell metacharacters *)
        in
        if dangerous then
          raise (Invalid_argument (Printf.sprintf "Invalid character (code=%d) in key" code))
      ) seg
    ) segments;

    key  (* Return unchanged - validation only, no sanitization *)

  let key_to_path t key =
    let safe_key = validate_key key in
    let path_part = String.map (function ':' -> '/' | c -> c) safe_key in
    (* Double-check: path_part must not start with '/' after conversion *)
    if String.length path_part > 0 && path_part.[0] = '/' then
      raise (Invalid_argument "Internal error: path starts with /");
    Filename.concat t.base_path path_part

  let safe_key_to_path t key =
    try Ok (key_to_path t key)
    with Invalid_argument msg -> Error (InvalidKey msg)

  let ensure_dir path =
    let dir = Filename.dirname path in
    Fs_compat.mkdir_p dir

  let create (cfg : config) : (t, error) result =
    let path = cfg.base_path in
    (try
      Fs_compat.mkdir_p path
    with Unix.Unix_error (err, _, _) ->
      Log.Misc.error "Failed to mkdir %s: %s" path (Unix.error_message err));
    Ok { base_path = path; pubsub = Backend_core.Pubsub_mem.create (); mutex = Eio.Mutex.create () }

  let close _t = ()

  (* Read operations are lock-free: writes use atomic rename, so a
     concurrent read always sees either the old or new complete content.
     Eio.Mutex is cooperative and does not starve the scheduler. *)
  let get t ~key =
    match safe_key_to_path t key with
    | Error e -> Error e
    | Ok path ->
        if Sys.file_exists path then
          match Safe_ops.read_file_safe path with
          | Ok content -> Ok (Some content)
          | Error _ -> Ok None
        else
          Ok None

  let set t ~key ~value =
    with_lock t (fun () ->
      match safe_key_to_path t key with
      | Error e -> Error e
      | Ok path ->
          ensure_dir path;
          try
            (* Atomic write: write to temp file, then rename.
               Sys.rename is atomic on POSIX, so concurrent lock-free
               reads always see complete file content. *)
            let tmp_path = Printf.sprintf "%s.%d.tmp" path (Unix.getpid ()) in
            Out_channel.with_open_text tmp_path (fun oc ->
              Out_channel.output_string oc value
            );
            Sys.rename tmp_path path;
            Ok ()
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | e -> Error (OperationFailed (Printexc.to_string e))
    )

  let delete t ~key =
    with_lock t (fun () ->
      match safe_key_to_path t key with
      | Error e -> Error e
      | Ok path ->
          if Sys.file_exists path then begin
            try
              Sys.remove path;
              Ok true
            with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | e -> Error (OperationFailed (Printexc.to_string e))
          end else
            Ok false
    )

  let exists t ~key =
    match safe_key_to_path t key with
    | Error _ -> false
    | Ok path -> Sys.file_exists path

  let starts_with ~prefix value =
    let prefix_len = String.length prefix in
    String.length value >= prefix_len
    && String.sub value 0 prefix_len = prefix

  let normalize_prefix_for_scan prefix =
    let len = String.length prefix in
    if len > 0 && prefix.[len - 1] = ':' then
      String.sub prefix 0 (len - 1)
    else
      prefix

  let key_of_path t path =
    let base = t.base_path ^ Filename.dir_sep in
    if path = t.base_path then
      Some ""
    else if starts_with ~prefix:base path then
      let rel =
        String.sub path (String.length base) (String.length path - String.length base)
      in
      Some (String.map (function '/' -> ':' | c -> c) rel)
    else
      None

  let rec collect_keys_under t ~requested_prefix path acc =
    if Sys.is_directory path then
      Sys.readdir path
      |> Array.fold_left
           (fun acc name ->
             collect_keys_under t ~requested_prefix
               (Filename.concat path name) acc)
           acc
    else
      match key_of_path t path with
      | Some key when requested_prefix = "" || starts_with ~prefix:requested_prefix key ->
          key :: acc
      | _ -> acc

  let list_keys t ~prefix =
    let scan_prefix = normalize_prefix_for_scan prefix in
    let scan_root_result =
      if scan_prefix = "" then
        Ok t.base_path
      else
        safe_key_to_path t scan_prefix
    in
    match scan_root_result with
    | Error e -> Error e
    | Ok scan_root ->
        if not (Sys.file_exists scan_root) then
          Ok []
        else
          Ok
            (collect_keys_under t ~requested_prefix:prefix scan_root []
             |> List.sort_uniq String.compare)

  let get_all t ~prefix =
    match list_keys t ~prefix with
    | Error e -> Error e
    | Ok keys ->
        let pairs = List.filter_map (fun k ->
          match get t ~key:k with
          | Ok (Some v) -> Some (k, v)
          | _ -> None
        ) keys in
        Ok pairs

  (* Atomic set using O_EXCL *)
  let set_if_not_exists t ~key ~value =
    with_lock t (fun () ->
      match safe_key_to_path t key with
      | Error e -> Error e
      | Ok path ->
          ensure_dir path;
          try
            let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL] 0o644 in
            let _ = Unix.write_substring fd value 0 (String.length value) in
            Unix.close fd;
            Ok true
          with
          | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok false
          | e -> Error (OperationFailed (Printexc.to_string e))
    )

  let compare_and_swap t ~key ~expected ~value =
    with_lock t (fun () ->
      match get t ~key with
      | Ok (Some current) when current = expected ->
          (match set t ~key ~value with
           | Ok () -> Ok true
           | Error e -> Error e)
      | _ -> Ok false
    )

  (* File-based locking with JSON metadata *)
  (* SAFETY: Uses validate_ttl, safe_parse_lock_json, flock *)
  (* NOTE: key_to_path already calls validate_key for path traversal prevention *)
  let acquire_lock t ~key ~ttl_seconds ~owner =
    try
      (* TTL validation: sanitize to safe range *)
      let safe_ttl = validate_ttl ttl_seconds in
      with_lock t (fun () ->
        let lock_key = "locks:" ^ key in
        let path = key_to_path t lock_key in  (* calls validate_key internally *)
        ensure_dir path;
        let now = Time_compat.now () in
        let expires_at = now +. float_of_int safe_ttl in

        (* File-level locking for cross-process safety *)
        let lock_file = path ^ ".flock" in
        let fd = Unix.openfile lock_file [Unix.O_CREAT; Unix.O_RDWR] 0o644 in
        if not (acquire_flock fd) then begin
          Unix.close fd;
          Ok false  (* Another process is modifying *)
        end else begin
          (* flock acquired - safe to read/write *)
          let result =
            try
              (* Check existing lock using safe parser *)
              let existing_valid =
                match safe_parse_lock_json path with
                | Some (own, exp) when exp > now && own <> owner -> Some own
                | _ -> None  (* Expired, same owner, or corrupted (removed) *)
              in

              match existing_valid with
              | Some _ -> Ok false  (* Locked by someone else *)
              | None ->
                  let json = `Assoc [
                    ("owner", `String owner);
                    ("expires_at", `Float expires_at);
                    ("acquired_at", `Float now);
                  ] in
                  Out_channel.with_open_text path (fun oc ->
                    Out_channel.output_string oc (Yojson.Safe.to_string json)
                  );
                  Ok true
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              Error (OperationFailed (Printexc.to_string exn))
          in
          release_flock fd;
          Unix.close fd;
          result
        end
      )
    with
    | Invalid_argument msg -> Error (InvalidKey msg)
    | exn -> Error (OperationFailed (Printexc.to_string exn))

  (* SAFETY: Uses safe_parse_lock_json, flock *)
  (* NOTE: key_to_path already calls validate_key for path traversal prevention *)
  let release_lock t ~key ~owner =
    try
      with_lock t (fun () ->
        let lock_key = "locks:" ^ key in
        let file_path = key_to_path t lock_key in  (* calls validate_key internally *)

        (* Check if lock file exists first *)
        if not (Sys.file_exists file_path) then
          Ok false  (* No lock file exists *)
        else begin
          (* File-level locking for cross-process safety *)
          let lock_file = file_path ^ ".flock" in
          let fd = Unix.openfile lock_file [Unix.O_CREAT; Unix.O_RDWR] 0o644 in
          if not (acquire_flock fd) then begin
            Unix.close fd;
            Ok false  (* Another process is modifying *)
          end else begin
            let result =
              try
                (* Check ownership using safe parser *)
                match safe_parse_lock_json file_path with
                | Some (own, _) when own = owner ->
                    Safe_ops.remove_file_logged ~context:"backend_lock" file_path;
                    Ok true
                | Some _ -> Ok false  (* Different owner *)
                | None -> Ok false    (* No valid lock *)
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | e ->
                Log.Misc.error "Lock operation failed: %s" (Printexc.to_string e);
                Ok false
            in
            release_flock fd;
            Unix.close fd;
            result
          end
        end
      )
    with
    | Invalid_argument msg -> Error (InvalidKey msg)
    | exn -> Error (OperationFailed (Printexc.to_string exn))

  (* SAFETY: Uses validate_ttl, flock *)
  (* NOTE: key_to_path already calls validate_key for path traversal prevention *)
  let extend_lock t ~key ~ttl_seconds ~owner =
    try
      (* TTL validation: sanitize to safe range *)
      let safe_ttl = validate_ttl ttl_seconds in
      with_lock t (fun () ->
        let lock_key = "locks:" ^ key in
        let file_path = key_to_path t lock_key in  (* calls validate_key internally *)

        (* File-level locking for cross-process safety *)
        let lock_file = file_path ^ ".flock" in
        if not (Sys.file_exists file_path) then
          Ok false  (* No lock to extend *)
        else begin
          let fd = Unix.openfile lock_file [Unix.O_CREAT; Unix.O_RDWR] 0o644 in
          if not (acquire_flock fd) then begin
            Unix.close fd;
            Ok false  (* Another process is modifying *)
          end else begin
            let result =
              try
                let content = In_channel.with_open_text file_path In_channel.input_all in
                let json = Yojson.Safe.from_string content in
                let open Yojson.Safe.Util in
                let own = json |> member "owner" |> to_string in
                if own = owner then begin
                  let now = Time_compat.now () in
                  let expires_at = now +. float_of_int safe_ttl in
                  let new_json = `Assoc [
                    ("owner", `String owner);
                    ("expires_at", `Float expires_at);
                    ("acquired_at", json |> member "acquired_at");
                  ] in
                  Out_channel.with_open_text file_path (fun oc ->
                    Out_channel.output_string oc (Yojson.Safe.to_string new_json)
                  );
                  Ok true
                end else
                  Ok false
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | e ->
                Log.Misc.error "Lock operation failed: %s" (Printexc.to_string e);
                Ok false
            in
            release_flock fd;
            Unix.close fd;
            result
          end
        end
      )
    with
    | Invalid_argument msg -> Error (InvalidKey msg)
    | exn -> Error (OperationFailed (Printexc.to_string exn))

  let publish t ~channel ~message =
    with_lock t (fun () -> Backend_core.Pubsub_mem.publish t.pubsub ~channel ~message)

  let subscribe t ~channel ~callback =
    with_lock t (fun () -> Backend_core.Pubsub_mem.subscribe t.pubsub ~channel ~callback)

  let health_check t =
    try
      let test_path = Filename.concat t.base_path ".health_check" in
      Out_channel.with_open_text test_path (fun oc ->
        Out_channel.output_string oc "ok"
      );
      Sys.remove test_path;
      Ok true
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Log.Misc.error "Health check failed: %s" (Printexc.to_string e);
      Ok false
end

(* ============================================ *)
(* PostgreSQL Backend (Eio-native, non-blocking) *)
(* ============================================ *)

(** PostgresNative - Eio-based PostgreSQL backend using caqti-eio.
    Implementation delegated to Backend_pg for separation of concerns. *)
module PostgresNative : sig
  include BACKEND
  val create_eio : sw:Eio.Switch.t -> env:Caqti_eio.stdenv -> config -> (t, error) result
  val create_eio_readonly : sw:Eio.Switch.t -> env:Caqti_eio.stdenv -> config -> (t, error) result
  val get_pool : t -> (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t
  val get_all_matching_recent :
    t ->
    prefix:string ->
    suffix:string ->
    updated_since:float ->
    limit:int ->
    ((string * string) list, error) result
  val cleanup_pubsub_by_age : t -> days:int -> (int, error) result
  val cleanup_pubsub_by_limit : t -> max_messages:int -> (int, error) result
  val cleanup_pubsub : t -> days:int -> max_messages:int -> (int, error) result
end = struct
  include Backend_pg
end
