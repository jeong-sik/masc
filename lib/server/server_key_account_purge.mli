(* HIGH-RISK-UNREVIEWED: this module takes a person's API key off the disk of
   the server. A wrong judgment removes the key of another person, or reports
   a key gone that is still there. Read it against RFC
   a-persons-api-key-is-their-own-provider-account 3.6. *)

(** The removal of a person's key account (design 8.5, RFC
    a-persons-api-key-is-their-own-provider-account 3.6). The owner asks for
    it, and it runs inside the call of the account
    ({!Runtime_account_call.one_call_of}), as each verification and
    each turn on the account does, so none of them runs meanwhile.

    The last purge record of the account decides where the removal starts.
    One that went through answers as an account that is not there, and one
    that is pending goes on at the second step. The steps are those of the
    RFC:

    + The owner writes [Purge_pending] ({!Authz_purge.start}). From this
      record on, no verification and no turn spends the account.
    + The folder of its keys and then its home are removed
      ({!Runtime_key_account_files.remove}).
    + The system maintenance writes [Purged] when both are gone, or
      [Purge_failed] with the one that stayed.

    No vendor is called: MASC made no copy of the account there, and the key
    stays valid at the vendor until the person revokes it there. *)

type error =
  | Not_found
      (** No account of the person has this id, or its removal went through. *)
  | Not_a_key_account
      (** The account holds a login. Only an account that holds a key is
          removed here. *)
  | Account_busy  (** A call of the account runs. *)
  | Not_started of Authz_purge.error
      (** The [Purge_pending] record is not in the log. Nothing was removed.
          A commit that answered an error after its record went in is not
          this: the removal goes on from that record. *)
  | Not_ended of Authz_purge.error
      (** The record of the end was not written. The removal stays pending:
          nothing spends the account, and the next removal of it, or the
          next start of the server, goes on from the second step. *)
  | Files_not_removed of Authz_purge_event.account_failed_stage
      (** [Purge_failed] was written with this stage. Nothing spends the
          account, and a removal by its owner starts again. *)

(** Removes the key account of [person] with this id. The details of a
    failure go to the log of the server. *)
val remove
  :  person:Server_setup_account_login.person
  -> base_path:string
  -> Authz_types.Provider_account_id.t
  -> (unit, error) result

(** Ends the removals a stopped server left (design 8.5-5), at the start of a
    server that serves the routes of the persons. The key is a secret, so a
    pending removal does not wait for its owner to ask again.

    An account whose removal went through and whose files a restore brought
    back is removed again, and the system maintenance records its end once
    more (design 8.5-6).

    A removal that failed waits for its owner to ask again, and so does one
    whose start the zone gave up: the log holds no record of it to end. A
    pending one whose owner has no membership is left, since nothing names
    the folder of their files.

    Each removal runs inside the call of its account, and the status is read
    again there. One whose account has a call running is left to the next
    start or to its owner. What happens goes to the log of the server. An
    exception of one removal goes there too and leaves that removal as it
    is: the others go on, and the server keeps serving. Cancellation and the
    exceptions of a process that cannot go on are raised. *)
val resume : zone:Authz_zone.t -> base_path:string -> unit

(** {!remove} for a caller that holds the call of the account: the
    registration whose files were not made removes the account it had just
    recorded, in the same call (RFC
    a-persons-api-key-is-their-own-provider-account 3.3,
    {!Server_key_account_registration}). It reads whose the account is and
    of which kind itself, as {!remove} does, so an id of a login account or
    of another person is answered [Not_a_key_account] or [Not_found] and
    nothing is removed. [in_call] is not tied to [id] by its type: the
    caller hands the witness of the call of that account. [Account_busy] is
    not answered. *)
val remove_in_call
  :  Runtime_account_call.t
  -> person:Server_setup_account_login.person
  -> base_path:string
  -> Authz_types.Provider_account_id.t
  -> (unit, error) result
