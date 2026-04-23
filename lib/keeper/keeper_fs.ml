(** Keeper_fs — Centralized keeper filesystem operations.

    Provides atomic file writes (write-to-temp + rename) and
    fiber-safe directory creation with caching. Consolidates the
    four scattered ensure_dir implementations into one.

    All mutable state is protected by an Eio.Mutex.

    @since 2.162.0 — #3721 keeper stabilization *)

(* ================================================================ *)
(* Directory Cache (Eio.Mutex-protected)                            *)
(* ================================================================ *)

let dir_mu = Eio.Mutex.create ()
let ensured_dirs : (string, unit) Hashtbl.t = Hashtbl.create 16

let ensure_dir (path : string) : string =
  (* Capture exceptions inside the mutex body so the lock exits normally,
     then re-raise after release. Escaping an exception from
     Eio.Mutex.use_rw poisons the mutex and breaks all subsequent
     ensure_dir calls in the same process (Issue #8475: fleet-test
     isolation cascade failures). *)
  let deferred_exn = ref None in
  Eio_guard.with_mutex dir_mu (fun () ->
    if not (Hashtbl.mem ensured_dirs path) || not (Fs_compat.file_exists path) then begin
      match
        try
          Fs_compat.mkdir_p path;
          Hashtbl.replace ensured_dirs path ();
          Ok ()
        with
        | Eio.Cancel.Cancelled _ as exn ->
            Log.Keeper.warn "keeper_fs: ensure_dir cancelled path=%s" path;
            Error (exn, Printexc.get_raw_backtrace ())
        | exn ->
            Log.Keeper.warn "keeper_fs: ensure_dir failed path=%s: %s"
              path (Printexc.to_string exn);
            Error (exn, Printexc.get_raw_backtrace ())
      with
      | Ok () -> ()
      | Error err -> deferred_exn := Some err
    end);
  match !deferred_exn with
  | Some (exn, bt) -> Printexc.raise_with_backtrace exn bt
  | None -> path

let invalidate_dir (path : string) : unit =
  Eio_guard.with_mutex dir_mu (fun () ->
    Hashtbl.remove ensured_dirs path)

let clear_dir_cache () : unit =
  Eio_guard.with_mutex dir_mu (fun () ->
    Hashtbl.clear ensured_dirs)

(* ================================================================ *)
(* Atomic File Write (write-to-temp + rename)                       *)
(* ================================================================ *)

(** Atomically save [content] to [path].
    Delegates to {!Fs_compat.save_file_atomic} (Eio-aware, re-raises
    [Eio.Cancel.Cancelled]).  Ensures the parent directory exists first.

    Returns [(unit, string) result] for explicit error handling. *)
let save_atomic (path : string) (content : string) : (unit, string) result =
  try
    let dir = Filename.dirname path in
    ignore (ensure_dir dir);
    match Fs_compat.save_file_atomic path content with
    | Ok () -> Ok ()
    | Error msg ->
        Log.Keeper.warn "keeper_fs: save_atomic failed path=%s error=%s" path msg;
        Error msg
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      let msg = Printexc.to_string exn in
      Log.Keeper.warn "keeper_fs: save_atomic raised path=%s error=%s" path msg;
      Error msg

(** Atomically save a Yojson value as pretty-printed JSON. *)
let save_json_atomic (path : string) (json : Yojson.Safe.t) : (unit, string) result =
  save_atomic path (Yojson.Safe.pretty_to_string json)

(* ================================================================ *)
(* Standard Keeper Paths                                            *)
(* ================================================================ *)

let keeper_dir (config : Coord.config) : string =
  let d = Filename.concat (Coord.masc_root_dir config) "keepers" in
  ensure_dir d

let session_base_dir (config : Coord.config) : string =
  let d = Filename.concat (Coord.masc_root_dir config) "traces" in
  ensure_dir d

let keeper_session_dir (config : Coord.config) (trace_id : string) : string =
  Filename.concat (session_base_dir config) trace_id
