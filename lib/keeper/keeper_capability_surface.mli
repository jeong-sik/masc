(** Immutable Tool and Skill authority for one Keeper turn.

    The caller supplies an already-frozen global catalog and Task selection.
    This module applies the Keeper's Tool Group and Skill-name selections once;
    ordinary Tools, instruction Skills, named compositions, and ad-hoc plans
    must consume this value instead of reopening either catalog. *)

type t

type capability_availability =
  | Active
  | Outside_tool_surface
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

type skill_identity =
  | Exact_skill of Keeper_skill_inventory.skill_inventory_item
  | Missing_configured_skill_name of string

type skill_capability = private
  { identity : skill_identity
  ; exposure : skill_exposure
  ; availability : capability_availability
  }

val create
  :  tool_groups:string list option
  -> skill_names:string list option
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

val capability_availability_to_string : capability_availability -> string
val skill_capability_to_yojson : skill_capability -> Yojson.Safe.t
