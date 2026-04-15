(** Room Backlog - Backlog I/O.

    Extracted from room_state.ml. *)

open Types
open Room_utils

let read_backlog_r config =
  match read_json_result config (backlog_path config) with
  | Error msg -> Error msg
  | Ok json ->
      (match backlog_of_yojson json with
       | Ok backlog -> Ok backlog
       | Error msg ->
           Error
             (Printf.sprintf
                "[read_backlog] backlog decode failed for %s: %s"
                (backlog_path config)
                msg))

let read_backlog config =
  match read_backlog_r config with
  | Ok backlog -> backlog
  | Error msg ->
      Log.Misc.error "%s" msg;
      { tasks = []; last_updated = now_iso (); version = 1 }

let write_backlog config backlog =
  write_json config (backlog_path config) (backlog_to_yojson backlog)
