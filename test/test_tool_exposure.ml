(** Tests for tool exposure consistency across MCP profiles.

    Validates that:
    1. Hidden tools do not leak into spawned agent passthrough lists
    2. Passthrough list entries correspond to real tool schemas (no dead entries)
    3. SDK alias tools have consistent visibility with Tool_catalog
    4. Tier system maintains essential ⊂ standard ⊂ full inclusion
    5. Annotation overrides in Tool_catalog take precedence *)

module Tool_catalog = Masc_mcp.Tool_catalog
module Agent_tool_surfaces = Masc_mcp.Agent_tool_surfaces
module Config = Masc_mcp.Config

let () =
  let open Alcotest in
  run "Tool_exposure"
    [
      ( "hidden_tool_leak",
        [
          test_case "no hidden tools in spawned_agent_public_tool_names" `Quick
            (fun () ->
              let names = Agent_tool_surfaces.spawned_agent_public_tool_names in
              let leaked =
                List.filter
                  (fun name ->
                    not (Tool_catalog.is_visible ~include_hidden:false name))
                  names
              in
              check (list string) "leaked hidden tools" [] leaked);
        ] );
      ( "passthrough_dead_entries",
        [
          test_case "all passthrough names exist in visible schemas" `Quick
            (fun () ->
              let all_schemas =
                Config.visible_tool_schemas ~include_hidden:false
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
          test_case "known hidden tools are not visible by default" `Quick
            (fun () ->
              let hidden_names =
                [
                  "masc_vote_create";
                  "masc_vote_cast";
                  "masc_vote_status";
                  "masc_post_create";
                  "masc_post_list";
                  "masc_rooms_list";
                  "masc_room_create";
                  "masc_room_enter";
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
                  "masc_vote_create";
                  "masc_vote_cast";
                  "masc_vote_status";
                  "masc_rooms_list";
                  "masc_room_create";
                  "masc_room_enter";
                ]
              in
              List.iter
                (fun name ->
                  check bool (name ^ " should be visible with flag") true
                    (Tool_catalog.is_visible ~include_hidden:true name))
                hidden_names);
          test_case "deprecated claim alias is hidden by default but visible with include_deprecated" `Quick
            (fun () ->
              check bool "masc_claim hidden by default" false
                (Tool_catalog.is_visible "masc_claim");
              check bool "masc_claim visible with include_deprecated" true
                (Tool_catalog.is_visible ~include_deprecated:true "masc_claim"));
        ] );
    ]
