type error =
  | Keeper_names_unread of string
  | Keeper_meta_unread of { keeper : string; detail : string }

let error_detail = function
  | Keeper_names_unread detail -> "keeper names unread: " ^ detail
  | Keeper_meta_unread { keeper; detail } ->
    Printf.sprintf "keeper %s meta unread: %s" keeper detail
;;

let row ~config keeper : (Yojson.Safe.t, error) result =
  match Keeper_meta_store.read_effective_meta config keeper with
  | Error detail -> Error (Keeper_meta_unread { keeper; detail })
  | Ok None ->
    Error (Keeper_meta_unread { keeper; detail = "listed by name but has no meta" })
  | Ok (Some meta) ->
    let status = Keeper_tool_lane_status.handle ~config ~meta ~args:(`Assoc []) in
    (match status with
     | `Assoc fields -> Ok (`Assoc (("keeper", `String keeper) :: fields))
     | other -> Ok (`Assoc [ "keeper", `String keeper; "status", other ]))
;;

let json ~config =
  match Keeper_meta_store.keeper_names_result config with
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
