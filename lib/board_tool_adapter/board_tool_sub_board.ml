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

let workflow_rejection ~tool_name ~start_time msg =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    msg
;;

let required_string_arg args key =
  match get_string_opt args key with
  | None -> Error (Printf.sprintf "%s is required" key)
  | Some raw ->
    let value = String.trim raw in
    if String.equal value ""
    then Error (Printf.sprintf "%s is required" key)
    else Ok value
;;

let optional_nonempty_string_arg args key =
  match get_string_opt args key with
  | None -> Ok None
  | Some raw ->
    let value = String.trim raw in
    if String.equal value ""
    then Error (Printf.sprintf "%s cannot be empty" key)
    else Ok (Some value)
;;

let sub_board_access_arg raw =
  match String.lowercase_ascii (String.trim raw) with
  | "members_only" -> Ok Board.Members_only
  | "owner_only" -> Ok Board.Owner_only
  | "open" -> Ok Board.Open
  | _ -> Error (Printf.sprintf "unknown sub_board access: %s" raw)
;;

let sub_board_access_with_default args =
  match get_string_opt args "access" with
  | Some raw -> sub_board_access_arg raw
  | None -> Ok Board.Open
;;

let sub_board_access_optional args =
  match get_string_opt args "access" with
  | Some raw ->
    (match sub_board_access_arg raw with
     | Ok access -> Ok (Some access)
     | Error msg -> Error msg)
  | None -> Ok None
;;

let optional_string_list_arg args key =
  match Json_util.assoc_member_opt key args with
  | None -> Ok None
  | Some (`List values) ->
    let rec loop idx acc = function
      | [] -> Ok (Some (List.rev acc))
      | `String raw :: rest ->
        let value = String.trim raw in
        if String.equal value ""
        then Error (Printf.sprintf "%s[%d] cannot be empty" key idx)
        else loop (idx + 1) (value :: acc) rest
      | _ :: _ -> Error (Printf.sprintf "%s[%d] must be a string" key idx)
    in
    loop 0 [] values
  | Some _ -> Error (Printf.sprintf "%s must be an array of strings" key)
;;

let handle_sub_board_create ~tool_name ~start_time args : Tool_result.result =
  let args_result =
    let ( let* ) = Result.bind in
    let* slug = required_string_arg args "slug" in
    let* name = required_string_arg args "name" in
    let* description = required_string_arg args "description" in
    let* owner = required_string_arg args "owner" in
    let* members = optional_string_list_arg args "members" in
    let* access = sub_board_access_with_default args in
    Ok (slug, name, description, owner, Option.value ~default:[] members, access)
  in
  match args_result with
  | Error msg -> workflow_rejection ~tool_name ~start_time msg
  | Ok (slug, name, description, owner, members, access) ->
    (match
       Board_dispatch.create_sub_board
         ~slug
         ~name
         ~description
         ~owner
         ~members
         ~access
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
    Board_tool_format.error_of_board_error ~tool_name ~start_time e)
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
  match required_string_arg args "sub_board_id" with
  | Error msg -> workflow_rejection ~tool_name ~start_time msg
  | Ok sub_board_id ->
    (match Board_dispatch.get_sub_board ~sub_board_id with
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
    Board_tool_format.error_of_board_error ~tool_name ~start_time e)
;;

let handle_sub_board_update ~tool_name ~start_time args : Tool_result.result =
  let args_result =
    let ( let* ) = Result.bind in
    let* sub_board_id = required_string_arg args "sub_board_id" in
    let* name = optional_nonempty_string_arg args "name" in
    let* description = optional_nonempty_string_arg args "description" in
    let* members = optional_string_list_arg args "members" in
    let* access = sub_board_access_optional args in
    Ok (sub_board_id, name, description, members, access)
  in
  match args_result with
  | Error msg -> workflow_rejection ~tool_name ~start_time msg
  | Ok (sub_board_id, name, description, members, access) ->
    (match
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
    Board_tool_format.error_of_board_error ~tool_name ~start_time e)
;;

let handle_sub_board_delete ~tool_name ~start_time args : Tool_result.result =
  match required_string_arg args "sub_board_id" with
  | Error msg -> workflow_rejection ~tool_name ~start_time msg
  | Ok sub_board_id ->
    (match Board_dispatch.delete_sub_board ~sub_board_id with
  | Ok () ->
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:(`String (Printf.sprintf "SubBoard deleted: %s" sub_board_id))
      ()
  | Error e ->
    Board_tool_format.error_of_board_error ~tool_name ~start_time e)
;;
