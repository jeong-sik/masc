module Schemas = Ephemeron.K1.Make (struct
  type t = Keeper_tool_descriptor.t

  let equal left right = left == right
  let hash descriptor = Hashtbl.hash descriptor.Keeper_tool_descriptor.id
end)

let schemas : Agent_core.Types.tool_schema Schemas.t = Schemas.create 0
let mutex = Stdlib.Mutex.create ()

let memoizes descriptor =
  let open Keeper_tool_descriptor in
  match descriptor.runtime_handler with
  | Tool_lane_addon _ -> false
  | Tool_execute | Tool_search_files | Tool_read_file | Tool_edit_file
  | Tool_write_file | Tool_lane_status | Tool_tools_list | Tool_capability_search
  | Tool_context_status | Tool_peer_artifact | Tool_artifact_read | Tool_skill_validate
  | Tool_artifact_draft | Tool_artifact_publish | Tool_skill_publish
  | Tool_workspace_memory_read
  | Tool_memory_search | Tool_memory_select | Tool_memory_retract | Tool_memory_write
  | Tool_constitution_write | Tool_constitution_read | Tool_constitution_remove
  | Tool_wiki_search | Tool_wiki_read | Tool_surface_read | Tool_surface_post
  | Tool_person_note_set | Tool_ide_annotate | Tool_voice_dispatch | Tool_task_dispatch
  | Tool_board_dispatch | Tool_masc_task_dispatch | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch | Tool_masc_agent_dispatch | Tool_masc_workspace_dispatch
  | Tool_masc_misc_dispatch | Tool_web_search | Tool_web_fetch | Tool_browser_tabs
  | Tool_browser_read | Tool_browser_session | Tool_browser_goto | Tool_browser_act
  | Tool_browser_instruct | Tool_browser_interact | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch | Tool_masc_schedule_dispatch
  | Tool_keeper_spawn_dispatch | Tool_keeper_job_dispatch
  | Tool_keeper_composition_result_dispatch | Tool_keeper_code_query_dispatch
  | Tool_keeper_webmcp_dispatch | Tool_masc_keeper_dispatch | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status | Tool_masc_fusion_decision | Tool_masc_file_dispatch
  | Tool_masc_wiki_dispatch | Tool_masc_local_runtime_dispatch
  | Tool_analyze_image | Tool_read_image -> true

let construct descriptor =
  match Keeper_tool_descriptor.keeper_model_names descriptor with
  | [name] ->
    Agent_core.Base.Schema_observation.constructor
      ~site:Bridge_execution_env_constructor
      (fun () ->
        Agent_core.Types.tool_schema_of_input_schema
          ~name
          ~description:descriptor.Keeper_tool_descriptor.description
          ~input_schema:descriptor.input_schema
          ())
  | [] -> Error "Keeper descriptor has no model-visible schema"
  | _ :: _ :: _ -> Error "Keeper descriptor has more than one model-visible name"

let for_descriptor descriptor =
  if not (memoizes descriptor) then construct descriptor
  else
    match Stdlib.Mutex.protect mutex (fun () -> Schemas.find_opt schemas descriptor) with
    | Some schema -> Ok schema
    | None ->
      (* Validation and diagnostic callbacks never run under the cache lock.
         The descriptor remains live through the locked publication recheck. *)
      match construct descriptor with
      | Error _ as error -> error
      | Ok candidate ->
        Ok (Stdlib.Mutex.protect mutex (fun () ->
          match Schemas.find_opt schemas descriptor with
          | Some winner -> winner
          | None -> Schemas.add schemas descriptor candidate; candidate))
