(** Coord Backlog - Backlog I/O.

    Extracted from room_state.ml. *)

open Types
open Coord_utils

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

let write_backlog config backlog =
  let json = backlog_to_yojson backlog in
  write_json config (backlog_path config) json;
  write_json config (backlog_recovery_path config) json
