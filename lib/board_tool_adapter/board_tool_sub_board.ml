(** Board_tool_sub_board — sub-board handlers (create / list / get /
    update / delete).

    Stage 10 split of lib/board_tool.ml — sub-domain split out of
    [Board_tool_handlers] so both files stay under the godfile new-file
    cap. *)

open Masc_board_handlers
open Tool_args

(* RFC-0189 PR-1b.3 — handlers return typed [Tool_result.result].
   Sub-board Board_dispatch errors (slug already exists, owner not found,
   sub_board not found, etc.) are predominantly caller-input violations →
   [Workflow_rejection]. A future RFC may route through
   [Board_tool_format.board_error_failure_class] for per-variant routing,
   but for the current sub_board error vocabulary a uniform
   Workflow_rejection matches observed semantics. *)

let owner_arg args =
  match get_string_opt args "owner" with
  | None -> Error (Board.Validation_error "owner is required")
  | Some raw ->
    let raw = String.trim raw in
    if String.equal raw ""
    then Error (Board.Validation_error "owner is required")
    else Board.Agent_id.of_string raw
;;

let same_agent_id left right =
  String.equal (Board.Agent_id.to_string left) (Board.Agent_id.to_string right)
;;

let require_sub_board_owner ~sub_board_id ~owner =
  match Board_dispatch.get_sub_board ~sub_board_id with
  | Error _ as err -> err
  | Ok sb ->
    if same_agent_id sb.Board.owner owner
    then Ok ()
    else
      Error
        (Board.Unauthorized
           (Printf.sprintf
              "agent %s cannot mutate sub-board %s owned by %s"
              (Board.Agent_id.to_string owner)
              sub_board_id
              (Board.Agent_id.to_string sb.owner)))
;;

let handle_sub_board_create ~tool_name ~start_time args : Tool_result.result =
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
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:
        (`String
           (Printf.sprintf "SubBoard created: %s (/%s)" sb.Board.name sb.Board.slug))
      ()
  | Error e ->
    Board_tool_format.error_of_board_error ~tool_name ~start_time e
;;

let handle_sub_board_list ~tool_name ~start_time _args : Tool_result.result =
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
  Tool_result.make_ok
    ~tool_name
    ~start_time
    ~data:(`String (String.concat "\n" lines))
    ()
;;

let handle_sub_board_get ~tool_name ~start_time args : Tool_result.result =
  let sub_board_id = get_string_opt args "sub_board_id" |> Option.value ~default:"" in
  match Board_dispatch.get_sub_board ~sub_board_id with
  | Ok sb ->
    let members =
      List.map Board.Agent_id.to_string sb.Board.members |> String.concat ", "
    in
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:
        (`String
           (Printf.sprintf
              "%s (/%s)\nDescription: %s\nOwner: %s\nAccess: %s\nMembers: %s\nPosts: %d"
              sb.name
              sb.slug
              sb.description
              (Board.Agent_id.to_string sb.owner)
              (Board.sub_board_access_to_string sb.access)
              members
              sb.post_count))
      ()
  | Error e ->
    Board_tool_format.error_of_board_error ~tool_name ~start_time e
;;

let handle_sub_board_update ~tool_name ~start_time args : Tool_result.result =
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
  match owner_arg args with
  | Error e -> Board_tool_format.error_of_board_error ~tool_name ~start_time e
  | Ok owner ->
  match require_sub_board_owner ~sub_board_id ~owner with
  | Error e -> Board_tool_format.error_of_board_error ~tool_name ~start_time e
  | Ok () ->
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
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:
        (`String
           (Printf.sprintf "SubBoard updated: %s (/%s)" sb.Board.name sb.Board.slug))
      ()
  | Error e ->
    Board_tool_format.error_of_board_error ~tool_name ~start_time e
;;

let handle_sub_board_delete ~tool_name ~start_time args : Tool_result.result =
  let sub_board_id = get_string_opt args "sub_board_id" |> Option.value ~default:"" in
  match owner_arg args with
  | Error e -> Board_tool_format.error_of_board_error ~tool_name ~start_time e
  | Ok owner ->
  match require_sub_board_owner ~sub_board_id ~owner with
  | Error e -> Board_tool_format.error_of_board_error ~tool_name ~start_time e
  | Ok () ->
  match Board_dispatch.delete_sub_board ~sub_board_id with
  | Ok () ->
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:(`String (Printf.sprintf "SubBoard deleted: %s" sub_board_id))
      ()
  | Error e ->
    Board_tool_format.error_of_board_error ~tool_name ~start_time e
;;
