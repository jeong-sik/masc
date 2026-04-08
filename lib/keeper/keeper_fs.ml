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
  Eio_guard.with_mutex dir_mu (fun () ->
    if not (Hashtbl.mem ensured_dirs path) || not (Sys.file_exists path) then begin
      (try Fs_compat.mkdir_p path
       with
       | Eio.Cancel.Cancelled _ as exn ->
           Log.Keeper.warn "keeper_fs: ensure_dir cancelled path=%s" path;
           raise exn
       | exn ->
           Log.Keeper.warn "keeper_fs: ensure_dir failed path=%s: %s"
             path (Printexc.to_string exn);
           raise exn);
      Hashtbl.replace ensured_dirs path ()
    end);
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

let keeper_dir (config : Room.config) : string =
  let d = Filename.concat (Room.masc_root_dir config) "keepers" in
  ensure_dir d

let session_base_dir (config : Room.config) : string =
  let d = Filename.concat (Room.masc_root_dir config) "traces" in
  ensure_dir d

let keeper_session_dir (config : Room.config) (trace_id : string) : string =
  Filename.concat (session_base_dir config) trace_id
