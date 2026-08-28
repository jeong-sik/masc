type t =
  { descriptors : Keeper_tool_descriptor.t list
  ; skill_projection : Keeper_skill_catalog.turn_projection
  }

let create ~tool_groups ~skill_names ~global_skill_catalog ~task_skills =
  let tool_surface =
    Keeper_tool_descriptor.tool_groups_to_surface tool_groups
  in
  let descriptors =
    Keeper_tool_descriptor.model_visible_descriptors_for_surface
      ~surface:tool_surface
  in
  let skill_projection =
    Keeper_skill_catalog.project_turn
      ~names:skill_names
      ~global:global_skill_catalog
      ~task:task_skills
  in
  { descriptors; skill_projection }
;;

let descriptors surface = surface.descriptors
let skill_projection surface = surface.skill_projection
let skill_catalog surface = surface.skill_projection.catalog
