module Observation = Agent_core.Base.Schema_observation

module Descriptors = Ephemeron.K1.Make (struct
  type t = Keeper_tool_descriptor.t
  let equal left right = left == right
  (* The immutable id selects a bucket; equality remains physical identity. *)
  let hash descriptor = Hashtbl.hash descriptor.Keeper_tool_descriptor.id
end)

module Owners = Ephemeron.K1.Make (struct
  type t = Lane_addon_tool_export.owner
  let equal = Lane_addon_tool_export.equal_owner
  let hash _ = 0
end)

let descriptors = Descriptors.create 128
let owners = Owners.create 16
let mutex = Mutex.create ()

let locked operation =
  Mutex.lock mutex;
  Fun.protect operation ~finally:(fun () -> Mutex.unlock mutex)

let descriptor_id descriptor =
  match locked (fun () -> Descriptors.find_opt descriptors descriptor) with
  | Some id -> Some id
  | None ->
    (* The SDK allocates identities outside this adapter's mutex. Recheck the
       winner before publication; no observer operation runs under this lock. *)
    match Observation.fresh_object_id () with
    | None -> None
    | Some fresh ->
      Some (locked (fun () ->
        match Descriptors.find_opt descriptors descriptor with
        | Some existing -> existing
        | None -> Descriptors.add descriptors descriptor fresh; fresh))

let owner_id owner =
  match locked (fun () -> Owners.find_opt owners owner) with
  | Some id -> Some id
  | None ->
    match Observation.fresh_object_id () with
    | None -> None
    | Some fresh ->
      Some (locked (fun () ->
        match Owners.find_opt owners owner with
        | Some existing -> existing
        | None -> Owners.add owners owner fresh; fresh))

let with_definition descriptor operation =
  let definition = Observation.observer_work (fun () ->
    Option.map (fun descriptor_id ->
      let addon_owner_id = match descriptor.Keeper_tool_descriptor.runtime_handler with
        | Tool_lane_addon export -> owner_id export.Lane_addon_tool_export.owner
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
        | Tool_analyze_image | Tool_read_image -> None in
      descriptor_id, addon_owner_id) (descriptor_id descriptor))
  in
  match definition with
  | None -> operation ()
  | Some (descriptor_id, addon_owner_id) ->
    Observation.with_definition ~descriptor_id ~addon_owner_id operation
