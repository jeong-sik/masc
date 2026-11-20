(* HIGH-RISK-UNREVIEWED: these functions put a person's API key on disk and
   take it off. A removal that reports the key gone while it is still there
   tells the person a deletion happened that did not. *)

(** The files of a key account under the runtime root of its person (RFC
    a-persons-api-key-is-their-own-provider-account 3.3, 3.6 and 3.9): the
    home its official client runs in (when the provider is a CLI client) and
    the folder of its key files.

    Official CLI key accounts of Claude Code carry a Claude Code home
    ({!Runtime_account_home_layout.home}); HTTP provider key accounts take
    [No_home] and have no CLI account home (the same RFC, 3.9). The key
    files are where {!Runtime_account_home_layout.key_dir} says.

    The files of an account change only inside the call of the account, which
    whoever asks holds: the registration that makes them, the replacement
    that puts a new key in place, and the purge that removes them. The
    functions are called from a fiber. Their file calls go
    through {!Fs_compat.Systhread_host} and {!Fs_compat.remove_tree}, which
    choose the thread; the spelling of a path reads the runtime root
    ([Unix.realpath]) on the fiber. *)

(** Whether a key account carries an official-client account home. HTTP
    provider key accounts have no CLI client and therefore take [No_home]. *)
type home_kind =
  | Claude_home
  | No_home

(** Why the files of an account were not made. The detail of a home can name
    a path of the server, so it is for the log of the server. *)
type make_error =
  | Home_not_made of string  (** No key was written. *)
  | Key_not_written of Runtime_api_key_file.write_error
      (** The home is there. What the write left is what
          {!Runtime_api_key_file.write} says of its error. *)

(** Makes the home of [account_id] under [runtime_root] for [home]
    (defaulting to {!Claude_home}), or looks at the one that is there, and
    writes no key: the first step of {!make}, alone. For {!No_home}, checks
    that [runtime_root] exists as a safe user-owned directory without creating
    a CLI home. The runtime root is read by its real path, as every function
    of this module reads it, and is a directory of this user that no other
    user writes ({!Runtime_account_home_folder.make}).

    The replacement of a key asks for it before its record: a root or a
    home this process does not reach turns the replacement down while
    nothing is recorded. The detail is for the log of the server: it can
    name a path of the server. *)
val make_home
  :  ?home:home_kind
  -> runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> (unit, string) result

(** Makes the home of [account_id] ({!make_home}) and then writes [key] as
    the key of [generation] ({!Runtime_api_key_file.write}). The home comes
    first, so an account whose key file is there has its home when [home] is
    {!Claude_home}; for {!No_home}, only [runtime_root] and the key file
    exist.

    It makes the files of an account that has none: a registration calls it
    once, inside the call of the account it has just recorded. After an
    error there, nothing under the id is a key the account was given, and
    whoever asked removes the account with what is under its id
    ({!remove}). A replacement calls it for the next generation of an
    account that has its files ({!replace}): the home that is there is
    looked at and left as it is.

    {!remove} is not the undo of a call, and neither is {!remove_keys}:
    each takes the key of every generation. On an account whose files are
    there, an error says what this call did. [Key_not_written
    Generation_taken] says it wrote no key and changed none: the key in
    place is the one that was there, and a removal after it takes that key
    away. A replacement asks for that after its record ({!remove_keys}),
    where the key before is not read any more. *)
val make
  :  ?home:home_kind
  -> runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> generation:Authz_types.Key_generation.t
  -> Runtime_api_key_file.key
  -> (unit, make_error) result

(** The error in words, for the log of the server: it can name a path of the
    server, and it holds nothing of the key. *)
val make_error_detail : make_error -> string

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
    link is removed and not followed. A path that leads through something
    that is no folder names nothing, and is removed already too. Each folder
    is looked at after its removal, and the folder it was in is synced
    ([fsync]). A folder that went and whose parent was not synced is
    reported as not removed; the removal asked again finds it gone and syncs
    again. *)
val remove
  :  ?home:home_kind
  -> runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> (unit, remove_error) result

(** Removes the folder of the keys of [account_id] with everything in it, as
    {!remove} does first, and leaves its home. A replacement whose key was
    not stored asks this (RFC
    a-persons-api-key-is-their-own-provider-account 3.7): the account is to
    read no key then, whatever the write left in the folder. A later write
    makes the folder again ({!make}). Under a runtime root that is not there
    it removes nothing and makes nothing. [Error] when the folder is still
    there, was not looked at, or went while the folder it was in was not
    synced; the detail can name a path of the server. What is in the folder
    goes in no order of its own and the first that does not go ends the
    removal, so a file that could have gone can stay beside it. *)
val remove_keys
  :  runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> (unit, string) result

(** Whether something has the name of the folder of the keys of [account_id]
    or (when [home] is {!Claude_home}) of its home under [runtime_root], a link
    included. A restore of a backup brings back the files of an account whose
    removal went through, and the start of the server asks this of each such
    account. [Error] when a name could not be looked at; the detail can name
    a path of the server. *)
val present
  :  ?home:home_kind
  -> runtime_root:string
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
    reading: an account whose registration, replacement or removal is under
    way can read [Key_missing] for that moment. *)
val key_state
  :  runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> generation:Authz_types.Key_generation.t
  -> key_state

(** {1 The replacement of a key}

    RFC a-persons-api-key-is-their-own-provider-account 3.7: the record of
    the new generation is written first, then the key file of that
    generation, then every other file of the folder of the keys goes. A
    reader opens the file of the generation the state names and no other, so
    a file of another generation is a key nothing reads, kept on disk. *)

(** What a look at the folder of the keys of an account did. *)
type other_keys_swept =
  { gone : int  (** How many of its other files went. *)
  ; stayed : string option
      (** The first, in the order of the names, that is still there. The
          detail can name a path of the server, so it is for the log of
          the server. *)
  }

(** Removes everything in the folder of the keys of [account_id] but the key
    file of [generation]: the key of any other generation, and a file a
    write did not put in place. A link is removed and not followed, and so
    is a folder with what is in it.

    Each is tried in the order of the names, whatever became of the one
    before it, so [gone] and [stayed] are both said of one look. Asked
    again, it finds what went gone and tries what stayed.

    A folder of keys that is not there holds nothing, and neither does a
    runtime root that is not there. [Error] is a folder that was not looked
    at: what stands in its place is no folder, a link among them, and is
    not read and is left, or its names could not be read, or the runtime
    root could not be looked at, or no key file is spelled under it. The
    detail is for the log of the server too. The key file of [generation] is not looked
    at, so this says nothing of whether the account has its key
    ({!key_state}).

    The start of the server asks this of each key account, for the
    generation its record names, inside the call of the account. *)
val remove_other_keys
  :  runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> generation:Authz_types.Key_generation.t
  -> (other_keys_swept, string) result

(** What became of the other files of the folder of the keys once the new
    key was in place. *)
type other_keys =
  | Other_keys_removed
  | Other_keys_left of string
      (** The new key is in place and is the one read. A file of the folder
          stayed, or the folder was not looked at ({!remove_other_keys});
          the detail is for the log of the server. *)

(** Puts [key] in place as the key of [generation] of [account_id]
    ({!make}), and then removes the other files of the folder of its keys
    ({!remove_other_keys}).

    [generation] is the one the record of the replacement has just named,
    so a use of the account reads the file of that name from that record
    on. After an error nothing was removed, and what the write left is what
    {!make} says of its error: after [Key_not_written (Not_written _)] the
    key may be in place, and after the others it is not.
    [Key_not_written Generation_taken] says a file of [generation] was there
    before the call, in place or beside the place, which no replacement of
    this server wrote: the record of a generation is written once, before
    its file. In place, it is what the account reads. So the caller of a
    replacement that answered an error removes the folder
    ({!remove_keys}): the key of the generation before is on disk and is
    not read, and the file of [generation] is not known to be absent. *)
val replace
  :  ?home:home_kind
  -> runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> generation:Authz_types.Key_generation.t
  -> Runtime_api_key_file.key
  -> (other_keys, make_error) result
