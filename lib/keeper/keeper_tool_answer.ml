type reader =
  | Whole_output
  | Reads_answer of (string -> Yojson.Safe.t option)

let reader (handler : Keeper_tool_descriptor.runtime_handler) =
  let open Keeper_tool_descriptor in
  match handler with
  | Tool_execute -> Reads_answer Keeper_tool_execute_runtime.answer_of_output
  | Tool_memory_write -> Reads_answer Keeper_tool_memory_runtime.memory_write_answer_of_output
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_lane_status
  | Tool_tools_list
  | Tool_capability_search
  | Tool_context_status
  | Tool_peer_artifact
  | Tool_artifact_read
  | Tool_skill_validate
  | Tool_skill_publish
  | Tool_workspace_memory_read
  | Tool_memory_search
  | Tool_memory_retract
  | Tool_constitution_write
  | Tool_constitution_read
  | Tool_constitution_remove
  | Tool_library_search
  | Tool_library_read
  | Tool_surface_read
  | Tool_surface_post
  | Tool_person_note_set
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Tool_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_workspace_dispatch
  | Tool_masc_misc_dispatch
  | Tool_web_search
  | Tool_web_fetch
  | Tool_browser_tabs
  | Tool_browser_read
  | Tool_browser_session
  | Tool_browser_goto
  | Tool_browser_act
  | Tool_browser_instruct
  | Tool_browser_interact
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_schedule_dispatch
  | Tool_keeper_spawn_dispatch
  | Tool_keeper_code_query_dispatch
  | Tool_keeper_webmcp_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_masc_fusion_decision
  | Tool_masc_file_dispatch
  | Tool_masc_library_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_analyze_image -> Whole_output
;;

type resolution =
  | Keeper_handler of Keeper_tool_descriptor.runtime_handler
  | Outside_keeper_descriptors

let resolve tool_name =
  match Keeper_tool_descriptor_resolution.descriptor_for_tool_name tool_name with
  | Some descriptor -> Keeper_handler descriptor.Keeper_tool_descriptor.runtime_handler
  | None -> Outside_keeper_descriptors
;;

let answer ~tool_name ~output_text =
  match resolve tool_name with
  | Outside_keeper_descriptors -> None
  | Keeper_handler handler ->
    (match reader handler with
     | Whole_output -> None
     | Reads_answer read -> read output_text)
;;
