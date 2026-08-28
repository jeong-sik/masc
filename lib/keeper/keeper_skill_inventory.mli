(** Typed inventory projected from one immutable Skill catalog snapshot.

    This module does not scan files or parse frontmatter. It projects the
    entries and rejections already frozen in {!Skill_catalog_snapshot}, and
    delegates usable-entry classification to {!Keeper_skill_catalog}. *)

type skill_kind =
  | Instruction
  | Composition of Keeper_tool_composition_catalog.entry

type skill_exposure =
  | Model_visible
  | Operator_only

type valid_skill = private
  { reference : Skill_reference.t
  ; description : string
  ; kind : skill_kind
  ; exposure : skill_exposure
  ; conformance : Agent_core.Skill_document.conformance
  ; diagnostics : Keeper_skill_catalog.error list
        (** Projection diagnostics that leave the frozen document usable.
            For example, a malformed composition remains an instruction Skill
            under the existing catalog contract. *)
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
        (** Exact reference for a decoded snapshot entry that the catalog
            cannot project. Snapshot-level rejections have no decoded Skill
            identity, so their typed source fields and optional content
            revision remain authoritative instead. *)
  ; error : invalid_error
  }

type skill_inventory_item =
  | Valid of valid_skill
  | Invalid of invalid_skill

type t

val of_snapshot : Skill_catalog_snapshot.t -> t
(** Build one inventory without rereading files or introducing another Skill
    parser. Effective entries are [Model_visible]; shadowed exact entries are
    [Operator_only]. Each invalid item is retained independently. *)

val snapshot_revision : t -> Skill_catalog_snapshot.snapshot_revision
val items : t -> skill_inventory_item list
