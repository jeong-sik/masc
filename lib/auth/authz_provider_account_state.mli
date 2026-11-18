(* HIGH-RISK-UNREVIEWED: this is what the provider account records of the
   authorization log add up to. The owner this module names for an account is
   the only person whose Runtime may spend it. *)

(** The owners and the kinds of the provider accounts that the provider
    account records of [authz.jsonl] add up to (design 4.2, plan D1-1, RFC
    a-persons-api-key-is-their-own-provider-account 3.1). {!Authz_state} keeps
    one of these as its field and hands it every provider account record of a
    bootstrapped log.

    {b Who may write.} An active human principal links an account for
    themselves. A service, the local operator, and the system authors link
    none: a person links a subscription through their own sign-in (design
    5.4).

    {b One id.} A provider account id names one account for good: once linked,
    it keeps its owner and its kind, and no record links it again, as a login
    account or as a key account.

    {b Kind.} The record that linked the account says what it is. A login
    account holds the login of the official client in its home. A key account
    holds a key its owner registered, of the generation the records say: the
    first, until a record replaces the key. *)

(** What an account is, as the record that linked it says. *)
type kind =
  | Login
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
  | Not_a_link_author of Authz_records.Author.t
      (** The local operator or a system author, which {!Authz_record.admits}
          does not let write a provider account record. *)

val refusal_to_string : refusal -> string

(** What one provider account record does to the owners. [is_active] says
    whether a human principal is there and active. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> is_active:(Authz_types.User_id.t -> bool)
  -> Authz_provider_account_event.t
  -> (t, refusal) result
