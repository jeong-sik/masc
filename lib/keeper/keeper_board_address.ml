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

let read config name =
  let requested_name = String.trim name in
  if requested_name = ""
  then Unavailable Metadata_absent
  else
    let meta_path =
      Filename.concat
        (Workspace.keepers_runtime_dir config)
        (Keeper_runtime_root_entry.keeper_basename
           ~keeper_name:requested_name
           Keeper_runtime_root_entry.Metadata)
    in
    match Keeper_meta_store.read_meta_file_path meta_path with
    | Error _ -> Unavailable Effective_metadata_unread
    | Ok None -> Unavailable Metadata_absent
    | Ok (Some meta) ->
      (match
         Keeper_meta_contract.effective_meta_result
           ~base_path:config.Workspace.base_path
           meta
       with
       | Ok meta -> of_effective_meta meta
       | Error _ -> Unavailable Effective_metadata_unread)
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
