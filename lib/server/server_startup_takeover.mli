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
val capture_existing_owner :
  run_dir:string -> base_path:string -> (Owner_process_identity.t, owner_capture_error) result
(** Validate the selected workspace's private lease and capture its kernel lock
    owner. This never signals a process or trusts the PID file. Before using the
    returned handle, the caller must authenticate as that workspace's admin and
    obtain explicit restart selection. Does not close this process's own lease. *)

(** {1 The account server announcement}

    Which port the account server of a workspace serves, told to the host
    through the lock table of the kernel. The probes of that server say
    nothing of the process or of the workspace
    ({!Server_accounts}), so no HTTP answer tells a command line which
    workspace a port belongs to. The server locks one byte of
    [<lease>.account-server], a file beside its lease that stays empty: the
    byte whose position is the port. Another process reads the holder and
    the position with [F_GETLK].

    The record is the lock. It is there while its holder lives and holds the
    lease, and gone the moment either ends, so no number is left on disk to
    go stale. A process of the same effective UID can take such a lock
    without the lease, as it can signal the server: the readers compare the
    holder with a process they know by other means, the kernel owner of the
    lease ({!capture_existing_owner}) or a child they started. *)

type account_server_announcement =
  { pid : int  (** The holder of the lock, as the kernel names it. *)
  ; port : int
  }

val announce_account_server : base_path_lease -> port:int -> (unit, base_path_lock_rejection) result
(** Announce [port] for the life of the lease: {!release_base_path_lease}
    withdraws it before it gives the lease up, and the kernel does at the
    exit of the process. Call it once, with the port bound. A handle that is
    not the active lease of this process, a second call, a [port] outside
    1..65535, a lease path that no longer names the lease this process
    holds, and an announcement file that is not a regular file of this user
    with one name are refused, and nothing is announced. The directory is
    not validated again as {!acquire_base_path_lock} validated it (the
    boundary of #24344). *)

val account_server_announcement :
  run_dir:string -> base_path:string -> (account_server_announcement option, base_path_lock_rejection) result
(** What is announced for [base_path] now. [Ok None] when no process holds
    the announcement: no owner, an owner that is not an account server, or
    one that has not bound its port. The file is opened with the checks of
    the lease file and never made. A process asking about a lease it holds
    itself is answered from its own table, since opening the file would
    drop its lock. A lock that is not at a port, or that the kernel cannot
    be asked about, is a [Lease_io_failed]. *)
