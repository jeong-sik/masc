(* HIGH-RISK-UNREVIEWED: these functions put a new key of a person in place
   of the one an account of theirs holds. A replacement that answers that a
   key is in place while the key before it is still the one read tells the
   person a key was retired that was not. *)

(** The replacement of the key of a key account (RFC
    a-persons-api-key-is-their-own-provider-account 3.7), in the order the
    RFC gives it:

    + The published state says the account is a key account of the person
      on which no removal began or stopped ({!Authz_state.key_to_replace}).
      It is asked before the call of the account is taken, and again inside
      it. The runtime root of the person and the home of the account are
      made or looked at there too, as the store of the key does first
      ({!Runtime_key_account_files.make_home}): under a root or a home that
      is not reached no record is written. A folder that was made there
      stays, whatever the steps after it answer.
    + The record [key_replaced] of the next generation is written
      ({!Authz_provider_account.replace_key}).
    + The key file of that generation is written, and then every other file
      of the folder of the keys of the account is removed
      ({!Runtime_key_account_files.replace}).

    The steps after the first run inside the call of the account
    ({!Server_setup_account_login.one_call_of}), where its turns, its
    verifications and its removal run too. From the record on, a use of the
    account reads the file of the new generation and no other. The account
    stays whatever becomes of its files: its Runtimes and the Keepers
    assigned to them are on it.

    The key is given to {!Runtime_key_account_files.replace} and to nothing
    else. The details of each failure go to the log of the server, and no
    line of it holds the key. *)

type error =
  | Refused of Authz_provider_account_state.refusal
      (** What the state said of the request before any record was written:
          no record and no key was changed. *)
  | Account_busy  (** A call of the account runs. Nothing was changed. *)
  | Files_not_reached
      (** The runtime root of the person or the home of the account was not
          reached, so no record was tried. No record and no key was
          changed. A folder on the way that was not there can have been
          made. *)
  | Not_recorded of Authz_provider_account.error
      (** The record did not go into the log. No key was changed. A
          replacement whose intent was written and given up blocks the
          account until the same request goes through
          ({!Authz_provider_account.replace_key}). *)
  | Key_not_stored
      (** The record went in and the key of its generation was not put in
          place, or is not known to stay there. The folder of the keys of
          the account was then removed, with the key before in it, so the
          account reads [key_missing] until a later replacement goes
          through. A folder that did not go is in the log of the server,
          and what the account reads then is what a list of the accounts
          says of its key. *)

type replaced =
  { old_keys_removed : bool
      (** [false] when a file of the folder of the keys stayed beside the
          new key: a key of a generation before it can still be on disk,
          where nothing reads it. The start of the server, the next
          replacement and a removal of the account take it away. *)
  }

val replace
  :  person:Server_setup_account_login.person
  -> base_path:string
  -> Authz_types.Provider_account_id.t
  -> Runtime_api_key_file.key
  -> (replaced, error) result

(** Removes, for every key account of the records, the files of the folder
    of its keys that are not the key of the generation the records say (the
    same RFC, 3.7): what a replacement that could not remove them left, and
    what a replacement that a stopped server did not end left. The start of
    the server runs it, and so does the start of the preview.

    The records are read where the zone can be trusted ({!Authz_zone.read}),
    as a decision made without a commit reads them, and a zone that cannot
    be is not acted on. Such a zone stays so until a restart, so the first
    account that finds it so is the last one asked about, and the log says
    it once.

    A log that went back alone stops the start before this runs. A log and
    an external store that went back together are not told from ones that
    did not: the files of a generation after the one their records say go
    too. The file of the generation they say went at the replacement after
    it, so the account reads no key until its key is sent again. Where that
    replacement left it ([old_keys_removed] false) and no start came since,
    the file is there, and the account reads the key from before the
    replacement. An account registered after the point the files went back
    to is not in the records, so its key file is not looked at and stays.

    The accounts are those the records hold when it starts: one registered
    after that has no file a stopped server left, and its replacements
    remove their own. Each account is looked at inside its call, and the
    generation is read there. An account with a call running is left: the
    next start looks again, and so do the next replacement and the removal
    of the account. For the moment an account is looked at, another use of
    it is answered as one whose call runs.

    Nothing is made: an account with no file gets none. The account of an
    owner with no membership is not looked at, since no record names the
    folder of their files (issue #53111). How many files of an account went
    goes to the log of the server, and so does a file that stays, an
    account that was not looked at, and an exception of one account, after
    which the others are looked at. Of an account whose removal began and
    whose owner has no membership nothing is said here: a removal that is
    pending says it in its resume, and one that went through took the
    files. Cancellation and the exceptions of a
    process that cannot go on are raised. *)
val remove_left_keys : zone:Authz_zone.t -> base_path:string -> unit
