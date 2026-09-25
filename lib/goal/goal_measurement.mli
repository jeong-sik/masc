(** Explicit, evidence-bearing observations of a Goal's declared metric.
    Observations never advance the Goal phase or certify its success. *)

type t = private {
  id : string;
  goal_id : string;
  criterion_revision : string;
  observed_value : string;
  evidence : string;
      (** An Evidence Reference that
          {!Workspace_verification_store.classify_evidence_reference} resolves
          ([artifact:], [note:], [board:] or [fusion:]), trimmed. A row is
          built only after that classification, on record and on load. *)
  actor : string;
  recorded_at : string;
}

type error =
  | Invalid_request of string
  | Conflict of string
  | Store_error of string

val error_to_string : error -> string

val to_yojson : t -> Yojson.Safe.t

val load : Workspace_utils.config -> (t list, string) result
(** An unreadable primary is an error. A missing primary with an existing
    recovery mirror is an error, rather than an empty snapshot. There is at
    most one observation per Goal; a new one replaces its previous revision. *)

val projection :
  (t list, string) result -> Goal_store.goal -> Yojson.Safe.t
(** Explicit reported, not_recorded, or unavailable state for a Goal. *)

val record :
  Workspace_utils.config ->
  goal_id:string ->
  criterion_revision:string ->
  observed_value:string ->
  evidence:string ->
  actor:string ->
  (t, error) result
(** Bind an explicit value and evidence to the exact current criterion under
    the Goal lock. The value is displayed verbatim; no numeric comparison or
    completion inference is performed. Evidence that is not a resolvable
    Evidence Reference is [Invalid_request]. The Goal phase is not consulted:
    a Completed or Dropped Goal still takes an observation, since recording
    one never moves the phase. *)

val remove_goal : Workspace_utils.config -> goal_id:string -> (unit, string) result
(** Drop the observation of a deleted Goal, so the snapshot stays bounded by
    the Goals that exist. [Ok ()] without a write when the Goal has none. *)

val record_json :
  Workspace_utils.config -> actor:string -> Yojson.Safe.t -> (t, error) result
(** Strict four-field request decoder shared by the operator and Keeper HTTP
    routes. The authenticated actor is supplied by the route. *)
