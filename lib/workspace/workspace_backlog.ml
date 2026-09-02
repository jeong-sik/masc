(** Workspace Backlog - Backlog I/O.

    Extracted from workspace_state.ml. *)

open Masc_domain
open Workspace_utils

let backlog_path = Workspace_utils.backlog_path

let backlog_lock_path config =
  Filename.concat (Filename.dirname (backlog_path config)) ".backlog"

let backlog_recovery_path config =
  backlog_path config ^ ".last-good"

let decode_backlog ~path json =
  match backlog_of_yojson json with
  | Ok backlog -> Ok backlog
  | Error msg ->
      Error
        (Printf.sprintf
           "[read_backlog] backlog decode failed for %s: %s"
           path
           msg)

(** Per-path backlog cache keyed by file mtime/size.

    CPU sampling showed that reading + Yojson-decoding backlog.json is one
    of the hottest paths in dashboard/keeper snapshot code, and the file is
    read many times between mutations.  Caching by mtime+size is safe because
    [write_backlog] invalidates the cache after persisting. *)
type backlog_cache_entry = {
  mtime : float;
  size : int;
  backlog : backlog;
}

let backlog_cache : (string, backlog_cache_entry) Hashtbl.t = Hashtbl.create 16
let backlog_cache_mu = Stdlib.Mutex.create ()

let file_stat_opt path =
  try Some (Unix.stat path) with Unix.Unix_error _ | Sys_error _ -> None

let clear_backlog_cache_for path =
  Stdlib.Mutex.protect backlog_cache_mu (fun () -> Hashtbl.remove backlog_cache path)

type backlog_recovery = {
  primary_error : string;
  recovery_path : string;
}

type backlog_observation = {
  observed_backlog : backlog;
  recovered_from : backlog_recovery option;
}

let read_backlog_with_source_r config =
  let path = backlog_path config in
  let recover primary_msg =
    let recovery_path = backlog_recovery_path config in
    (* [read_json_result] answers a missing key with an empty object, so an
       absent mirror would otherwise reach [decode_backlog] and be reported as a
       schema violation. Split absence out before the decode. Root fix: #29562. *)
    if not (Workspace_utils.path_exists config recovery_path)
    then
      Error
        (Printf.sprintf "%s; no recovery mirror at %s" primary_msg recovery_path)
    else
    match read_json_result config recovery_path with
    | Ok json ->
      (match decode_backlog ~path:recovery_path json with
       | Ok backlog ->
         Log.Misc.warn
           "read_backlog: primary backlog unreadable, recovered from %s (%s)"
           recovery_path
           primary_msg;
         Ok
           {
             observed_backlog = backlog;
             recovered_from = Some { primary_error = primary_msg; recovery_path };
           }
       | Error recovery_msg ->
         Error
           (Printf.sprintf
              "%s; recovery failed: %s"
              primary_msg
              recovery_msg))
    | Error recovery_msg ->
      Error
        (Printf.sprintf
           "%s; recovery read failed for %s: %s"
           primary_msg
           recovery_path
           recovery_msg)
  in
  let cached =
    Stdlib.Mutex.protect backlog_cache_mu (fun () ->
        match Hashtbl.find_opt backlog_cache path with
        | None -> None
        | Some entry -> (
            match file_stat_opt path with
            | None -> None
            | Some st ->
                if st.Unix.st_mtime = entry.mtime && st.Unix.st_size = entry.size
                then Some entry.backlog
                else None))
  in
  match cached with
  | Some backlog ->
    Ok { observed_backlog = backlog; recovered_from = None }
  | None when not (Workspace_utils.path_exists config path) ->
      recover (Printf.sprintf "no backlog at %s" path)
  | None -> (
      (* Cache the decoded backlog keyed on the file's (mtime, size). A
         writer commits under [with_backlog_file_lock] and clears this cache
         after its write, but the reader takes no such lock: statting only
         after the read would register (new stat, old backlog) when a commit
         lands between the two — an entry the writer's clear has already
         passed, poisoning hits until the next write. Stat before the read
         too and only register when nothing changed across it. *)
      let stat_before = file_stat_opt path in
      match read_json_result config path with
      | Ok json ->
          let decoded = decode_backlog ~path json in
          (match decoded with
          | Ok backlog ->
              (match (stat_before, file_stat_opt path) with
              | Some before, Some after
                when after.Unix.st_mtime = before.Unix.st_mtime
                     && after.Unix.st_size = before.Unix.st_size ->
                  Stdlib.Mutex.protect backlog_cache_mu (fun () ->
                      Hashtbl.replace backlog_cache path
                        { mtime = after.Unix.st_mtime
                        ; size = after.Unix.st_size
                        ; backlog
                        })
              | _ ->
                  (* The file moved under the read (or vanished before it):
                     hand back the value but leave the cache to the next
                     reader, which starts from a miss. *)
                  ());
              Ok { observed_backlog = backlog; recovered_from = None }
          | Error primary_msg -> recover primary_msg)
      | Error primary_msg -> recover primary_msg)

let read_backlog_r config =
  match read_backlog_with_source_r config with
  | Ok { observed_backlog; recovered_from = None } -> Ok observed_backlog
  | Ok
      {
        observed_backlog;
        recovered_from = Some { primary_error; recovery_path };
      } ->
    Error
      (Printf.sprintf
         "%s; recovery snapshot at %s revision=%d is available but non-authoritative for mutation"
         primary_error
         recovery_path
         observed_backlog.version)
  | Error _ as error -> error

let read_backlog_observation_with_source_r = read_backlog_with_source_r

let read_backlog_observation_r config =
  match read_backlog_with_source_r config with
  | Ok { observed_backlog; _ } -> Ok observed_backlog
  | Error _ as error -> error

exception Backlog_read_failed of string
exception Backlog_write_failed of string

let protect_backlog_commit_settlement f =
  match Eio_guard.execution_context () with
  | Eio_guard.Eio_fiber -> Eio.Cancel.protect f
  | Eio_guard.Non_eio -> f ()
;;

let read_backlog config =
  match read_backlog_with_source_r config with
  | Ok { observed_backlog; _ } -> observed_backlog
  | Error msg ->
    Log.Misc.error "%s" msg;
    raise (Backlog_read_failed msg)

type write_backlog_outcome =
  { committed_revision : int
  ; primary_mirror_error : string option
  ; recovery_error : string option
  ; post_commit_error : string option
  }

(** Result-returning variant with the primary backlog as the commit point.
    Once the primary write succeeds, recovery-copy failure is returned as an
    explicit committed outcome rather than a false mutation failure.

    Commits the NEXT revision of the given snapshot: [version] is stamped to
    [backlog.version + 1] and [last_updated] to now at this single commit
    point, so revision monotonicity is structural instead of a convention
    spread across every caller. Callers pass the snapshot they read, with
    mutated [tasks], and never hand-bump. *)
let write_backlog_result ?after_commit config backlog =
  if backlog.version = max_int then
    Error
      (Printf.sprintf
         "[write_backlog] revision exhausted at %d; refusing to wrap"
         backlog.version)
  else
  let backlog =
    { backlog with version = backlog.version + 1; last_updated = now_iso () }
  in
  let json = backlog_to_yojson backlog in
  let primary_path = backlog_path config in
  let recovery_path = backlog_recovery_path config in
  match write_json_commit_result config primary_path json with
  | Error msg -> Error msg
  | Ok primary_commit ->
    protect_backlog_commit_settlement (fun () ->
    Option.iter
      (fun message ->
         Log.TaskState.error
           "backlog primary committed but local mirror write failed path=%s error=%s"
           primary_path
           message)
      primary_commit.mirror_error;
    let recovery_error =
      match write_json_commit_result config recovery_path json with
      | Ok { mirror_error = None } -> None
      | Ok { mirror_error = Some message } ->
        Log.TaskState.error
          "backlog primary and recovery backend committed but recovery local \
           mirror write failed path=%s error=%s"
          recovery_path
          message;
        Some message
      | Error message ->
        Log.TaskState.error
          "backlog primary committed but recovery copy write failed path=%s error=%s"
          recovery_path
          message;
        Some message
    in
    clear_backlog_cache_for primary_path;
    clear_backlog_cache_for recovery_path;
    let mutation_observer_error =
      try
        (Atomic.get Workspace_hooks.on_task_mutation_fn) ();
        None
      with
      | exn ->
        let message = Printexc.to_string exn in
        Log.TaskState.error
          "backlog primary committed but task mutation observer failed path=%s \
           error=%s"
          primary_path
          message;
        Some message
    in
    let caller_post_commit_error =
      match after_commit with
      | None -> None
      | Some f ->
        (try
           f ();
           None
         with
         | exn ->
           let message = Printexc.to_string exn in
           Log.TaskState.error
             "backlog primary committed but post-commit callback failed path=%s \
              error=%s"
             primary_path
             message;
           Some message)
    in
    let post_commit_error =
      match mutation_observer_error, caller_post_commit_error with
      | None, None -> None
      | Some message, None | None, Some message -> Some message
      | Some observer_error, Some caller_error ->
        Some
          (Printf.sprintf
             "task mutation observer: %s; caller post-commit: %s"
             observer_error
             caller_error)
    in
    Ok
      { committed_revision = backlog.version
      ; primary_mirror_error = primary_commit.mirror_error
      ; recovery_error
      ; post_commit_error
      })

(** [write_backlog ?after_commit config backlog] persists the primary SSOT,
    then observes secondary recovery/mirror/projection failures without
    misreporting the committed mutation as a primary failure. *)
let write_backlog ?after_commit config backlog =
  match write_backlog_result ?after_commit config backlog with
  | Ok _ -> ()
  | Error message -> raise (Backlog_write_failed message)
