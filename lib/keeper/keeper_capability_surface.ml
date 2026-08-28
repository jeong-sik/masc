type capability_availability =
  | Active
  | Outside_tool_surface
  | Outside_skill_surface
  | Not_model_invocable
  | Invalid_definition
  | Missing_task_skill
  | Missing_configured_skill

type skill_exposure =
  | Model_visible
  | Operator_only

type tool_capability =
  { descriptor : Keeper_tool_descriptor.t
  ; availability : capability_availability
  }

type skill_identity =
  | Exact_skill of Keeper_skill_inventory.skill_inventory_item
  | Missing_configured_skill_name of string

type skill_capability =
  { identity : skill_identity
  ; exposure : skill_exposure
  ; availability : capability_availability
  }

type candidate =
  | Ordinary_tool of tool_capability
  | Skill of skill_capability

type t =
  { descriptors : Keeper_tool_descriptor.t list
  ; skill_projection : Keeper_skill_catalog.turn_projection
  ; tool_capabilities : tool_capability list
  ; skill_capabilities : skill_capability list
  ; skill_snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  }

let descriptor_is_active descriptors (candidate : Keeper_tool_descriptor.t) =
  List.exists
    (fun (active : Keeper_tool_descriptor.t) -> String.equal active.id candidate.id)
    descriptors
;;

let valid_skill_availability
      ~skill_names
      ~skill_projection
      (valid : Keeper_skill_inventory.valid_skill)
  =
  if Keeper_skill_catalog.exact_is_executable skill_projection valid.reference
  then Active
  else
    match skill_names with
    | Some names when not (List.exists (String.equal valid.reference.identity.name) names) ->
      Outside_skill_surface
    | None | Some _ -> Not_model_invocable
;;

let skill_capability ~skill_names ~skill_projection = function
  | Keeper_skill_inventory.Valid valid as item ->
    let availability =
      valid_skill_availability ~skill_names ~skill_projection valid
    in
    { identity = Exact_skill item
    ; exposure = (match availability with Active -> Model_visible | _ -> Operator_only)
    ; availability
    }
  | Keeper_skill_inventory.Invalid _ as item ->
    { identity = Exact_skill item
    ; exposure = Operator_only
    ; availability = Invalid_definition
    }
;;

let inventory_item_has_name name = function
  | Keeper_skill_inventory.Valid valid ->
    String.equal valid.reference.identity.name name
  | Keeper_skill_inventory.Invalid invalid ->
    (match invalid.reference with
     | Some reference -> String.equal reference.identity.name name
     | None -> String.equal invalid.directory name)
;;

let missing_skill_capabilities ~skill_names ~skill_inventory =
  match skill_names with
  | None -> []
  | Some names ->
    let inventory_items = Keeper_skill_inventory.items skill_inventory in
    names
    |> Json_util.dedupe_keep_order
    |> List.filter_map (fun name ->
      if List.exists (inventory_item_has_name name) inventory_items
      then None
      else
        Some
          { identity = Missing_configured_skill_name name
          ; exposure = Operator_only
          ; availability = Missing_configured_skill
          })
;;

let create
      ~tool_groups
      ~skill_names
      ~global_skill_catalog
      ~skill_inventory
      ~task_skills
  =
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
  let tool_capabilities =
    Keeper_tool_descriptor.model_visible_descriptors ()
    |> List.map (fun descriptor ->
      { descriptor
      ; availability =
          (if descriptor_is_active descriptors descriptor
           then Active
           else Outside_tool_surface)
      })
  in
  let skill_capabilities =
    Keeper_skill_inventory.items skill_inventory
    |> List.map (skill_capability ~skill_names ~skill_projection)
    |> fun capabilities ->
    capabilities
    @ missing_skill_capabilities
        ~skill_names
        ~skill_inventory
  in
  { descriptors
  ; skill_projection
  ; tool_capabilities
  ; skill_capabilities
  ; skill_snapshot_revision = Keeper_skill_inventory.snapshot_revision skill_inventory
  }
;;

let descriptors surface = surface.descriptors
let skill_projection surface = surface.skill_projection
let skill_catalog surface = surface.skill_projection.catalog
let tool_capabilities surface = surface.tool_capabilities
let skill_capabilities surface = surface.skill_capabilities
let skill_snapshot_revision surface = surface.skill_snapshot_revision
let candidates surface =
  List.map (fun capability -> Ordinary_tool capability) surface.tool_capabilities
  @ List.map (fun capability -> Skill capability) surface.skill_capabilities
;;

let capability_availability_to_string = function
  | Active -> "active"
  | Outside_tool_surface -> "outside_tool_surface"
  | Outside_skill_surface -> "outside_skill_surface"
  | Not_model_invocable -> "not_model_invocable"
  | Invalid_definition -> "invalid_definition"
  | Missing_task_skill -> "missing_task_skill"
  | Missing_configured_skill -> "missing_configured_skill"
;;

let skill_kind_to_fields = function
  | Keeper_skill_inventory.Instruction -> [ "kind", `String "instruction" ]
  | Keeper_skill_inventory.Composition entry ->
    [ "kind", `String "composition"
    ; ( "tool_name"
      , `String (Keeper_tool_composition_catalog.tool_name entry) )
    ]
;;

let skill_exposure_to_string = function
  | Model_visible -> "model_visible"
  | Operator_only -> "operator_only"
;;

let catalog_status_to_string = function
  | Keeper_skill_inventory.Effective -> "effective"
  | Keeper_skill_inventory.Shadowed -> "shadowed"
;;

let tool_capability_to_yojson capability =
  `Assoc
    (Keeper_tool_descriptor.discovery_fields capability.descriptor
     @ [ ( "model_names"
         , Json_util.json_string_list
             (Keeper_tool_descriptor.keeper_model_names capability.descriptor) )
       ; ( "availability"
         , `String
             (capability_availability_to_string capability.availability) )
       ])
;;

let invalid_reference_fields (invalid : Keeper_skill_inventory.invalid_skill) =
  match invalid.reference with
  | Some reference -> [ "reference", Skill_reference.to_yojson reference ]
  | None ->
    [ "reference", `Null
    ; ( "source_id"
      , `String (Skill_source_config.source_id_to_string invalid.source_id) )
    ; ( "package_id"
      , Option.fold
          ~none:`Null
          ~some:(fun package_id ->
            `String (Skill_reference.package_id_to_string package_id))
          invalid.package_id )
    ; "directory", `String invalid.directory
    ; ( "content_revision"
      , Option.fold
          ~none:`Null
          ~some:(fun revision ->
            `String (Skill_reference.content_revision_to_string revision))
          invalid.content_revision )
    ]
;;

let skill_capability_to_yojson capability =
  let availability =
    capability_availability_to_string capability.availability
  in
  match capability.identity with
  | Missing_configured_skill_name name ->
    `Assoc
      [ "reference", `Null
      ; "name", `String name
      ; "kind", `String "missing_configured"
      ; "exposure", `String (skill_exposure_to_string capability.exposure)
      ; "availability", `String availability
      ]
  | Exact_skill (Keeper_skill_inventory.Valid valid) ->
    `Assoc
      ([ "reference", Skill_reference.to_yojson valid.reference
       ; "description", `String valid.description
       ; "catalog_status", `String (catalog_status_to_string valid.catalog_status)
       ; "exposure", `String (skill_exposure_to_string capability.exposure)
       ; "availability", `String availability
       ]
       @ skill_kind_to_fields valid.kind)
  | Exact_skill (Keeper_skill_inventory.Invalid invalid) ->
    `Assoc
      (invalid_reference_fields invalid
       @ [ "kind", `String "invalid"
         ; "error", Keeper_skill_inventory.invalid_error_to_yojson invalid.error
         ; "exposure", `String (skill_exposure_to_string capability.exposure)
         ; "availability", `String availability
         ])
;;

let skill_name = function
  | Missing_configured_skill_name name -> name
  | Exact_skill (Keeper_skill_inventory.Valid valid) ->
    valid.reference.identity.name
  | Exact_skill (Keeper_skill_inventory.Invalid invalid) ->
    (match invalid.reference with
     | Some reference -> reference.identity.name
     | None -> invalid.directory)
;;

let candidate_name = function
  | Ordinary_tool capability -> capability.descriptor.internal_name
  | Skill capability -> skill_name capability.identity
;;

let candidate_description = function
  | Ordinary_tool capability -> capability.descriptor.description
  | Skill { identity = Exact_skill (Keeper_skill_inventory.Valid valid); _ } ->
    valid.description
  | Skill { identity = Exact_skill (Keeper_skill_inventory.Invalid invalid); _ } ->
    Keeper_skill_inventory.invalid_error_to_yojson invalid.error
    |> Yojson.Safe.to_string
  | Skill { identity = Missing_configured_skill_name _; _ } ->
    "Configured Skill is absent from the frozen catalog."
;;

let candidate_category = function
  | Ordinary_tool capability ->
    Keeper_tool_descriptor.keeper_tool_group_to_string
      capability.descriptor.keeper_tool_group
  | Skill _ -> "skill"
;;

let candidate_invocation_name = function
  | Ordinary_tool capability ->
    (match Keeper_tool_descriptor.keeper_model_names capability.descriptor with
     | [ name ] -> Some name
     | [] -> None
     | _ :: _ :: _ -> None)
  | Skill { identity = Exact_skill (Keeper_skill_inventory.Valid valid); _ } ->
    (match valid.kind with
     | Keeper_skill_inventory.Instruction -> Some "keeper_skill"
     | Keeper_skill_inventory.Composition entry ->
       Some (Keeper_tool_composition_catalog.tool_name entry))
  | Skill
      { identity = (Exact_skill (Keeper_skill_inventory.Invalid _)
                   | Missing_configured_skill_name _)
      ; _
      } -> None
;;

let candidate_to_yojson = function
  | Ordinary_tool capability ->
    `Assoc
      [ "candidate_kind", `String "ordinary_tool"
      ; "capability", tool_capability_to_yojson capability
      ]
  | Skill capability ->
    `Assoc
      [ "candidate_kind", `String "skill"
      ; "capability", skill_capability_to_yojson capability
      ]
;;

let digest_candidate_to_yojson = function
  | Ordinary_tool capability as candidate ->
    `Assoc
      [ "candidate", candidate_to_yojson candidate
      ; "input_schema", capability.descriptor.input_schema
      ]
  | Skill _ as candidate -> candidate_to_yojson candidate
;;

let digest_material_to_yojson surface =
  `Assoc
    [ ( "skill_snapshot_revision"
      , `String
          (Skill_catalog_snapshot.snapshot_revision_to_string
             surface.skill_snapshot_revision) )
    ; ( "candidates"
      , `List (List.map digest_candidate_to_yojson (candidates surface)) )
    ]
;;

let digest surface =
  let canonical =
    digest_material_to_yojson surface
    |> Yojson.Safe.sort
    |> Yojson.Safe.to_string
  in
  Digestif.SHA256.(digest_string canonical |> to_hex)
;;
