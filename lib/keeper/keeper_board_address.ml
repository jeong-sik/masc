type unavailable = Metadata_absent | Effective_metadata_unread

type t =
  | Ready of Keeper_identity.Keeper_id.t list
  | Unavailable of unavailable

let of_effective_meta (meta : Keeper_meta_contract.keeper_meta) =
  Ready
    (Keeper_lane_mentions.effective_target_ids
       ~keeper_name:meta.name
       ~mention_targets:meta.mention_targets)
;;

type address_file_stamp = {
  st_dev : int;
  st_ino : int;
  st_size : int;
  st_mtime : float;
  st_ctime : float;
  st_perm : int;
  st_uid : int;
  st_gid : int;
}

let equal_address_file_stamp (a : address_file_stamp) (b : address_file_stamp) =
  Int.equal a.st_dev b.st_dev
  && Int.equal a.st_ino b.st_ino
  && Int.equal a.st_size b.st_size
  && Float.equal a.st_mtime b.st_mtime
  && Float.equal a.st_ctime b.st_ctime
  && Int.equal a.st_perm b.st_perm
  && Int.equal a.st_uid b.st_uid
  && Int.equal a.st_gid b.st_gid
;;

let stat_regular_opt (path : string) : address_file_stamp option =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG
    ; st_dev; st_ino; st_size; st_mtime; st_ctime; st_perm; st_uid; st_gid; _ } ->
    Some { st_dev; st_ino; st_size; st_mtime; st_ctime; st_perm; st_uid; st_gid }
  | { Unix.st_kind =
        Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK
    ; _ } -> None
  | exception Unix.Unix_error _ -> None
;;

let stamp_is_settled ~now (st : address_file_stamp) =
  now -. st.st_mtime >= 0.05 && now -. st.st_ctime >= 0.05
;;

type meta_source_stamp =
  | Owner_written of Keeper_meta_contract.keeper_meta
  | Meta_file of { path : string; stamp : address_file_stamp }

type cached_board_address = {
  source : meta_source_stamp;
  meta_name : string;
  toml_path : string;
  toml_stamp : address_file_stamp;
  value : t;
}

let board_address_cache_mu = Stdlib.Mutex.create ()
let board_address_cache : (string * string, cached_board_address) Hashtbl.t =
  Hashtbl.create 64
let board_address_cache_max = 256

let meta_path_for (config : Workspace.config) requested_name =
  Filename.concat
    (Workspace.keepers_runtime_dir config)
    (Keeper_runtime_root_entry.keeper_basename
       ~keeper_name:requested_name
       Keeper_runtime_root_entry.Metadata)
;;

let read_cached_opt (config : Workspace.config) name : t option =
  let requested_name = String.trim name in
  if requested_name = "" then Some (Unavailable Metadata_absent)
  else
    let key = config.Workspace.base_path, requested_name in
    match
      Stdlib.Mutex.protect board_address_cache_mu (fun () ->
        Hashtbl.find_opt board_address_cache key)
    with
    | None -> None
    | Some cached ->
      let now = Time_compat.now () in
      let owner_meta =
        Keeper_owner_projection.meta_the_file_holds
          ~base_path:config.Workspace.base_path
          ~keeper_name:requested_name
      in
      let source_valid =
        match cached.source, owner_meta with
        | Owner_written written, Some held -> held == written
        | Meta_file { path; stamp }, None ->
          let expected_path = meta_path_for config requested_name in
          String.equal path expected_path
          && (match stat_regular_opt path with
              | Some current ->
                equal_address_file_stamp current stamp
                && stamp_is_settled ~now current
              | None -> false)
        | Owner_written _, None | Meta_file _, Some _ -> false
      in
      if not source_valid then None
      else
        let expected_toml_path =
          Config_dir_resolver.keeper_toml_path_for_base_path
            ~base_path:config.Workspace.base_path
            cached.meta_name
        in
        if String.equal cached.toml_path expected_toml_path
        then
          match stat_regular_opt cached.toml_path with
          | Some ts
            when equal_address_file_stamp ts cached.toml_stamp
                 && stamp_is_settled ~now ts ->
            Some cached.value
          | Some _ | None -> None
        else None
;;

let read config name =
  let requested_name = String.trim name in
  if requested_name = ""
  then Unavailable Metadata_absent
  else
    match read_cached_opt config requested_name with
    | Some cached -> cached
    | None ->
      let key = config.Workspace.base_path, requested_name in
      let meta_path = meta_path_for config requested_name in
      let now_before = Time_compat.now () in
      let owner_before =
        Keeper_owner_projection.meta_the_file_holds
          ~base_path:config.Workspace.base_path
          ~keeper_name:requested_name
      in
      let meta_stamp_before =
        match owner_before with
        | Some _ -> None
        | None -> stat_regular_opt meta_path
      in
      let invalidate_cached () =
        Stdlib.Mutex.protect board_address_cache_mu (fun () ->
          Hashtbl.remove board_address_cache key)
      in
      match
        Keeper_stored_meta.read config requested_name ~read_file:(fun () ->
          Keeper_meta_store.read_meta_file_path meta_path)
      with
      | Error _ ->
        invalidate_cached ();
        Unavailable Effective_metadata_unread
      | Ok None ->
        invalidate_cached ();
        Unavailable Metadata_absent
      | Ok (Some meta) ->
        let toml_path =
          Config_dir_resolver.keeper_toml_path_for_base_path
            ~base_path:config.Workspace.base_path
            meta.name
        in
        let now_toml_before = Time_compat.now () in
        let toml_stamp_before = stat_regular_opt toml_path in
        (match
           Keeper_meta_contract.effective_meta_result
             ~base_path:config.Workspace.base_path
             meta
         with
         | Error _ ->
           invalidate_cached ();
           Unavailable Effective_metadata_unread
         | Ok eff_meta ->
           let value = of_effective_meta eff_meta in
           let now_after = Time_compat.now () in
           let verified_source =
             let owner_after =
               Keeper_owner_projection.meta_the_file_holds
                 ~base_path:config.Workspace.base_path
                 ~keeper_name:requested_name
             in
             match owner_before, owner_after, meta_stamp_before with
             | Some w1, Some w2, _ when w1 == w2 -> Some (Owner_written w2)
             | None, None, Some m1 ->
               (match stat_regular_opt meta_path with
                | Some m2
                  when stamp_is_settled ~now:now_before m1
                       && equal_address_file_stamp m1 m2
                       && stamp_is_settled ~now:now_after m2 ->
                  Some (Meta_file { path = meta_path; stamp = m2 })
                | Some _ | None -> None)
             | Some _, (Some _ | None), _
             | None, Some _, _
             | None, None, None -> None
           in
           let verified_toml =
             match toml_stamp_before, stat_regular_opt toml_path with
             | Some t1, Some t2
               when stamp_is_settled ~now:now_toml_before t1
                    && equal_address_file_stamp t1 t2
                    && stamp_is_settled ~now:now_after t2 ->
               Some t2
             | Some _, Some _ | Some _, None | None, Some _ | None, None -> None
           in
           (match verified_source, verified_toml with
            | Some source, Some toml_stamp ->
              Stdlib.Mutex.protect board_address_cache_mu (fun () ->
                if Hashtbl.length board_address_cache >= board_address_cache_max
                   && not (Hashtbl.mem board_address_cache key)
                then Hashtbl.clear board_address_cache;
                Hashtbl.replace board_address_cache key
                  { source; meta_name = meta.name; toml_path; toml_stamp; value })
            | Some _, None | None, Some _ | None, None -> ());
           value)
;;

let to_yojson = function
  | Ready target_ids ->
    `Assoc
      [ "state", `String "ready"
      ; "target_ids", `List
          (List.map
             (fun id -> `String (Keeper_identity.Keeper_id.to_string id))
             target_ids)
      ]
  | Unavailable reason ->
    let reason = match reason with
      | Metadata_absent -> "metadata_absent"
      | Effective_metadata_unread -> "effective_metadata_unread"
    in
    `Assoc [ "state", `String "unavailable"; "reason", `String reason ]
;;
