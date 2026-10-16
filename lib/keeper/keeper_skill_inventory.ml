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
  { snapshot : Skill_catalog_snapshot.t
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; items : skill_inventory_item list
  }

let kind_of_surface = function
  | Keeper_skill_catalog.Instruction -> Instruction
  | Keeper_skill_catalog.Composition entry -> Composition entry
;;

let valid_of_projection ~effective entry skill diagnostics =
  Valid
    { reference = Skill_catalog_snapshot.entry_reference entry
    ; description = skill.Keeper_skill_catalog.description
    ; kind = kind_of_surface skill.surface
    ; catalog_status = if effective then Effective else Shadowed
    ; diagnostics
    }
;;

let item_of_entry ~effective (entry : Skill_catalog_snapshot.entry) = function
  | Keeper_skill_catalog.Projected skill -> valid_of_projection ~effective entry skill []
  | Frozen_instruction { skill; diagnostic } ->
    valid_of_projection ~effective entry skill [ diagnostic ]
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

let of_prepared preparation =
  let snapshot = Keeper_skill_catalog.prepared_snapshot preparation in
  let projected =
    Keeper_skill_catalog.fold_prepared_entries preparation ~init:[]
      ~f:(fun items entry projection ~effective ->
        item_of_entry ~effective entry projection :: items)
    |> List.rev
  in
  let rejected =
    Skill_catalog_snapshot.rejections snapshot |> List.map item_of_rejection
  in
  { snapshot
  ; snapshot_revision = Skill_catalog_snapshot.snapshot_revision snapshot
  ; items = projected @ rejected
  }
;;

let of_snapshot ?(descriptors = Keeper_tool_descriptor.all_descriptors ()) snapshot =
  of_prepared (Keeper_skill_catalog.prepare_snapshot ~descriptors snapshot)
;;

let snapshot_revision inventory = inventory.snapshot_revision
let items inventory = inventory.items

let exact_absence_proven inventory (reference : Skill_reference.t) =
  let snapshot = inventory.snapshot in
  let source_id = reference.identity.source_id in
  let same_source id = id = source_id in
  match Skill_catalog_snapshot.config_state snapshot with
  | Config_rejected _ | Config_unreadable _ -> false
  | Configured _ ->
    let complete = List.exists (fun (scan : Skill_catalog_snapshot.source_scan) ->
      same_source scan.source.source.id &&
      match scan.observation with
      | Source_ready _ -> List.for_all (function
          | Skill_catalog_snapshot.Candidate_document _ -> true
          | Candidate_unreadable _ -> false) scan.candidates
      | Source_missing _ | Source_not_directory _ | Source_unavailable _ | Source_unresolved _ -> false)
        (Skill_catalog_snapshot.sources snapshot) in
    complete
    && not (List.exists (fun (rejection : Skill_catalog_snapshot.rejection) ->
      same_source rejection.source_id) (Skill_catalog_snapshot.rejections snapshot))
    && not (List.exists (function
      | Valid valid -> same_source valid.reference.identity.source_id
          && (valid.diagnostics <> [] || Skill_reference.equal_identity reference.identity valid.reference.identity)
      | Invalid invalid -> same_source invalid.source_id) inventory.items)
;;

(* The source scan is complete and clean, so [found] over the valid items sees
   everything this source publishes. *)
let reference_proven inventory (reference : Skill_reference.t) ~found =
  let snapshot = inventory.snapshot in
  match Skill_catalog_snapshot.config_state snapshot with
  | Config_rejected _ | Config_unreadable _ -> false
  | Configured _ ->
    let same_source source_id =
      source_id = reference.identity.source_id in
    let complete = List.exists (fun (scan : Skill_catalog_snapshot.source_scan) ->
      same_source scan.source.source.id &&
      match scan.observation with
      | Source_ready _ -> List.for_all (function
          | Skill_catalog_snapshot.Candidate_document _ -> true
          | Candidate_unreadable _ -> false) scan.candidates
      | Source_missing _ | Source_not_directory _ | Source_unavailable _ | Source_unresolved _ -> false)
        (Skill_catalog_snapshot.sources snapshot) in
    complete
    && not (List.exists (fun (rejection : Skill_catalog_snapshot.rejection) ->
      same_source rejection.source_id) (Skill_catalog_snapshot.rejections snapshot))
    && not (List.exists (function
      | Valid valid -> same_source valid.reference.identity.source_id && valid.diagnostics <> []
      | Invalid invalid -> same_source invalid.source_id) inventory.items)
    && List.exists (function
      | Valid valid -> valid.diagnostics = [] && found valid.reference
      | Invalid _ -> false) inventory.items
;;

let changed_reference_proven inventory (reference : Skill_reference.t) =
  reference_proven inventory reference ~found:(fun (published : Skill_reference.t) ->
    Skill_reference.equal_identity reference.identity published.identity
    && not (Skill_reference.equal reference published))
;;

let snapshot_rejection_to_yojson = function
  | Skill_catalog_snapshot.Document_rejected diagnostics ->
    `Assoc
      [ "kind", `String "document_rejected"
      ; ( "diagnostics"
        , `List
            (List.map Agent_core.Skill_document.diagnostic_to_yojson diagnostics) )
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
