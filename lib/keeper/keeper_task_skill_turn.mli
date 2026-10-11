(** Frozen Task Skill selection for one Keeper turn. *)

type error =
  | Tool_surface_unavailable of string
  | Skill_config_rejected of { diagnostics : Skill_source_config.diagnostic list }
  | Skill_config_unreadable of { detail : string }
      (** The snapshot's Skill configuration was rejected or could not be
          read, so it holds no entries and no pin can be told apart from a
          deleted Skill. Resolution fails when any Task pins a Skill; a stale
          pin against a configured snapshot is an {!unprojectable} row. *)

type selected = private
  { reference : Skill_reference.t
  ; skill : Keeper_skill_catalog.skill
  ; diagnostic : Keeper_skill_catalog.error option
  ; task_ids : string list
  }

type unavailable_reason =
  | Catalog_entry_unprojectable of Keeper_skill_catalog.error
      (** The snapshot holds the entry but the catalog cannot project it
          ({!Keeper_skill_catalog.Entry_unavailable}), such as an instruction
          body over the inline read boundary. *)
  | Pin_unresolved of Skill_catalog_snapshot.reference_resolution_error
      (** The pinned exact reference no longer resolves: no entry has its
          identity ([Identity_not_found]), or the entry that does has another
          content revision ([Content_revision_mismatch]). The Skill was
          deleted or edited after the Task pinned it. *)

type unprojectable = private
  { reference : Skill_reference.t
  ; reason : unavailable_reason
  ; task_ids : string list
  }
(** A Task reference the turn cannot offer. The turn still runs: the Skill is
    shown unavailable with [reason], and the Task's other Skills and the
    Keeper's other Tasks are unaffected. *)

type t = private
  { selected : selected list
  ; unprojectable : unprojectable list
  ; descriptor_authority : Keeper_tool_descriptor.t list option
  }

type partition = private
  { instructions : selected list
  ; compositions : selected list
  }

val resolve :
  snapshot:Skill_catalog_snapshot.t -> Skill_reference.t list -> (t, error) result
(** Resolve every Task reference against the already captured immutable
    snapshot. Exact lookup includes shadowed entries. *)

val resolve_for_task :
  snapshot:Skill_catalog_snapshot.t ->
  task_id:string ->
  Skill_reference.t list ->
  (t, error) result
(** Resolve one Task's exact references while retaining its identity as
    activation provenance. *)

val resolve_observations :
  snapshot:Skill_catalog_snapshot.t ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  held_task_skills:Keeper_world_observation_inputs.held_task_skills list ->
  (t, error) result
(** Resolve current and held Task references exactly once from one observed turn
    state, retaining every Task identity on shared references. *)

val with_descriptors : descriptors:Keeper_tool_descriptor.t list ->
  snapshot:Skill_catalog_snapshot.t -> t -> (t, error) result
(** Reproject only already selected exact references from the same frozen snapshot;
    preserve Task provenance and bind the descriptor objects used by the turn. *)
val descriptors : t -> Keeper_tool_descriptor.t list option
(** [None] means no runtime Tool authority has been captured yet. *)
val resolve_live_observations :
  config:Workspace.config -> keeper_name:string ->
  snapshot:Skill_catalog_snapshot.t ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  held_task_skills:Keeper_world_observation_inputs.held_task_skills list ->
  (t, error) result
(** Capture authorized Add-on descriptors once for both prompt and execution. *)

val empty : t
val merge : t list -> t
(** Preserve Task order while deduplicating identical exact references, in
    both [selected] and [unprojectable]. *)

val unavailable_reason_code : unavailable_reason -> string
val unavailable_reason_to_string : unavailable_reason -> string

val unprojectable_to_string : unprojectable -> string
(** One line naming the reference, the Tasks that pinned it, and the reason. *)

val unprojectable_to_yojson : unprojectable -> Yojson.Safe.t
(** [reference], [task_ids], the reason [error_code] and its [detail]. *)

val error_code : error -> string
val error_to_string : error -> string
val core_error : error -> Agent_core.Error.t
val of_core_error : Agent_core.Error.t -> error option

val partition : t -> partition
(** Split one exact selection by its projected surface. Malformed composition
    declarations are frozen instruction selections with [diagnostic = Some _];
    they are not setup failures or executable composition tools. *)

val skills : t -> Keeper_skill_catalog.skill list

val task_ids_for_reference : t -> Skill_reference.t -> string list
(** Exact Task ids that selected this revision in the frozen turn observation. *)

val executable_selection :
  projection:Keeper_skill_catalog.turn_projection -> t -> t
(** Retain only Task selections present in the executable turn projection.
    Activation provenance uses this view, so a profile-filtered Task Skill
    cannot be recorded as an executable Task activation. *)

val exact_task_surfaces :
  snapshot:Skill_catalog_snapshot.t ->
  tool_deny:string list ->
  sandbox_profile:Keeper_types_profile_sandbox.sandbox_profile ->
  skill_names:string list option ->
  selection:t ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  held_task_skills:Keeper_world_observation_inputs.held_task_skills list ->
  (string * Keeper_skill_catalog.exact_surface list) list
(** Project the per-task exact Skill surfaces a turn advertises and executes,
    keyed by task id in observation order (current task first). Takes the
    already-resolved frozen [selection] and never re-resolves. [tool_deny],
    [sandbox_profile] and [skill_names] are the same inputs the executable bundle passes to
    {!Keeper_capability_surface.create}, which builds this projection too, so
    prompt, bundle, and preview consumers share one computation without
    breaking the turn-boundary freeze. Each task's [unprojectable] references
    follow its projected ones as unavailable rows carrying their reason. *)
