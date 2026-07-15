(** Explicit operator-intent supersession of a durable blocked shutdown.

    Preflight binds the admission owner's typed operation id and durable
    revision before metadata mutation. [commit_after_metadata_update] must be
    called only after that metadata update has durably committed. *)

type t
type operator_authority

type committed =
  | No_shutdown_admission
  | Shutdown_superseded of Keeper_shutdown_types.t

type error =
  | Operator_authority_required
  | Invalid_operator_authority of string
  | Preflight_failed of Keeper_shutdown_store.error
  | Multiple_durable_shutdown_operations of
      Keeper_shutdown_types.Operation_id.t list
  | Metadata_committed_supersession_failed of Keeper_shutdown_store.error
  | Metadata_committed_admission_owned_by_other of
      Keeper_shutdown_types.Operation_id.t

val error_to_string : error -> string

(** Mint the internal capability carried by a dashboard route that has already
    passed [CanAdmin] authentication. This function validates and binds the
    authenticated actor name; it does not perform HTTP authentication itself. *)
val of_authenticated_dashboard_actor :
  actor:string -> (operator_authority, error) result

val requires_supersession : t -> bool

val preflight :
  config:Workspace.config ->
  keeper_name:string ->
  authority:operator_authority option ->
  (t, error) result

val commit_after_metadata_update :
  config:Workspace.config ->
  t ->
  (committed, error) result
