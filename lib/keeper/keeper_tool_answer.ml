type reader =
  | Whole_output
  | Reads_answer of (string -> Yojson.Safe.t option)

let reader (handler : Keeper_tool_descriptor.runtime_handler) =
  let open Keeper_tool_descriptor in
  match handler with
  | Tool_execute -> Reads_answer Keeper_tool_execute_runtime.answer_of_output
  | Tool_memory_write -> Reads_answer Keeper_tool_memory_runtime.memory_write_answer_of_output
  | Tool_memory_select -> Reads_answer Keeper_memory_select.answer_of_output
  | Tool_lane_addon _
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

(* Only the bridge's closed manifest envelope may expose an original answer.
   Child artifact addresses remain answer data; never follow them recursively. *)
let stored_answer_content ~mime original =
  if not (String.equal mime Tool_output.artifact_manifest_mime) then Some original
  else
    match Yojson.Safe.from_string original with
    | json ->
      (match Tool_output.artifact_manifest_of_json json with
       | Tool_output.Decoded_artifact_manifest {content; structured_content; artifact_refs = _ :: _} ->
         (match Yojson.Safe.from_string content with
          | data when Yojson.Safe.sort data = Yojson.Safe.sort structured_content -> Some content
          | _ -> None
          | exception Yojson.Json_error _ -> None)
       | Tool_output.Decoded_artifact_manifest _
       | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ -> None)
    | exception Yojson.Json_error _ -> None
;;

let verified_stored_answer ~base_path ~tool_name ~output_text =
  let declared_reader = match resolve tool_name with
    | Outside_keeper_descriptors -> None
    | Keeper_handler handler ->
      (match reader handler with Whole_output -> None | Reads_answer read -> Some read) in
  match declared_reader with
  | None -> None
  | Some read -> Domain_pool_ref.submit_io_or_inline (fun () ->
  match Tool_output.decode_from_agent_core output_text with
  | Tool_output.Decoded {sha256; bytes; mime; answer_fingerprint = Some declared; _} ->
    (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256 with
     | Ok (Some original) when String.length original = bytes ->
       (match Option.bind (stored_answer_content ~mime original) read with
        | Some value ->
          let actual = Digestif.SHA256.(digest_string
              (value |> Yojson.Safe.sort |> Yojson.Safe.to_string) |> to_hex) in
          if String.equal actual declared then Some value else None
        | None -> None)
     | Ok _ | Error _ -> None)
  | Tool_output.Decoded _ | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> None)
;;
