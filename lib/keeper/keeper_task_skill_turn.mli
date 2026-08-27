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

type task_scope =
  | No_task
  | Task of
      { task_id : string
      ; references : Skill_reference.t list
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

val empty : t
val merge : t list -> t
(** Preserve Task order while deduplicating identical exact references. *)

val error_code : error -> string
val error_to_string : error -> string
val core_error : error -> Agent_core.Error.t
val of_core_error : Agent_core.Error.t -> error option

val scope_of_observation :
  Keeper_world_observation_inputs.current_task_observation -> task_scope
(** Capture Task identity and exact Skill references from one observation. *)

val references : task_scope -> Skill_reference.t list

val partition : t -> partition
(** Split one exact selection by its projected surface. Malformed composition
    declarations are frozen instruction selections with [diagnostic = Some _];
    they are not setup failures or executable composition tools. *)

val skills : t -> Keeper_skill_catalog.skill list
