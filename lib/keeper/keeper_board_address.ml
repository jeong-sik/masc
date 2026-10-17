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
  match Keeper_meta_store.read_effective_meta config name with
  | Ok (Some meta) -> of_effective_meta meta
  | Ok None -> Unavailable Metadata_absent
  | Error _ -> Unavailable Effective_metadata_unread
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
