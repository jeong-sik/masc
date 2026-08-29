(** Immutable Tool and Skill authority for one Keeper turn.

    The caller supplies an already-frozen global catalog and Task selection.
    This module applies the Keeper's Tool Group and Skill-name selections once;
    ordinary Tools, instruction Skills, named compositions, and ad-hoc plans
    must consume this value instead of reopening either catalog. *)

type t

type capability_availability =
  | Active
  | Outside_skill_surface
  | Not_model_invocable
  | Invalid_definition
  | Missing_task_skill
      (** Reserved for an exact Task Skill reference that Task resolution
          proves absent. Configured name misses never use this constructor. *)
  | Missing_configured_skill

type skill_exposure =
  | Model_visible
  | Operator_only
(** Exposure is derived for this Keeper turn after exact name and Task
    selection. It is not the global catalog's [Effective | Shadowed] status. *)

type tool_capability = private
  { descriptor : Keeper_tool_descriptor.t
  ; availability : capability_availability
  }

type ordinary_tool_reference = private
  { descriptor_id : string
  ; capability_id : string
  }
(** Exact identity of one ordinary Tool. It carries no display name or alias
    and can only be constructed from a capability in a frozen surface. *)

type skill_identity =
  | Exact_skill of Keeper_skill_inventory.skill_inventory_item
  | Missing_configured_skill_name of string

type skill_capability = private
  { identity : skill_identity
  ; exposure : skill_exposure
  ; availability : capability_availability
  }

type candidate =
  | Ordinary_tool of tool_capability
  | Skill of skill_capability

val create
  :  skill_names:string list option
  -> global_skill_catalog:Keeper_skill_catalog.t
  -> skill_inventory:Keeper_skill_inventory.t
  -> task_skills:Keeper_skill_catalog.skill list
  -> t

val descriptors : t -> Keeper_tool_descriptor.t list
val skill_projection : t -> Keeper_skill_catalog.turn_projection
val skill_catalog : t -> Keeper_skill_catalog.t
val tool_capabilities : t -> tool_capability list

val skill_capabilities : t -> skill_capability list
(** Exact inventory rows plus configured names that have no matching valid or
    invalid catalog item. An invalid configured Skill is reported once as
    [Invalid_definition], never again as [Missing_configured_skill]. *)
val skill_snapshot_revision : t -> Skill_catalog_snapshot.snapshot_revision
val candidates : t -> candidate list
val digest_material_to_yojson : t -> Yojson.Safe.t
(** Private canonical digest projection exposed for focused verification.
    Tool rows bind the exact input schema. Skill rows bind logical source
    identity and exact content revision while excluding resolved host paths,
    OS error detail, and the path-dependent snapshot revision. Public
    diagnostic projections remain unchanged. *)
val digest : t -> string
(** SHA-256 of the ordered, typed Tool and Skill capability projection. The
    separately exposed Skill snapshot revision is not digest material. *)

val capability_availability_to_string : capability_availability -> string
val skill_capability_to_yojson : skill_capability -> Yojson.Safe.t
val candidate_to_yojson : candidate -> Yojson.Safe.t
val candidate_name : candidate -> string
val candidate_description : candidate -> string
val candidate_invocation_name : candidate -> string option
