(** Workspace-shared Goal to observed Ego Space bindings. These records select a
    browser; they never grant Space control or Page mutation authority. *)
type t = private {
  goal_id : string;
  addon_instance_id : string;
  space : Browser_lane.ego_space;
  actor : string;
}
type error = Invalid of string | Unavailable of string | Conflict of string
  | Goal_reference of Goal_store.goal_reference_error
val error_message : error -> string
val to_json : t -> Yojson.Safe.t
val decode : Yojson.Safe.t -> (t list, error) result
(** Strict store decoder; duplicate Goal or controller/Space identities fail. *)
val find : Workspace.config -> goal_id:string -> (t option, error) result
(** [None] means an existing Goal has no binding, never a failed read. *)
type commit = { binding : t; created : bool; mirror_error : string option }
val bind : Workspace.config -> goal_id:string -> addon_instance_id:string ->
  space:Browser_lane.ego_space -> actor:string -> (commit, error) result
(** Idempotent for the same Goal/controller/Space ID. Different assignments are
    refused. Holds the Goal lock before the binding-store lock. A mirror error
    after the authoritative commit is returned as a committed result. *)
type unbinding = { removed : t option; mirror_error : string option }
val unbind : Workspace.config -> goal_id:string -> (unbinding, error) result
(** Removes the Goal's binding so a wrong one can be replaced. Holds the Goal
    lock before the binding-store lock, as [bind] does. [removed = None] means
    the Goal had no binding and nothing was written. A mirror error after the
    authoritative commit is returned as a committed result. *)
val resolve : t -> addon_instance_id:string -> Browser_lane.client_info list ->
  (Browser_lane.client_id, error) result
(** Resolve the durable identity to the current observed connection, including
    after its ephemeral client UUID changes. Never claims or takes over. *)
