(** Ordinary-user access to the local Linux Docker group. Membership grants
    root-level Docker control and is changed only after explicit selection. *)
type state = Group_missing | Membership_required | Session_refresh_required | Group_active
type observation = { account : string; uid : int; state : state }
type error = Unsupported_host | Unsupported_distribution | Invalid_account
  | Account_read_failed | Grant_failed | Invalid_resume | Session_not_active
  | Service_unavailable of Sandbox_readiness.entry
val error_message : error -> string
val grant_detail : string
val inspect : host:Sandbox_readiness.host -> (observation, error) result
val to_json : observation -> Yojson.Safe.t
val grant : host:Sandbox_readiness.host -> distribution:Sandbox_prerequisites.distribution ->
  run:(string list -> (unit, unit) result) -> (observation, error) result
(** Adds only the actual invoking Unix account, then rereads persisted membership
    and current process groups. This does not turn old process groups into new ones. *)
type handoff = Already_active | Child_finished | Reauthentication_pending
val handoff : host:Sandbox_readiness.host -> executable_path:string -> base_path:string -> port:int ->
  run:(string list -> (unit, unit) result) -> (handoff, error) result
(** User-selected terminal handoff through sg. Child runs the same native binary
    [docker-session-resume] as the same UID; no sudo Docker and no environment edits.
    Child exit is not an imp/guest readiness claim. *)
val validate_session : host:Sandbox_readiness.host -> expected_uid:int ->
  probe_run:Sandbox_readiness.runner -> require_rootless:bool -> require_userns:bool ->
  (Sandbox_readiness.entry, error) result
(** The internal child endpoint MUST call this before continuing the saved setup.
    It requires matching nonroot real/effective UID, active group, and a successful
    ordinary-user Docker service probe. Guest verification remains Not_run. *)
module For_testing : sig
  type snapshot = { uid:int; effective_uid:int; account:string; account_primary_gid:int;
    primary_gid:int; supplementary_gids:int list; docker_group:(int * string list) option }
  val inspect : host:Sandbox_readiness.host -> snapshot -> (observation, error) result
  val grant : host:Sandbox_readiness.host -> distribution:Sandbox_prerequisites.distribution ->
    read:(unit -> (snapshot, error) result) -> run:(string list -> (unit, unit) result) ->
    (observation, error) result
  val session_argv : executable_path:string -> base_path:string -> port:int -> uid:int -> (string list, error) result
  val validate_session : host:Sandbox_readiness.host -> expected_uid:int -> snapshot ->
    probe_run:Sandbox_readiness.runner -> require_rootless:bool -> require_userns:bool ->
    (Sandbox_readiness.entry, error) result
end
