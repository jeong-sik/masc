(** Explicit selected-account imports. The immutable private reference is scoped
    to the authorized workspace and selected integration/CLI. No account reads
    happen during ordinary catalog inspection. *)
type reference
type error = Invalid_reference | Private_storage_unavailable | Import_failed | Scope_mismatch
val error_message : error -> string
val reference_to_string : reference -> string
val reference_of_string : string -> (reference,error) result
type imported = { credential_file:string; timeout_s:float; catalog:Yojson.Safe.t }
type binding = private
  | Antigravity_account of { credential_file:string; timeout_s:float }
  | Native_home of { account_home:string }
val lease_home : workspace:string -> integration_id:string -> cli_path:string ->
  account_home:string -> (reference,error) result
(** Lease a server-selected account directory without reading or copying its
    authentication. The caller resolves a declared/default account after an
    explicit selection action; browser input cannot supply this path. Repeated
    selections of the same account and scope reuse the lease while retries or
    an abandoned selection retain it. Successful setup releases the lease. *)
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
val release_native_home : workspace:string -> integration_id:string -> cli_path:string ->
  reference -> (unit,error) result
(** Consume a successfully saved native HOME lease. Validates its scope before
    deleting only the reference; never deletes account contents or imported
    Antigravity credentials. Failed transactions retain the lease for retry. *)
