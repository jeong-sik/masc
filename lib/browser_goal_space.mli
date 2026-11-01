(** Workspace-shared Goal to observed Ego Space bindings. These records select a
    browser; they never grant Space control or Page mutation authority. *)
type owner =
  | Installation of Lane_addon_tool_request_owner.installation
  | Legacy_addon_instance of string
type t = private {
  goal_id : string;
  owner : owner;
  space : Browser_lane.ego_space;
  actor : string;
}
type error = Invalid of string | Unavailable of string | Conflict of string
  | Goal_reference of Goal_store.goal_reference_error
val error_message : error -> string
val to_json : t -> Yojson.Safe.t
val decode : Yojson.Safe.t -> (t list, error) result
(** Strict store decoder; duplicate Goal or installation/Space identities fail.
    Current rows decode [installationId] through the canonical installation
    codec; earlier [addonInstanceId] rows decode as [Legacy_addon_instance] so
    they remain readable, preserve sibling Goal bindings, and can be explicitly
    unbound without inferring configured or manual installation ownership. *)
val find : Workspace.config -> goal_id:string -> (t option, error) result
(** [None] means an existing Goal has no binding, never a failed read. *)
type commit = { binding : t; created : bool; mirror_error : string option }
val bind : Workspace.config -> goal_id:string ->
  installation:Lane_addon_tool_request_owner.installation ->
  space:Browser_lane.ego_space -> actor:string -> (commit, error) result
(** Idempotent for the same Goal/installation/Space ID. A configured installation
    uses its exact declaration owner ID; a manual one retains its runtime
    instance. Different assignments or existing [Legacy_addon_instance] rows are
    refused until explicitly unbound. Holds the Goal lock before the
    binding-store lock. A mirror error after the authoritative commit is returned
    as a committed result. *)
type unbinding = { removed : t option; mirror_error : string option }
val unbind : Workspace.config -> goal_id:string -> (unbinding, error) result
(** Removes the Goal's binding (including an earlier [Legacy_addon_instance] row)
    so it can be replaced while preserving other Goals' bindings. Holds the Goal
    lock before the binding-store lock, as [bind] does. [removed = None] means
    the Goal had no binding and nothing was written. A mirror error after the
    authoritative commit is returned as a committed result. *)
val resolve : t -> installation:Lane_addon_tool_request_owner.installation ->
  Browser_lane.client_info list ->
  (Browser_lane.client_id, error) result
(** Resolve the durable identity to the current observed connection, including
    after its ephemeral client UUID changes, or a configured installation
    reattaches with a new instance. Earlier [Legacy_addon_instance] rows are
    refused with [Conflict] until explicitly unbound and rebound. The caller must
    supply the unique current publisher's own clients and retain its live
    instance/export authority. Never claims or takes over. *)
