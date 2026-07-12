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

let fsync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> Unix.fsync fd)
;;

let save_json_durable_atomic path json =
  let dir = Filename.dirname path in
  let content = Yojson.Safe.pretty_to_string json in
  try
    ignore (ensure_dir dir : string);
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
             try Filename.open_temp_file ~temp_dir:dir ".keeper_atomic_" ".tmp" with
             | exn ->
               raise
                 (Durable_write_failed
                    { renamed = false
                    ; stage = Temp_file_create
                    ; reason = Printexc.to_string exn
                    })
           in
           temp_path := Some temp;
           channel := Some oc;
           (try output_string oc content; flush oc with
            | exn ->
              raise
                (Durable_write_failed
                   { renamed = false
                   ; stage = Payload_write
                   ; reason = Printexc.to_string exn
                   }));
           (try Unix.fsync (Unix.descr_of_out_channel oc) with
            | exn ->
              raise
                (Durable_write_failed
                   { renamed = false
                   ; stage = Payload_fsync
                   ; reason = Printexc.to_string exn
                   }));
           (try close_out oc; channel := None with
            | exn ->
              raise
                (Durable_write_failed
                   { renamed = false
                   ; stage = Temp_file_close
                   ; reason = Printexc.to_string exn
                   }));
           (try Unix.rename temp path; renamed := true with
            | exn ->
              raise
                (Durable_write_failed
                   { renamed = false
                   ; stage = Atomic_rename
                   ; reason = Printexc.to_string exn
                   }));
           (try fsync_directory dir with
            | exn ->
              raise
                (Durable_write_failed
                   { renamed = true
                   ; stage = Parent_directory_fsync_after_rename
                   ; reason = Printexc.to_string exn
                   }));
           Ok ()))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Durable_write_failed error -> Error error
  | exn ->
    Error
      { renamed = false
      ; stage = Temp_file_create
      ; reason = Printexc.to_string exn
      }
;;

type durable_move_stage =
  | Rename
  | Destination_directory_fsync
  | Source_directory_fsync

type durable_move_error =
  { renamed : bool
  ; failures : (durable_move_stage * string) list
  }

let durable_move_stage_to_string = function
  | Rename -> "rename"
  | Destination_directory_fsync -> "destination_directory_fsync"
  | Source_directory_fsync -> "source_directory_fsync"
;;

let durable_move_error_to_string error =
  error.failures
  |> List.map (fun (stage, reason) ->
    Printf.sprintf "%s: %s" (durable_move_stage_to_string stage) reason)
  |> String.concat "; "
;;

let move_file_durable ~src ~dst =
  let src_dir = Filename.dirname src in
  let dst_dir = Filename.dirname dst in
  try
    ignore (ensure_dir dst_dir : string);
    Eio_guard.run_in_systhread (fun () ->
      match Unix.rename src dst with
      | exception exn ->
        Error { renamed = false; failures = [ Rename, Printexc.to_string exn ] }
      | () ->
        let failures =
          match fsync_directory dst_dir with
          | () -> []
          | exception exn ->
            [ Destination_directory_fsync, Printexc.to_string exn ]
        in
        let failures =
          if String.equal src_dir dst_dir
          then failures
          else
            match fsync_directory src_dir with
            | () -> failures
            | exception exn ->
              failures @ [ Source_directory_fsync, Printexc.to_string exn ]
        in
        if List.is_empty failures
        then Ok ()
        else Error { renamed = true; failures })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error { renamed = false; failures = [ Rename, Printexc.to_string exn ] }
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

let remove_file_durable path =
  let parent = Filename.dirname path in
  Eio_guard.run_in_systhread (fun () ->
    match Unix.unlink path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
    | exception exn ->
      Error { removed = false; failure = Unlink, Printexc.to_string exn }
    | () ->
      (match fsync_directory parent with
       | () -> Ok ()
       | exception exn ->
         Error
           { removed = true
           ; failure = Parent_directory_fsync, Printexc.to_string exn
           }))
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
