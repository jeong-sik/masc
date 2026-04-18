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
      match Fs_compat.mkdir_p path with
      | () -> Hashtbl.replace ensured_dirs path ()
      | exception (Eio.Cancel.Cancelled _ as exn) ->
          Log.Keeper.warn "keeper_fs: ensure_dir cancelled path=%s" path;
          deferred_exn := Some exn
      | exception exn ->
          Log.Keeper.warn "keeper_fs: ensure_dir failed path=%s: %s"
            path (Printexc.to_string exn);
          deferred_exn := Some exn
    end);
  (match !deferred_exn with Some exn -> raise exn | None -> ());
  path

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

    @raises Sys_error on I/O failure *)
let save_atomic (path : string) (content : string) : unit =
  let dir = Filename.dirname path in
  ignore (ensure_dir dir);
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error msg ->
    Log.Keeper.warn "keeper_fs: save_atomic failed path=%s error=%s" path msg;
    raise (Sys_error msg)

(** Atomically save a Yojson value as pretty-printed JSON. *)
let save_json_atomic (path : string) (json : Yojson.Safe.t) : unit =
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
