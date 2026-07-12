(** Keeper_fs — Centralized keeper filesystem operations.

    Provides atomic file writes (write-to-temp + rename) and
    fiber-safe directory creation with caching. Consolidates the
    four scattered ensure_dir implementations into one.

    All mutable state is protected by an Eio.Mutex.

    @since 2.162.0 — #3721 keeper stabilization *)

(* ================================================================ *)
(* Directory Cache (path-local Eio synchronization)                 *)
(* ================================================================ *)

let ensured_dirs : (string, unit) Hashtbl.t = Hashtbl.create 16

type dir_lock =
  { mutex : Eio.Mutex.t
  ; mutable users : int
  }

let dir_state_mu = Stdlib.Mutex.create ()
let dir_locks : (string, dir_lock) Hashtbl.t = Hashtbl.create 16
let dir_cache_epoch = ref (ref ())

let dir_cache_key path =
  let path = Env_config_core.strip_path_trailing_slashes path in
  if Filename.is_relative path
  then Filename.concat (Sys.getcwd ()) path
  else path

let dir_is_cached path =
  Stdlib.Mutex.protect dir_state_mu (fun () ->
    Hashtbl.mem ensured_dirs path)

let acquire_dir_lock path =
  Stdlib.Mutex.protect dir_state_mu (fun () ->
    match Hashtbl.find_opt dir_locks path with
    | Some lock ->
      lock.users <- lock.users + 1;
      lock
    | None ->
      let lock = { mutex = Eio.Mutex.create (); users = 1 } in
      Hashtbl.add dir_locks path lock;
      lock)

let release_dir_lock path lock =
  Stdlib.Mutex.protect dir_state_mu (fun () ->
    lock.users <- lock.users - 1;
    if lock.users = 0
    then
      match Hashtbl.find_opt dir_locks path with
      | Some current when current == lock -> Hashtbl.remove dir_locks path
      | Some _ | None -> ())

let capture_dir_cache_epoch () =
  Stdlib.Mutex.protect dir_state_mu (fun () -> !dir_cache_epoch)

let mark_dir_cached_if_current path expected_epoch =
  Stdlib.Mutex.protect dir_state_mu (fun () ->
    if !dir_cache_epoch == expected_epoch
    then Hashtbl.replace ensured_dirs path ())

let ensure_dir (path : string) : string =
  let key = dir_cache_key path in
  if dir_is_cached key
  then path
  else
    let lock = acquire_dir_lock key in
    Fun.protect
      ~finally:(fun () -> release_dir_lock key lock)
      (fun () ->
        let result =
          Eio_guard.with_mutex lock.mutex (fun () ->
            try
              if not (dir_is_cached key)
              then begin
                let expected_epoch = capture_dir_cache_epoch () in
                Fs_compat.mkdir_p_durable path;
                mark_dir_cached_if_current key expected_epoch
              end;
              Ok ()
            with
            | exn -> Error (exn, Printexc.get_raw_backtrace ()))
        in
        match result with
        | Ok () -> path
        | Error ((Eio.Cancel.Cancelled _ as exn), bt) ->
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string FsFailures)
            ~labels:
              [ "path", path
              ; ( "site"
                , Keeper_fs_failure_site.(to_label Ensure_dir_cancelled) )
              ]
            ();
          Log.Keeper.warn "filesystem_runtime: ensure_dir cancelled path=%s" path;
          Printexc.raise_with_backtrace exn bt
        | Error (exn, bt) ->
          Keeper_fd_pressure.note_exception
            ~site:"filesystem_runtime.ensure_dir"
            exn;
          Keeper_disk_pressure.note_exception
            ~site:"filesystem_runtime.ensure_dir"
            exn;
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string FsFailures)
            ~labels:
              [ "path", path
              ; "site", Keeper_fs_failure_site.(to_label Ensure_dir_failed)
              ]
            ();
          Log.Keeper.warn
            "filesystem_runtime: ensure_dir failed path=%s: %s"
            path
            (Printexc.to_string exn);
          Printexc.raise_with_backtrace exn bt)

let invalidate_dir (path : string) : unit =
  let key = dir_cache_key path in
  Stdlib.Mutex.protect dir_state_mu (fun () ->
    dir_cache_epoch := ref ();
    let rec is_same_or_descendant candidate =
      if String.equal candidate key
      then true
      else
        let parent = Filename.dirname candidate in
        if String.equal parent candidate
        then false
        else is_same_or_descendant parent
    in
    Hashtbl.filter_map_inplace
      (fun candidate () ->
        if is_same_or_descendant candidate then None else Some ())
      ensured_dirs)

let clear_dir_cache () : unit =
  Stdlib.Mutex.protect dir_state_mu (fun () ->
    dir_cache_epoch := ref ();
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
        Keeper_fd_pressure.note_if_fd_exhaustion
          ~site:"filesystem_runtime.save_atomic"
          msg;
        Keeper_disk_pressure.note_if_disk_exhaustion
          ~site:"filesystem_runtime.save_atomic"
          msg;
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string FsFailures)
          ~labels:[("path", path); ("site", Keeper_fs_failure_site.(to_label Save_atomic_failed))]
          ();
        Log.Keeper.warn "filesystem_runtime: save_atomic failed path=%s error=%s" path msg;
        Error msg
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      let msg = Printexc.to_string exn in
      Keeper_fd_pressure.note_exception
        ~site:"filesystem_runtime.save_atomic"
        exn;
      Keeper_disk_pressure.note_exception
        ~site:"filesystem_runtime.save_atomic"
        exn;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string FsFailures)
        ~labels:[("path", path); ("site", Keeper_fs_failure_site.(to_label Save_atomic_raised))]
        ();
      Log.Keeper.warn "filesystem_runtime: save_atomic raised path=%s error=%s" path msg;
      Error msg

(** Atomically save a Yojson value as pretty-printed JSON. *)
let save_json_atomic (path : string) (json : Yojson.Safe.t) : (unit, string) result =
  save_atomic path (Yojson.Safe.pretty_to_string json)

(* ================================================================ *)
(* Standard Keeper Paths                                            *)
(* ================================================================ *)

let keeper_dir (config : Workspace.config) : string =
  let d = Workspace.keepers_runtime_dir config in
  ensure_dir d

let session_base_dir (config : Workspace.config) : string =
  let d = Filename.concat (Workspace.masc_root_dir config) "traces" in
  ensure_dir d

let keeper_session_dir (config : Workspace.config) (trace_id : string) : string =
  Filename.concat (session_base_dir config) trace_id
