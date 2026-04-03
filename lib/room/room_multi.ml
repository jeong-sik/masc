(** Room current-room compatibility helpers.

    The public operational model is now a single default namespace under
    [.masc/]. The current-room file is kept only as a backward-compatible
    marker for older tooling. *)

open Room_utils

(** Get current room file path *)
let current_room_path config = current_room_root_path config

(** Cache retained only so older code paths still have a stable shape. *)
let current_room_cache : (string * float * string option) ref =
  ref ("", 0.0, None)

let read_current_room config =
  let path = current_room_path config in
  let result = Room_utils.read_current_room config in
  current_room_cache := (path, 0.0, result);
  result

(** Write the compatibility room marker.
    Non-default inputs are accepted only for legacy callers, but the stored
    operational namespace is always forced back to [default]. *)
let write_current_room config room_id =
  match validate_room_id room_id with
  | Ok _requested_room_id ->
      let write_to path =
        Fs_compat.mkdir_p (Filename.dirname path);
        Fs_compat.save_file path "default\n"
      in
      write_to (current_room_path config);
      current_room_cache := ("", 0.0, Some "default")
  | Error _ ->
      current_room_cache := ("", 0.0, Some "default")

(** Get path for a specific room *)
let room_path config room_id = room_dir_for config room_id
