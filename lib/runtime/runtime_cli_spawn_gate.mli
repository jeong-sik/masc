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
    {!child_fd_ceiling} open files is failed loudly instead of completing
    silently. The spawn-per-call shape stays: relocating workspaces
    outside git repositories is operator-owned, and the CLI's own preload
    behavior is upstream's; the boundary guard is what MASC can decide
    alone.

    Scope: the machinery is provider-agnostic, but only Antigravity turns
    are wired through it today — that is where the incident came from.
    Other CLI runtimes (Claude Code, Codex, Muse) still spawn ungated; wiring
    them needs their own fd profiles, not this ceiling. A slot spans the
    whole turn including unbounded tool phases, so {!max_concurrent_cli_spawns}
    is also the number of turns that may wait on tools at once.

    Deadlock contract: a turn holding a slot must never synchronously wait
    for another gated turn, and the gate is not reentrant — a fiber that
    re-enters while holding a slot waits for itself until [Slot_timeout].
    Every gate wait ends after {!max_slot_wait_s} at the latest, so any
    wait cycle containing a gate wait dissolves at the first expiry: the
    nested caller receives the typed refusal as its tool result and the
    outer turn proceeds to release. A cycle with no gate wait in it —
    pure tool-to-tool nesting — predates the gate and is outside its
    scope. Tool phases additionally carry a 2h idle backstop
    ([Runtime_antigravity.tool_step_idle_timeout_s]): silence there is
    the protocol, so the bound sits far above any plausible healthy
    tool and only a wedged one trips it, failing typed [Timeout].
    Holders therefore release on tool return, owner cancel, or the
    backstop at the latest, and saturation in between degrades to typed
    "retry shortly" refusals, never to a hang. Releasing the slot during
    tool phases would break the fd bound the gate exists for — the child
    keeps its descriptors while it waits on tools — so the slot spans
    the whole turn by design. Owner cancellation reaches every gated
    turn at its suspension points (protocol reads, sleeps, the slot
    wait itself): keeper turns race an abort promise
    ([Keeper_antigravity_runtime], [Switch.run] plus [Watched_work.run]
    over [abort_turn]), and fusion, verification, and capability-probe
    turns all run under an [Eio.Switch] their lane can fail
    ([Fusion_official_client], [Runtime_verification_antigravity],
    [Keeper_capability_probe]). A tool callback doing unbounded pure
    compute would delay delivery, as before this gate existed. The
    waiter gauges below tell saturation (tune the bound) apart from a
    wedge (investigate the stuck turns). *)

val max_concurrent_cli_spawns : int
(** [8]. Worst enforced case is 8 x {!child_fd_ceiling} = 128k files
    against ~430k headroom (491,520 system ceiling minus ~60k ambient
    use); the typical case is 8 x 7.5k = 60k. The arithmetic assumes
    every live child is observable: a child that is alive yet
    unobservable under fd pressure is refused ([Fds_pressured]), so the
    ceiling cannot evaporate in the incident regime. Benign misses (an
    already-exited child, a hidden [/proc] entry, a missing [lsof]) stay
    allowed. *)

val child_fd_ceiling : int
(** [16_000]. Twice the healthy 7.5k baseline with growth headroom,
    below the 26k sick floor: the 2026-10-16 cookie-driven turns would
    have failed here instead of completing. Enforced at the first
    protocol event and at the result event; growth strictly between the
    two samples is seen only at the result. *)

val max_slot_wait_s : float
(** [120.0]. A waiter that cannot get a slot within this budget fails
    with [Slot_timeout] instead of waiting unboundedly. Twice a generous
    healthy drain (slots turn over in seconds while healthy) and below
    the 300s admission bound, so a saturated gate surfaces while the
    caller still has patience. *)

val child_fd_probe_timeout_s : float
(** [5.0]. The child fd probe only reads; if it cannot answer within
    this budget the child is treated as unobservable (allowed), never
    as zero. Callers wrap the probe in [Eio.Time.with_timeout]. *)

exception Slot_timeout of { waited_s : float; limit_s : float }
(** Raised by {!with_cli_spawn_slot} when the wait budget expires.
    [waited_s] is the measured wait, [limit_s] the budget that expired.
    A busy gate is retryable pressure, not a broken turn: callers map it
    to a "capacity busy, retry shortly" refusal. *)

val with_cli_spawn_slot :
  clock:_ Eio.Time.clock -> ?wait_timeout_s:float -> (unit -> 'a) -> 'a
(** [with_cli_spawn_slot ~clock ?wait_timeout_s f] waits up to
    [wait_timeout_s] (default {!max_slot_wait_s}) for a CLI spawn slot,
    runs [f] under [Fd_accountant.observe ~kind:Provider_cli] so the
    concurrency distribution stays measurable, and releases the slot on
    every exit path. Raises [Slot_timeout] on budget expiry; besides
    that and [f]'s own exceptions, only [Eio.Cancel.Cancelled]
    propagates — a cancelled waiter holds no slot. *)

val active_cli_spawns : unit -> int
(** Currently held slots. Test seam and telemetry; agrees with
    [Fd_accountant.active_count ~kind:Provider_cli] over gated turns. *)

val waiting_cli_spawns : unit -> int
(** Current waiters: turns blocked for a slot right now. Together with
    {!active_cli_spawns} this separates "8 running" from "8 stuck with
    12 queued". *)

val oldest_cli_spawn_wait_s : unit -> float option
(** Age in seconds (wall clock) of the longest-waiting waiter, [None]
    when nobody waits. A climbing age with a full gate is the wedge
    signal; a climbing count with a low age is healthy burst traffic. *)

type child_fds =
  | Fd_count of int
  | Fds_unobservable
  | Fds_pressured
(** A child file-usage sample. [Fd_count] is a read count: [/proc]
    directory entries minus dot entries on Linux, numeric-FD [lsof]
    rows (cwd/txt/mem excluded) on macOS. [Fds_unobservable] is a
    benign miss — exited child, hidden entry, missing probe. Only
    [Fds_pressured] (the probe itself hit EMFILE/ENFILE) may fail a
    turn closed. *)

val sample_child_fds :
  mgr:_ Eio.Process.mgr -> cwd:Eio.Fs.dir_ty Eio.Path.t -> pid:int -> child_fds
(** Best-effort open-file sample of a live child process. Tries
    [/proc/<pid>/fd] first, then [lsof -p <pid>] where [/proc] misses
    (macOS, and Linux corners like hidepid). Besides
    [Eio.Cancel.Cancelled], never raises. Unbounded: callers time-box it
    with {!child_fd_probe_timeout_s}. *)

val child_is_alive : pid:int -> bool
(** [Unix.kill pid 0] existence test. [false] for non-positive pids.
    Decides the pressured case: a pressured sample of a dead child is a
    benign miss, of a live one a closed refusal. *)

module For_testing : sig
  val count_proc_fds : pid:int -> child_fds
  (** Direct [/proc/<pid>/fd] read, no fallback. *)

  val count_lsof_lines : string -> int
  (** Count numeric-FD data lines in [lsof -p <pid>] default output:
      every post-header row whose fourth field starts with a digit. *)

  val error_signals_pressure : Unix.error -> bool
  (** True exactly for EMFILE/ENFILE. *)
end
