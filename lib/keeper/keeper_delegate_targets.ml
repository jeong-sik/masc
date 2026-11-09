type unavailable =
  | Unknown_keeper
  | Owner_unavailable
  | Store_unavailable

type presence =
  | Not_registered
  | Between_turns
  | In_turn of { age_s : int }

type queue =
  { queued_count : int
  ; oldest_queued_age_s : int option
  }

type row =
  | Available of { name : string; presence : presence; queue : queue }
  | Unavailable of { name : string; reason : unavailable }

let age_seconds ~now ~since = Float.to_int (Float.max 0.0 (now -. since))

let presence ~now ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Not_registered
  | Some entry ->
    (match Keeper_composite_observer.live_turn_observation entry with
     | None -> Between_turns
     | Some observation ->
       In_turn { age_s = age_seconds ~now ~since:observation.Keeper_registry.started_at })
;;

let unavailable_of_lookup : Keeper_owner_registry.lookup_error -> unavailable = function
  | Keeper_owner_registry.Owner_not_found _ -> Unknown_keeper
  | Keeper_owner_registry.Inventory_not_installed _
  | Keeper_owner_registry.Owner_unavailable _
  | Keeper_owner_registry.Owner_initialization_failed _
  | Keeper_owner_registry.Inventory_stopping -> Owner_unavailable
;;

let queue_of_projection ~now (projection : Keeper_owner.operation_projection) =
  { queued_count = projection.Keeper_owner.queued_count
  ; oldest_queued_age_s =
      Option.map
        (fun created_at -> age_seconds ~now ~since:created_at)
        projection.Keeper_owner.oldest_queued_created_at
  }
;;

let observe ~now ~base_path ~keeper_name =
  match Keeper_owner_registry.operation_projection ~base_path ~keeper_name with
  | Error lookup -> Unavailable { name = keeper_name; reason = unavailable_of_lookup lookup }
  | Ok projection when projection.Keeper_owner.store_unavailable ->
    Unavailable { name = keeper_name; reason = Store_unavailable }
  | Ok projection ->
    Available
      { name = keeper_name
      ; presence = presence ~now ~base_path keeper_name
      ; queue = queue_of_projection ~now projection
      }
;;

let unavailable_to_string = function
  | Unknown_keeper -> "unknown_keeper"
  | Owner_unavailable -> "owner_unavailable"
  | Store_unavailable -> "store_unavailable"
;;

let presence_fields = function
  | Not_registered -> [ "turn", `String "not_registered" ]
  | Between_turns -> [ "turn", `String "between_turns" ]
  | In_turn { age_s } -> [ "turn", `String "in_turn"; "turn_age_s", `Int age_s ]
;;

let row_to_json = function
  | Available { name; presence; queue } ->
    let oldest =
      match queue.oldest_queued_age_s with
      | None -> []
      | Some age_s -> [ "oldest_queued_age_s", `Int age_s ]
    in
    `Assoc
      ([ "name", `String name ]
       @ presence_fields presence
       @ [ "queued_count", `Int queue.queued_count ]
       @ oldest)
  | Unavailable { name; reason } ->
    `Assoc [ "name", `String name; "unavailable", `String (unavailable_to_string reason) ]
;;

let invalid_input detail =
  Keeper_types_profile.tool_result_error_data
    ~class_:Tool_result.Policy_rejection
    (`Assoc
       [ "error", `String Keeper_chat_public_error.(code Invalid_input)
       ; "message", `String detail
       ])
;;

let name_of_json = function
  | `String raw ->
    Keeper_id.Keeper_name.of_string raw
    |> Result.map Keeper_id.Keeper_name.to_string
    |> Result.map_error (fun detail -> Printf.sprintf "invalid Keeper name: %s" detail)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error "names must hold strings"
;;

let names_of_args = function
  | `Assoc [ ("names", `List (_ :: _ as items)) ] ->
    List.fold_right
      (fun item names ->
         match names with
         | Error _ as failed -> failed
         | Ok names -> Result.map (fun name -> name :: names) (name_of_json item))
      items
      (Ok [])
  | _ -> Error "keeper delegate targets requires exactly names, a non-empty list of Keeper names"
;;

let body ~(config : Workspace.config) args =
  match names_of_args args with
  | Error detail -> invalid_input detail
  | Ok names ->
    let now = Time_compat.now () in
    let rows =
      List.map
        (fun keeper_name ->
           row_to_json (observe ~now ~base_path:config.Workspace.base_path ~keeper_name))
        names
    in
    Keeper_types_profile.tool_result_ok_data (`Assoc [ "targets", `List rows ])
;;
