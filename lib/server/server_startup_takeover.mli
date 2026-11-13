type base_path_lease

type base_path_lock_rejection =
  | Base_path_canonicalization_failed of
      { base_path : string
      ; reason : string
      }
  | Base_path_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Run_directory_canonicalization_failed of
      { run_dir : string
      ; reason : string
      }
  | Run_directory_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Run_directory_creation_failed of
      { path : string
      ; reason : string
      }
  | Run_directory_untrusted_owner of
      { path : string
      ; effective_uid : int
      ; observed_uid : int
      }
  | Run_directory_insecure_permissions of
      { path : string
      ; permissions : int
      }
  | Lease_directory_creation_failed of
      { path : string
      ; reason : string
      }
  | Lease_directory_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Lease_directory_wrong_owner of
      { path : string
      ; expected_uid : int
      ; observed_uid : int
      }
  | Lease_directory_insecure_permissions of
      { path : string
      ; permissions : int
      }
  | Lease_directory_identity_changed of { path : string }
  | Runtime_directory_rejected of Fs_compat.owned_directory_chain_rejection
  | Runtime_directory_creation_failed of
      { path : string
      ; reason : string
      }
  | Lease_file_non_regular of
      { path : string
      ; kind : Unix.file_kind
      }
  | Lease_file_multiply_linked of
      { path : string
      ; links : int
      }
  | Lease_file_wrong_owner of
      { path : string
      ; expected_uid : int
      ; observed_uid : int
      }
  | Lease_identity_changed of { path : string }
  | Lease_io_failed of
      { operation : string
      ; path : string
      ; reason : string
      }
  | Announcement_port_invalid of { port : int }
      (** A port announcement was asked for, or about, a number outside
          1..65535. *)
  | Announcement_already_made of
      { path : string
      ; port : int
      }
      (** This process already announces [port] on the file; it announces
          once. *)
  | Announcement_lease_not_active of { path : string }
      (** The handle is not the active lease of this process: it was
          released, or it never was. *)
  | Announcement_port_locked of
      { path : string
      ; port : int
      ; holder : int option
      }
      (** Another process holds a lock over the byte of [port]. [holder] is
          that process when its lock is the write lock of that one byte,
          the shape of an announcement. *)

(* Only the process-local table establishes ownership identity. The recorded
   number is written after locking and may describe a previous owner or a
   different PID namespace; local process liveness cannot verify it. *)
type base_path_owner =
  | Owner_this_process of int
      (** This process already holds the lease. A second acquisition in the
          same process would take the same kernel lock, which is why the
          in-process table is consulted first. *)
  | Owner_recorded of int
      (** A number recorded in the lease, with no verified PID namespace or
          current-holder identity. It may be stale or identify another process. *)
  | Owner_unnamed
      (** The lease file carried no readable number. *)

type base_path_acquire_result =
  | Base_path_acquired of base_path_lease
  | Base_path_already_owned of { owner : base_path_owner; lock_path : string }
      (** [lock_path] is the lease file whose kernel lock was refused. The file
          identifies the contested resource, not a process in the contender's
          PID namespace. *)
  | Base_path_rejected of base_path_lock_rejection

val base_path_lock_rejection_to_string : base_path_lock_rejection -> string

val base_path_owner_pid : base_path_owner -> int option
(** The number the lease file carried, whatever became of that process. For a
    caller that only reports or compares it; a caller that tells an operator
    what to do must match on the variant instead. *)

val base_path_contention_message :
  base_path:string -> lock_path:string -> base_path_owner -> string
(** Recovery guidance shared by HTTP and stdio entrypoints. *)

val lease_run_dir :
  Host_config.base_path_lease_root ->
  base_path:string ->
  (string, base_path_lock_rejection) result
(** The run root to pass as [run_dir] for [base_path]. [Beside_base_path] is
    [<canonical base_path>/.masc-owner], made with mode [0700] when missing; it
    sits beside [.masc] so deleting [.masc] state does not drop a live owner's
    lease. [Lease_dir_override] is returned as given. *)

(** Acquire the process-lifetime owner lease below a current-UID-owned [0700]
    private directory in [run_dir] ({!lease_run_dir} names it), then establish
    and validate [<base_path>/.masc]. A group- or world-writable [run_dir] is
    accepted only when its sticky bit prevents other UIDs from renaming the
    private directory. No fallback directory is selected.

    The effective UID is the host trust principal: the private directory blocks
    mutation by other UIDs, while processes already running as that UID are in
    the same host authority domain. Acquisition revalidates directory and file
    identities at every commit boundary and fails closed on an observed change.
    The retained lease descriptor does not make later path-based persistence
    descriptor-relative; the residual lifetime boundary is tracked by #24344. *)
val acquire_base_path_lock :
  run_dir:string ->
  string ->
  base_path_acquire_result

val acquire_owner_lease :
  Host_config.base_path_lease_root -> string -> base_path_acquire_result
(** [acquire_base_path_lock] under {!lease_run_dir}. A root that cannot be
    made is [Base_path_rejected]. *)

type base_path_wait_refusal =
  | Another_replacement_waits of
      { waiter : base_path_owner
          (** The number the waiter file records, like a lease owner's. *)
      ; waiter_path : string
      }
      (** Another process already waits for this workspace. A second waiter
          would queue behind whichever process the kernel hands the lease to
          next, so it is refused instead. *)

(** {!acquire_base_path_lock}, except that a lease another process holds is
    waited for instead of returned as [Base_path_already_owned]. It first
    takes [<lease>.waiter] with [F_TLOCK], so only one process waits for a
    workspace; a second one gets [Error Another_replacement_waits] at once.
    Then [on_wait] hears the number the lease file records, and the process
    sleeps in [lockf] until the kernel grants the lock, which happens the
    moment the owner's descriptor closes. The waiter lock is released when
    this returns. Nothing is signalled and nothing ends the wait but the
    owner's exit or a signal to this process. For an owner that was already
    asked to stop, as [masc restart] does. A lease this process already holds
    is still [Base_path_already_owned].

    [on_wait] runs while this module's process-wide lease mutex is held, so
    it must not call back into this module. *)
val acquire_base_path_lock_after_owner_exits :
  run_dir:string ->
  on_wait:(base_path_owner -> unit) ->
  string ->
  (base_path_acquire_result, base_path_wait_refusal) result

val release_base_path_lease : base_path_lease -> unit

(** Preserve an active lease across the caller's next [exec]. POSIX record
    locks survive [exec] in the same process, but the lease descriptor is
    normally opened close-on-exec. The replacement runtime must immediately
    acquire the same BasePath lease through [acquire_base_path_lock]; that
    same-process acquisition registers its ordinary process-lifetime handle.

    This capability is intentionally narrow: it does not transfer ownership to
    a child process and rejects stale or foreign handles. *)
val prepare_base_path_lease_exec_handoff :
  base_path_lease ->
  (unit, base_path_lock_rejection) result

module For_testing : sig
  (** Immutable synchronization boundaries around the external lease open and
      the final identity checks. Production acquisition closes over no-op
      functions; no mutable test hook is reachable from production callers.
      [before_lease_commit] runs immediately before [lockf] with the freshly
      opened lease descriptor and defaults to a no-op: it exists so tests can
      deterministically fail the lock commit (for example by closing the
      descriptor) and exercise the rejection's descriptor cleanup. *)
  val acquire_base_path_lock
    :  ?before_lease_commit:(Unix.file_descr -> unit)
    -> before_lease_open:(unit -> unit)
    -> before_commit_identity_check:(unit -> unit)
    -> before_runtime_identity_check:(unit -> unit)
    -> run_dir:string
    -> string
    -> base_path_acquire_result

  (** The v2 (st_dev, st_ino)-digest lease file name of an already-canonical
      BasePath, creating its private parent directory if needed. Name-only:
      nothing is opened or locked. *)
  val lease_path : run_dir:string -> canonical_base_path:string -> string
end

type owner_capture_error =
  | Owner_lease_rejected of base_path_lock_rejection
  | Owner_identity_unavailable of Owner_process_identity.error
  | Current_process_owner

val owner_capture_error_to_string : owner_capture_error -> string
(** Why the owner of a lease was not captured, as a clause for the sentence
    of a command: the rejection of the lease in its own words, or what the
    kernel did not give of the process that holds it. *)

val capture_existing_owner :
  run_dir:string -> base_path:string -> (Owner_process_identity.t, owner_capture_error) result
(** Validate the selected workspace's private lease and capture its kernel lock
    owner. This never signals a process or trusts the PID file. Before using the
    returned handle to signal, the caller must have an explicit restart
    selection and the authority the server takes its stop from. For the server
    of a single user that is authentication as the admin of that workspace.
    For the account server of a multi-account installation it is the
    authority of the host, the effective UID that could open this private
    lease ({!Server_upgrade_preparation.stop_account_server}). Does not close
    this process's own lease. *)

val lease_file_present :
  Host_config.base_path_lease_root -> base_path:string -> (bool, base_path_lock_rejection) result
(** Whether the lease file of [base_path] is there for the effective user,
    read without making anything. {!lease_run_dir} makes the run directory,
    and {!capture_existing_owner} makes the private lease directory and an
    empty lease file. A BasePath whose lease file was never made was never
    held, so a command that must leave a BasePath as it found it asks this
    first and reads the owner only on [true].

    [false] when the BasePath, the run directory, the private lease directory
    or the lease file is not there. [true] when the lease file is there, and
    when an entry on the way is there and is no directory: the capture that
    follows refuses such an entry in its own words. After a [true] the
    capture finds nothing left to make. An [Error] when an entry could not be
    read. The path is the one {!lease_run_dir} and the capture spell, and
    nothing of an entry is judged here. *)

(** {1 The port announcements}

    Which port a server of a workspace serves, told to the host through the
    lock table of the kernel. An answer over HTTP is whatever the process
    that listens on the port says of itself, so it cannot prove which
    workspace the port belongs to. The kernel names the process that holds
    a lock.

    Each kind of server announces on a file of its own beside its lease,
    and the file stays empty: the account server of a multi-account
    installation on [<lease>.account-server], the server of a single user
    on [<lease>.single-user-server]. A reader asks the file of the kind it
    looks for, so the lock of one kind never answers a question about the
    other. The server locks one byte of its file: the byte whose position
    is the port. Another process asks the kernel with [F_GETLK] who holds
    the byte of a port.

    The record is the lock, so no number is left on disk to go stale. It
    ends when its holder exits, gives the lease up
    ({!release_base_path_lease}), or execs: the descriptor that holds it does
    not cross an exec, and {!prepare_base_path_lease_exec_handoff} carries
    the lease alone. The empty file stays.

    A process of the same effective UID can lock bytes of the file without
    the lease, as it can signal the server. So a lock says nothing by
    itself: a reader compares its holder with a process it knows by other
    means, the kernel owner of the lease ({!capture_existing_owner}) or a
    child it started. A write lock on a byte has one holder, so while a
    server announces a port no other process holds that byte, and a lock
    another process took there first stops the boot of the server
    ({!announce_account_server}). *)

val announce_account_server : base_path_lease -> port:int -> (unit, base_path_lock_rejection) result
(** Announce [port] as the port of the account server, until the lease is
    released, or the process exits or execs. Call it once, with the port
    bound. Each refusal says why, and after one nothing more is announced
    than before the call: a [port] outside 1..65535
    ([Announcement_port_invalid]), a handle that is not the active lease of
    this process ([Announcement_lease_not_active]), a second call
    ([Announcement_already_made], and the first announcement stays), a byte
    that another process holds a lock on ([Announcement_port_locked]), a
    lease path that no longer names the lease this process holds
    ([Lease_identity_changed]), and an announcement file that is not a
    regular file of this user with one name (the [Lease_file_*] refusals).
    The file is made when it is missing, and is never removed. The directory
    is not validated again as {!acquire_base_path_lock} validated it (the
    boundary of #24344). *)

val announce_single_user_server :
  base_path_lease -> port:int -> (unit, base_path_lock_rejection) result
(** {!announce_account_server} for the server of a single user, on its own
    file. A second call is a second call of this kind: an announcement of
    the account server does not refuse it. *)

val account_server_port_holder :
  run_dir:string -> base_path:string -> port:int -> (int option, base_path_lock_rejection) result
(** The process that holds the account server announcement lock of [port]
    for [base_path], as the kernel names it now. This is the read to decide
    on: no lock on another byte of the file hides or changes its answer.
    [Ok None] when no process holds a write lock on exactly that byte: no
    announcement file, a server on another port, or no account server. The
    pid proves nothing until the caller compares it (see above).

    The file is opened with the checks of the lease file, and a read makes
    no file. The announcing process is found by the identity of the file,
    under any spelling of [run_dir], and is answered through the descriptor
    that holds its lock, since closing a second one would drop the
    announcement. A [port] outside 1..65535 is an
    [Announcement_port_invalid], and a kernel that cannot be asked a
    [Lease_io_failed]. *)

val single_user_server_port_holder :
  run_dir:string -> base_path:string -> port:int -> (int option, base_path_lock_rejection) result
(** {!account_server_port_holder} on the file of the server of a single
    user: [Ok None] when no such server announces [port], whatever the
    account server announces. *)

type account_server_announcement =
  { pid : int  (** The holder of the lock, as the kernel names it. *)
  ; port : int
  }

val account_server_announcement :
  run_dir:string -> base_path:string -> (account_server_announcement option, base_path_lock_rejection) result
(** An announcement on the account server file of [base_path], for a caller
    that does not know the port: the kernel is asked about the whole file.
    It names one lock, and does not say which when several processes hold
    locks there, so an announcement can stay unseen behind the lock of
    another process. Use it to tell an operator which port to ask about, and
    decide with {!account_server_port_holder}. [Ok None] when the kernel
    names no lock, or one that is not the write lock of one byte at a port.
    The file is read as {!account_server_port_holder} reads it. *)

type single_user_server_announcement = account_server_announcement

val single_user_server_announcement :
  run_dir:string ->
  base_path:string ->
  (single_user_server_announcement option, base_path_lock_rejection) result
(** {!account_server_announcement} on the file of the server of a single
    user; decide with {!single_user_server_port_holder}. *)
