(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   starts or ends the purge of what a person owns. A purge that reads as ended
   while what it names is still on disk tells the person a deletion happened
   that did not. *)

(** The body of a purge record (design 8.5, plan S1b-3c, RFC
    a-persons-api-key-is-their-own-provider-account 3.6): the start of the
    purge of one target, and its end.

    {b Target.} What a person owns and deletes, named by its owner and its id.
    - A conversation of a person with one of their Keepers. The purge deletes
      the folder of the conversation, and asks the vendor CLI to drop the copy
      it keeps of the conversation.
    - A provider account of a person. The purge deletes the key the account
      holds and the home of the account.

    {b Events.} [Purge_pending] starts the purge. From it on, the target is not
    read (design 8.5-2). [Purged] says that what the target names is gone, and
    [Purge_failed] that it is not, at the stage that failed. What else the two
    say follows the kind of the target (design 8.5-7): of a conversation, what
    became of the vendor copy; of an account, nothing, because MASC makes no
    copy of an account at the vendor.

    {b Body.} An object whose first member is [event], with the members in
    this order.
    - [{"event":"pending","target":T}], of either kind.
    - Of a conversation: [{"event":"purged","target":T,"vendor_copy":V}] or
      [{"event":"failed","target":T,"failed_stage":S,"vendor_copy":V}]. [T] is
      [{"type":"keeper_conversation","owner":...,"conversation_id":...}], the
      shape that {!Authz_external_store} writes for the same subject. [V] is
      [removed], [none], or [may_remain], and [S] is [folder_not_removed].
    - Of an account: [{"event":"purged","target":T}] or
      [{"event":"failed","target":T,"failed_stage":S}]. [T] is
      [{"type":"provider_account","owner":...,"provider_account_id":...}], and
      [S] is [key_not_removed] or [home_not_removed].

    The labels are on disk, and renaming one orphans every record written with
    it. A body with other members, the same members in another order, a
    member of another type, or the members of the other kind of target is
    refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_purge_state} decide that), nor in which order the events may
    come. *)

type conversation =
  { owner : Authz_types.User_id.t
  ; conversation_id : Authz_types.Conversation_id.t
  }

type account =
  { owner : Authz_types.User_id.t
  ; provider_account_id : Authz_types.Provider_account_id.t
  }

type target =
  | Keeper_conversation of conversation
  | Provider_account of account

val conversation_compare : conversation -> conversation -> int
val account_compare : account -> account -> int
val target_equal : target -> target -> bool

(** The subject that the start of a purge of the target is an intent on
    (design 8.2). An account is the credential of its id, the subject a turn
    decision already stands on ({!Authz_decision}), so a start that the log
    gave up blocks the turns of the account (design 8.3). *)
val subject : target -> Authz_records.Subject.t

(** What became of the copy that the vendor CLI keeps of the conversation. *)
type vendor_copy =
  | Removed  (** The CLI was asked to drop it and exited 0. *)
  | No_copy
      (** No turn of the conversation reached the CLI, so it holds none and
          was not asked. *)
  | May_remain
      (** A turn reached the CLI, and the CLI was too old to be asked or did
          not exit 0. *)

(** The label of the record: [removed], [none] or [may_remain]. The route
    that deletes a conversation answers with it too. *)
val vendor_copy_label : vendor_copy -> string

type conversation_failed_stage =
  | Folder_not_removed  (** The folder of the conversation is still there. *)

type account_failed_stage =
  | Key_not_removed  (** The folder of the keys of the account is still there. *)
  | Home_not_removed
      (** The keys are gone, and the home of the account is still there. *)

(** The end of a purge that went through, with what its kind says of it. *)
type purged =
  | Conversation_purged of
      { conversation : conversation
      ; vendor_copy : vendor_copy
      }
  | Account_purged of { account : account }

(** The end of a purge that did not go through, with what its kind says of
    it. *)
type failed =
  | Conversation_not_purged of
      { conversation : conversation
      ; failed_stage : conversation_failed_stage
      ; vendor_copy : vendor_copy
      }
  | Account_not_purged of
      { account : account
      ; failed_stage : account_failed_stage
      }

type t =
  | Purge_pending of { target : target }
  | Purged of purged
  | Purge_failed of failed

val target : t -> target
val equal : t -> t -> bool

(** The body of the record. The error cannot come from a value of {!t}. It is
    returned because {!Authz_body.t} can only be made through functions that
    check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of a purge record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event of one kind of
          target, in their order, with [target] an object of [type], [owner],
          and the id of its kind, and every other member a string. *)
  | Unknown_target of string  (** The [type] of the target is not a label of one. *)
  | Invalid_owner of Authz_id.error
  | Invalid_conversation_id of Authz_id.error
  | Invalid_provider_account_id of Authz_id.error
  | Unknown_failed_stage of string
      (** Not a stage that the purge of a target of this kind fails at. *)
  | Unknown_vendor_copy of string

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, the
    target is one, the members are those of its kind, and then the stage and
    the vendor copy are ones. *)
val of_body : Authz_body.t -> (t, error) result
