(** Explicit, evidence-bearing observations of a Goal's declared metric.
    Observations never advance the Goal phase or certify its success. *)

type t = {
  id : string;
  goal_id : string;
  criterion_revision : string;
  observed_value : string;
  evidence : string;
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
    recovery mirror is an error, rather than an empty measurement history. *)

val latest_for_goal :
  Workspace_utils.config -> goal:Goal_store.goal -> (t option, string) result
(** Only the current success-criterion revision is eligible. *)

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
    completion inference is performed. *)

val record_json :
  Workspace_utils.config -> actor:string -> Yojson.Safe.t -> (t, error) result
(** Strict four-field request decoder shared by the operator and Keeper HTTP
    routes. The authenticated actor is supplied by the route. *)
