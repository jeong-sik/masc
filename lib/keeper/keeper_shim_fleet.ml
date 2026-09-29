type error =
  | Keeper_names_unread of string
  | Keeper_meta_unread of { keeper : string; detail : string }

let error_detail = function
  | Keeper_names_unread detail -> "keeper names unread: " ^ detail
  | Keeper_meta_unread { keeper; detail } ->
    Printf.sprintf "keeper %s meta unread: %s" keeper detail
;;

let row ~config keeper : (Yojson.Safe.t, error) result =
  let ( let* ) = Result.bind in
  let unread detail = Keeper_meta_unread { keeper; detail } in
  (* Status reads must not create the store or repair a metadata snapshot. *)
  let path =
    Filename.concat (Workspace.keepers_runtime_dir config)
      (Keeper_runtime_root_entry.keeper_basename
         ~keeper_name:keeper Keeper_runtime_root_entry.Metadata)
  in
  let* meta =
    Keeper_meta_store.read_meta_file_path_read_only
      ~ownership_root:config.Workspace.base_path path
    |> Result.map_error (function
      | Keeper_meta_store.Unreadable detail | Not_current detail -> unread detail)
  in
  let* meta =
    match meta with
    | None -> Error (unread "listed by name but has no meta")
    | Some meta when not (String.equal meta.Keeper_meta_contract.name keeper) ->
      Error (unread "metadata name differs from its filename")
    | Some meta ->
      Keeper_meta_contract.effective_meta_result ~base_path:config.base_path meta
      |> Result.map_error unread
  in
  let status = Keeper_tool_lane_status.handle ~config ~meta ~args:(`Assoc []) in
  match status with
  | `Assoc fields -> Ok (`Assoc (("keeper", `String keeper) :: fields))
  | other -> Ok (`Assoc [ "keeper", `String keeper; "status", other ])
;;

let json ~config =
  match Keeper_meta_store.persisted_keeper_names_read_only_result config with
  | Error detail -> Error (Keeper_names_unread detail)
  | Ok names ->
    let rec rows acc = function
      | [] -> Ok (List.rev acc)
      | keeper :: rest ->
        (match row ~config keeper with
         | Ok json -> rows (json :: acc) rest
         | Error _ as error -> error)
    in
    (match rows [] (List.sort_uniq String.compare names) with
     | Error error -> Error error
     | Ok keepers ->
       Ok
         (`Assoc
             [ "server_release", `String Build_version.current
             ; "keepers", `List keepers
             ]))
;;
