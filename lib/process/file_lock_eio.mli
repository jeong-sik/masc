(** File_lock_eio — cooperative per-key locking via [Eio.Mutex] + [flock].

    Two-layer locking for local filesystem paths:

    + {b Eio.Mutex} (cooperative) — prevents blocking the Eio fiber
      scheduler; serialises fibers within the process so most contention
      is resolved cooperatively.
    + {b Unix.lockf F_TLOCK} (non-blocking) — preserves cross-process
      safety; acquired after the Eio.Mutex. If another process holds
      the flock the caller yields and retries.

    Distributed backend paths (non-local keys in
    [room_utils_ops.ml]) are not affected. *)

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

(** Non-blocking [F_TLOCK] with retry. On success returns the open
    file descriptor holding the lock. On timeout closes the fd and
    raises [Failure]. [clock] is accepted but ignored in this variant
    (systhread-friendly). *)
val acquire_flock_retry
  :  ?clock:'a option
  -> lock_path:string
  -> mode:Unix.open_flag list
  -> perm:int
  -> ?max_attempts:int
  -> ?sleep_sec:float
  -> caller:string
  -> unit
  -> Unix.file_descr

(** Fiber-friendly wrapper around {!acquire_flock_retry}. Systhread
    is used for [openfile], [F_TLOCK], and retry sleeps (unless a
    clock is supplied, in which case [Eio.Time.sleep] yields to the
    Eio scheduler). *)
val acquire_flock_retry_cooperative
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> lock_path:string
  -> mode:Unix.open_flag list
  -> perm:int
  -> ?max_attempts:int
  -> ?sleep_sec:float
  -> caller:string
  -> unit
  -> Unix.file_descr

(** Convenience wrapper using [O_CREAT;O_WRONLY], mode [0o644],
    caller tag ["File_lock_eio"]. *)
val acquire_flock_fd
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> string
  -> Unix.file_descr

(** [release_flock_fd fd] unlocks (best-effort) and closes [fd]. *)
val release_flock_fd : Unix.file_descr -> unit

(** {1 High-level scoped locking} *)

(** [with_mutex path f] runs [f] while holding the cooperative
    per-[path] Eio.Mutex only. Use for in-memory backends that need
    single-process fiber serialisation but have no filesystem
    artifact to flock. *)
val with_mutex : string -> (unit -> 'a) -> 'a

(** [with_lock ?clock path f] runs [f] while holding both the
    cooperative Eio.Mutex and an OS-level flock on [path ^ ".lock"].
    The flock uses non-blocking F_TLOCK retries — max 200 attempts,
    ~2s total with default sleeps. *)
val with_lock
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> string
  -> (unit -> 'a)
  -> 'a

(** {1 Diagnostics} *)

(** Current number of tracked lock paths. *)
val lock_count : unit -> int
