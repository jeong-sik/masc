module Lib = Masc_mcp

open Alcotest

let projection_names (capability : Lib.Capability_registry.capability_def) =
  capability.Lib.Capability_registry.projections
  |> List.map (fun (projection : Lib.Capability_registry.projection) ->
         projection.tool_name)

let test_public_visible_surface_hides_deprecated_aliases () =
  let names =
    Lib.Capability_registry.visible_public_tool_schemas_from
      Lib.Config.raw_all_tool_schemas
    |> List.map (fun (schema : Types.tool_schema) -> schema.name)
  in
  check bool "public contains masc_transition" true
    (List.mem "masc_transition" names)

let test_public_visible_surface_hides_pruned_voice_tools () =
  let names =
    Lib.Capability_registry.visible_public_tool_schemas_from
      Lib.Config.raw_all_tool_schemas
    |> List.map (fun (schema : Types.tool_schema) -> schema.name)
  in
  check bool "public omits masc_voice_agent" false
    (List.mem "masc_voice_agent" names);
  check bool "public omits masc_voice_speak" false
    (List.mem "masc_voice_speak" names);
  check bool "public omits masc_voice_ping_pong" false
    (List.mem "masc_voice_ping_pong" names)

let test_board_post_capability_merges_public_and_keeper_projections () =
  let capability =
    Lib.Capability_registry.all_capabilities_from Lib.Config.raw_all_tool_schemas
    |> List.find (fun (capability : Lib.Capability_registry.capability_def) ->
           String.equal capability.Lib.Capability_registry.capability_id
             "masc_board_post")
  in
  let names = projection_names capability in
  check bool "public projection" true (List.mem "masc_board_post" names);
  check bool "keeper projection" true (List.mem "keeper_board_post" names)

let test_team_session_capability_merges_public_and_local_worker_projections () =
  let capability =
    Lib.Capability_registry.all_capabilities_from Lib.Config.raw_all_tool_schemas
    |> List.find (fun (capability : Lib.Capability_registry.capability_def) ->
           String.equal capability.Lib.Capability_registry.capability_id
             "masc_team_session_step")
  in
  let names = projection_names capability in
  check bool "public canonical projection" true
    (List.mem "masc_team_session_step" names);
  check bool "turn alias removed" false
    (List.mem "masc_team_session_turn" names)

let test_local_worker_projection_exposes_internal_and_auditable_tools () =
  match
    Lib.Capability_registry.local_worker_tool_schemas
      ~names:
        [
          "masc_heartbeat";
          "masc_code_search";
          "masc_run_plan";
        ]
      ()
  with
  | Error err -> failf "expected local worker schemas: %s" err
  | Ok schemas ->
      let names =
        List.map (fun (schema : Types.tool_schema) -> schema.name) schemas
      in
      check bool "heartbeat" true (List.mem "masc_heartbeat" names);
      check bool "masc_code_search" true (List.mem "masc_code_search" names);
      check bool "masc_run_plan" true (List.mem "masc_run_plan" names)

let test_spawned_agent_surface_stays_curated () =
  let names = Lib.Capability_registry.spawned_agent_prefixed_tools in
  check bool "contains masc_status" true
    (List.mem "mcp__masc__masc_status" names);
  check bool "omits team_session_step" false
    (List.mem "mcp__masc__masc_team_session_step" names);
  check bool "omits a2a_delegate" false
    (List.mem "mcp__masc__masc_a2a_delegate" names);
  check bool "omits portal_send" false
    (List.mem "mcp__masc__masc_portal_send" names);
  check bool "omits voice agent" false
    (List.mem "mcp__masc__masc_voice_agent" names);
  check bool "omits voice speak" false
    (List.mem "mcp__masc__masc_voice_speak" names);
  check bool "omits voice ping pong" false
    (List.mem "mcp__masc__masc_voice_ping_pong" names)

let test_privileged_keeper_surface_is_split () =
  check bool "keeper_bash privileged" true
    (List.mem "keeper_bash" Lib.Capability_registry.keeper_privileged_tool_names);
  check bool "keeper_fs_edit privileged" true
    (List.mem "keeper_fs_edit"
       Lib.Capability_registry.keeper_privileged_tool_names);
  check bool "keeper_fs_read standard" true
    (List.mem "keeper_fs_read" Lib.Capability_registry.keeper_safe_tool_names);
  check bool "keeper_board_post not privileged" false
    (List.mem "keeper_board_post"
       Lib.Capability_registry.keeper_privileged_tool_names)

let () =
  Alcotest.run "capability_registry"
    [
      ( "surfaces",
        [
          test_case "public surface hides deprecated aliases" `Quick
            test_public_visible_surface_hides_deprecated_aliases;
          test_case "public surface hides pruned voice tools" `Quick
            test_public_visible_surface_hides_pruned_voice_tools;
          test_case "board capability merges public and keeper projections"
            `Quick
            test_board_post_capability_merges_public_and_keeper_projections;
          test_case "team session capability merges public and local worker projections"
            `Quick
            test_team_session_capability_merges_public_and_local_worker_projections;
          test_case "local worker projection exposes internal and auditable tools"
            `Quick
            test_local_worker_projection_exposes_internal_and_auditable_tools;
          test_case "spawned agent surface stays curated" `Quick
            test_spawned_agent_surface_stays_curated;
          test_case "privileged keeper surface is split" `Quick
            test_privileged_keeper_surface_is_split;
        ] );
    ]
