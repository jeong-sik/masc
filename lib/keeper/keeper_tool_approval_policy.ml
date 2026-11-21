module Descriptor = Keeper_tool_descriptor

type verdict =
  | Ask of { because : string }
  | Run

let unclassifiable_because = "no descriptor declares what this tool does"

type undescribed =
  | Control
  | Attached_service
  | Unknown

let descriptor_for tool_name =
  match Descriptor.descriptors_for_internal tool_name with
  | descriptor :: _ -> Some descriptor
  | [] -> Descriptor.find_public tool_name
;;

let producer_authorizes descriptor =
  match descriptor.Descriptor.runtime_handler with
  | Descriptor.Tool_execute
  | Descriptor.Tool_write_file
  | Descriptor.Tool_edit_file
  | Descriptor.Tool_web_search
  | Descriptor.Tool_web_fetch -> true
  | Descriptor.Tool_search_files
  | Descriptor.Tool_read_file
  | Descriptor.Tool_lane_status
  | Descriptor.Tool_tools_list
  | Descriptor.Tool_capability_search
  | Descriptor.Tool_context_status
  | Descriptor.Tool_peer_artifact
  | Descriptor.Tool_artifact_read
  | Descriptor.Tool_skill_validate
  | Descriptor.Tool_artifact_draft
  | Descriptor.Tool_artifact_publish
  | Descriptor.Tool_skill_publish
  | Descriptor.Tool_workspace_memory_read
  | Descriptor.Tool_memory_search
  | Descriptor.Tool_memory_select
  | Descriptor.Tool_memory_retract
  | Descriptor.Tool_memory_write
  | Descriptor.Tool_constitution_write
  | Descriptor.Tool_constitution_read
  | Descriptor.Tool_constitution_remove
  | Descriptor.Tool_wiki_search
  | Descriptor.Tool_wiki_read
  | Descriptor.Tool_surface_read
  | Descriptor.Tool_surface_post
  | Descriptor.Tool_ide_annotate
  | Descriptor.Tool_voice_dispatch
  | Descriptor.Tool_task_dispatch
  | Descriptor.Tool_board_dispatch
  | Descriptor.Tool_masc_task_dispatch
  | Descriptor.Tool_masc_plan_dispatch
  | Descriptor.Tool_masc_run_dispatch
  | Descriptor.Tool_masc_agent_dispatch
  | Descriptor.Tool_masc_workspace_dispatch
  | Descriptor.Tool_masc_misc_dispatch
  | Descriptor.Tool_browser_tabs
  | Descriptor.Tool_browser_read
  | Descriptor.Tool_browser_session
  | Descriptor.Tool_browser_goto
  | Descriptor.Tool_browser_act
  | Descriptor.Tool_browser_interact
  | Descriptor.Tool_masc_agent_timeline_dispatch
  | Descriptor.Tool_masc_schedule_dispatch
  | Descriptor.Tool_keeper_composition_result_dispatch
  | Descriptor.Tool_keeper_code_query_dispatch
  | Descriptor.Tool_receipt_wait
  | Descriptor.Tool_keeper_job_dispatch
  | Descriptor.Tool_masc_keeper_dispatch
  | Descriptor.Tool_masc_fusion_dispatch
  | Descriptor.Tool_masc_fusion_status
  | Descriptor.Tool_masc_fusion_decision
  | Descriptor.Tool_masc_file_dispatch
  | Descriptor.Tool_masc_wiki_dispatch
  | Descriptor.Tool_masc_local_runtime_dispatch
  | Descriptor.Tool_analyze_image
  | Descriptor.Tool_read_image
  | Descriptor.Tool_lane_addon _ -> false
;;

let undescribed_kind ~identity_tool_index tool_name =
  if String.equal tool_name Keeper_instruction_skill.skill_tool_name
     || String.equal tool_name Tool_schemas_identity_tool_search.schema.name
  then Control
  else if Keeper_identity_tool_index.mem identity_tool_index ~tool_name
  then Attached_service
  else Unknown
;;

let verdict_for ~identity_tool_index ~tool_name ~input =
  match descriptor_for tool_name with
  | None ->
    (match undescribed_kind ~identity_tool_index tool_name with
     | Control | Attached_service -> Run
     | Unknown -> Ask { because = unclassifiable_because })
  | Some descriptor ->
    if producer_authorizes descriptor
    then Run
    else
      (match Descriptor.readonly_for_input descriptor ~input with
       | Some true -> Run
       | Some false | None ->
         if descriptor.Descriptor.policy.Descriptor.leaves_masc
         then Ask { because = "this call reaches outside masc" }
         else Run)
;;

let classifies ~identity_tool_index ~tool_name =
  match descriptor_for tool_name with
  | Some _ -> true
  | None ->
    (match undescribed_kind ~identity_tool_index tool_name with
     | Control | Attached_service -> true
     | Unknown -> false)
;;

let question_for ~tool_name ~input =
  let subject =
    Keeper_chat_tool_trail.tool_subject
      ~name:tool_name
      ~args:(Yojson.Safe.to_string input)
  in
  match subject with
  | None -> Printf.sprintf "Run %s?" tool_name
  | Some subject -> Printf.sprintf "Run %s on %s?" tool_name subject
;;
