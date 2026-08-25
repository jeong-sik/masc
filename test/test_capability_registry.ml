module Types = Masc_domain

module Lib = Masc

open Alcotest

let test_public_visible_surface_exposes_masc_transition () =
  let names =
    Lib.Capability_registry.visible_tool_schemas_from
      Lib.Config.raw_all_tool_schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  in
  check bool "public contains masc_transition" true
    (List.mem "masc_transition" names)


let test_board_post_capability_merges_public_and_keeper_projections () =
  let capability =
    Lib.Capability_registry.all_capabilities_from Lib.Config.raw_all_tool_schemas
    |> List.find (fun (capability : Lib.Capability_registry.capability_def) ->
           String.equal capability.Lib.Capability_registry.capability_id
             "masc_board_post")
  in
  let projections_for surface =
    capability.projections
    |> List.filter (fun (projection : Lib.Capability_registry.projection) ->
      projection.surface = surface)
  in
  let public = projections_for Lib.Capability_registry.Public_mcp in
  let keeper = projections_for Lib.Capability_registry.Keeper in
  check int "one public projection" 1 (List.length public);
  check int "one Keeper projection" 1 (List.length keeper);
  let public = List.hd public in
  let keeper = List.hd keeper in
  List.iter
    (fun (projection : Lib.Capability_registry.projection) ->
       check string "canonical surface name" "masc_board_post" projection.tool_name;
       check string
         "canonical backend name"
         "masc_board_post"
         projection.backend_tool_name)
    [ public; keeper ];
  let canonical =
    Board_tool_registry.schema_for_board_name Tool_name.Board_name.Board_post
  in
  let descriptor =
    Lib.Keeper_tool_descriptor.descriptors_for_internal "masc_board_post"
    |> List.hd
  in
  check bool
    "public schema is canonical"
    true
    (Yojson.Safe.equal public.input_schema canonical.input_schema);
  check bool
    "Keeper schema is its narrowed projection"
    true
    (Yojson.Safe.equal keeper.input_schema descriptor.input_schema);
  check bool
    "surface-specific schemas are distinct"
    false
    (Yojson.Safe.equal public.input_schema keeper.input_schema)


let test_spawned_agent_surface_stays_curated () =
  let names = Lib.Capability_registry.spawned_agent_prefixed_tools in
  check bool "contains masc_status" true
    (List.mem "mcp__masc__masc_status" names)

let test_keeper_surface_is_exact_descriptor_projection () =
  let projected_names =
    Lib.Capability_registry.all_projection_seeds_from
      Lib.Config.raw_all_tool_schemas
    |> List.filter_map (fun (seed : Lib.Capability_registry.capability_seed) ->
      match seed.projection.surface with
      | Lib.Capability_registry.Keeper -> Some seed.projection.tool_name
      | Lib.Capability_registry.Public_mcp
      | Lib.Capability_registry.Spawned_agent_mcp -> None)
    |> List.sort_uniq String.compare
  in
  let descriptor_names =
    Lib.Keeper_tool_descriptor.model_visible_descriptors ()
    |> List.concat_map Lib.Keeper_tool_descriptor.keeper_model_names
    |> List.sort_uniq String.compare
  in
  check (list string)
    "Keeper capability surface is the descriptor projection"
    descriptor_names
    projected_names

let test_keeper_projection_uses_descriptor_capability_identity () =
  Lib.Capability_registry.all_projection_seeds_from
    Lib.Config.raw_all_tool_schemas
  |> List.iter (fun (seed : Lib.Capability_registry.capability_seed) ->
    match seed.projection.surface with
    | Lib.Capability_registry.Keeper ->
      (match
         Lib.Keeper_tool_descriptor_resolution.descriptor_for_tool_name
           seed.projection.tool_name
       with
       | None ->
         failf
           "Keeper projection %S has no descriptor"
           seed.projection.tool_name
       | Some descriptor ->
         check string
           (seed.projection.tool_name ^ " capability identity")
           descriptor.Lib.Keeper_tool_descriptor.capability_id
           seed.capability_id)
    | Lib.Capability_registry.Public_mcp
    | Lib.Capability_registry.Spawned_agent_mcp -> ())

let test_inventory_marks_only_projected_keeper_names () =
  let open Yojson.Safe.Util in
  let rows =
    Lib.Tool_misc_introspection.tool_inventory_json () ~include_hidden:false
    |> member "tools"
    |> to_list
  in
  let surfaces name =
    rows
    |> List.find (fun row -> row |> member "name" |> to_string = name)
    |> member "surfaces"
    |> to_list
    |> List.map to_string
  in
  check bool "public Write alias is Keeper-visible" true
    (List.mem "keeper" (surfaces "Write"));
  check bool "internal write backend is not a second Keeper tool" false
    (List.mem "keeper" (surfaces "tool_write_file"))

let () =
  Alcotest.run "capability_registry"
    [
      ( "surfaces",
        [
          test_case "public surface exposes masc_transition" `Quick
            test_public_visible_surface_exposes_masc_transition;
          test_case "board capability merges public and keeper projections"
            `Quick
            test_board_post_capability_merges_public_and_keeper_projections;

          test_case "spawned agent surface stays curated" `Quick
            test_spawned_agent_surface_stays_curated;
          test_case "Keeper surface is the exact descriptor projection" `Quick
            test_keeper_surface_is_exact_descriptor_projection;
          test_case "Keeper capability identity is descriptor-owned" `Quick
            test_keeper_projection_uses_descriptor_capability_identity;
          test_case "inventory marks only exact Keeper projections" `Quick
            test_inventory_marks_only_projected_keeper_names;
        ] );
    ]
