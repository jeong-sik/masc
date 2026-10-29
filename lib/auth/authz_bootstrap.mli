(* HIGH-RISK-UNREVIEWED: this module sets up an installation. It writes the
   record that says where the external store is, creates the store, and appends
   the first record of the authorization log. A bootstrap that runs on an
   installation that was already set up replaces its history. *)

(** [Fresh_bootstrap] (design 8.4): the host-local operation that sets up a new
    installation with accounts. It leaves four things behind:

    - the install record ({!Authz_install_record}) names the external store;
    - the external store exists and holds the intent of the bootstrap and its
      answer ({!Authz_external_store});
    - the authorization log holds one record, a {!Authz_mode_event} of the event
      [Fresh_bootstrap], written by the local operator;
    - the high-water mark of that installation is [Matches]
      ({!Authz_high_water}).

    The module knows the files and nothing about the process around them. It
    does not know whether a server runs on the base path, who may run a
    bootstrap, or where the workspace id comes from. It must be called from an
    Eio fiber. It opens the log and the store itself for the length of the call
    and keeps nothing between two calls: each call reads the files anew.

    The work is two steps. {!prepare} checks and opens, {!write} writes.
    {!fresh_bootstrap} is the two in a row. The steps are separate so that a
    test can change a file between them, which is the only way to make an append
    fail in the middle of a bootstrap.

    {b What {!prepare} checks and opens.} Nothing is written until all of this
    holds, with the exceptions that every start shares: opening a file cuts a
    last line that never ended and makes the lock file next to the file, and
    opening the log makes the directory [<base path>/.masc/auth]. The cut applies
    to the store that the install record names as well, so a refused call can
    leave that store shorter by a torn line.
    - The path of the store is absolute, holds no NUL byte, and is in its normal
      form: no empty, [.] or [..] segment and no separator at the end. It is not
      the install record, and it is not inside the base path or inside the
      directory of the log, which a link can put outside the base path. The log,
      its lock file and the rest of what this module writes are in those
      directories, and a store inside the base path is in every backup of it.
      The links in the path of the store are followed first, so a link to a
      folder inside the base path does not hide it. Directories are compared by
      the files they are, the device and the inode, so a mount that shows one
      directory twice, and the case of a name that exists do not hide a
      collision. A name that does not exist has no file to compare, and the
      directories above it are compared instead. The directory of the log is not
      made until the log is opened, and until then it is compared by the place
      its name leads to, after the links in the part that exists are resolved.
      The install record may not be written yet, and then its path is compared
      as spelled, after the links in the part that exists are resolved: a
      spelling that differs in the case of a name that is not there yet gets
      past. The config directory is not checked to be outside the base path.
    - A config directory is known, so the install record can be written.
    - The install record is not unreadable or corrupt. It names a store, or none.
    - The path where the store will be created holds nothing, unless the install
      record names it and it holds a regular file. A directory, a symbolic link
      (one that leads nowhere included) or a file that the record does not name
      is not opened, and the bootstrap fails (design 8.4).
    - The authorization log has no record. A torn last line is cut when the log
      is opened, as it is at every start.
    - The store that the install record names, if there is a file, is a regular
      file and reads as [Absent] over the empty log: it holds no answered event.
      A store that holds one means that the installation was set up, or that its
      log went back.

    {b What {!write} writes, in this order.}
    + The install record. It is read first and must be the one that {!prepare}
      read, or the call fails with {!Install_record_changed}: a bootstrap that
      ran in between has written it, and replacing it would point the
      installation at a store that has no answer. The record is written even
      when it names the path already, because a write that returned
      [Replaced_but_not_durable] on an earlier call left a record that is not
      known to survive a crash. A record that named another store is replaced,
      because design 8.4 lets a bootstrap replace the record of a store that
      reads as [Absent].
    + The store, when the path holds no file: the parent directory with
      [Fs_compat.mkdir_p], then the empty file with [O_EXCL] and mode 0600,
      synced with its directory. The file is not made with
      [Fs_compat.create_file_exclusive], which keeps a registry in the directory
      of the file: a process that dies while the registry is being made leaves
      one that blocks every later creation by the same owner.
    + [Aborted_intent] for the intent that an earlier bootstrap left pending. The
      log is empty, so that bootstrap never appended its record.
    + The intent of this bootstrap, then its record in the log, then the answer
      ({!Authz_external_store.entry} [Committed]), inside the zone of the store
      and, inside it, the zone of the log. A caller that enters both zones enters
      them in this order. The answer is made from the head that the append of the
      record returned, so it cannot be written before the record.

    {b After a failure.} Each write is one step, and a process that stops between
    two of them leaves a state that a second call goes on from, or that a boot
    reads (design 8.2). In order: only the install record is written, only an
    empty store is created, an intent is pending, the intent was given up and no
    new one is written, the record is in the log and the answer is missing. The
    first four are met by calling again: the call gives up the pending intent, if
    there is one, and writes a new one. The fifth is not met: the log has a
    record, so the call fails with {!Log_not_empty}, and the next boot promotes
    the intent ({!Authz_high_water.Promote}). An error from a write says which
    step failed. A failed append may or may not have reached the file, and a call
    after it reads the files and goes on from there. Cancellation and a failure
    of the thread host ([Systhread_host.Host_failed], raised by the appends as
    {!Authz_log.append} says) are not turned into errors. They end the call
    where they happen, as a crash does, and the same holds.

    {b What it does not do.} It refuses a store inside the base path, and it
    does not check more than that that the store is outside the backup of the
    base path, because it cannot know the extent of the backup. It does not hold
    the BasePath lease and does not know whether a server runs on the base path.
    The lock of the log file lasts for one operation, so a server that is running
    does not stop this call from opening the log, and the next append of that
    server fails with [Diverged]. Two bootstraps of one base path do not exclude
    each other either. Between the re-read of the install record and its write
    there is no exclusion, and two that run at once with different store paths
    can point the record at the one that loses. Nothing in this module repairs
    that. The caller runs one bootstrap at a time, where it holds the lease or
    where no server runs. The files can change between {!prepare} and {!write}:
    an install record that changed fails the re-read, a store that appeared fails
    the exclusive creation, and the zones notice a moved end ([Diverged]) and
    stop. The module does not choose the workspace id, and it takes the time of
    the record as an argument. *)

type request =
  { base_path : string  (** The base path of the installation. It must exist. *)
  ; config_dir : string option
        (** The [masc] directory of the config home of the user, as
            {!Authz_install_record.locate} takes it. [None] when it is not
            known. *)
  ; external_store : string
        (** The absolute path where the external store will be created. *)
  ; workspace_id : Authz_types.Workspace_id.t  (** The workspace of the installation. *)
  ; at_ms : int  (** The time of the record. *)
  }

type completed =
  { record_hash : Authz_record.Hash.t
        (** The hash of the record that the bootstrap appended. *)
  ; closed_intent : Authz_external_store.intent option
        (** The intent of an earlier bootstrap that was pending and that this
            call gave up. *)
  }

(** Why the path of the store cannot be used. *)
type path_problem =
  | Not_absolute
  | Holds_nul  (** No file has a name with a NUL byte: the system calls end the name there. *)
  | Not_normal
      (** The path has an empty, [.] or [..] segment, or ends with a separator.
          Write the path without them. *)
  | Inside_base_path
      (** The path is, or lies under, the base path or the directory of the log.
          The log is there. *)
  | Is_install_record  (** The path is the file of the install record of this base path. *)

type error =
  | External_store_path_invalid of
      { path : string
      ; problem : path_problem
      }
  | No_config_dir
      (** Neither [XDG_CONFIG_HOME] nor [HOME] is known, so no install record can
          be written. *)
  | Install_record_not_located of Authz_install_record.locate_error
  | Install_record_unreadable of Authz_install_record.read_error
      (** The record is unreadable or corrupt, or the config directory fails the
          test of {!Authz_install_record}. *)
  | Install_record_changed of
      { expected : string option
      ; found : string option
      }
      (** {!write} read the install record again and it is not the one that
          {!prepare} read. Nothing was written. [expected] is the store that
          {!prepare} saw named, [found] the store named now. *)
  | Path_not_inspected of
      { path : string
      ; detail : string
      }  (** The file system could not say whether the path of the store holds a file. *)
  | External_store_in_the_way of { path : string }
      (** The path holds something that cannot be taken for the store: it is not
          a regular file, or the install record does not name it. It was not
          opened. The path is that of the store to create, or that of the store
          that the install record names. *)
  | Log_not_opened of unit Authz_log.open_error
  | Log_not_empty of { lines : int }
  | External_store_not_opened of
      { path : string
      ; error : unit Authz_external_store.open_error
      }
  | Not_a_fresh_installation of
      { store : string
      ; value : Authz_high_water.t
      }
      (** The store that the install record names does not read as [Absent]
          over the empty log. [value] is [Matches], or [Mismatch] with the
          reasons, [Commit_not_in_log] in particular. *)
  | Install_record_not_written of Authz_install_record.write_error
  | External_store_not_created of
      { path : string
      ; detail : string
      }
      (** The directory or the file of the store could not be made, or the file
          was made and could not be synced. The install record was written
          before. *)
  | Store_stopped of Authz_external_store.stop
  | Log_stopped of Authz_log.stop
  | Dead_intent_not_closed of Authz_external_store.append_error
  | Intent_not_written of Authz_external_store.append_error
  | Record_not_appended of Authz_log.append_error
      (** The intent is in the store. The record may or may not be in the log. *)
  | Answer_not_written of
      { record_hash : Authz_record.Hash.t
      ; error : Authz_external_store.append_error
      }
      (** The record is in the log and the store may not hold the answer: a
          failed append can leave the line behind. The next boot reads the
          files. *)
  | Mode_event_not_built of Authz_body.error
  | Record_not_built of Authz_record.make_error
      (** The last two cannot come from a request: the labels and the ids are
          ASCII, and the local operator may write a mode event. *)

val error_to_string : error -> string

(** A request that passed every check of {!prepare}. It holds the log and the
    store open. Give it to {!write} once. *)
type prepared

(** Checks and opens. See the top of this interface for what is checked. *)
val prepare : request -> (prepared, error) result

(** Writes. See the top of this interface for what is written and in which
    order. *)
val write : prepared -> (completed, error) result

(** Sets up the installation, or says why not: {!prepare}, then {!write}. *)
val fresh_bootstrap : request -> (completed, error) result
