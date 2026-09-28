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
val register_home : workspace:string -> integration_id:string -> cli_path:string ->
  account_home:string -> (reference,error) result
(** Register a durable server-selected account reference without reading or
    copying authentication. References live with the user-global setup registry,
    independently of a setup transaction. Repeated selection of the same exact
    account and scope returns one reference; saving cannot invalidate another
    tab or a lost-response retry. Browser input cannot supply the account path. *)
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

val account_of_binding : binding -> Runtime_account_email.account
(** The account a resolved reference selects, spelled as runtime.toml records
    it for the provider saved from that reference. *)

val set_email :
  Runtime_account_email.account -> Runtime_account_email.t option -> (unit, error) result
(** Record the email a completed setup login read for this exact account, or
    clear the record when that login reported none, so an account signed into
    another identity never keeps showing the previous email. The record is
    private and user-global, beside the references, and is display data only. *)

val email : Runtime_account_email.account -> Runtime_account_email.recorded
(** Reads only the record {!set_email} wrote, never an account's login files,
    so setup inventory can call it for every declared account. *)
