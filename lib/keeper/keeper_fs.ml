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
      Fs_compat.mkdir_p path;
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
    Writes to a temporary file first, then renames. On POSIX systems
    rename(2) is atomic within the same filesystem, so readers never
    see a partially-written file.

    @raises Sys_error on I/O failure *)
let save_atomic (path : string) (content : string) : unit =
  let dir = Filename.dirname path in
  ignore (ensure_dir dir);
  let tmp_path, oc =
    Filename.open_temp_file ~temp_dir:dir (Filename.basename path ^ ".") ".tmp"
  in
  let closed = ref false in
  Fun.protect ~finally:(fun () ->
    if not !closed then begin
      close_out_noerr oc;
      closed := true
    end;
    try Sys.remove tmp_path with Sys_error _ -> ())
    (fun () ->
      output_string oc content;
      close_out oc;
      closed := true;
      Unix.rename tmp_path path)

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
