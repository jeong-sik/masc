(** Compatibility shim — operational namespace is always "default".
    Retained for Room facade re-export. Will be removed when Room facade
    is deprecated. *)

open Room_utils

let current_room_path config = current_room_root_path config
let read_current_room _config = Some "default"
let write_current_room _config _room_id = ()
let room_path config room_id = room_dir_for config room_id
