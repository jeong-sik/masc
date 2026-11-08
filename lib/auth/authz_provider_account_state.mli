(* HIGH-RISK-UNREVIEWED: this is what the provider account records of the
   authorization log add up to. The owner this module names for an account is
   the only person whose Runtime may spend it. *)

(** The owners of the provider accounts that the provider account records of
    [authz.jsonl] add up to (design 4.2, plan D1-1). {!Authz_state} keeps one
    of these as its field and hands it every provider account record of a
    bootstrapped log.

    {b Who may write.} An active human principal links an account for
    themselves. A service, the local operator, and the system authors link
    none: a person links a subscription through their own sign-in (design
    5.4).

    {b One id.} A provider account id names one account for good: once linked,
    it keeps its owner, and no record links it again. *)

type t

val empty : t

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
