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
  }

type t = private { selected : selected list }

val resolve :
  snapshot:Skill_catalog_snapshot.t -> Skill_reference.t list -> (t, error) result
(** Resolve every Task reference against the already captured immutable
    snapshot. Exact lookup includes shadowed entries. *)

val error_code : error -> string
val error_to_string : error -> string
val core_error : error -> Agent_core.Error.t
val of_core_error : Agent_core.Error.t -> error option

val references_of_observation :
  Keeper_world_observation_inputs.current_task_observation -> Skill_reference.t list
(** Authoritative and recovery Task observations both preserve their exact
    references. Missing/unavailable/no-current-task observations carry none. *)
