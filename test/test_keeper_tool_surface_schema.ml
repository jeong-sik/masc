(** Model-visible callable tools and provider schema validity. *)

open Alcotest

let all_surface_golden_names =
  [ "BrowserAct"
  ; "BrowserGoto"
  ; "BrowserInstruct"
  ; "BrowserInteract"
  ; "BrowserRead"
  ; "BrowserSession"
  ; "BrowserTabs"
  ; "Edit"
  ; "Execute"
  ; "Grep"
  ; "Read"
  ; "WebFetch"
  ; "WebSearch"
  ; "Write"
  
  ; "keeper_analyze_image"
  ; "keeper_artifact_read"
  ; "keeper_artifact_transfer"
  ; "keeper_broadcast"
  ; "keeper_code_query"
  ; "keeper_context_status"
  ; "keeper_ide_annotate"
  ; "keeper_lane_status"
  ; "keeper_library_read"
  ; "keeper_portrait_read"
  ; "keeper_library_search"
  ; "keeper_workspace_memory_read"
  ; "keeper_memory_search"
  ; "keeper_memory_retract"
  ; "keeper_memory_write"
  ; "keeper_constitution_write"
  ; "keeper_constitution_remove"
  ; "keeper_constitution_read"
  ; "keeper_person_note_set"
  
  ; "keeper_skill_validate"
  
  ; "keeper_skill_publish"
  ; "keeper_spawn"
  ; "keeper_spawn_read"
  ; "keeper_spawn_stop"
  ; "keeper_spawn_wait"
  ; "keeper_surface_post"
  ; "keeper_surface_read"
  ; "keeper_task_cancel"
  ; "keeper_task_claim"
  ; "keeper_task_create"
  ; "keeper_task_done"
  
  ; "keeper_task_release"
  ; "keeper_tasks_audit"
  ; "keeper_tasks_list"
  ; "keeper_tools_list"
  ; "keeper_capability_search"
  ; "keeper_voice_agent"
  ; "keeper_voice_listen"
  ; "keeper_voice_session_end"
  ; "keeper_voice_session_start"
  ; "keeper_voice_sessions"
  ; "keeper_voice_speak"
    
  ; "keeper_webmcp_call"
  ; "keeper_webmcp_list"
  ; "masc_agent_fitness"
    
  ; "masc_ask"
  ; "masc_ask_status"
  ; "masc_ask_withdraw"
  ; "masc_board_cleanup"
  ; "masc_board_close"
  ; "masc_board_comment"
  ; "masc_board_comment_vote"
  ; "masc_board_curation_read"
  ; "masc_board_curation_submit"
  ; "masc_board_delete"
  ; "masc_board_hearths"
  ; "masc_board_list"
  ; "masc_board_post"
  ; "masc_board_post_get"
  ; "masc_board_post_update"
  ; "masc_board_profile"
  ; "masc_board_reaction"
  ; "masc_board_reopen"
  ; "masc_board_search"
  ; "masc_board_stats"
  ; "masc_board_vote"
  ; "masc_config"
  ; "masc_dashboard"
  ; "masc_file_delete"
  ; "masc_file_list"
  ; "masc_file_upload"
  ; "masc_fusion"
  
  ; "masc_fusion_decision"
  ; "masc_fusion_status"
  ; "masc_gc"
  ; "masc_get_metrics"
  ; "masc_goal_list"
  ; "masc_goal_measure"
  ; "masc_goal_transition"
  ; "masc_goal_upsert"
  ; "masc_keeper_delegate"
  ; "masc_keeper_delegate_cancel"
  ; "masc_keeper_delegate_status"
  ; "masc_library_add"
  ; "masc_library_list"
  ; "masc_dos_click"
  ; "masc_dos_eject"
  ; "masc_dos_load"
  ; "masc_dos_pass"
  ; "masc_dos_peek"
  ; "masc_dos_press"
  ; "masc_dos_restore"
  ; "masc_dos_save"
  ; "masc_dos_screen"
  ; "masc_dos_step"
  ; "masc_dos_type"
  ; "masc_lane_attach"
  ; "masc_lane_declaration_read"
  ; "masc_lane_declaration_save"
  ; "masc_lane_act"
  ; "masc_lane_action_status"
  ; "masc_lane_detach"
  ; "masc_lane_evidence"
  ; "masc_lane_inspect"
  ; "masc_lane_observe"
  ; "masc_lane_slice"
  
  ; "masc_lane_updates"
  ; "masc_msx_change_disk"
  ; "masc_msx_eject"
  ; "masc_msx_load"
  ; "masc_msx_peek"
  ; "masc_msx_press"
  ; "masc_msx_ram_diff"
  ; "masc_msx_restore"
  ; "masc_msx_save"
  ; "masc_msx_screen"
  ; "masc_msx_step"
  
  ; "masc_msx_step_until_change"
  ; "masc_plan_clear_task"
  ; "masc_plan_get_task"
  ; "masc_run_get"
  ; "masc_run_init"
  ; "masc_run_list"
  ; "masc_run_plan"
  ; "masc_schedule_cancel"
  ; "masc_schedule_note_add"
  ; "masc_schedule_notes_list"
  ; "masc_schedule_create"
  ; "masc_schedule_get"
  ; "masc_schedule_list"
  ; "masc_schedule_update"
  ; "masc_task_history"
  ; "masc_task_set_goal"
  ]
;;

let test_all_surface_is_unchanged () =
  let schemas = Masc.Keeper_tool_descriptor.model_visible_schemas () in
  let names = List.sort String.compare (List.map (fun (s : Masc_domain.tool_schema) -> s.name) schemas) in
  let missing = List.filter (fun n -> not (List.mem n names)) all_surface_golden_names in
  let added = List.filter (fun n -> not (List.mem n all_surface_golden_names)) names in
  (match missing, added with
   | [], [] -> ()
   | _ ->
     failf
       "the default (All) tool surface changed.\n\
        gone: %s\n\
        new:  %s\n\
        A Keeper with no [keeper.tools] declaration gets this list. Update \
        all_surface_golden_names in this file with the PR that moves it and say \
        what the move bought."
       (if missing = [] then "(none)" else String.concat ", " missing)
       (if added = [] then "(none)" else String.concat ", " added));
  check int "All surface tool count unchanged"
    (List.length all_surface_golden_names)
    (List.length names)
;;


(* Gemini refuses a whole request when any tool declares an array without
   [items]: #39061's two bare arrays failed every Antigravity turn once #38588
   declared every Antigravity tool eagerly. Tool_definition_toml refuses that
   shape at load; this walks the whole model-visible surface, including the
   schemas built in OCaml, which the loader never sees. *)
let arrays_without_items schema =
  let rec walk path acc = function
    | `Assoc fields ->
      let is_array =
        match List.assoc_opt "type" fields with
        | Some (`String "array") -> true
        | Some (`List types) -> List.mem (`String "array") types
        | Some _ | None -> false
      in
      let acc =
        if is_array && not (List.mem_assoc "items" fields)
        then String.concat "." (List.rev path) :: acc
        else acc
      in
      List.fold_left (fun acc (key, value) -> walk (key :: path) acc value) acc fields
    | `List values -> List.fold_left (walk path) acc values
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ -> acc
  in
  List.rev (walk [] [] schema)
;;

let test_every_model_visible_array_declares_items () =
  check (list string) "the walker names a bare array"
    [ "properties.rows.items.properties.tags" ]
    (arrays_without_items
       (`Assoc
         [ "type", `String "object"
         ; ( "properties"
           , `Assoc
               [ ( "rows"
                 , `Assoc
                     [ "type", `String "array"
                     ; ( "items"
                       , `Assoc
                           [ "type", `String "object"
                           ; ( "properties"
                             , `Assoc [ "tags", `Assoc [ "type", `String "array" ] ] )
                           ] )
                     ] )
               ] )
         ]));
  let offenders =
    List.concat_map
      (fun (schema : Masc_domain.tool_schema) ->
         List.map (fun path -> schema.name ^ ": " ^ path)
           (arrays_without_items schema.input_schema))
      (Masc.Keeper_tool_descriptor.model_visible_schemas ())
  in
  check (list string) "model-visible arrays without items" [] offenders
;;

let () =
  run
    "keeper_tool_surface_schema"
    [ ( "provider schema validity"
      , [ test_case "every array declares items" `Quick
            test_every_model_visible_array_declares_items
        ] )
    ; ( "surface golden"
      , [ test_case "the surface is unchanged" `Quick
            test_all_surface_is_unchanged
        ] )
    ]
;;
