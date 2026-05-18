(** Tool_board_sub_board — sub-board handlers (create / list / get /
    update / delete).

    Stage 10 split of lib/tool_board.ml — sub-domain split out of
    [Tool_board_handlers] so both files stay under the godfile new-file
    cap. *)

open Tool_args

let handle_sub_board_create ~tool_name ~start_time args =
  let slug = get_string_opt args "slug" |> Option.value ~default:"" in
  let name = get_string_opt args "name" |> Option.value ~default:"" in
  let description = get_string_opt args "description" |> Option.value ~default:"" in
  let access =
    match get_string_opt args "access" with
    | Some "members_only" -> Some Board.Members_only
    | Some "owner_only" -> Some Board.Owner_only
    | Some "open" | Some _ -> Some Board.Open
    | None -> Some Board.Open
  in
  let members = get_string_list args "members" in
  let owner = get_string_opt args "owner" |> Option.value ~default:"" in
  match
    Board_dispatch.create_sub_board
      ~slug
      ~name
      ~description
      ~owner
      ~members
      ?access
      ()
  with
  | Ok sb ->
    Tool_result.ok
      ~tool_name
      ~start_time
      (Printf.sprintf "SubBoard created: %s (/%s)" sb.Board.name sb.Board.slug)
  | Error e -> Tool_result.error ~tool_name ~start_time (Board.show_board_error e)
;;

let handle_sub_board_list ~tool_name ~start_time _args =
  let boards = Board_dispatch.list_sub_boards () in
  let lines =
    List.map
      (fun (sb : Board.sub_board) ->
         Printf.sprintf
           "- %s (/%s): %s | %s | %d members | %d posts"
           sb.name
           sb.slug
           sb.description
           (Board.sub_board_access_to_string sb.access)
           (List.length sb.members)
           sb.post_count)
      boards
  in
  Tool_result.ok ~tool_name ~start_time (String.concat "\n" lines)
;;

let handle_sub_board_get ~tool_name ~start_time args =
  let sub_board_id = get_string_opt args "sub_board_id" |> Option.value ~default:"" in
  match Board_dispatch.get_sub_board ~sub_board_id with
  | Ok sb ->
    let members =
      List.map Board.Agent_id.to_string sb.Board.members |> String.concat ", "
    in
    Tool_result.ok
      ~tool_name
      ~start_time
      (Printf.sprintf
         "%s (/%s)\nDescription: %s\nOwner: %s\nAccess: %s\nMembers: %s\nPosts: %d"
         sb.name
         sb.slug
         sb.description
         (Board.Agent_id.to_string sb.owner)
         (Board.sub_board_access_to_string sb.access)
         members
         sb.post_count)
  | Error e -> Tool_result.error ~tool_name ~start_time (Board.show_board_error e)
;;

let handle_sub_board_update ~tool_name ~start_time args =
  let sub_board_id = get_string_opt args "sub_board_id" |> Option.value ~default:"" in
  let name = get_string_opt args "name" in
  let description = get_string_opt args "description" in
  let access =
    match get_string_opt args "access" with
    | Some "members_only" -> Some Board.Members_only
    | Some "owner_only" -> Some Board.Owner_only
    | Some "open" -> Some Board.Open
    | Some _ -> None
    | None -> None
  in
  let members_raw = get_string_list args "members" in
  let members = if members_raw = [] then None else Some members_raw in
  match
    Board_dispatch.update_sub_board
      ~sub_board_id
      ?name
      ?description
      ?members
      ?access
      ()
  with
  | Ok sb ->
    Tool_result.ok
      ~tool_name
      ~start_time
      (Printf.sprintf "SubBoard updated: %s (/%s)" sb.Board.name sb.Board.slug)
  | Error e -> Tool_result.error ~tool_name ~start_time (Board.show_board_error e)
;;

let handle_sub_board_delete ~tool_name ~start_time args =
  let sub_board_id = get_string_opt args "sub_board_id" |> Option.value ~default:"" in
  match Board_dispatch.delete_sub_board ~sub_board_id with
  | Ok () ->
    Tool_result.ok
      ~tool_name
      ~start_time
      (Printf.sprintf "SubBoard deleted: %s" sub_board_id)
  | Error e -> Tool_result.error ~tool_name ~start_time (Board.show_board_error e)
;;
