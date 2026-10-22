(** Immutable host-side destination binding, independent of execution history.
    Caller holds the workspace process lease and serializes competing retains. *)
type error = Binding_conflict | Store_unavailable of string | Invalid_identity of string
  | Invalid_request of string
type retained = private {
  scope : string;
  request_id : string;
  installation_id : string;
  package_id : string;
  tool : string;
  request_digest : string;
  request : Yojson.Safe.t;
}
val load : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  (retained option, error) result
(** Read the complete original canonical request through the verified durable
    store. [None] means the key is absent; malformed, changed or unreadable
    records are errors. This restores a known ID, not restart discovery or
    permission to dispatch or commit. The caller owns workspace authority. *)
val retain : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  installation_id:string -> package_id:string -> tool:string -> request:Yojson.Safe.t -> (unit, error) result
(** Persist the complete canonical request before dispatch. Same input and
    original destination is idempotent; replacement never changes the fence.
    Invalid JSON is refused before writing. Publication failure is not proof
    of absence: a retry strictly reads the original record again. *)
val error_to_string : error -> string
