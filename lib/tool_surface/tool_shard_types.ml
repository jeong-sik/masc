(** Tool_shard_types — single SSOT compiling embedded [config/tools/*.toml]
    declarations into pure Keeper schema families. *)

let schema_of_name = Tool_definition_embedded.schema

(* Always-on base tool schemas every keeper sees. *)
let base_tools : Masc_domain.tool_schema list =
  List.map
    schema_of_name
    [ "keeper_context_status"
    ; "keeper_lane_status"
    ; "keeper_workspace_memory_read"
    ; "keeper_memory_search"
    ; "keeper_memory_select"
    ; "keeper_memory_retract"
    ; "keeper_memory_write"
    ; "keeper_constitution_write"
    ; "keeper_constitution_remove"
    ; "keeper_constitution_read"
    ; "keeper_tools_list"
    ; "keeper_capability_search"
    ]
;;

(* Narrower Keeper-model input projections for Board capabilities, read from
   [keeper_projection] tables in [config/tools/masc_board_*.toml]. *)
let projection_of_board_name board_name : Masc_domain.tool_schema =
  let name = Tool_name.Board_name.to_string board_name in
  match (Tool_definition_embedded.load name).Tool_definition_toml.keeper_projection with
  | Some schema -> schema
  | None ->
    failwith
      (Printf.sprintf
         "%s declares no keeper_projection table"
         (Tool_definition_embedded.path name))
;;

let keeper_board_projections : Masc_domain.tool_schema list =
  List.map
    projection_of_board_name
    Tool_name.Board_name.
      [ Board_post
      ; Board_list
      ; Board_comment
      ; Board_vote
      ; Board_stats
      ; Board_search
      ; Board_curation_read
      ; Board_curation_submit
      ]
;;

let keeper_board_schema board_name =
  let name = Tool_name.Board_name.to_string board_name in
  List.find_opt
    (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
    keeper_board_projections
;;

let filesystem_tools : Masc_domain.tool_schema list =
  List.map
    schema_of_name
    [ "tool_read_file"
    ; "tool_edit_file"
    ; "tool_write_file"
    ; "keeper_ide_annotate"
    ]
;;

let search_files_tools : Masc_domain.tool_schema list =
  [ schema_of_name "tool_search_files" ]
;;

let tool_execute_schema : Masc_domain.tool_schema =
  schema_of_name "tool_execute"
;;

let typed_execute_tools : Masc_domain.tool_schema list =
  [ tool_execute_schema ]
;;

let voice_tools : Masc_domain.tool_schema list =
  List.map
    schema_of_name
    [ "keeper_voice_speak"
    ; "keeper_voice_listen"
    ; "keeper_voice_agent"
    ]
;;

let wiki_tools : Masc_domain.tool_schema list =
  List.map schema_of_name [ "keeper_wiki_search"; "keeper_wiki_read" ]
;;

(* Slack's chat.postMessage caps top-level blocks at 50. This lower tool-surface
   layer owns the wire limit; the Keeper executor consumes the public value. *)
let max_rich_blocks = 50

let surface_tools : Masc_domain.tool_schema list =
  List.map schema_of_name [ "keeper_surface_read"; "keeper_surface_post" ]
;;

let taskboard_tools : Masc_domain.tool_schema list =
  List.map
    schema_of_name
    [ "keeper_tasks_list"
    ; "keeper_tasks_audit"
    ; "keeper_broadcast"
    ; "keeper_task_claim"
    ; "keeper_task_done"
    ; "keeper_task_cancel"
    ; "keeper_task_release"
    ; "keeper_task_create"
    ]
;;
