(* HIGH-RISK-UNREVIEWED: this module writes the record that makes a person the
   owner of a provider account. Only the owner's Runtime may spend it. *)

(** Links a provider account to the person who connected it, against the
    writer zone (design 4.2 and 5.4, plan D1-4). The subscription connect
    route calls {!link} when the official client confirms the login. *)

type error =
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error
      (** The zone refused the record: the person is no longer active, or the
          account was linked before, among others. *)

val error_to_string : error -> string

(** Writes the record that links [provider_account_id] to [user_id], who
    connected it. *)
val link
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> provider_account_id:Authz_types.Provider_account_id.t
  -> (unit, error) result

(** The accounts the person owns, in the order of their ids. *)
val owned : Authz_state.t -> Authz_types.User_id.t -> Authz_types.Provider_account_id.t list
