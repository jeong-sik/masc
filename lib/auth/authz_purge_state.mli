(* HIGH-RISK-UNREVIEWED: this is what the purge records of the authorization log
   add up to. A target that this module holds as pending or purged is not read
   again. An account is not read from the start of its purge on, whatever
   became of the purge, a failure too ({!Authz_state.provider_account_status}).
   A target no purge record names reads as if no purge had begun. *)

(** Where the purge of each target stands (design 8.5, plan S1b-3c, RFC
    a-persons-api-key-is-their-own-provider-account 3.6): what the last purge
    record of the target says (design 8.5-6). {!Authz_state} keeps one of
    these as its field and hands it every purge record of a bootstrapped log.

    {b Who may write.} An active human principal starts the purge of a target
    they own. The system maintenance ends it: it deletes what the target names
    and writes whether that went. A service, the local operator, and the
    other system authors write no purge record.

    {b Order.} A purge starts when the target has none, or when the last one
    failed and its owner asks again. It does not start again while one is
    pending or once one went through. A pending purge ends as [Purged] or
    [Purge_failed]. A purge that went through ends once more when a restore
    brought back what it deleted and the maintenance deleted that again
    (design 8.5-6), and that end may fail. A failed purge ends only by a new
    start. The order is the same for a conversation and for an account.

    {b Owner.} The target names its owner, and this module checks that the
    author is that owner.
    - Whether a conversation is one of the owner's is for the caller: the
      records of conversations are not in the log.
    - The records of accounts are in the log, so the owner an account target
      names is checked against the record that linked the account
      ([account_owner] of {!apply}). An account that no record linked is
      owned by no one. *)

(** Where the purge of a conversation stands. *)
type conversation_status =
  | Pending of { earlier_vendor_copy : Authz_purge_event.vendor_copy option }
      (** Started and not ended. [earlier_vendor_copy] is what the failed
          purge before it wrote of the vendor copy, when its owner started this
          one after a failure, and [None] when no purge of the target failed
          before. *)
  | Purged of { vendor_copy : Authz_purge_event.vendor_copy }
  | Failed of
      { failed_stage : Authz_purge_event.conversation_failed_stage
      ; vendor_copy : Authz_purge_event.vendor_copy
      }

(** Where the purge of an account stands. *)
type account_status =
  | Account_pending  (** Started and not ended. *)
  | Account_purged
  | Account_failed of { failed_stage : Authz_purge_event.account_failed_stage }

type t

val empty : t

(** The status of the conversation, or [None] when no purge of it has
    started. *)
val find_conversation : t -> Authz_purge_event.conversation -> conversation_status option

(** Each conversation a purge record names, with its status, in the order of
    the conversations. *)
val conversations : t -> (Authz_purge_event.conversation * conversation_status) list

(** The status of the account, or [None] when no purge of it has started. *)
val find_account : t -> Authz_purge_event.account -> account_status option

(** Each account a purge record names, with its status, in the order of the
    accounts. *)
val accounts : t -> (Authz_purge_event.account * account_status) list

type refusal =
  | Not_the_owner of
      { target : Authz_purge_event.target
      ; author : Authz_types.User_id.t
      }
      (** A principal starts the purge only of a target they own: the target
          names another owner, or it is an account that the log links to
          another person or to no one. This refusal comes before the status of
          the target, so it says nothing of the purge of another's target. *)
  | User_not_active of Authz_types.User_id.t
      (** No active principal has this id: it never joined, or it is disabled
          or deleted. *)
  | Already_pending of Authz_purge_event.target
  | Already_purged of Authz_purge_event.target
  | Not_started of Authz_purge_event.target
      (** The end of a purge that is neither pending nor gone through: none
          started, or the last one failed and its owner has not asked again. *)
  | Not_a_human of Authz_types.Principal.t  (** A service owns nothing to purge. *)
  | Ended_by_a_principal of Authz_types.User_id.t
      (** A principal does not end a purge: the maintenance that deletes the
          target does. *)
  | Started_by_the_maintenance of Authz_purge_event.target
      (** The maintenance does not start a purge: the owner of the target
          does. *)
  | Not_a_purge_author of Authz_records.Author.t
      (** The local operator or the system cron, which
          {!Authz_record.admits} does not let write a purge record. *)

val refusal_to_string : refusal -> string

(** What one purge record does to the purges. [is_active] says whether a
    human principal is there and active, and [account_owner] who the log
    links a provider account to. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> is_active:(Authz_types.User_id.t -> bool)
  -> account_owner:(Authz_types.Provider_account_id.t -> Authz_types.User_id.t option)
  -> Authz_purge_event.t
  -> (t, refusal) result
