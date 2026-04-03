(** Tests for tool exposure consistency across MCP profiles.

    Validates that:
    1. Hidden tools do not leak into spawned agent passthrough lists
    2. Passthrough list entries correspond to real tool schemas (no dead entries)
    3. SDK alias tools have consistent visibility with Tool_catalog
    4. Tier system maintains essential ⊂ standard ⊂ full inclusion
    5. Annotation overrides in Tool_catalog take precedence
    6. Public MCP surface is a valid subset of the full registry
    7. Non-public tools remain callable via dispatch *)

module Tool_catalog = Masc_mcp.Tool_catalog
module Agent_tool_surfaces = Masc_mcp.Agent_tool_surfaces
module Config = Masc_mcp.Config

let () =
  let open Alcotest in
  run "Tool_exposure"
    [
      ( "hidden_tool_leak",
        [
          test_case "no explicitly-hidden tools in spawned_agent_public_tool_names" `Quick
            (fun () ->
              (* Only check tools with explicit Hidden metadata (not auto-classified).
                 Auto-Hidden tools are just "not on public MCP surface" and may
                 legitimately appear in other profiles like Managed_agent. *)
              let explicit_hidden =
                List.filter_map (fun (name, (meta : Tool_catalog.metadata)) ->
                  match meta.visibility with
                  | Tool_catalog.Hidden -> Some name
                  | Tool_catalog.Default -> None)
                Tool_catalog.explicit_metadata
              in
              let names = Agent_tool_surfaces.spawned_agent_public_tool_names in
              let leaked =
                List.filter (fun name -> List.mem name explicit_hidden) names
              in
              check (list string) "leaked explicitly-hidden tools" [] leaked);
        ] );
      ( "passthrough_dead_entries",
        [
          test_case "all passthrough names exist in visible schemas" `Quick
            (fun () ->
              let all_schemas =
                Config.visible_tool_schemas ~include_hidden:true
                  ~include_deprecated:false ()
              in
              let schema_names =
                List.map
                  (fun (s : Types.tool_schema) -> s.name)
                  all_schemas
              in
              let names =
                Agent_tool_surfaces.spawned_agent_public_tool_names
              in
              let dead =
                List.filter
                  (fun name -> not (List.mem name schema_names))
                  names
              in
              (* Dead entries indicate tools that were removed from schemas
                 but left in the static list. Not a hard failure since the
                 passthrough filter naturally drops them, but worth tracking. *)
              if dead <> [] then
                Alcotest.failf
                  "dead passthrough entries (no matching schema): %s"
                  (String.concat ", " dead));
          test_case "agent passthrough omits operator and diagnostics" `Quick
            (fun () ->
              let names = Agent_tool_surfaces.spawned_agent_public_tool_names in
              let banned =
                [
                  "masc_tool_stats";
                  "masc_tool_admin_snapshot";
                  "masc_keeper_tool_catalog";
                  "masc_operator_snapshot";
                  "masc_operator_action";
                  "masc_operator_confirm";
                  "masc_team_session_prove";
                  "masc_heartbeat_list";
                ]
              in
              List.iter
                (fun name ->
                  check bool (name ^ " omitted from public agent surface") false
                    (List.mem name names))
                banned);
        ] );
      ( "tier_inclusion",
        [
          test_case "essential ⊂ standard" `Quick (fun () ->
              let essentials =
                List.filter
                  (fun name ->
                    Tool_catalog.is_in_tier Tool_catalog.Essential name)
                  Tool_catalog.essential_tools
              in
              List.iter
                (fun name ->
                  check bool
                    (name ^ " essential should be in standard")
                    true
                    (Tool_catalog.is_in_tier Tool_catalog.Standard name))
                essentials);
          test_case "standard ⊂ full" `Quick (fun () ->
              let standards =
                List.filter
                  (fun name ->
                    Tool_catalog.is_in_tier Tool_catalog.Standard name)
                  Tool_catalog.standard_tools
              in
              List.iter
                (fun name ->
                  check bool
                    (name ^ " standard should be in full")
                    true
                    (Tool_catalog.is_in_tier Tool_catalog.Full name))
                standards);
        ] );
      ( "annotation_overrides",
        [
          test_case "masc_run_get has readonly override" `Quick (fun () ->
              let meta = Tool_catalog.metadata "masc_run_get" in
              check (option bool) "readonly" (Some true) meta.readonly;
              check (option bool) "idempotent" (Some true) meta.idempotent);
          test_case "masc_operation_stop has destructive override" `Quick
            (fun () ->
              let meta = Tool_catalog.metadata "masc_operation_stop" in
              check (option bool) "destructive" (Some true) meta.destructive);
          test_case "masc_operation_pause is not destructive" `Quick
            (fun () ->
              let meta = Tool_catalog.metadata "masc_operation_pause" in
              check (option bool) "destructive" (Some false) meta.destructive);
          test_case "default tools have None annotations" `Quick (fun () ->
              let meta = Tool_catalog.metadata "masc_join" in
              check (option bool) "readonly" None meta.readonly;
              check (option bool) "destructive" None meta.destructive;
              check (option bool) "idempotent" None meta.idempotent);
        ] );
      ( "hidden_tools_contract",
        [
          test_case "keeper internal tools are hidden and not directly callable" `Quick
            (fun () ->
              List.iter
                (fun name ->
                  let meta = Tool_catalog.metadata name in
                  check bool (name ^ " hidden") false
                    (Tool_catalog.is_visible name);
                  check bool (name ^ " direct call blocked") false
                    (Tool_catalog.allow_direct_call name);
                  check bool (name ^ " on keeper_internal surface") true
                    (Tool_catalog.is_on_surface Tool_catalog.Keeper_internal name);
                  check bool (name ^ " reason present") true
                    (Option.is_some meta.reason))
                [ "keeper_time_now"; "keeper_board_post"; "keeper_bash" ]);
          test_case "known hidden tools are not visible by default" `Quick
            (fun () ->
              let hidden_names =
                [
                  "masc_operator_judgment_write";
                  "masc_set_room";
                ]
              in
              List.iter
                (fun name ->
                  check bool (name ^ " should be hidden") false
                    (Tool_catalog.is_visible name))
                hidden_names);
          test_case "hidden tools are visible with include_hidden" `Quick
            (fun () ->
              let hidden_names =
                [
                  "masc_operator_judgment_write";
                  "masc_set_room";
                ]
              in
              List.iter
                (fun name ->
                  check bool (name ^ " should be visible with flag") true
                    (Tool_catalog.is_visible ~include_hidden:true name))
                hidden_names);
          test_case "masc_set_room stays callable as a hidden compatibility alias" `Quick
            (fun () ->
              let meta = Tool_catalog.metadata "masc_set_room" in
              check bool "masc_set_room hidden" false
                (Tool_catalog.is_visible "masc_set_room");
              check bool "masc_set_room direct call allowed" true
                (Tool_catalog.allow_direct_call "masc_set_room");
              check bool "masc_set_room on system_internal surface" true
                (Tool_catalog.is_on_surface Tool_catalog.System_internal
                   "masc_set_room");
              check (option string) "masc_set_room replacement" (Some "masc_start")
                meta.replacement);
          test_case "legacy mitosis tools are removed from the public registry" `Quick
            (fun () ->
              let removed_names =
                [
                  "masc_mitosis_status";
                  "masc_mitosis_divide";
                  "masc_mitosis_check";
                  "masc_mitosis_prepare";
                  "masc_mitosis_handoff";
                ]
              in
              let all_names = Config.all_tool_names () in
              List.iter
                (fun name ->
                  check bool (name ^ " removed from registry")
                    false
                    (List.mem name all_names))
                removed_names);
          test_case "removed named-room tools are absent from the schema registry" `Quick
            (fun () ->
              let all_names = Config.all_tool_names () in
              List.iter
                (fun name ->
                  check bool (name ^ " removed from registry") false
                    (List.mem name all_names))
                [ "masc_rooms_list"; "masc_room_create"; "masc_room_enter" ]);
        ] );
      ( "public_mcp_surface",
        [
          test_case "all public_mcp_tools exist in schema registry" `Quick
            (fun () ->
              let all_names = Config.all_tool_names () in
              let missing =
                List.filter
                  (fun name -> not (List.mem name all_names))
                  Tool_catalog.public_mcp_tools
              in
              check (list string) "missing from registry" [] missing);
          test_case "public surface count is between 30 and 50" `Quick
            (fun () ->
              let count = List.length Tool_catalog.public_mcp_tools in
              check bool "count is within expected range"
                true (count >= 30 && count <= 50));
          test_case "is_public_mcp returns true for listed tools" `Quick
            (fun () ->
              List.iter
                (fun name ->
                  check bool (name ^ " is public") true
                    (Tool_catalog.is_public_mcp name))
                Tool_catalog.public_mcp_tools);
          test_case "internal tools are not public" `Quick
            (fun () ->
              let internal =
                [ "masc_code_search";
                  "masc_team_session_step"; "masc_auth_create_token";
                  "masc_worktree_create"; "masc_governance_set" ]
              in
              List.iter
                (fun name ->
                  check bool (name ^ " not public") false
                    (Tool_catalog.is_public_mcp name))
                internal);
          test_case "non-public tool remains in full registry" `Quick
            (fun () ->
              let all_names =
                Config.raw_all_tool_schemas
                |> List.map (fun (s : Types.tool_schema) -> s.name)
              in
              (* masc_team_session_step has a schema but is not public *)
              let internal = "masc_team_session_step" in
              check bool (internal ^ " in registry") true
                (List.mem internal all_names);
              check bool (internal ^ " not public") false
                (Tool_catalog.is_public_mcp internal));
        ] );
    ]
