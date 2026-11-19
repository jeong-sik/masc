(* HIGH-RISK-UNREVIEWED: this module puts a person's API key on the disk of the
   server and reads it back. A file that another user of the machine can read
   gives them the key. A key written over another is a key nobody asked to
   replace. *)

(** The file that holds an API key (RFC
    a-persons-api-key-is-their-own-provider-account 3.2).

    The key of a key account is in
    [<runtime root>/api-keys/<account id>/<generation>]
    ({!Runtime_account_home_layout.key_file}). The two folders are [0700] and
    the file is [0600]. The file is outside the home of the account: a client
    writes the home, and only this module writes the key file.

    One check reads every API credential file, the key file of an account and
    the file a provider declares alike ({!read_file}). *)

(** {1 A key} *)

(** A key as its owner gave it. No function prints it and none compares it. *)
type key

(** The key in [text], without the blanks around it. [None] when nothing is
    left, when a control character is in it, or when it is a JSON object or
    array, which is a credential document and not a key. Neither a prefix nor
    a length is read: the kind of a key is the kind of the account it is
    registered for. *)
val key_of_string : string -> key option

(** The characters of the key, for the one environment variable of the client
    that sends it. Not for a log, an answer or a record. *)
val value : key -> string

(** {1 Reading} *)

(** Why a credential file gives no value. *)
type file_error =
  | Relative_path
  | Not_an_owned_regular_file
      (** The path could not be read as a regular file of its folder: a link,
          a folder, or a file that changed while it was read. *)
  | Missing
  | Not_private
      (** Another user owns the file, or its group or others have a
          permission on it. *)
  | Empty
  | Json_document

(** The content of the credential file at [path], without the blanks around
    it. The file is a regular file the user of the process owns, with no
    permission for its group or for others, and its content is neither empty
    nor a JSON object or array. *)
val read_file : string -> (string, file_error) result

(** Why the key file of an account gives no key. *)
type unreadable =
  | Path_not_absolute
  | Not_a_regular_file  (** {!Not_an_owned_regular_file}. *)
  | Open_to_others  (** {!Not_private}. *)
  | Not_a_key  (** The content is not a key ({!key_of_string}). *)

type read_error =
  | Key_missing
      (** No file is at the path. The record that made the account comes
          before its file, so a process that died between the two leaves
          this. *)
  | Key_unreadable of unreadable

(** The key in the file at [path], by {!read_file}. *)
val read : string -> (key, read_error) result

(** The name of the reason in an answer: [key_missing] or [key_unreadable]. *)
val read_error_code : read_error -> string

(** Why the file gave no key, for a diagnostic of the configuration. It names
    neither the path nor anything of the content. *)
val read_error_to_string : read_error -> string

(** {1 Writing} *)

type write_error =
  | Root_unavailable of string
      (** The runtime root has no real path
          ({!Runtime_account_home_layout.key_dir}). *)
  | Folder_not_private of string
      (** The folder at this path is not a directory of the user of the
          process closed to its group and to others. *)
  | Generation_taken
      (** A file of this generation is there, or what an earlier write of it
          left. A generation is written once. *)
  | Not_written of string
      (** A system call failed. The file may be there. The detail can name a
          path of the server, so it is for the log of the server. *)

(** Writes [key] as the key of [generation] of [account_id] under
    [runtime_root], which is there.

    It makes the two folders [0700] when they are not there. It makes a file
    beside the place of the key, sets it [0600], writes the key, syncs it,
    puts it in place by a rename that replaces nothing, and syncs the folder.
    The path is spelled where the call was made, which reads the real path
    of the runtime root. On an Eio fiber the calls that make the folders and
    the file run on a system thread ({!Fs_compat.Systhread_host}).

    What an error leaves:
    - After any error the folders may be there.
    - After [Not_written] the key may be in place: the sync of the folder
      failed after the rename.
    - The file beside the place, [<generation>.tmp], holds the key until the
      rename. It is removed when a later step fails and when the rename
      meets a file ([Generation_taken]). A failure to remove it is dropped,
      and the file stays. It also stays after an exception that is no
      [Unix.Unix_error], which this function does not catch.

    A second write of a generation is [Generation_taken] only while a file
    of it is there, in place or beside the place: the write puts nothing in
    place and changes nothing that was there. After an error that left
    neither, a folder that was not private, a file that could not be made,
    or a step that failed and whose file was removed, a second write of the
    generation goes through.

    No function of this module removes the folder of an account. What
    follows an error is for whoever asked. A registration writes the first
    generation of an account it has just recorded, and after an error it
    removes the account with its folder
    ({!Runtime_key_account_files.remove}). A replacement writes the next
    generation of an account whose record already names it, and after an
    error it removes the folder of the keys
    ({!Runtime_key_account_files.remove_keys}): from that record on the key
    before is not read. Either removal takes every generation: neither is
    the undo of a write. The replacement asks for its removal after
    [Generation_taken] too. A file of the generation its record names was
    there before the call, in place or beside the place: this call wrote
    neither, and a file in place is what the account would read as its
    key. *)
val write
  :  runtime_root:string
  -> account_id:Authz_types.Provider_account_id.t
  -> generation:Authz_types.Key_generation.t
  -> key
  -> (unit, write_error) result
