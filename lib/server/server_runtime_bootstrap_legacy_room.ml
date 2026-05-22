(** Legacy-room inference for the flat-room migration path.

    Pre-flat-migration, sessions lived under [.masc/rooms/<room_id>/].
    The new layout puts session files directly under [.masc/]. When
    we detect a [rooms/] dir but no [current_room] marker, this
    module decides which legacy room (if any) becomes the root.

    Pure filesystem + Log.Misc + Coord; no parent-local state.
    Extracted verbatim from [Server_runtime_bootstrap]; all callers
    are internal to the parent. *)

let default_room_for_flat_migration = "focus-room"

let legacy_room_candidates rooms_dir =
  if not (Sys.file_exists rooms_dir) then
    []
  else
    Safe_ops.protect ~default:[] (fun () ->
      Sys.readdir rooms_dir
      |> Array.to_list
      |> List.filter_map (fun room_id ->
           let room_path = Filename.concat rooms_dir room_id in
           if Sys.is_directory room_path then
             let trimmed_room_id = String.trim room_id in
             if not (String.equal room_id trimmed_room_id) then begin
               Log.Misc.warn
                 "migrate: ignoring invalid legacy room dir %S (must not have leading/trailing whitespace)"
                 room_id;
               None
             end else
               match Coord.validate_room_id room_id with
               | Ok valid_room_id -> Some valid_room_id
               | Error msg ->
                 Log.Misc.warn
                   "migrate: ignoring invalid legacy room dir %s (%s)" room_id
                   msg;
                   None
           else
             None))

let infer_current_room_from_legacy_dirs rooms_dir =
  match legacy_room_candidates rooms_dir with
  | [ room_id ] ->
      Log.Misc.info
        "migrate: current_room unavailable; using only legacy room %s" room_id;
      Some room_id
  | room_ids when List.mem default_room_for_flat_migration room_ids ->
      Log.Misc.info
        "migrate: current_room unavailable; using legacy room %s"
        default_room_for_flat_migration;
      Some default_room_for_flat_migration
  | [] -> None
  | room_ids ->
      Log.Misc.warn
        "migrate: current_room unavailable and multiple legacy rooms exist (%s); skipping room flatten"
        (String.concat ", " room_ids);
      None

let load_current_room_or_default masc_root rooms_dir =
  let path = Filename.concat masc_root "current_room" in
  if not (Sys.file_exists path) then
    infer_current_room_from_legacy_dirs rooms_dir
  else
    match Safe_ops.read_file_safe path with
    | Error msg ->
        Log.Misc.warn
          "migrate: failed to read %s (%s); probing legacy room dirs instead"
          path msg;
        infer_current_room_from_legacy_dirs rooms_dir
    | Ok raw -> (
        match Coord.validate_room_id (String.trim raw) with
        | Ok room_id -> Some room_id
        | Error msg ->
            Log.Misc.warn
              "migrate: ignoring invalid current_room in %s (%s); probing legacy room dirs instead"
              path msg;
            infer_current_room_from_legacy_dirs rooms_dir)
