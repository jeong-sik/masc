(* HIGH-RISK-UNREVIEWED: this is what the Runtime records of the authorization
   log add up to. The owner this module names for a Runtime is the person whose
   subscription it spends and whose Self grant it carries. *)

(** The Runtimes that the Runtime records of [authz.jsonl] add up to (design
    4.2-4.3, plan D1). {!Authz_state} keeps one of these as its field and hands
    it every Runtime record of a bootstrapped log.

    {b Who may write.} An active human principal makes a Runtime for
    themselves, on a provider account they own. An Admin makes none for
    another person, nor on the account of another person (design 4.2). A
    service, the local operator, and the system authors make none.

    {b One id.} A Runtime id names one Runtime for good, and a grant id one
    grant: once made, a Runtime keeps its owner, its account, and its Self
    grant, and no record makes it again or names its grant again. *)

type runtime =
  { owner : Authz_types.User_id.t
  ; provider_account_id : Authz_types.Provider_account_id.t
  ; self_grant : Authz_types.Grant_id.t
  ; self_effects : Authz_types.Effect.Set.t  (** What the Self grant allows. *)
  }

type t

val empty : t

(** The Runtime, if it was made. *)
val find : t -> Authz_types.Runtime_id.t -> runtime option

(** The owner of the Runtime, if it was made. *)
val owner : t -> Authz_types.Runtime_id.t -> Authz_types.User_id.t option

(** The Runtimes this person owns, in the order of their ids. *)
val owned_by : t -> Authz_types.User_id.t -> (Authz_types.Runtime_id.t * runtime) list

type refusal =
  | Already_made of Authz_types.Runtime_id.t
  | Grant_named_before of Authz_types.Grant_id.t
  | Made_for_another of
      { author : Authz_types.User_id.t
      ; user_id : Authz_types.User_id.t
      }
      (** A principal makes a Runtime only for themselves, an Admin too
          (design 4.2). *)
  | Account_not_theirs of
      { provider_account_id : Authz_types.Provider_account_id.t
      ; user_id : Authz_types.User_id.t
      }
      (** The account was never linked, or it was linked by another person: a
          Runtime spends only an account of its owner (design 4.2). *)
  | User_not_active of Authz_types.User_id.t
      (** No active principal has this id: it never joined, or it is disabled
          or deleted. *)
  | Not_a_human of Authz_types.Principal.t
  | Not_a_runtime_author of Authz_records.Author.t
      (** The local operator or a system author, which {!Authz_record.admits}
          does not let write a Runtime record. *)

val refusal_to_string : refusal -> string

(** What one Runtime record does to the Runtimes. [is_active] says whether a
    human principal is there and active, and [account_owner] who owns a
    provider account, if anyone does. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> is_active:(Authz_types.User_id.t -> bool)
  -> account_owner:(Authz_types.Provider_account_id.t -> Authz_types.User_id.t option)
  -> Authz_runtime_event.t
  -> (t, refusal) result
