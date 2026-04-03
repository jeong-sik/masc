(** Room current-room helpers.

    Since #4638 the multi-room abstraction has been removed.
    All state lives under the root .masc/ directory.
    These functions are kept for API compatibility. *)

open Room_utils

(** Get current room file path (legacy) *)
let current_room_path config = current_room_root_path config

(** Delegate to the shared reader so legacy-state warnings still fire. *)
let read_current_room config = Room_utils.read_current_room config

(** Persist the current-room label for dashboards and compat callers.
    Storage stays flattened; this only updates the display pointer. *)
let write_current_room config room_id =
  match Room_utils.validate_room_id room_id with
  | Ok valid_room_id ->
      Room_utils.mkdir_p (masc_root_dir config);
      Room_utils.write_text config (current_room_root_path config)
        (valid_room_id ^ "\n")
  | Error _ -> ()

(** Get path for a specific room -- always returns [masc_root_dir] since #4638. *)
let room_path config _room_id = masc_root_dir config
