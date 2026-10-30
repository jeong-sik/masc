(** Task lifecycle observations do not establish external acceptance or Goal
    confirmation. The verification and Goal stores retain those authorities. *)

type terminal = Approved | Cancelled

val lifecycle_success : terminal -> bool
(** Projection onto the existing Task metric/event boolean. [true] records
    Task approval, never an observed external result. *)

type basis = Task_lifecycle

val basis_to_yojson : basis -> Yojson.Safe.t
val basis_of_yojson : Yojson.Safe.t -> (basis, string) result
val pp_basis : Format.formatter -> basis -> unit

type external_acceptance = Unobserved of { completed_tasks : int }
(** The Task metric stream has no external acceptance observations. Coverage
    names the completed Tasks whose external result remains unobserved by it;
    this says nothing about observations held by another authority. *)

val external_acceptance_to_yojson : external_acceptance -> Yojson.Safe.t
val external_acceptance_of_yojson :
  Yojson.Safe.t -> (external_acceptance, string) result
val pp_external_acceptance : Format.formatter -> external_acceptance -> unit
