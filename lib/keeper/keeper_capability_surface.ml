type capability_availability =
  | Active
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

type ordinary_tool_reference =
  { descriptor_id : string
  ; capability_id : string
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
      ~skill_names
      ~global_skill_catalog
      ~skill_inventory
      ~task_skills
  =
  let descriptors =
    Keeper_tool_descriptor.model_visible_descriptors ()
  in
  let skill_projection =
    Keeper_skill_catalog.project_turn
      ~names:skill_names
      ~global:global_skill_catalog
      ~task:task_skills
  in
  let tool_capabilities =
    Keeper_tool_descriptor.all_descriptors ()
    |> List.map (fun descriptor ->
      { descriptor
        (* A descriptor that names itself to the model is in the surface, and
           nothing left can take it back out. Until #31728 a Keeper could
           narrow its own surface by declaring tool groups, and what fell
           outside was carried here as [Outside_tool_surface]; that
           declaration was removed because no Keeper ever wrote one. What
           names itself is exactly what [model_visible_descriptors] holds --
           [keeper_model_names] answers [] for a descriptor with schema
           errors, which is the only other way those two lists could differ --
           so the arm that said "outside" could not be reached, and the
           surface it named does not exist. *)
      ; availability =
          (match Keeper_tool_descriptor.keeper_model_names descriptor with
           | [] -> Not_model_invocable
           | _ :: _ -> Active)
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

let ordinary_tool_reference capability =
  { descriptor_id = capability.descriptor.id
  ; capability_id = capability.descriptor.capability_id
  }
;;

let ordinary_tool_reference_to_yojson reference =
  `Assoc
    [ "descriptor_id", `String reference.descriptor_id
    ; "capability_id", `String reference.capability_id
    ]
;;

let skill_capabilities surface = surface.skill_capabilities
let skill_snapshot_revision surface = surface.skill_snapshot_revision
let candidates surface =
  List.map (fun capability -> Ordinary_tool capability) surface.tool_capabilities
  @ List.map (fun capability -> Skill capability) surface.skill_capabilities
;;

let capability_availability_to_string = function
  | Active -> "active"
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
      ; ( "reference"
        , ordinary_tool_reference capability
          |> ordinary_tool_reference_to_yojson )
      ; "capability", tool_capability_to_yojson capability
      ]
  | Skill capability ->
    `Assoc
      [ "candidate_kind", `String "skill"
      ; "capability", skill_capability_to_yojson capability
      ]
;;

type digest_skill_error_kind =
  | Snapshot_document_rejected
  | Snapshot_document_unreadable
  | Snapshot_exact_identity_duplicate
  | Snapshot_invalid_package_id
  | Catalog_rejection_kind of Keeper_skill_catalog.error

type digest_skill_kind =
  | Digest_instruction
  | Digest_composition
  | Digest_invalid
  | Digest_missing_configured

type digest_skill_identity =
  | Digest_exact_reference of Skill_reference.t
  | Digest_invalid_source of
      { source_id : Skill_source_config.source_id
      ; package_id : Skill_reference.package_id option
      ; directory : string
      ; content_revision : Skill_reference.content_revision option
      }
  | Digest_configured_name of string

type digest_candidate =
  | Digest_tool of tool_capability
  | Digest_skill of
      { logical_identity : digest_skill_identity
      ; exposure : skill_exposure
      ; availability : capability_availability
      ; kind : digest_skill_kind
      ; catalog_status : Keeper_skill_inventory.catalog_status option
      ; error_kind : digest_skill_error_kind option
      }

let digest_skill_error_kind = function
  | Keeper_skill_inventory.Snapshot_rejection reason ->
    (match reason with
     | Skill_catalog_snapshot.Document_rejected _ -> Snapshot_document_rejected
     | Skill_catalog_snapshot.Document_unreadable _ -> Snapshot_document_unreadable
     | Skill_catalog_snapshot.Exact_identity_duplicate _ ->
       Snapshot_exact_identity_duplicate
     | Skill_catalog_snapshot.Invalid_package_id _ -> Snapshot_invalid_package_id)
  | Keeper_skill_inventory.Catalog_rejection error ->
    Catalog_rejection_kind error
;;

let digest_skill_error_kind_to_string = function
  | Snapshot_document_rejected -> "snapshot:document_rejected"
  | Snapshot_document_unreadable -> "snapshot:document_unreadable"
  | Snapshot_exact_identity_duplicate -> "snapshot:exact_identity_duplicate"
  | Snapshot_invalid_package_id -> "snapshot:invalid_package_id"
  | Catalog_rejection_kind error ->
    "catalog:" ^ Keeper_skill_catalog.error_code error
;;

let digest_skill_kind_to_string = function
  | Digest_instruction -> "instruction"
  | Digest_composition -> "composition"
  | Digest_invalid -> "invalid"
  | Digest_missing_configured -> "missing_configured"
;;

let digest_skill_identity_to_yojson = function
  | Digest_exact_reference reference -> Skill_reference.to_yojson reference
  | Digest_configured_name name -> `Assoc [ "configured_name", `String name ]
  | Digest_invalid_source { source_id; package_id; directory; content_revision } ->
    `Assoc
      [ ( "source_id"
        , `String (Skill_source_config.source_id_to_string source_id) )
      ; ( "package_id"
        , Option.fold
            ~none:`Null
            ~some:(fun package_id ->
              `String (Skill_reference.package_id_to_string package_id))
            package_id )
      ; "directory", `String directory
      ; ( "content_revision"
        , Option.fold
            ~none:`Null
            ~some:(fun revision ->
              `String (Skill_reference.content_revision_to_string revision))
            content_revision )
      ]
;;

let digest_invalid_identity (invalid : Keeper_skill_inventory.invalid_skill) =
  match invalid.reference with
  | Some reference -> Digest_exact_reference reference
  | None ->
    Digest_invalid_source
      { source_id = invalid.source_id
      ; package_id = invalid.package_id
      ; directory = invalid.directory
      ; content_revision = invalid.content_revision
      }
;;

let digest_candidate = function
  | Ordinary_tool capability -> Digest_tool capability
  | Skill capability ->
    (match capability.identity with
     | Missing_configured_skill_name name ->
       Digest_skill
         { logical_identity = Digest_configured_name name
         ; exposure = capability.exposure
         ; availability = capability.availability
         ; kind = Digest_missing_configured
         ; catalog_status = None
         ; error_kind = None
         }
     | Exact_skill (Keeper_skill_inventory.Valid valid) ->
       Digest_skill
         { logical_identity = Digest_exact_reference valid.reference
         ; exposure = capability.exposure
         ; availability = capability.availability
         ; kind =
             (match valid.kind with
              | Keeper_skill_inventory.Instruction -> Digest_instruction
              | Composition _ -> Digest_composition)
         ; catalog_status = Some valid.catalog_status
         ; error_kind = None
         }
     | Exact_skill (Keeper_skill_inventory.Invalid invalid) ->
       Digest_skill
         { logical_identity = digest_invalid_identity invalid
         ; exposure = capability.exposure
         ; availability = capability.availability
         ; kind = Digest_invalid
         ; catalog_status = None
         ; error_kind = Some (digest_skill_error_kind invalid.error)
         })
;;

let digest_candidate_to_yojson = function
  | Digest_tool capability ->
    `Assoc
      [ ( "candidate"
        , candidate_to_yojson (Ordinary_tool capability) )
      ; "input_schema", capability.descriptor.input_schema
      ]
  | Digest_skill skill ->
    `Assoc
      [ "candidate_kind", `String "skill"
      ; "logical_identity", digest_skill_identity_to_yojson skill.logical_identity
      ; "exposure", `String (skill_exposure_to_string skill.exposure)
      ; ( "availability"
        , `String (capability_availability_to_string skill.availability) )
      ; "kind", `String (digest_skill_kind_to_string skill.kind)
      ; ( "catalog_status"
        , Option.fold
            ~none:`Null
            ~some:(fun status -> `String (catalog_status_to_string status))
            skill.catalog_status )
      ; ( "error_kind"
        , Option.fold
            ~none:`Null
            ~some:(fun kind -> `String (digest_skill_error_kind_to_string kind))
            skill.error_kind )
      ]
;;

let digest_material_to_yojson surface =
  `Assoc
    [ ( "candidates"
      , `List
          (candidates surface
           |> List.map digest_candidate
           |> List.map digest_candidate_to_yojson) )
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
