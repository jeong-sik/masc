module Types = Masc_domain

module Lib = Masc

open Alcotest

let projection_names (capability : Lib.Capability_registry.capability_def) =
  capability.Lib.Capability_registry.projections
  |> List.map (fun (projection : Lib.Capability_registry.projection) ->
         projection.tool_name)

let test_public_visible_surface_hides_deprecated_aliases () =
  let names =
    Lib.Capability_registry.visible_public_tool_schemas_from
      Lib.Config.raw_all_tool_schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  in
  check bool "public contains masc_transition" true
    (List.mem "masc_transition" names)

let test_public_visible_surface_hides_pruned_voice_tools () =
  let names =
    Lib.Capability_registry.visible_public_tool_schemas_from
      Lib.Config.raw_all_tool_schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
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
           Lib.Tool_capability_id.equal
             capability.Lib.Capability_registry.capability_id
             (Lib.Tool_capability_id.board_operation Tool_name.Board_name.Board_post))
  in
  let names = projection_names capability in
  check bool "public projection" true (List.mem "masc_board_post" names);
  check bool "keeper projection" true (List.mem "keeper_board_post" names)

let capability_for_projection ~surface name =
  Lib.Capability_registry.all_capabilities_from Lib.Config.raw_all_tool_schemas
  |> List.find (fun (capability : Lib.Capability_registry.capability_def) ->
    List.exists
      (fun (projection : Lib.Capability_registry.projection) ->
        projection.surface = surface && String.equal projection.tool_name name)
      capability.projections)
;;

let test_task_and_broadcast_contracts_remain_distinct () =
  let check_distinct raw_name keeper_name =
    let raw =
      capability_for_projection
        ~surface:Lib.Capability_registry.Public_mcp
        raw_name
    in
    let keeper =
      capability_for_projection
        ~surface:Lib.Capability_registry.Keeper_standard
        keeper_name
    in
    check bool
      (raw_name ^ " and " ^ keeper_name ^ " remain distinct")
      false
      (Lib.Tool_capability_id.equal
         raw.capability_id
         keeper.capability_id)
  in
  check_distinct "masc_tasks" "keeper_tasks_list";
  check_distinct "masc_broadcast" "keeper_broadcast"
;;

let test_web_descriptor_capability_follows_backend_route () =
  List.iter
    (fun (keeper_name, internal_name) ->
      let descriptor =
        match Lib.Keeper_tool_descriptor.find_public keeper_name with
        | Some descriptor -> descriptor
        | None -> fail ("missing public descriptor: " ^ keeper_name)
      in
      check bool
        (keeper_name ^ " capability follows its backend route")
        true
        (Lib.Tool_capability_id.equal
           descriptor.capability_id
           (Lib.Tool_capability_id.route internal_name)))
    [ "WebSearch", "masc_web_search"; "WebFetch", "masc_web_fetch" ]
;;

let test_projection_inventory_is_valid () =
  match
    Lib.Capability_registry.all_projection_seeds_from_result
      Lib.Config.raw_all_tool_schemas
  with
  | Ok _ -> ()
  | Error errors ->
    failf
      "invalid capability projection: %s"
      (errors
       |> List.map Lib.Capability_registry.projection_error_to_json
       |> List.map Yojson.Safe.to_string
      |> String.concat "; ")
;;

let test_conflicting_projection_returns_typed_error () =
  let seed capability_id backend_tool_name : Lib.Capability_registry.capability_seed =
    { capability_id
    ; risk_class = Lib.Capability_registry.Safe
    ; audiences = [ Lib.Capability_registry.External_mcp_client ]
    ; supports_audit_evidence = false
    ; supports_direct_user_discovery = true
    ; projection =
        { surface = Lib.Capability_registry.Public_mcp
        ; tool_name = "same_name"
        ; description = "same description"
        ; input_schema = `Assoc [ "type", `String "object" ]
        ; backend_tool_name
        }
    }
  in
  match
    Lib.Capability_registry.validate_projection_seeds
      [ seed (Lib.Tool_capability_id.route "left") "left"
      ; seed (Lib.Tool_capability_id.route "right") "right"
      ]
  with
  | Error [ Lib.Capability_registry.Conflicting_surface_projection _ ] -> ()
  | Error errors ->
    failf
      "unexpected projection errors: %s"
      (errors
       |> List.map Lib.Capability_registry.projection_error_to_json
       |> List.map Yojson.Safe.to_string
       |> String.concat "; ")
  | Ok () -> fail "conflicting projection unexpectedly validated"
;;

let test_external_surface_contains_only_public_catalog_tools () =
  Lib.Capability_registry.surface_tool_names_from
    Lib.Config.raw_all_tool_schemas
    Lib.Capability_registry.Public_mcp
  |> List.iter (fun name ->
    check bool (name ^ " is public MCP") true (Tool_catalog.is_public_mcp name))
;;

let test_managed_surface_prefers_sdk_contract () =
  let schemas =
    Lib.Capability_registry.surface_tool_schemas_from
      Lib.Config.raw_all_tool_schemas
      Lib.Capability_registry.Managed_agent_mcp
  in
  let names = List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) schemas in
  check int
    "managed names are unique"
    (List.length names)
    (List.length (List.sort_uniq String.compare names));
  List.iter
    (fun (binding : Sdk_tool_contract.sdk_tool_binding) ->
      let schema =
        List.find (fun (schema : Masc_domain.tool_schema) ->
          String.equal schema.name binding.sdk_name) schemas
      in
      check bool
        (binding.sdk_name ^ " uses SDK schema")
        true
        (schema.input_schema = binding.input_schema))
    Sdk_tool_contract.sdk_bindings
;;

let test_maintenance_route_is_not_keeper_model_projection () =
  let keeper_names =
    Lib.Capability_registry.surface_tool_names_from
      Lib.Config.raw_all_tool_schemas
      Lib.Capability_registry.Keeper_standard
  in
  let managed_names =
    Lib.Capability_registry.surface_tool_names_from
      Lib.Config.raw_all_tool_schemas
      Lib.Capability_registry.Managed_agent_mcp
  in
  check bool "heartbeat absent from Keeper model" false
    (List.mem "masc_heartbeat" keeper_names);
  check bool "heartbeat remains on Managed SDK surface" true
    (List.mem "masc_heartbeat" managed_names)
;;


let test_local_worker_projection_exposes_internal_and_auditable_tools () =
  match
    Lib.Capability_registry.local_worker_tool_schemas
      ~names:
        [
          "masc_heartbeat";
          "masc_run_plan";
        ]
      ()
  with
  | Error err -> failf "expected local worker schemas: %s" err
  | Ok schemas ->
      let names =
        List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) schemas
      in
      check bool "heartbeat" true (List.mem "masc_heartbeat" names);
      check bool "masc_run_plan" true (List.mem "masc_run_plan" names)

let test_spawned_agent_surface_stays_curated () =
  let names = Lib.Capability_registry.spawned_agent_prefixed_tools in
  check bool "contains masc_status" true
    (List.mem "mcp__masc__masc_status" names);
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
  check bool "tool_execute privileged" true
    (List.mem "tool_execute" Lib.Capability_registry.keeper_privileged_tool_names);
  check bool "tool_edit_file privileged" true
    (List.mem "tool_edit_file"
       Lib.Capability_registry.keeper_privileged_tool_names);
  check bool "tool_read_file standard" true
    (List.mem "tool_read_file" Lib.Capability_registry.keeper_safe_tool_names);
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
          test_case "Task and Broadcast contracts remain distinct"
            `Quick test_task_and_broadcast_contracts_remain_distinct;
          test_case "Web capability follows backend route" `Quick
            test_web_descriptor_capability_follows_backend_route;
          test_case "projection inventory is valid" `Quick
            test_projection_inventory_is_valid;
          test_case "conflicting projection returns typed error" `Quick
            test_conflicting_projection_returns_typed_error;
          test_case "external surface follows public catalog" `Quick
            test_external_surface_contains_only_public_catalog_tools;
          test_case "managed surface prefers SDK contract" `Quick
            test_managed_surface_prefers_sdk_contract;
          test_case "maintenance route is not a Keeper projection" `Quick
            test_maintenance_route_is_not_keeper_model_projection;

          test_case "local worker projection exposes internal and auditable tools"
            `Quick
            test_local_worker_projection_exposes_internal_and_auditable_tools;
          test_case "spawned agent surface stays curated" `Quick
            test_spawned_agent_surface_stays_curated;
          test_case "privileged keeper surface is split" `Quick
            test_privileged_keeper_surface_is_split;
        ] );
    ]
