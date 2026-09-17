(** Immutable Tool and Skill authority for one Keeper turn.

    The caller supplies an already-frozen global catalog and Task selection.
    This module applies the Keeper's [tool_deny] and Skill-name selections
    once; ordinary Tools, instruction Skills, named compositions, and ad-hoc
    plans must consume this value instead of reopening either catalog. *)

type t

type capability_availability =
  | Active
  | Outside_skill_surface
  | Not_model_invocable
  | Denied_by_profile
      (** A model-visible Tool the Keeper profile's [tool_deny] names. It is
          not in {!descriptors}; the row says why. *)
  | Refused_by_sandbox of { detail : string }
      (** A model-visible Tool the Keeper's sandbox profile cannot run. [detail]
          is the start refusal {!Keeper_spawn_boundary.of_sandbox_profile}
          gives: the handler's own answer for [keeper_spawn], and for
          [keeper_spawn_read]/[_wait]/[_stop] the reason no handle can exist
          for them to address. It is not in {!descriptors}. *)
  | Node_tools_outside_surface of { tools : string list }
      (** A composition Skill whose plan runs node tools this surface does not
          admit, named by their model names. The composition is withheld from
          the executable catalog; see
          {!Keeper_skill_catalog.withhold_compositions_outside}. *)
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
  :  tool_deny:string list
  -> sandbox_profile:Keeper_types_profile_sandbox.sandbox_profile
  -> skill_names:string list option
  -> global_skill_catalog:Keeper_skill_catalog.t
  -> skill_inventory:Keeper_skill_inventory.t
  -> task_skills:Keeper_skill_catalog.skill list
  -> t
(** [tool_deny] holds model-visible tool names (e.g.
    ["keeper_spawn"; "masc_keeper_delegate"]) the keeper's profile
    refuses; matching descriptors are neither listed to the model nor present
    in the dispatch bundle built from {!descriptors}, and their inventory row
    reads [Denied_by_profile]. A name that matches no model-visible descriptor
    is refused where the profile loads. A keeper with no selection passes
    [[]]: the argument is mandatory because an optional here would sit in
    front of only labelled arguments, which OCaml never erases.

    [sandbox_profile] is the Keeper's profile. The four spawn tools leave
    {!descriptors} the same way when {!Keeper_spawn_boundary.of_sandbox_profile}
    refuses a start for it, their rows read [Refused_by_sandbox], and a
    composition that runs one is then withheld. *)

val descriptors : t -> Keeper_tool_descriptor.t list

val admits : t -> Keeper_tool_descriptor.t -> bool
(** Whether this exact descriptor value is on the surface. Direct dispatch and
    composition withholding both decide with this predicate. *)

val tool_row_availability :
  t -> Keeper_tool_descriptor.t -> capability_availability option
(** The inventory row for this exact descriptor value, or [None] when no row
    holds it. *)

val tool_row_availability_for_name : t -> string -> capability_availability option
(** The inventory row whose descriptor answers to this model name, or [None]
    when no row does. A dispatch rejection reports this instead of a bare
    "outside the surface" when a row exists. *)

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

val availability_detail_fields : capability_availability -> (string * Yojson.Safe.t) list
(** The fields an availability carries beyond its name: [sandbox_refusal] for
    [Refused_by_sandbox], [outside_node_tools] for [Node_tools_outside_surface],
    none for the rest. The model-facing rows append these: [keeper_tools_list],
    capability search, and a frozen-surface dispatch rejection. Digest material
    carries the availability name only. *)
val skill_capability_to_yojson : skill_capability -> Yojson.Safe.t
val candidate_to_yojson : candidate -> Yojson.Safe.t
val candidate_name : candidate -> string
val candidate_description : candidate -> string
val candidate_invocation_name : candidate -> string option
