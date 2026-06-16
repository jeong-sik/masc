(** Workspace Backlog - Backlog I/O.

    Extracted from workspace_state.ml. *)

open Masc_domain
open Workspace_utils

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

(** [write_backlog ?after_commit config backlog] persists the backlog to
    both the primary and recovery paths, then invokes [after_commit] if
    provided.  The callback runs only after both writes succeed, making it
    the correct place for cache-invalidation side-effects that must not
    fire unless the backlog actually landed on disk (RFC-0221 §3.3). *)
let write_backlog ?after_commit config backlog =
  let json = backlog_to_yojson backlog in
  write_json config (backlog_path config) json;
  write_json config (backlog_recovery_path config) json;
  clear_backlog_cache_for (backlog_path config);
  clear_backlog_cache_for (backlog_recovery_path config);
  (match after_commit with
   | Some f -> f ()
   | None -> ())
