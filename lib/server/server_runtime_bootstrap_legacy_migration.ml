(** Legacy directory migration helpers for server runtime bootstrap,
    extracted from server_runtime_bootstrap.ml.

    Provides recursive merge migration for legacy dir names
    (perpetual -> traces, resident-keepers -> keepers) with quarantine
    semantics for conflicting files and keeper-meta promotion when the
    legacy record is fresher/valid. *)

let keeper_meta_updated_ts (meta : Keeper_types.keeper_meta) =
  Coord_resilience.Time.parse_iso8601_opt meta.updated_at
  |> Option.value ~default:0.0

let should_promote_legacy_keeper_meta ~legacy_path ~current_path =
  match
    Keeper_types.read_meta_file_path legacy_path,
    Keeper_types.read_meta_file_path current_path
  with
  | Ok (Some _legacy), Ok (Some _current) -> (
      keeper_meta_updated_ts _legacy > keeper_meta_updated_ts _current)
  | Ok (Some _), Ok None | Ok (Some _), Error _ -> true
  | _ -> false

let migrate_legacy_dirs_with_renames (state : Mcp_server.server_state) renames =
  let masc_root = Coord.masc_root_dir state.room_config in
  let quarantine_rel_path ~source_name ~rel_path =
    if rel_path = "" then source_name else Filename.concat source_name rel_path
  in
  let quarantine = Filename.concat masc_root "_quarantine" in
  let quarantine_replaced_path ~source_name ~rel_path =
    Filename.concat quarantine
      (Filename.concat "_replaced"
         (quarantine_rel_path ~source_name ~rel_path))
  in
  let rec migrate_recursive ~source_name ~old_dir ~new_dir ~rel_path
      ~prefer_root_keeper_meta_conflicts
      ~prefer_room_flatten_conflicts =
    if not (Sys.file_exists old_dir) then ()
    else begin
      Keeper_types.mkdir_p new_dir;
      Array.iter (fun name ->
        let old_path = Filename.concat old_dir name in
        let new_path = Filename.concat new_dir name in
        let rel = if rel_path = "" then name else Filename.concat rel_path name in
        if Sys.is_directory old_path then begin
          if Sys.file_exists new_path then
            migrate_recursive ~source_name ~old_dir:old_path ~new_dir:new_path ~rel_path:rel
              ~prefer_root_keeper_meta_conflicts
              ~prefer_room_flatten_conflicts
          else
            Sys.rename old_path new_path
        end else begin
          if Sys.file_exists new_path then begin
            if prefer_root_keeper_meta_conflicts && rel_path = ""
               && Filename.check_suffix name ".json"
               && should_promote_legacy_keeper_meta
                    ~legacy_path:old_path ~current_path:new_path
            then begin
              let replaced_q_path = quarantine_replaced_path ~source_name ~rel_path:rel in
              Keeper_types.mkdir_p (Filename.dirname replaced_q_path);
              Sys.rename new_path replaced_q_path;
              Sys.rename old_path new_path
            end else if prefer_room_flatten_conflicts then begin
              let replaced_q_path = quarantine_replaced_path ~source_name ~rel_path:rel in
              Keeper_types.mkdir_p (Filename.dirname replaced_q_path);
              Sys.rename new_path replaced_q_path;
              Sys.rename old_path new_path
            end else begin
              let q_path =
                Filename.concat quarantine
                  (quarantine_rel_path ~source_name ~rel_path:rel)
              in
              Keeper_types.mkdir_p (Filename.dirname q_path);
              Sys.rename old_path q_path
            end
          end else
            Sys.rename old_path new_path
        end
      ) (Sys.readdir old_dir);
      (try
        if Array.length (Sys.readdir old_dir) = 0 then
          Sys.rmdir old_dir
        else
          Log.Misc.warn "migrate: old dir not empty after migration: %s" old_dir
      with Sys_error _ -> ())
    end
  in
  (try
    List.iter (fun (old_name, new_name) ->
      let old_dir = Filename.concat masc_root old_name in
      let new_dir = Filename.concat masc_root new_name in
      if Sys.file_exists old_dir then begin
        Log.Misc.info "migrate: %s -> %s" old_name new_name;
        migrate_recursive ~source_name:old_name ~old_dir ~new_dir ~rel_path:""
          ~prefer_root_keeper_meta_conflicts:(String.equal new_name "keepers")
          ~prefer_room_flatten_conflicts:(String.starts_with ~prefix:"rooms/" old_name)
      end
    ) renames
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.error "legacy dir migration failed: %s" (Printexc.to_string exn))

let migrate_legacy_dirs (state : Mcp_server.server_state) =
  migrate_legacy_dirs_with_renames state
    [ ("perpetual", "traces"); ("resident-keepers", "keepers") ]

let migrate_legacy_keeper_dirs_blocking (state : Mcp_server.server_state) =
  migrate_legacy_dirs_with_renames state [ ("resident-keepers", "keepers") ]
