(** Explicit selected-account imports. The immutable private reference is scoped
    to the authorized workspace and selected integration/CLI. No account reads
    happen during ordinary catalog inspection. *)
type reference
type error = Invalid_reference | Private_storage_unavailable | Import_failed | Scope_mismatch
val error_message : error -> string
val reference_to_string : reference -> string
val reference_of_string : string -> (reference,error) result
type imported = { credential_file:string; timeout_s:float; catalog:Yojson.Safe.t }
type binding = private { credential_file:string; timeout_s:float }
val create : workspace:string -> integration_id:string -> cli_path:string ->
  import:(base_path:string -> (imported,error) result) ->
  (reference * Yojson.Safe.t,error) result
(** Runs inside Eio. [import] is a trusted native callback and receives a fresh
    private user-global directory. Imported credentials must stay inside it.
    Successful account import persists across owner restart; model save and
    verification are separate. No arbitrary browser path is accepted. *)
val resolve : workspace:string -> integration_id:string -> cli_path:string ->
  reference -> (binding,error) result
(** A reference from another canonical workspace is refused. After relocation,
    reimport explicitly for new selections; already-saved global File credentials
    remain at their stable user-global paths. *)
