(* HIGH-RISK-UNREVIEWED: these functions put a person's API key on disk and
   take it off. A removal that reports the key gone while it is still there
   tells the person a deletion happened that did not. *)

(** The files of a key account under the runtime root of its person (RFC
    a-persons-api-key-is-their-own-provider-account 3.3 and 3.6): the home
    its client runs in and the folder of its key files.

    The home is a Claude Code home ({!Runtime_account_home_layout.home}):
    the keys of stage 1 are keys of Claude Code (the same RFC, 3.9). The key
    files are where {!Runtime_account_home_layout.key_dir} says.

    The files of an account change only inside the call of the account, which
    whoever asks holds: the registration that makes them, and the purge that
    removes them. The functions are called from a fiber and run their file
    calls on a system thread. *)

(** Why the files of an account were not made. The detail of a home can name
    a path of the server, so it is for the log of the server. *)
type make_error =
  | Home_not_made of string  (** No key was written. *)
  | Key_not_written of Runtime_api_key_file.write_error
      (** The home is there. What the write left is what
          {!Runtime_api_key_file.write} says of its error. *)

(** Makes the home of [account_id] and then writes [key] as the key of
    [generation] ({!Runtime_api_key_file.write}). The home comes first, so an
    account whose key file is there has its home.

    After an error, whoever asked removes what was made ({!remove}). *)
val make
  :  runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> generation:Authz_types.Key_generation.t
  -> Runtime_api_key_file.key
  -> (unit, make_error) result

(** What is still there after a removal that did not go through, as the
    stages of {!Authz_purge_event.account_failed_stage}. The detail can name
    a path of the server, so it is for the log of the server. *)
type remove_error =
  | Key_not_removed of string
      (** The folder of the keys is still there, or was not looked at. The
          home was not touched. *)
  | Home_not_removed of string
      (** The folder of the keys is gone, and the home is still there or was
          not looked at. *)

(** Removes the folder of the keys of [account_id] with everything in it, a
    key of any generation and a file a write did not put in place, and then
    its home. The key goes first: it is the secret, and a removal that stops
    leaves the home rather than the key.

    A folder that is not there is removed already, so a removal that stopped
    is asked again, and an account whose files were never made is removed
    too. A runtime root that is not there holds no file of any account. A
    link is removed and not followed. Each folder is looked at after
    its removal, and the folder it was in is synced, so what is reported gone
    stays gone after a crash. *)
val remove
  :  runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> (unit, remove_error) result

(** Whether something has the name of the folder of the keys of [account_id]
    or of its home under [runtime_root], a link included. A restore of a
    backup brings back the files of an account whose removal went through,
    and the start of the server asks this of each such account. [Error] when
    a name could not be looked at; the detail can name a path of the
    server. *)
val present
  :  runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> (bool, string) result

(** What a list says of the key of an account (RFC
    a-persons-api-key-is-their-own-provider-account 3.8). *)
type key_state =
  | Key_readable
      (** The file of the generation gives a key. Whether the vendor takes
          the key is what a verification says. *)
  | Key_not_read of Runtime_api_key_file.read_error
      (** What a use of the account answers ({!Runtime_api_key_file.read}):
          the file is missing, or it gives no key. A runtime root that is
          not there holds no file, so its accounts read [Key_missing]. *)
  | Key_not_looked_at of string
      (** The place of the file could not be looked at. The detail can name
          paths of the server. *)

(** Reads the key file of [generation] of [account_id] as a use of the
    account reads it, and gives nothing of the key. It makes nothing: where
    a use makes the runtime root of the person, this looks whether it is
    there. It takes no call of the account, so it says what was there at the
    reading: an account whose registration or removal is under way can read
    [Key_missing] for that moment. *)
val key_state
  :  runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> generation:Authz_types.Key_generation.t
  -> key_state
