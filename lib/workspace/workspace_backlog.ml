(** Workspace Backlog - Backlog I/O.

    Extracted from workspace_state.ml. *)

open Masc_domain
open Workspace_utils

let backlog_path = Workspace_utils.backlog_path

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

let read_backlog_r config =
  let path = backlog_path config in
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
  | Some backlog -> Ok backlog
  | None -> (
      match read_json_result config path with
      | Ok json ->
          let decoded = decode_backlog ~path json in
          (match decoded with
          | Ok backlog ->
              (match file_stat_opt path with
              | Some st ->
                  Stdlib.Mutex.protect backlog_cache_mu (fun () ->
                      Hashtbl.replace backlog_cache path
                        { mtime = st.Unix.st_mtime; size = st.Unix.st_size; backlog })
              | None -> ());
              Ok backlog
          | Error _ as e -> e)
      | Error primary_msg ->
          let recovery_path = backlog_recovery_path config in
          (match read_json_result config recovery_path with
           | Ok json ->
               (match decode_backlog ~path:recovery_path json with
                | Ok backlog ->
                    Log.Misc.warn
                      "read_backlog: primary backlog unreadable, recovered from %s (%s)"
                      recovery_path
                      primary_msg;
                    Ok backlog
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
                    recovery_msg)))

let read_backlog config =
  match read_backlog_r config with
  | Ok backlog -> backlog
  | Error msg ->
      Log.Misc.error "%s" msg;
      { tasks = []; last_updated = now_iso (); version = 1 }

exception Backlog_write_failed of string

type write_backlog_outcome =
  { primary_mirror_error : string option
  ; recovery_error : string option
  ; post_commit_error : string option
  }

(** Result-returning variant with the primary backlog as the commit point.
    Once the primary write succeeds, recovery-copy failure is returned as an
    explicit committed outcome rather than a false mutation failure. *)
let write_backlog_result ?after_commit config backlog =
  let json = backlog_to_yojson backlog in
  let primary_path = backlog_path config in
  let recovery_path = backlog_recovery_path config in
  match write_json_commit_result config primary_path json with
  | Error msg -> Error msg
  | Ok primary_commit ->
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
    let post_commit_error =
      match after_commit with
      | None -> None
      | Some f ->
        (try
           f ();
           None
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           let message = Printexc.to_string exn in
           Log.TaskState.error
             "backlog primary committed but post-commit callback failed path=%s \
              error=%s"
             primary_path
             message;
           Some message)
    in
    Ok
      { primary_mirror_error = primary_commit.mirror_error
      ; recovery_error
      ; post_commit_error
      }

(** [write_backlog ?after_commit config backlog] persists the primary SSOT,
    then observes secondary recovery/mirror/projection failures without
    misreporting the committed mutation as a primary failure. *)
let write_backlog ?after_commit config backlog =
  match write_backlog_result ?after_commit config backlog with
  | Ok _ -> ()
  | Error message -> raise (Backlog_write_failed message)
