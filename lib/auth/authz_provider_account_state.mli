(* HIGH-RISK-UNREVIEWED: this is what the provider account records of the
   authorization log add up to. The owner this module names for an account is
   the only person whose Runtime may spend it. *)

(** The owners and the kinds of the provider accounts that the provider
    account records of [authz.jsonl] add up to (design 4.2, plan D1-1, RFC
    a-persons-api-key-is-their-own-provider-account 3.1). {!Authz_state} keeps
    one of these as its field and hands it every provider account record of a
    bootstrapped log.

    {b Who may write.} An active human principal links an account for
    themselves, and replaces the key of a key account of theirs. A service,
    the local operator, and the system authors write none of these records: a
    person links a subscription through their own sign-in (design 5.4).

    {b One id.} A provider account id names one account for good: once linked,
    it keeps its owner and its kind, and no record links it again, as a login
    account or as a key account.

    {b Kind.} The record that linked the account says what it is. A login
    account holds the login of the official client in its home. A key account
    holds a key its owner registered, of the generation the records say: the
    first, until a record replaces the key.

    {b Replacing a key.} A record replaces the key of a key account of its
    author whose removal did not begin and did not stop, and names the
    generation after the one the account holds (RFC 3.7). The account keeps
    its id, its owner and its integration. *)

(** What an account is, as the record that linked it says. *)
type kind =
  | Login of { integration_id : Authz_types.Integration_id.t }
  | Key of
      { integration_id : Authz_types.Integration_id.t
      ; generation : Authz_types.Key_generation.t
      }

type account =
  { owner : Authz_types.User_id.t
  ; kind : kind
  }

type t

val empty : t

(** The account, if it was linked. *)
val find : t -> Authz_types.Provider_account_id.t -> account option

(** The owner of the account, if it was linked. *)
val owner : t -> Authz_types.Provider_account_id.t -> Authz_types.User_id.t option

(** The accounts this person owns, in the order of their ids. *)
val owned_by : t -> Authz_types.User_id.t -> Authz_types.Provider_account_id.t list

(** The key accounts of every person, in the order of their ids: those a
    removal went through among them, since their records stay. *)
val key_accounts : t -> Authz_types.Provider_account_id.t list

(** What the records of its removal say of an account, as far as a
    replacement of its key reads them. This module holds no record of a
    removal: {!Authz_state} reads them for it. *)
type removal =
  | Not_begun
  | Begun  (** The account is on its way out, or gone. *)
  | Stopped
      (** A removal ended with a stage still there, or its start was given up.
          The account is removed before anything else is done with it. *)

type refusal =
  | Already_linked of Authz_types.Provider_account_id.t
  | Linked_for_another of
      { author : Authz_types.User_id.t
      ; user_id : Authz_types.User_id.t
      }
      (** A principal links an account only for themselves, an Admin too
          (design 4.2). *)
  | User_not_active of Authz_types.User_id.t
      (** No active principal has this id: it never joined, or it is disabled
          or deleted. *)
  | Not_a_human of Authz_types.Principal.t
  | Not_an_account_author of Authz_records.Author.t
      (** The local operator or a system author, which {!Authz_record.admits}
          does not let write a provider account record. *)
  | Replaced_for_another of
      { author : Authz_types.User_id.t
      ; user_id : Authz_types.User_id.t
      }  (** A principal replaces a key only for themselves. *)
  | Not_linked of Authz_types.Provider_account_id.t
      (** No record links the account whose key the record replaces. *)
  | Not_the_owner of Authz_types.Provider_account_id.t
      (** The account is another person's. It is compared before the kind and
          the removal of the account, so the refusal says of another's
          account only that someone holds it. A route answers it as it
          answers {!Not_linked}. *)
  | Not_a_key_account of Authz_types.Provider_account_id.t
      (** A login account holds no key. *)
  | Account_removed of Authz_types.Provider_account_id.t  (** {!Begun}. *)
  | Removal_stopped of Authz_types.Provider_account_id.t  (** {!Stopped}. *)
  | Generation_not_next of
      { held : Authz_types.Key_generation.t
      ; given : Authz_types.Key_generation.t
      }
      (** The record names a generation that is not the one after the
          generation the account holds: it was applied before, or another
          replacement went in first. *)

val refusal_to_string : refusal -> string

(** The generation of the key of [provider_account_id] that [user_id] may
    replace now: they are active, the account is a key account of theirs, and
    its removal did not begin and did not stop. A record that replaces the
    key is taken on the same conditions ({!apply}), and names the generation
    after this one. Nothing else of the account is read: an account the
    given-up start of a replacement blocks has its key replaced all the
    same, which is how that start is made again (design 8.3). The given-up
    start of a removal is a removal that stopped. *)
val key_to_replace
  :  t
  -> is_active:(Authz_types.User_id.t -> bool)
  -> removal:(owner:Authz_types.User_id.t -> Authz_types.Provider_account_id.t -> removal)
  -> user_id:Authz_types.User_id.t
  -> Authz_types.Provider_account_id.t
  -> (Authz_types.Key_generation.t, refusal) result

(** What one provider account record does to the accounts. [is_active] says
    whether a human principal is there and active. [removal] says what the
    records of its removal say of an account of [owner]; only a replacement
    of a key asks it, and only of an account of its author. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> is_active:(Authz_types.User_id.t -> bool)
  -> removal:(owner:Authz_types.User_id.t -> Authz_types.Provider_account_id.t -> removal)
  -> Authz_provider_account_event.t
  -> (t, refusal) result
