(* Keeper-owned MCP tool-name vocabulary.

   This lives outside the central [Tool_name] module so the tool dispatch
   substrate stays keeper-agnostic: the substrate routes
   opaque tool names and the keeper subsystem owns the typed vocabulary of its
   own tools. Dependency direction is keeper -> tool, never the reverse.

   The SSOT is on the keeper side of the Tool/Keeper boundary. *)

type t =
  | Execute
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
  | Context_status
  | Fs_edit
  | Fs_write
  | Fs_read
  | Ide_annotate
  | Handoff
  | Library_read
  | Library_search
  | Memory_search
  | Memory_write
  | Keeper_msg
  | Search_files
  | Surface_read
  | Surface_post
  | Person_note_set
  | Task_claim
  | Task_create
  | Task_done
  | Tasks_audit
  | Tasks_list
  | Time_now
  | Tool_search
  | Tools_list
  | Persona_create
  | Persona_update
  | Persona_delete
  | Voice_agent
  | Voice_listen
  | Voice_session_end
  | Voice_session_start
  | Voice_sessions
  | Voice_speak

let all : t list =
  [ Execute
  ; Board_comment
  ; Board_comment_vote
  ; Board_curation_read
  ; Board_curation_submit
  ; Board_post_get
  ; Board_list
  ; Board_post
  ; Board_search
  ; Board_stats
  ; Board_sub_board_create
  ; Board_sub_board_delete
  ; Board_sub_board_get
  ; Board_sub_board_list
  ; Board_sub_board_update
  ; Board_vote
  ; Broadcast
  ; Context_status
  ; Fs_edit
  ; Fs_write
  ; Fs_read
  ; Ide_annotate
  ; Handoff
  ; Library_read
  ; Library_search
  ; Memory_search
  ; Memory_write
  ; Keeper_msg
  ; Search_files
  ; Surface_read
  ; Surface_post
  ; Person_note_set
  ; Task_claim
  ; Task_create
  ; Task_done
  ; Tasks_audit
  ; Tasks_list
  ; Time_now
  ; Tool_search
  ; Tools_list
  ; Persona_create
  ; Persona_update
  ; Persona_delete
  ; Voice_agent
  ; Voice_listen
  ; Voice_session_end
  ; Voice_session_start
  ; Voice_sessions
  ; Voice_speak
  ]
;;

let to_string = function
  | Execute -> "tool_execute"
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
  | Context_status -> "keeper_context_status"
  | Fs_edit -> "tool_edit_file"
  | Fs_write -> "tool_write_file"
  | Fs_read -> "tool_read_file"
  | Ide_annotate -> "keeper_ide_annotate"
  | Handoff -> "keeper_handoff"
  | Library_read -> "keeper_library_read"
  | Library_search -> "keeper_library_search"
  | Memory_search -> "keeper_memory_search"
  | Memory_write -> "keeper_memory_write"
  | Keeper_msg -> "masc_keeper_msg"
  | Search_files -> "tool_search_files"
  | Surface_read -> "keeper_surface_read"
  | Surface_post -> "keeper_surface_post"
  | Person_note_set -> "keeper_person_note_set"
  | Task_claim -> "keeper_task_claim"
  | Task_create -> "keeper_task_create"
  | Task_done -> "keeper_task_done"
  | Tasks_audit -> "keeper_tasks_audit"
  | Tasks_list -> "keeper_tasks_list"
  | Time_now -> "keeper_time_now"
  | Tool_search -> "keeper_tool_search"
  | Tools_list -> "keeper_tools_list"
  | Persona_create -> "masc_persona_create"
  | Persona_update -> "masc_persona_update"
  | Persona_delete -> "masc_persona_delete"
  | Voice_agent -> "keeper_voice_agent"
  | Voice_listen -> "keeper_voice_listen"
  | Voice_session_end -> "keeper_voice_session_end"
  | Voice_session_start -> "keeper_voice_session_start"
  | Voice_sessions -> "keeper_voice_sessions"
  | Voice_speak -> "keeper_voice_speak"
;;

let of_string = function
  | "tool_execute" -> Some Execute
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
  | "keeper_context_status" -> Some Context_status
  | "tool_edit_file" -> Some Fs_edit
  | "tool_write_file" -> Some Fs_write
  | "tool_read_file" -> Some Fs_read
  | "keeper_ide_annotate" -> Some Ide_annotate
  | "keeper_handoff" -> Some Handoff
  | "keeper_library_read" -> Some Library_read
  | "keeper_library_search" -> Some Library_search
  | "keeper_memory_search" -> Some Memory_search
  | "keeper_memory_write" -> Some Memory_write
  | "masc_keeper_msg" -> Some Keeper_msg
  | "tool_search_files" -> Some Search_files
  | "keeper_surface_read" -> Some Surface_read
  | "keeper_surface_post" -> Some Surface_post
  | "keeper_person_note_set" -> Some Person_note_set
  | "keeper_task_claim" -> Some Task_claim
  | "keeper_task_create" -> Some Task_create
  | "keeper_task_done" -> Some Task_done
  | "keeper_tasks_audit" -> Some Tasks_audit
  | "keeper_tasks_list" -> Some Tasks_list
  | "keeper_time_now" -> Some Time_now
  | "keeper_tool_search" -> Some Tool_search
  | "keeper_tools_list" -> Some Tools_list
  | "keeper_voice_agent" -> Some Voice_agent
  | "keeper_voice_listen" -> Some Voice_listen
  | "keeper_voice_session_end" -> Some Voice_session_end
  | "keeper_voice_session_start" -> Some Voice_session_start
  | "keeper_voice_sessions" -> Some Voice_sessions
  | "keeper_voice_speak" -> Some Voice_speak
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
  | External_only

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
  | Tool_name.Board_name.Board_reaction -> Direct_masc
  | Tool_name.Board_name.Board_cleanup
  | Tool_name.Board_name.Board_delete -> External_only
;;

let masc_board_name_of_keeper_tool keeper_tool =
  Tool_name.Board_name.all
  |> List.find_map (fun board_name ->
    match board_projection_of_masc_board_name board_name with
    | Keeper_wrapper projected when projected = keeper_tool -> Some board_name
    | Keeper_wrapper _ | Direct_masc | External_only -> None)
;;

let is_keeper_board_tool tool =
  Option.is_some (masc_board_name_of_keeper_tool tool)
;;

let masc_board_name_of_keeper_name name =
  match of_string name with
  | Some tool -> masc_board_name_of_keeper_tool tool
  | None -> None
;;

let is_board_surface_name name =
  match of_string name with
  | Some tool -> is_keeper_board_tool tool
  | None -> Option.is_some (Tool_name.Board_name.of_string name)
;;

let strip_mcp_masc_prefix name =
  if String.starts_with ~prefix:"mcp__masc__" name
  then String.sub name 11 (String.length name - 11)
  else name
;;

let is_board_write_name = Tool_name.Board_name.is_resource_write

let is_board_write_surface_name name =
  let name = strip_mcp_masc_prefix name in
  match masc_board_name_of_keeper_name name with
  | Some board_name -> is_board_write_name board_name
  | None ->
    (match Tool_name.Board_name.of_string name with
     | Some board_name -> is_board_write_name board_name
     | None -> false)
;;
