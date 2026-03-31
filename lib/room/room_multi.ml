(** Room current-room helpers.

    Keeps the current-room pointer durable while avoiding named-room registry
    management. *)

open Room_utils

(** Get current room file path *)
let current_room_path config = current_room_root_path config

(** Mtime-based cache for current_room: avoids re-reading the file when
    the modification time has not changed.  The file is tiny (~10 bytes)
    and updates are rare (only via masc_set_room), so a single stat()
    to check mtime is a safe substitute for open+read+close. *)
let current_room_cache : (string * float * string option) ref =
  ref ("", 0.0, None)

let read_current_room config =
  let read_from path =
    match Safe_ops.read_file_safe path with
    | Ok content ->
      let trimmed = String.trim content in
      if trimmed = "" then None else Some trimmed
    | Error _ -> None
  in
  let path = current_room_path config in
  let mtime =
    try (Unix.stat path).Unix.st_mtime
    with Unix.Unix_error _ -> 0.0
  in
  let (cached_path, cached_mtime, cached_value) = !current_room_cache in
  if String.equal cached_path path && Float.equal mtime cached_mtime
     && mtime > 0.0 then
    cached_value
  else begin
    let result =
      match read_from path with
      | Some room_id -> Some room_id
      | None -> Some "default"
    in
    current_room_cache := (path, mtime, result);
    result
  end

(** Write current room ID *)
let write_current_room config room_id =
  let room_id =
    match validate_room_id room_id with
    | Ok room_id -> room_id
    | Error msg -> invalid_arg ("invalid room_id: " ^ msg)
  in
  let write_to path =
    Fs_compat.mkdir_p (Filename.dirname path);
    Fs_compat.save_file path (room_id ^ "\n")
  in
  (* Canonical location inside .masc/ *)
  write_to (current_room_path config);
  (* Invalidate the mtime cache so next read picks up the new value *)
  current_room_cache := ("", 0.0, None)

(** Get path for a specific room *)
let room_path config room_id = room_dir_for config room_id
