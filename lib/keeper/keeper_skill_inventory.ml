type skill_kind =
  | Instruction
  | Composition of Keeper_tool_composition_catalog.entry

type catalog_status =
  | Effective
  | Shadowed

type valid_skill =
  { reference : Skill_reference.t
  ; description : string
  ; kind : skill_kind
  ; catalog_status : catalog_status
  ; diagnostics : Keeper_skill_catalog.error list
  }

type invalid_error =
  | Snapshot_rejection of Skill_catalog_snapshot.rejection_reason
  | Catalog_rejection of Keeper_skill_catalog.error

type invalid_skill =
  { source_index : int
  ; source_id : Skill_source_config.source_id
  ; package_id : Skill_reference.package_id option
  ; directory : string
  ; content_revision : Skill_reference.content_revision option
  ; reference : Skill_reference.t option
  ; error : invalid_error
  }

type skill_inventory_item =
  | Valid of valid_skill
  | Invalid of invalid_skill

type t =
  { snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; items : skill_inventory_item list
  }

let catalog_status_of_entry snapshot (entry : Skill_catalog_snapshot.entry) =
  if
    Skill_catalog_snapshot.effective_entries snapshot
    |> List.exists (fun (effective : Skill_catalog_snapshot.entry) ->
      Skill_reference.equal_identity effective.identity entry.identity)
  then Effective
  else Shadowed
;;

let kind_of_surface = function
  | Keeper_skill_catalog.Instruction -> Instruction
  | Keeper_skill_catalog.Composition entry -> Composition entry
;;

let valid_of_projection snapshot entry skill diagnostics =
  Valid
    { reference = Skill_catalog_snapshot.entry_reference entry
    ; description = skill.Keeper_skill_catalog.description
    ; kind = kind_of_surface skill.surface
    ; catalog_status = catalog_status_of_entry snapshot entry
    ; diagnostics
    }
;;

let item_of_entry snapshot (entry : Skill_catalog_snapshot.entry) =
  match Keeper_skill_catalog.project_entry_or_fallback snapshot entry with
  | Projected skill -> valid_of_projection snapshot entry skill []
  | Frozen_instruction { skill; diagnostic } ->
    valid_of_projection snapshot entry skill [ diagnostic ]
  | Entry_unavailable error ->
    Invalid
      { source_index = entry.source_index
      ; source_id = entry.identity.source_id
      ; package_id = Some entry.identity.package_id
      ; directory = entry.directory
      ; content_revision = Some entry.content_revision
      ; reference = Some (Skill_catalog_snapshot.entry_reference entry)
      ; error = Catalog_rejection error
      }
;;

let item_of_rejection (rejection : Skill_catalog_snapshot.rejection) =
  Invalid
    { source_index = rejection.source_index
    ; source_id = rejection.source_id
    ; package_id = rejection.package_id
    ; directory = rejection.directory
    ; content_revision = rejection.content_revision
    ; reference = None
    ; error = Snapshot_rejection rejection.reason
    }
;;

let of_snapshot snapshot =
  let projected =
    Skill_catalog_snapshot.entries snapshot |> List.map (item_of_entry snapshot)
  in
  let rejected =
    Skill_catalog_snapshot.rejections snapshot |> List.map item_of_rejection
  in
  { snapshot_revision = Skill_catalog_snapshot.snapshot_revision snapshot
  ; items = projected @ rejected
  }
;;

let snapshot_revision inventory = inventory.snapshot_revision
let items inventory = inventory.items

let snapshot_rejection_to_yojson = function
  | Skill_catalog_snapshot.Document_rejected diagnostics ->
    `Assoc
      [ "kind", `String "document_rejected"
      ; ( "diagnostics"
        , `List
            (List.map
               (fun diagnostic ->
                  `String
                    (Agent_core.Skill_document.diagnostic_to_string diagnostic))
               diagnostics) )
      ]
  | Skill_catalog_snapshot.Document_unreadable { path; detail } ->
    `Assoc
      [ "kind", `String "document_unreadable"
      ; "path", `String path
      ; "detail", `String detail
      ]
  | Skill_catalog_snapshot.Exact_identity_duplicate { first_directory } ->
    `Assoc
      [ "kind", `String "exact_identity_duplicate"
      ; "first_directory", `String first_directory
      ]
  | Skill_catalog_snapshot.Invalid_package_id _ ->
    `Assoc [ "kind", `String "invalid_package_id" ]
;;

let invalid_error_to_yojson = function
  | Snapshot_rejection reason ->
    `Assoc
      [ "origin", `String "snapshot"
      ; "reason", snapshot_rejection_to_yojson reason
      ]
  | Catalog_rejection error ->
    `Assoc
      [ "origin", `String "catalog"
      ; "kind", `String "catalog_rejection"
      ; "detail", `String (Keeper_skill_catalog.error_to_string error)
      ]
;;
