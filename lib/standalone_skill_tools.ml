let of_snapshot ~config ?on_result snapshot =
  let catalog, diagnostics = Keeper_skill_catalog.of_snapshot snapshot in
  List.iter
    (fun (diagnostic : Keeper_skill_catalog.projection_diagnostic) ->
      Log.Task.warn "standalone Skill projection: %s"
        (Keeper_skill_catalog.error_to_string diagnostic.error))
    diagnostics;
  match Keeper_tool_composition_surface.instruction_skills_of_catalog catalog with
  | [] -> []
  | instruction_skills ->
    [ Keeper_tool_composition_surface.make_instruction_skill_tool
        ~config ?on_result ~instruction_skills () ]

let for_workspace ~config ?on_result () =
  match Skill_catalog_snapshot_service.find_workspace_of_base_path
          ~base_path:config.Workspace.base_path with
  | Error _ -> Error "standalone Skill workspace could not be resolved"
  | Ok None -> Ok []
  | Ok (Some workspace) ->
    match Skill_catalog_snapshot_service.current ~workspace with
    | None -> Ok []
    | Some snapshot -> Ok (of_snapshot ~config ?on_result snapshot)
