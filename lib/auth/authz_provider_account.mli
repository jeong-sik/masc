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

(** Writes the record that links [provider_account_id] to [user_id] for
    [integration_id], who connected it. *)
val link
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> provider_account_id:Authz_types.Provider_account_id.t
  -> integration_id:Authz_types.Integration_id.t
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

(** Why the key of an account was not replaced. *)
type replace_error =
  | Not_replaced of Authz_provider_account_state.refusal
      (** The records of now refuse it, and nothing was written: the account
          is not a key account of the person, its removal began or stopped,
          or the person is not active. *)
  | Replace_failed of error
      (** The record was not built, or the zone did not take it. A commit can
          answer an error after its record went in. *)

(** Writes the record that replaces the key of [provider_account_id] of
    [user_id] with one of the next generation, and answers that generation
    (RFC a-persons-api-key-is-their-own-provider-account 3.7). The intent of
    the replacement goes to the external store before the record. The route
    that replaces a key writes it before the file of the new key, inside the
    call of the account.

    The account is not asked whether it is spent now ({!availability}): a
    record that replaces a key closes the given-up start of a replacement,
    which blocks the account until then. *)
val replace_key
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> provider_account_id:Authz_types.Provider_account_id.t
  -> (Authz_types.Key_generation.t, replace_error) result

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
          of a purge, or of a replacement of its key, that was given up. It
          blocks the account until its owner asks for the same again (design
          8.3). *)

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

(** What stopped on an account and blocks it. Nothing spends the account
    ({!availability}). An account a removal and a replacement both stopped
    on shows the removal: it is removed next, and a replacement of its key
    is refused until then. *)
type blocked =
  | Removal of removal
  | Replacement_start_given_up
      (** The start of a replacement of its key wrote its intent and no record
          (design 8.3). Its owner asks for the replacement again, or removes
          the account. *)

(** An account as a list of the accounts of its owner shows it (RFC
    a-persons-api-key-is-their-own-provider-account 3.6 and 3.8). The
    Runtimes of an account something is [blocked] on are not listed. *)
type shown =
  { provider_account_id : Authz_types.Provider_account_id.t
  ; kind : Authz_provider_account_state.kind
  ; blocked : blocked option
  }

(** The accounts of the person that a list shows, in the order of their ids:
    those the person owns whose removal is not pending and did not go
    through. An account whose removal is pending is on its way out, and one
    whose removal went through is gone; the records of both stay in the
    log. *)
val shown : Authz_state.t -> Authz_types.User_id.t -> shown list
