(** Shared admission gate for CLI provider subprocesses.

    One CLI provider call holds thousands of file descriptors for its whole
    turn, so unbounded concurrent spawns exhaust the SYSTEM file table
    (ENFILE) and take down unrelated work: keeper turns, the credential
    token index (#43258), even dune. Measured 2026-10-16 (#43259): a
    healthy [agy] turn holds ~7.5k files (7.3k preloaded project records
    plus workspace scans); a sick one held 26k-45k after walking a git
    directory full of stale watchman cookies. Nine concurrent sick turns
    drove [kern.num_files] to its 491,520 ceiling.

    This gate bounds the product mechanically. At most
    {!max_concurrent_cli_spawns} CLI turns run at once — waiters are
    suspended fibers holding no file descriptors — and any child past
    {!child_fd_ceiling} open files is failed loudly at its first protocol
    event instead of completing silently. The spawn-per-call shape stays:
    relocating workspaces outside git repositories is operator-owned, and
    the CLI's own preload behavior is upstream's; the boundary guard is
    what MASC can decide alone. *)

val max_concurrent_cli_spawns : int
(** [8]. Worst enforced case is 8 x {!child_fd_ceiling} = 128k files
    against ~430k headroom (491,520 system ceiling minus ~60k ambient
    use); the typical case is 8 x 7.5k = 60k. The incident peaked at 9
    concurrent sick turns, so 8 also sheds the observed overload shape. *)

val child_fd_ceiling : int
(** [16_000]. Twice the healthy 7.5k baseline with growth headroom,
    below the 26k sick floor: the 2026-10-16 cookie-driven turns would
    have failed here instead of completing. *)

val with_cli_spawn_slot : (unit -> 'a) -> 'a
(** [with_cli_spawn_slot f] waits for a CLI spawn slot, runs [f] under
    [Fd_accountant.observe ~kind:Provider_cli] so the concurrency
    distribution stays measurable, and releases the slot on every exit
    path. The wait is cancellation-safe: a cancelled waiter holds no
    slot. Never raises itself. *)

val active_cli_spawns : unit -> int
(** Currently held slots. Test seam and telemetry; agrees with
    [Fd_accountant.active_count ~kind:Provider_cli] over gated turns. *)

val child_fd_count :
  mgr:_ Eio.Process.mgr -> cwd:Eio.Fs.dir_ty Eio.Path.t -> pid:int -> int option
(** Best-effort open-file count of a live child process. Reads
    [/proc/<pid>/fd] where the kernel offers it (Linux); otherwise runs
    [lsof -p <pid>] and counts data lines (macOS). Returns [None] when
    the platform offers neither, the child is already gone, or the probe
    fails for any reason — callers treat [None] as "unobservable", never
    as zero. Never raises. *)

module For_testing : sig
  val count_proc_fds : pid:int -> int option
  (** Direct [/proc/<pid>/fd] read, no fallback. *)

  val count_lsof_lines : string -> int
  (** Count data lines in [lsof -p <pid>] default output: every line
      after the [COMMAND PID ...] header. *)
end
