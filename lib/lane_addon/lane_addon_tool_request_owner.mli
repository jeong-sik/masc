(** Immutable host-side destination binding, independent of execution history.
    Caller holds the workspace process lease and serializes competing retains. *)
type error = Binding_conflict | Store_unavailable of string | Invalid_identity of string
val retain : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  installation_id:string -> package_id:string -> tool:string -> request:Yojson.Safe.t -> (unit, error) result
val error_to_string : error -> string
