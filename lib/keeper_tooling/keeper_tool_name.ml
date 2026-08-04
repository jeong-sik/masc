(* Typed vocabulary for Keeper task and board runtime adapters.

   This lives outside the central [Tool_name] module so the tool dispatch
   substrate stays keeper-agnostic: the substrate routes
   opaque tool names and the keeper subsystem owns the typed vocabulary of its
   own tools. Dependency direction is keeper -> tool, never the reverse.

   The SSOT is on the keeper side of the Tool/Keeper boundary. *)

type t =
  | Board_comment
  | Board_comment_vote
  | Board_curation_read
  | Board_curation_submit
  | Board_post_get
  | Board_list
  | Board_post
  | Board_search
  | Board_stats
  | Board_sub_board_create
  | Board_sub_board_delete
  | Board_sub_board_get
  | Board_sub_board_list
  | Board_sub_board_update
  | Board_vote
  | Broadcast
  | Task_claim
  | Task_create
  | Task_done
  | Tasks_audit
  | Tasks_list

let to_string = function
  | Board_comment -> "keeper_board_comment"
  | Board_comment_vote -> "keeper_board_comment_vote"
  | Board_curation_read -> "keeper_board_curation_read"
  | Board_curation_submit -> "keeper_board_curation_submit"
  | Board_post_get -> "keeper_board_post_get"
  | Board_list -> "keeper_board_list"
  | Board_post -> "keeper_board_post"
  | Board_search -> "keeper_board_search"
  | Board_stats -> "keeper_board_stats"
  | Board_sub_board_create -> "keeper_board_sub_board_create"
  | Board_sub_board_delete -> "keeper_board_sub_board_delete"
  | Board_sub_board_get -> "keeper_board_sub_board_get"
  | Board_sub_board_list -> "keeper_board_sub_board_list"
  | Board_sub_board_update -> "keeper_board_sub_board_update"
  | Board_vote -> "keeper_board_vote"
  | Broadcast -> "keeper_broadcast"
  | Task_claim -> "keeper_task_claim"
  | Task_create -> "keeper_task_create"
  | Task_done -> "keeper_task_done"
  | Tasks_audit -> "keeper_tasks_audit"
  | Tasks_list -> "keeper_tasks_list"
;;

let of_string = function
  | "keeper_board_comment" -> Some Board_comment
  | "keeper_board_comment_vote" -> Some Board_comment_vote
  | "keeper_board_curation_read" -> Some Board_curation_read
  | "keeper_board_curation_submit" -> Some Board_curation_submit
  | "keeper_board_post_get" -> Some Board_post_get
  | "keeper_board_list" -> Some Board_list
  | "keeper_board_post" -> Some Board_post
  | "keeper_board_search" -> Some Board_search
  | "keeper_board_stats" -> Some Board_stats
  | "keeper_board_vote" -> Some Board_vote
  | "keeper_board_sub_board_create" -> Some Board_sub_board_create
  | "keeper_board_sub_board_delete" -> Some Board_sub_board_delete
  | "keeper_board_sub_board_get" -> Some Board_sub_board_get
  | "keeper_board_sub_board_list" -> Some Board_sub_board_list
  | "keeper_board_sub_board_update" -> Some Board_sub_board_update
  | "keeper_broadcast" -> Some Broadcast
  | "keeper_task_claim" -> Some Task_claim
  | "keeper_task_create" -> Some Task_create
  | "keeper_task_done" -> Some Task_done
  | "keeper_tasks_audit" -> Some Tasks_audit
  | "keeper_tasks_list" -> Some Tasks_list
  | _ -> None
;;

let pp fmt t = Format.pp_print_string fmt (to_string t)
;;


let public_mcp_non_descriptor_names =
  [ "masc_start"
  ; "masc_broadcast"
  ; "masc_messages"
  ; "masc_keeper_sandbox_status"
  ; "masc_keeper_create_from_persona"
  ; "masc_persona_list"
  (* Persona CRUD (#23664) lives with masc_persona_list outside the keeper
     descriptor spine (operator-plane handlers in mcp_server); #23664 added
     the surface entries without this allowlist edit while main was red. *)
  ; "masc_persona_create"
  ; "masc_persona_update"
  ; "masc_persona_delete"
  ]
;;

type board_projection =
  | Keeper_wrapper of t
  | Direct_masc

let board_projection_of_masc_board_name = function
  | Tool_name.Board_name.Board_comment -> Keeper_wrapper Board_comment
  | Tool_name.Board_name.Board_comment_vote -> Keeper_wrapper Board_comment_vote
  | Tool_name.Board_name.Board_curation_read -> Keeper_wrapper Board_curation_read
  | Tool_name.Board_name.Board_curation_submit -> Keeper_wrapper Board_curation_submit
  | Tool_name.Board_name.Board_post_get -> Keeper_wrapper Board_post_get
  | Tool_name.Board_name.Board_list -> Keeper_wrapper Board_list
  | Tool_name.Board_name.Board_post -> Keeper_wrapper Board_post
  | Tool_name.Board_name.Board_search -> Keeper_wrapper Board_search
  | Tool_name.Board_name.Board_stats -> Keeper_wrapper Board_stats
  | Tool_name.Board_name.Board_sub_board_create -> Keeper_wrapper Board_sub_board_create
  | Tool_name.Board_name.Board_sub_board_delete -> Keeper_wrapper Board_sub_board_delete
  | Tool_name.Board_name.Board_sub_board_get -> Keeper_wrapper Board_sub_board_get
  | Tool_name.Board_name.Board_sub_board_list -> Keeper_wrapper Board_sub_board_list
  | Tool_name.Board_name.Board_sub_board_update -> Keeper_wrapper Board_sub_board_update
  | Tool_name.Board_name.Board_vote -> Keeper_wrapper Board_vote
  | Tool_name.Board_name.Board_hearths
  | Tool_name.Board_name.Board_post_update
  | Tool_name.Board_name.Board_profile
  | Tool_name.Board_name.Board_reaction
  | Tool_name.Board_name.Board_cleanup
  | Tool_name.Board_name.Board_delete -> Direct_masc
;;

let masc_board_name_of_keeper_tool keeper_tool =
  Tool_name.Board_name.all
  |> List.find_map (fun board_name ->
    match board_projection_of_masc_board_name board_name with
    | Keeper_wrapper projected when projected = keeper_tool -> Some board_name
    | Keeper_wrapper _ | Direct_masc -> None)
;;

let masc_board_name_of_keeper_name name =
  match of_string name with
  | Some tool -> masc_board_name_of_keeper_tool tool
  | None -> None
;;
