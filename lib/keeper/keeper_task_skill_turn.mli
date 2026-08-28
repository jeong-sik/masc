(** Frozen Task Skill selection for one Keeper turn. *)

type error =
  | Reference_resolution_failed of
      { reference : Skill_reference.t
      ; error : Skill_catalog_snapshot.reference_resolution_error
      }
  | Projection_failed of
      { reference : Skill_reference.t
      ; error : Keeper_skill_catalog.error
      }

type selected = private
  { reference : Skill_reference.t
  ; skill : Keeper_skill_catalog.skill
  ; diagnostic : Keeper_skill_catalog.error option
  ; task_ids : string list
  }

type t = private { selected : selected list }

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

val empty : t
val merge : t list -> t
(** Preserve Task order while deduplicating identical exact references. *)

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
  skill_names:string list option ->
  selection:t ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  held_task_skills:Keeper_world_observation_inputs.held_task_skills list ->
  (string * Keeper_skill_catalog.exact_surface list) list
(** Project the per-task exact Skill surfaces a turn advertises and executes,
    keyed by task id in observation order (current task first). Takes the
    already-resolved frozen [selection] and never re-resolves. [skill_names]
    is the same profile selection used by the executable bundle, so prompt,
    bundle, and preview consumers share one computation without breaking the
    turn-boundary freeze. *)
