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

(** Writes the record that links [provider_account_id] to [user_id] as a key
    account of [integration_id]: the account holds a key the person
    registered (RFC a-persons-api-key-is-their-own-provider-account, 3.1 and
    3.3). The route that registers a key writes it before any file of the
    key. *)
val link_key
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> provider_account_id:Authz_types.Provider_account_id.t
  -> integration_id:Authz_types.Integration_id.t
  -> (unit, error) result

(** The accounts the person owns, in the order of their ids. *)
val owned : Authz_state.t -> Authz_types.User_id.t -> Authz_types.Provider_account_id.t list

(** Why a person does not spend an account now. *)
type unavailable =
  | Linked_to_another
      (** The log links the account to another person. Nothing of the account
          is read for the person who asked: the answer is the same whatever
          became of the account. *)
  | Defect of Authz_decision.resource_defect
      (** The status of the account is not [Active]: its purge began
          ({!Authz_state.provider_account_status}). *)
  | Reduction_given_up
      (** A reduction of the account wrote its intent and no record: the start
          of a purge that was given up. It blocks the account until its owner
          asks for the purge again (design 8.3). *)

val unavailable_to_string : unavailable -> string

(** Whether [user_id] spends [provider_account_id] now, read as a turn of a
    Keeper reads the account ({!Authz_decision}): its status, and a reduction
    of it that was given up. A check outside a turn stands on this, so that it
    and a turn refuse the same accounts.

    An account no record links is spent by whoever asks: it is the account of
    a login the official client has not confirmed yet, and nothing of the log
    names it. The caller decides whose home it is. *)
val availability
  :  Authz_state.t
  -> user_id:Authz_types.User_id.t
  -> Authz_types.Provider_account_id.t
  -> (unit, unavailable) result

(** What the records say of a removal of an account that is neither pending
    nor through. In both cases nothing spends the account ({!availability}),
    and its owner asks for the removal again. *)
type removal =
  | Start_given_up
      (** The start of its removal wrote its intent and no record (design
          8.3). *)
  | Stayed of Authz_purge_event.account_failed_stage
      (** The removal ended with this stage still there. *)

(** An account as a list of the accounts of its owner shows it (RFC
    a-persons-api-key-is-their-own-provider-account 3.6 and 3.8). *)
type shown =
  { provider_account_id : Authz_types.Provider_account_id.t
  ; kind : Authz_provider_account_state.kind
  ; removal : removal option
  }

(** The accounts of the person that a list shows, in the order of their ids:
    those the person owns whose removal is not pending and did not go
    through. An account whose removal is pending is on its way out, and one
    whose removal went through is gone; the records of both stay in the
    log. *)
val shown : Authz_state.t -> Authz_types.User_id.t -> shown list
