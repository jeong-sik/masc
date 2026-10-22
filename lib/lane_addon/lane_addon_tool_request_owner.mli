(** Original host-side request and progress in one durable record. Caller holds
    the workspace process lease and serializes retains and progress updates. *)
type error = Binding_conflict | Store_unavailable of string | Invalid_identity of string
  | Invalid_request of string
type installation = Configuration of string | Manual of string
val installation_id : installation -> string
(** Canonical identity used by original request retention and worker state.
    A configured declaration and a manual instance with equal names are distinct. *)
type retained = private {
  scope : string;
  request_id : string;
  installation_id : string;
  package_id : string;
  tool : string;
  request_digest : string;
  request : Yojson.Safe.t;
  progress : Lane_addon_request_progress.t;
}
val load : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  (retained option, error) result
(** Read the complete original canonical request through the verified durable
    store. [None] means the key is absent; malformed, changed or unreadable
    records are errors. This restores a known ID, not restart discovery or
    permission to dispatch or commit. The caller owns workspace authority. *)
val discover : store:Lane_addon_store.t -> scope:string -> (retained list, error) result
(** Read and strictly validate every published original request in this scope,
    including its exact hashed filename and complete input/progress history.
    Any malformed, misnamed, vanished or unreadable published record rejects the
    inventory; no partial list is returned as complete. No directories, requests
    or dispatches are created. Results are observations; load/advance and actual
    workspace authority must be revalidated by the original serialized owner. *)
val retain : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  installation_id:string -> package_id:string -> tool:string -> request:Yojson.Safe.t -> (unit, error) result
(** Persist the complete canonical request before dispatch. Same input and
    original destination is idempotent and preserves advanced progress.
    Invalid JSON is refused before writing. Publication failure is not proof
    of absence: a retry strictly reads the original record again. *)
type update_error = Ownership_error of error | State_conflict | Invalid_transition of string
type publication = Stored of retained | Already_stored of retained | Unconfirmed of string
val advance : store:Lane_addon_store.t -> expected:retained ->
  event:Lane_addon_request_progress.event -> (publication, update_error) result
(** Check the entire original expected record before appending a canonical
    event. An exact already-stored next history is acknowledged without writing;
    [Already_stored] does not permit another dispatch or effect. Any other tail
    is [State_conflict]. This is an expected-record check under the caller's
    lease and serialization, not a filesystem or cross-process CAS.

    [Unconfirmed] means save failed and publication may already be visible.
    Reload the original key; never infer absence or invent a replacement ID.
    Cancellation propagates and likewise does not prove publication absent.
    This API records trusted host facts; it performs no worker/domain effects. *)
val update_error_to_string : update_error -> string
val error_to_string : error -> string
