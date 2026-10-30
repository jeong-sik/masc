(* HIGH-RISK-UNREVIEWED: this module reads and writes the file that tells a
   boot where the external store is. A record that reads as absent when it
   should not lets a boot treat a reverted installation as a new one. *)

(** The install record of one base path (design 8.4): a small file that names
    the external store, the high-water store that lives outside the backup of
    the base path.

    The record sits in the config directory of the user, outside the base
    path, so that a restore of the base path from a backup does not take it
    back in time. The module knows the file and nothing about what the
    external store holds or when a boot reads the record. It has no caller
    yet.

    {b File.} [<config dir>/authz-install-<16 hex>.json]. The hex is the start
    of the SHA-256 of the canonical base path ([Unix.realpath]), so two base
    paths of one user have two files. The file holds two members, the
    canonical base path and the absolute path of the external store. The
    reader compares the base path, so a file that was written for another base
    path and is read for this one is {!Corrupt}.

    {b Write.} {!write} replaces the file with
    [Fs_compat.save_file_atomic_strict_staged]: a temporary file with a random
    name, an fsync of its bytes, a rename, and an fsync of the directory. A
    reader sees no file or a whole one, and never reads a temporary file left
    by a write that died. [Fs_compat] does not call [F_FULLFSYNC], so the file
    survives a restart of the process, not a power cut. The file has mode
    0600. Two rules about directories come from the XDG Base Directory
    Specification: a missing directory is created with mode 0700, and a
    directory that is already there keeps its mode. So the config directory
    may be readable by others, which only shows the path of the external
    store.

    {b Config directory.} {!read} and {!write} apply one test to the config
    directory: after its symbolic links are resolved it is a directory that
    belongs to the effective uid of the process and that neither the group nor
    others can write. {!write} refuses a directory that fails the test
    ({!Config_dir_unusable}) before it writes anything, so a record that
    {!write} has put in a directory is a record that {!read} accepts there.
    The test looks at the config directory itself and not at the directories
    above it. That is the range of the owner-checked read of [Fs_compat], and
    design 8.4 says that a party who can write both the config directory and
    the base path is not stopped.

    {b Read.} {!read} gives [None] in two cases: the file is not there, or the
    config directory is not there and no component of its path is a dangling
    symbolic link. A dangling symbolic link on the way to the config
    directory, a symbolic link as the file, a directory, a file with a second
    hard link, a file that another user owns, a config directory that fails
    the test above, and any read error are {!Unreadable}. A file that is there
    and does not hold exactly the two members is {!Corrupt}. A caller never
    treats either as an absent record. The file is read with the owner-checked
    read of [Fs_compat], which checks the file and its directory before and
    after the read ([Fs_compat.load_owned_regular_file_with_snapshot]). Design
    8.4 reads the record for a [Fresh_bootstrap] and for an installation that
    has a mode event. A boot of any other installation does not call {!read},
    so a config directory that fails the test stops only those two.

    {b Blocking.} {!read} and {!write} are blocking and meant for the boot
    sequence, not for a request path. The file replacement and the read of the
    file run on a system thread when they are called from an Eio fiber, and
    the directory calls around them are plain system calls. *)

(** A record that has a place: the config directory and the canonical base
    path it belongs to. *)
type t

type located =
  | No_config_dir
      (** There is no place for a record. Reading gives [None] and writing is
          refused. *)
  | Located of t

type locate_error =
  | Base_path_unresolved of
      { base_path : string
      ; detail : string
      }  (** [Unix.realpath] failed on the base path. *)
  | Base_path_not_utf8 of { canonical : string }
      (** The canonical base path cannot be written into the JSON record. *)
  | Config_dir_not_absolute of { config_dir : string }
      (** A relative config directory names another file for every working
          directory of the process. *)

(** [locate ~config_dir ~base_path] resolves [base_path] to its canonical form
    and names the file. [config_dir] is the absolute path of the [masc]
    directory of the config home of the user, or [None] when neither
    [XDG_CONFIG_HOME] nor [HOME] is known. The module does not read the
    environment: the caller passes [config_dir]. A caller that reads [XDG_CONFIG_HOME]
    ignores a relative value and falls back to [HOME], as the XDG Base
    Directory Specification asks. [locate] refuses a relative [config_dir]
    instead of reading it as an absent record. *)
val locate : config_dir:string option -> base_path:string -> (located, locate_error) result

val locate_error_to_string : locate_error -> string

(** Where the file is expected. A config directory that is a symbolic link is
    followed when the file is opened, and this path keeps the spelling that
    was given. *)
val file_path : t -> string

type corruption =
  | Not_json
  | Wrong_members
      (** The text is JSON, but it is not an object with exactly the two
          members, both strings. *)
  | Base_path_differs of { recorded : string }
  | Store_path_not_absolute

type read_error =
  | Unreadable of
      { path : string
      ; detail : string
      }
  | Corrupt of
      { path : string
      ; reason : corruption
      }

(** The absolute path of the external store the record names, or [None] when
    there is no record. *)
val read : located -> (string option, read_error) result

val read_error_to_string : read_error -> string

type write_error =
  | No_config_dir_to_write
  | Store_path_invalid of { external_store : string }
      (** The path is not absolute, or is not valid UTF-8. *)
  | Config_dir_unusable of
      { dir : string
      ; detail : string
      }
      (** The config directory cannot be created, is not a directory, or fails
          the config-directory test that {!read} also applies. Nothing was
          written. *)
  | Not_replaced of
      { path : string
      ; detail : string
      }  (** The write failed before the rename. The old record, if any, is as it was. *)
  | Replaced_but_not_durable of
      { path : string
      ; detail : string
      }
      (** The rename happened and a later fsync failed. The new record can be
          read, and it is not known to survive a crash. The caller treats the
          write as failed and writes again. *)

(** Writes the record for [external_store], an absolute path, over any record
    the base path has, whatever that record holds. The module does not look at
    the external store. The caller keeps the rule of the design: it never
    overwrites a record whose external store already exists. *)
val write : located -> external_store:string -> (unit, write_error) result

val write_error_to_string : write_error -> string
