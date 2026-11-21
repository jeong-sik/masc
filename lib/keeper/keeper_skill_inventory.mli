(** Typed inventory projected from one immutable Skill catalog snapshot. *)

type skill_kind =
  | Instruction

type catalog_status =
  | Effective
  | Shadowed

type valid_skill = private
  { reference : Skill_reference.t
  ; description : string
  ; kind : skill_kind
  ; catalog_status : catalog_status
  ; diagnostics : Keeper_skill_catalog.error list
  }

type invalid_error =
  | Snapshot_rejection of Skill_catalog_snapshot.rejection_reason
  | Catalog_rejection of Keeper_skill_catalog.error

type invalid_skill = private
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

type t

val of_prepared : Keeper_skill_catalog.prepared -> t
val of_snapshot : ?descriptors:Keeper_tool_descriptor.t list -> Skill_catalog_snapshot.t -> t
val snapshot_revision : t -> Skill_catalog_snapshot.snapshot_revision
val items : t -> skill_inventory_item list
val exact_absence_proven : t -> Skill_reference.t -> bool
val changed_reference_proven : t -> Skill_reference.t -> bool
val invalid_error_to_yojson : invalid_error -> Yojson.Safe.t
