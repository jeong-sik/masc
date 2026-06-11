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

let read_backlog_r config =
  match read_json_result config (backlog_path config) with
  | Ok json -> decode_backlog ~path:(backlog_path config) json
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
                recovery_msg))

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
  (match after_commit with
   | Some f -> f ()
   | None -> ())
