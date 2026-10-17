(** Typed inventory projected from one immutable Skill catalog snapshot.

    This module does not scan files or parse frontmatter. It projects the
    entries and rejections already frozen in {!Skill_catalog_snapshot}, and
    delegates usable-entry classification to {!Keeper_skill_catalog}. *)

type skill_kind =
  | Instruction
  | Composition of Keeper_tool_composition_catalog.entry

type catalog_status =
  | Effective
  | Shadowed

type valid_skill = private
  { reference : Skill_reference.t
  ; description : string
  ; kind : skill_kind
  ; catalog_status : catalog_status
        (** Global source-precedence result only. Keeper configuration, Task
            selection, runtime delivery, and model visibility are outside this
            inventory and must be derived from a capability surface. *)
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

val of_prepared : Keeper_skill_catalog.prepared -> t
(** Build directly from one frozen projection fold, including exact shadowed
    entries and independent snapshot rejections. No per-entry catalog lookup. *)

val of_snapshot : ?descriptors:Keeper_tool_descriptor.t list -> Skill_catalog_snapshot.t -> t
(** Build one inventory without rereading files or introducing another Skill
    parser. Each valid exact entry is [Effective] or [Shadowed] under global
    source precedence. Each invalid item is retained independently. *)

val snapshot_revision : t -> Skill_catalog_snapshot.snapshot_revision
val items : t -> skill_inventory_item list
val exact_absence_proven : t -> Skill_reference.t -> bool
(** True only for a producer identity absent from a completely readable,
    decoded source scan. Missing/unreadable/unresolved sources and rejected
    candidates never prove producer absence: one malformed or unreadable
    sibling Skill in the same source blocks absence proof for every producer
    in that source. *)

val changed_reference_proven : t -> Skill_reference.t -> bool
(** True when a valid, diagnostic-free item has the same identity as the
    reference but a different content revision, in a completely readable,
    decoded source scan. Its identity remains present when its revision changes,
    so this proof and {!exact_absence_proven} are disjoint. *)
val invalid_error_to_yojson : invalid_error -> Yojson.Safe.t
