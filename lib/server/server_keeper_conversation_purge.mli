(* HIGH-RISK-UNREVIEWED: this module deletes what a person asked their Keeper
   and what it answered, and asks the vendor CLI to drop its copy on the home
   of the person's account. A wrong judgment deletes the conversation of
   another person, or keeps one its owner deleted. Read it against plan
   S1b-3c. *)

(** The deletion of a person's conversation with their Keeper (design 8.5,
    plan S1b-3c). The owner asks for it, and it runs inside the call of the
    account the conversation began on
    ({!Server_setup_account_login.one_call_of}), as each turn of the
    conversation does, so no turn of it runs meanwhile.

    + The last purge record of the conversation decides where the deletion
      starts. A deletion that went through answers as a conversation that is
      not there, and one that is pending goes on at the third step.
    + The owner writes [Purge_pending] ({!Authz_purge.start}). From this
      record on, no read shows the conversation and no turn goes on in it.
    + The copy the vendor keeps. Claude Code is asked to purge the project
      the turns started in ({!Runtime_claude_code.purge_project}) when a
      client of the conversation may have been started with a message. The
      CLI exits 1 alike for a project it holds nothing of and for a failure,
      so it is not asked when no client was.
    + The directory of the conversation is removed
      ({!Server_keeper_conversation.remove}).
    + The system maintenance writes [Purged] when the directory is gone, or
      [Purge_failed] when it is still there. *)

(** Where the deletion of a conversation stands. *)
type standing =
  | Kept  (** No deletion of it began. *)
  | Deletion_failed
      (** Its last deletion left its directory, or the zone gave up the record
          of its start and blocks it (design 8.3). A list shows it so. Nothing
          reads it, and no turn goes on in it. A deletion by its owner ends
          it, and closes the block. *)
  | Deleted  (** A deletion of it is pending or went through. Nothing shows it. *)

(** Where the deletion of the conversation of [person] stands, on what the
    zone last published ({!Authz_zone.snapshot}): the purge record of the
    conversation and the block of its subject. The records of a deletion
    are written before it removes anything, and it runs inside the call of
    the account of the conversation: a caller inside that call reads a
    standing that holds until the call ends. *)
val standing : Server_setup_account_login.person -> Authz_types.Conversation_id.t -> standing

(** Whether the standing of the conversation is not [Kept]. *)
val deletion_began : Server_setup_account_login.person -> Authz_types.Conversation_id.t -> bool

type error =
  | Not_found
      (** No conversation of the person has this id, or its deletion went
          through. *)
  | Account_busy  (** A call of the account the conversation began on runs. *)
  | Record_unavailable of Server_keeper_conversation.error
      (** The conversations of the person were not read. Nothing was
          written. *)
  | Not_started of Authz_purge.error
      (** The [Purge_pending] record is not in the log. Nothing was deleted.
          When the zone gave the record up, the conversation stands as
          [Deletion_failed]. A commit that answered an error after its record
          went in is not this: the deletion goes on from that record. *)
  | Not_ended of Authz_purge.error
      (** The record of the end was not written. The deletion stays pending:
          nothing shows the conversation, and the next deletion of it goes
          on from the third step. *)
  | Directory_not_removed of Authz_purge_event.vendor_copy
      (** [Purge_failed] was written, with what became of the copy of the
          vendor. *)

(** Deletes the conversation of [person] with this id, and gives what became
    of the copy of the vendor. The details of a failure go to the log of the
    server. *)
val delete
  :  env:Eio_unix.Stdenv.base
  -> person:Server_setup_account_login.person
  -> base_path:string
  -> Authz_types.Conversation_id.t
  -> (Authz_purge_event.vendor_copy, error) result
