(* HIGH-RISK-UNREVIEWED: this module puts a person's API key on the disk of
   the server. A wrong order leaves a key that no record names, and a line
   that is given the key writes it where the operator of the host reads it.
   Read it against RFC a-persons-api-key-is-their-own-provider-account 3.3. *)

(** The registration of a person's API key as a key account (RFC
    a-persons-api-key-is-their-own-provider-account 3.3). The caller checked
    that the integration takes a key. All of it runs inside the call of the
    account it makes ({!Runtime_account_call.one_call_of}), so no
    verification, no turn and no removal of the account runs before its
    files are there.

    + A new account id is drawn.
    + The person writes [key_linked] ({!Authz_provider_account.link_key}).
      The record comes first, so every key file has a record that names its
      account, and a removal finds every key from the records alone.
    + The runtime root of the person, the home of the account and then its
      key file are made ({!Runtime_key_account_files.make}), the key as the
      generation the record gives the account: the first.
    + When the files were not made, the same call removes the account
      ({!Server_key_account_purge.remove_in_call}).

    No client is called: whether the vendor takes the key is what a
    verification says. The key goes into its file and nowhere else. No log
    line, no error and no result of this module holds it or a part of it.

    A process that dies between the record and the files leaves a key
    account with no key file, and so does a request that is cancelled
    there: a cancellation is no error of the files, so nothing removes the
    account. It answers [key_missing] when it is used, the list of its
    owner says so, and its owner replaces its key or removes it. *)

type error =
  | Id_not_usable
      (** The id that was drawn is no account id, or a call under it runs.
          Nothing was written. *)
  | Not_recorded of Authz_provider_account.error
      (** The [key_linked] record is not in the log. Nothing was written. A
          commit that answered an error after its record went in is not
          this: the registration goes on from that record. *)
  | Files_not_made
      (** The files of the account were not all made, and its removal went
          through: nothing of the key is on the server, and the account
          answers as one that is not there. *)
  | Account_stays of
      { provider_account_id : Authz_types.Provider_account_id.t
      ; removal : Server_key_account_purge.error
      }
      (** The files of the account were not all made, and its removal did
          not go through. The records hold the account. They hold how far
          its removal went when its start was recorded; [removal] being
          [Not_started] says it was not, and then the account reads as one
          in use, with whatever of its files was made. Its owner removes it
          ({!Server_key_account_purge.remove}). *)

(** Registers [key] as a new key account of [person] on [integration_id] and
    gives the id of the account. The details of a failure go to the log of
    the server. [?home] defaults to {!Runtime_key_account_files.Claude_home};
    HTTP providers pass {!Runtime_key_account_files.No_home}. *)
val register
  :  ?home:Runtime_key_account_files.home_kind
  -> person:Server_setup_account_login.person
  -> base_path:string
  -> integration_id:Authz_types.Integration_id.t
  -> Runtime_api_key_file.key
  -> (Authz_types.Provider_account_id.t, error) result
