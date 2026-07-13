(** Keeper_fs — Centralized keeper filesystem operations.

    Provides atomic file writes (write-to-temp + rename) and
    fiber-safe directory creation with caching. Consolidates the
    four scattered ensure_dir implementations into one.

    Mutable caches use either an Eio mutex or an immutable Atomic snapshot.

    @since 2.162.0 — #3721 keeper stabilization *)

(* ================================================================ *)
(* Directory Cache (Eio.Mutex-protected)                            *)
(* ================================================================ *)

let dir_mu = Eio.Mutex.create ()
let ensured_dirs : (string, unit) Hashtbl.t = Hashtbl.create 16
module String_set = Set.Make (String)

let durable_dirs = Atomic.make String_set.empty

(* Cold directory preparation is globally serialized. Two sibling leaves can
   share an ancestor created during this boot; a leaf-keyed lock would let one
   sibling observe that ancestor before the creator fsyncs its parent and then
   publish a record whose successful durability still depends on the creator.
   Warm writes remain lock-free through [durable_dirs]. *)
let durable_prepare_mu = Eio.Mutex.create ()

let rec update_durable_dirs f =
  let current = Atomic.get durable_dirs in
  let updated = f current in
  if current == updated || Atomic.compare_and_set durable_dirs current updated
  then ()
  else update_durable_dirs f
;;

let mark_dir_durable path =
  update_durable_dirs (fun paths ->
    if String_set.mem path paths then paths else String_set.add path paths)
;;

let path_is_at_or_below ~root path =
  String.equal root path
  ||
  let prefix =
    if String.ends_with ~suffix:Filename.dir_sep root
    then root
    else root ^ Filename.dir_sep
  in
  String.starts_with ~prefix path
;;

let ensure_dir (path : string) : string =
  (* Capture exceptions inside the mutex body so the lock exits normally,
     then re-raise after release. Escaping an exception from
     Eio.Mutex.use_rw poisons the mutex and breaks all subsequent
     ensure_dir calls in the same process (Issue #8475: fleet-test
     isolation runtime failures). *)
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
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string FsFailures)
              ~labels:[("path", path); ("site", Keeper_fs_failure_site.(to_label Ensure_dir_cancelled))]
              ();
            Log.Keeper.warn "filesystem_runtime: ensure_dir cancelled path=%s" path;
            Error (exn, Printexc.get_raw_backtrace ())
        | exn ->
            Keeper_fd_pressure.note_exception
              ~site:"filesystem_runtime.ensure_dir"
              exn;
            Keeper_disk_pressure.note_exception
              ~site:"filesystem_runtime.ensure_dir"
              exn;
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string FsFailures)
              ~labels:[("path", path); ("site", Keeper_fs_failure_site.(to_label Ensure_dir_failed))]
              ();
            Log.Keeper.warn "filesystem_runtime: ensure_dir failed path=%s: %s"
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
  Eio_guard.with_mutex dir_mu (fun () -> Hashtbl.remove ensured_dirs path);
  update_durable_dirs (fun paths ->
    String_set.filter
      (fun candidate -> not (path_is_at_or_below ~root:path candidate))
      paths)

let clear_dir_cache () : unit =
  Eio_guard.with_mutex dir_mu (fun () -> Hashtbl.clear ensured_dirs);
  Atomic.set durable_dirs String_set.empty

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

type durable_write_stage =
  | Directory_prepare
  | Temp_file_create
  | Payload_write
  | Payload_fsync
  | Temp_file_close
  | Atomic_rename
  | Parent_directory_fsync_after_rename

type durable_write_error =
  { renamed : bool
  ; stage : durable_write_stage
  ; reason : string
  }

let durable_write_stage_to_string = function
  | Directory_prepare -> "directory_prepare"
  | Temp_file_create -> "temp_file_create"
  | Payload_write -> "payload_write"
  | Payload_fsync -> "payload_fsync"
  | Temp_file_close -> "temp_file_close"
  | Atomic_rename -> "atomic_rename"
  | Parent_directory_fsync_after_rename ->
    "parent_directory_fsync_after_rename"
;;

let durable_write_error_to_string error =
  Printf.sprintf
    "stage=%s renamed=%b reason=%s"
    (durable_write_stage_to_string error.stage)
    error.renamed
    error.reason
;;

exception Durable_write_failed of durable_write_error

let run_durable_write_stage ~renamed ~before_stage stage f =
  try
    before_stage stage;
    f ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    raise
      (Durable_write_failed
         { renamed; stage; reason = Printexc.to_string exn })
;;

let fsync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> Unix.fsync fd)
;;

let missing_directory_chain path =
  let rec loop missing current =
    match Fs_compat.path_kind current with
    | Fs_compat.Directory -> missing
    | Fs_compat.Other ->
      failwith (Printf.sprintf "directory path is occupied by a non-directory: %s" current)
    | Fs_compat.Missing ->
      let parent = Filename.dirname current in
      if String.equal parent current
      then failwith (Printf.sprintf "cannot create filesystem root: %s" current)
      else loop (current :: missing) parent
  in
  loop [] path
;;

let ensure_dir_durable ~before_stage dir =
  if not (String_set.mem dir (Atomic.get durable_dirs))
  then (
    let prepared =
      Eio.Mutex.use_rw ~protect:true durable_prepare_mu (fun () ->
        try
          if not (String_set.mem dir (Atomic.get durable_dirs))
          then
            run_durable_write_stage
              ~renamed:false
              ~before_stage
              Directory_prepare
              (fun () ->
                 let created = missing_directory_chain dir in
                 Fs_compat.mkdir_p dir;
                 (* Persist only names created by this operation. The cold
                    preparation mutex ensures an existing same-boot ancestor
                    was fully anchored by its creator before it is trusted. *)
                 Eio_guard.run_in_systhread (fun () ->
                   List.iter
                     (fun created_dir ->
                        fsync_directory (Filename.dirname created_dir))
                     created);
                 mark_dir_durable dir);
          Ok ()
        with
        | exn -> Error (exn, Printexc.get_raw_backtrace ()))
    in
    match prepared with
    | Ok () -> ()
    | Error (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace)
;;

let save_json_durable_atomic_with ~before_stage path json =
  let dir = Filename.dirname path in
  let content = Yojson.Safe.pretty_to_string json in
  try
    ensure_dir_durable ~before_stage dir;
    Eio_guard.run_in_systhread (fun () ->
      let temp_path = ref None in
      let channel = ref None in
      let renamed = ref false in
      Fun.protect
        ~finally:(fun () ->
          Option.iter close_out_noerr !channel;
          match !temp_path with
          | Some temp when not !renamed && Sys.file_exists temp ->
            (try Sys.remove temp with
             | exn ->
               Log.Keeper.error
                 "filesystem_runtime: strict atomic temp cleanup failed path=%s error=%s"
                 temp
                 (Printexc.to_string exn))
          | Some _ | None -> ())
        (fun () ->
           let temp, oc =
             run_durable_write_stage
               ~renamed:false
               ~before_stage
               Temp_file_create
               (fun () ->
                  Filename.open_temp_file ~temp_dir:dir ".keeper_atomic_" ".tmp")
           in
           temp_path := Some temp;
           channel := Some oc;
           run_durable_write_stage
             ~renamed:false
             ~before_stage
             Payload_write
             (fun () -> output_string oc content; flush oc);
           run_durable_write_stage
             ~renamed:false
             ~before_stage
             Payload_fsync
             (fun () -> Unix.fsync (Unix.descr_of_out_channel oc));
           run_durable_write_stage
             ~renamed:false
             ~before_stage
             Temp_file_close
             (fun () -> close_out oc; channel := None);
           run_durable_write_stage
             ~renamed:false
             ~before_stage
             Atomic_rename
             (fun () -> Unix.rename temp path; renamed := true);
           run_durable_write_stage
             ~renamed:true
             ~before_stage
             Parent_directory_fsync_after_rename
             (fun () -> fsync_directory dir);
           Ok ()))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Durable_write_failed error -> Error error
  | exn ->
    Error
      { renamed = false
      ; stage = Directory_prepare
      ; reason = Printexc.to_string exn
      }
;;

let save_json_durable_atomic path json =
  save_json_durable_atomic_with ~before_stage:(fun _ -> ()) path json
;;

type durable_remove_stage =
  | Unlink
  | Parent_directory_fsync

type durable_remove_error =
  { removed : bool
  ; failure : durable_remove_stage * string
  }

let durable_remove_stage_to_string = function
  | Unlink -> "unlink"
  | Parent_directory_fsync -> "parent_directory_fsync"
;;

let durable_remove_error_to_string error =
  let stage, reason = error.failure in
  Printf.sprintf "%s: %s" (durable_remove_stage_to_string stage) reason
;;

let remove_file_durable_with ~before_stage path =
  let parent = Filename.dirname path in
  Eio_guard.run_in_systhread (fun () ->
    let removed =
      try
        before_stage Unlink;
        Unix.unlink path;
        Ok true
      with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
      | exn -> Error { removed = false; failure = Unlink, Printexc.to_string exn }
    in
    match removed with
    | Error _ as error -> error
    | Ok removed ->
      (try
         before_stage Parent_directory_fsync;
         fsync_directory parent;
         Ok ()
       with
       | exn ->
         Error
           { removed
           ; failure = Parent_directory_fsync, Printexc.to_string exn
           }))
;;

let remove_file_durable path =
  remove_file_durable_with ~before_stage:(fun _ -> ()) path
;;

module For_testing = struct
  let save_json_durable_atomic ~before_stage path json =
    save_json_durable_atomic_with ~before_stage path json
  ;;

  let remove_file_durable ~before_stage path =
    remove_file_durable_with ~before_stage path
  ;;
end
;;

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
