(** File_lock_eio — cooperative per-key locking via [Eio.Mutex] + [flock].

    Two-layer locking for local filesystem paths:

    + {b Eio.Mutex} (cooperative) — prevents blocking the Eio fiber
      scheduler; serialises fibers within the process so most contention
      is resolved cooperatively.
    + {b Unix.lockf F_TLOCK} (non-blocking) — preserves cross-process
      safety; acquired after the Eio.Mutex. If another process holds
      the flock the caller yields and retries.

    Distributed backend paths (non-local keys in
    [workspace_utils_ops.ml]) are not affected. *)

(** {1 Tuning constants} *)

(** Cap on tracked per-path entries. When exceeded, entries with
    [Atomic.get active = 0] older than {!stale_lock_seconds} are
    pruned. *)
val max_lock_entries : int

(** Staleness threshold for inactive entries (seconds). *)
val stale_lock_seconds : float

(** {1 Low-level flock helpers}

    Used by non-Eio systhread contexts. Prefer {!with_lock} for
    ordinary callers. *)

exception Flock_timeout of { caller : string; path : string; attempts : int }

exception Lock_file_cleanup_failed of
  { primary : exn
  ; primary_backtrace : Printexc.raw_backtrace
  ; close_error : exn
  }

exception Flock_release_failed of
  { unlock_error : exn option
  ; close_error : exn option
  }
(** Unlock and close both ran but at least one failed. Neither failure is
    discarded; [close_error = Some _] means the descriptor's final state is
    unknown and must not be retried. *)

(** Non-blocking [F_TLOCK] with retry. On success returns the open
    file descriptor holding the lock. On timeout closes the fd and
    raises {!Flock_timeout}. [clock] is accepted but ignored in this
    variant (systhread-friendly). *)
val acquire_flock_retry :
  ?clock:'a option ->
  lock_path:string ->
  mode:Unix.open_flag list ->
  perm:int ->
  ?max_attempts:int ->
  ?sleep_sec:float ->
  caller:string ->
  unit ->
  Unix.file_descr

(** Fiber-friendly wrapper around {!acquire_flock_retry}. Systhread
    is used for [openfile], [F_TLOCK], and retry sleeps (unless a
    clock is supplied, in which case [Eio.Time.sleep] yields to the
    Eio scheduler). *)
val acquire_flock_retry_cooperative :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  lock_path:string ->
  mode:Unix.open_flag list ->
  perm:int ->
  ?max_attempts:int ->
  ?sleep_sec:float ->
  caller:string ->
  unit ->
  Unix.file_descr

(** Convenience wrapper using [O_CREAT;O_WRONLY], mode [0o644],
    caller tag ["File_lock_eio"]. *)
val acquire_flock_fd :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  string ->
  Unix.file_descr

(** [release_flock_fd fd] unlocks and closes [fd]. Failures from either step
    are reported as {!Flock_release_failed}; close is attempted even if unlock
    failed. *)
val release_flock_fd : Unix.file_descr -> unit

(** {1 High-level scoped locking} *)

(** [with_mutex path f] runs [f] while holding the cooperative
    per-[path] Eio.Mutex only. Use for in-memory backends that need
    single-process fiber serialisation but have no filesystem artifact to
    flock. Before Eio starts, it uses a transition gate; an Eio caller drains
    that gate before acquiring the cooperative mutex, so the two modes never
    overlap for one key. *)
val with_mutex : string -> (unit -> 'a) -> 'a

(** [with_lock ?clock path f] runs [f] while holding both the
    cooperative Eio.Mutex and an OS-level flock on [path ^ ".lock"].
    The flock uses non-blocking F_TLOCK retries — max 200 attempts,
    ~2s total with default sleeps. A pre-Eio caller and a later Eio caller use
    the same transition gate before the latter acquires its cooperative mutex.
    *)
val with_lock :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  string ->
  (unit -> 'a) ->
  'a

val with_anchored_file_lock :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> path:string
  -> directory:Fs_compat.Anchored_dir.t
  -> name:Fs_compat.Anchored_dir.Segment.t
  -> perm:int
  -> (unit -> 'a)
  -> 'a
(** Descriptor-relative lock scoped to an anchored directory capability. It
    opens, identifies, locks, and closes one regular lock artifact as a single
    ownership unit. Same-process serialization is derived from that opened
    file's actual [(device, inode)], so hard-link aliases cannot select
    different cooperative mutexes. [path] is diagnostic only.

    The lock artifact closes in a cancellation-protected cleanup scope. If the
    close syscall reports an error, its descriptor is never retried because a
    retry could close a reused descriptor. *)

(** {1 Observability hook} *)

(** Fires after every {!acquire_flock_retry} / {!acquire_flock_retry_cooperative}
    attempt sequence completes — once per [acquire_*] invocation, with
    [outcome] = ["acquired"] or ["timeout"].

    [retries] is the number of failed [F_TLOCK] attempts before the
    final outcome (0 = succeeded on the first attempt).  [elapsed_s]
    is the wall-clock time spent in the retry loop excluding [openfile].

    Default no-op.  Wired at startup ([lib/workspace.ml]) to a Otel_metric_store
    counter ([masc_file_lock_retries_total]) and histogram
    ([masc_file_lock_acquire_seconds]) so contention storms surface in
    metrics.  [masc_process] cannot depend on [Otel_metric_store] (sub-library
    boundary), so emission goes through this Atomic ref. *)
val on_lock_attempt_fn :
  (caller:string -> retries:int -> elapsed_s:float -> outcome:string -> unit)
    Atomic.t

(** Observability hook fired on every CAS retry inside [atomic_update*].
    The lock table is shared by [prune_stale_entries] and [get_entry];
    high fiber contention (many fibers traversing the table for
    different paths) drives retry rate, the precise contention signal
    that was previously invisible. Wired at startup ([lib/workspace.ml]) to
    a no-label Otel_metric_store counter ([masc_file_lock_table_cas_retries]).
    [masc_process] cannot depend on [Otel_metric_store] (sub-library
    boundary), so emission goes through this Atomic ref. *)
val on_cas_retry_fn : (unit -> unit) Atomic.t

(** {1 Diagnostics} *)

(** Current number of tracked lock paths. *)
val lock_count : unit -> int
