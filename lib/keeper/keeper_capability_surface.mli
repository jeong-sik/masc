(** Immutable Tool and Skill authority for one Keeper turn.

    The caller supplies an already-frozen global catalog and Task selection.
    This module applies the Keeper's Tool Group and Skill-name selections once;
    ordinary Tools, instruction Skills, named compositions, and ad-hoc plans
    must consume this value instead of reopening either catalog. *)

type t

val create
  :  tool_groups:string list option
  -> skill_names:string list option
  -> global_skill_catalog:Keeper_skill_catalog.t
  -> task_skills:Keeper_skill_catalog.skill list
  -> t

val descriptors : t -> Keeper_tool_descriptor.t list
val skill_projection : t -> Keeper_skill_catalog.turn_projection
val skill_catalog : t -> Keeper_skill_catalog.t
