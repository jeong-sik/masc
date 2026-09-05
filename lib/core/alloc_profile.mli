(** Alloc_profile — which call sites allocate, reach the major heap, and
    still hold sampled blocks, measured with [Gc.Memprof].

    [Heap_roots] sizes what a registered value reaches. It cannot see state
    that lives only on a fiber's stack, and it says nothing about who
    allocates. Memprof samples allocations at a fixed rate per word,
    records the allocating call stack, and reports promotion and
    deallocation of each sampled block, so the same samples give three
    tables keyed by call stack: words allocated since sampling started,
    words that reached the major heap (promoted, or allocated there
    directly), and words still live now.

    Every word count is an estimate that includes block headers: the rate
    is samples per word including the header, so a block of [s] words
    carries [(s + 1) * rate] samples in expectation and [samples / rate]
    estimates header-inclusive words.

    Memprof runs its callbacks not at the allocation but at the allocating
    thread's next poll point, which may be inside any code that allocates,
    including this module's own reader. A callback that took a lock the
    reader holds would deadlock or, with [Stdlib.Mutex], raise, and a raising
    callback makes the runtime drop the block so its deallocation is never
    reported. So callbacks here take no lock at all: each pushes one event
    onto a lock-free stack and returns. The reader drains the stack under a
    lock only it takes, and folds the events into the site table there.

    The stack is bounded. When {!max_pending_events} events wait undrained,
    new allocations stop being tracked and {!report} counts them in
    [dropped_samples]; blocks already tracked always report their promotion
    and deallocation, so the live table never inflates. Read the report at
    least every few minutes while the profile runs.

    The site table is bounded too: past {!max_sites} distinct call stacks,
    further sites fold into one overflow site named in the report.

    Cost is proportional to the sampling rate. The OCaml manual reports no
    visible effect at 1e-4; the process-wide profile uses
    {!default_sampling_rate}, a tenth of that. Every domain spawned by the
    starting domain while it samples shares the profile, so a profile started
    before the domain pool exists covers the pool. *)

val default_sampling_rate : float
val max_pending_events : int
val max_sites : int
val overflow_site_key : string

val start : sampling_rate:float -> unit
(** Start sampling in the current domain. A second call in a domain that
    already samples replaces its profile ([Gc.Memprof.start] semantics);
    call it once, before spawning domains. *)

val stop : unit -> unit
(** Stop the profile started by {!start}, in every domain sharing it, and
    discard it. Does nothing when none was started. *)

val is_sampling : unit -> bool

type site_totals =
  { key : string  (** the call stack, top frame first, one frame per line *)
  ; samples : int
  ; words : int  (** estimated words including headers: [samples / rate] *)
  }

type report =
  { sampling_rate : float
  ; sampling : bool
  ; live : site_totals list  (** sampled blocks not yet deallocated, largest first *)
  ; major : site_totals list  (** reached the major heap, cumulative, largest first *)
  ; allocated : site_totals list  (** cumulative, largest first *)
  ; live_samples : int
  ; live_words : int
  ; allocated_samples : int
  ; allocated_words : int
  ; major_samples : int
  ; major_words : int
  ; direct_major_samples : int  (** of [major_samples], allocated in the major heap directly *)
  ; dropped_samples : int  (** allocations not tracked because the event stack was full *)
  ; pending_events : int  (** events waiting to be drained after this report *)
  ; sites : int  (** distinct call stacks in the table, the overflow site included *)
  }

val report : top:int -> report
(** Drain pending events, then return the three tables cut to their [top]
    entries plus the totals they were cut from. *)

val report_to_yojson : report -> Yojson.Safe.t

val key_of_callstack : Printexc.raw_backtrace -> string
(** The site key for a call stack: of the top {!callstack_frames} frames,
    the first {!frames_per_key} that are not Stdlib or Yojson frames, each
    formatted as [Printexc.Slot.format] does, one per line. Those two
    libraries are skipped because their frames say how a value was built
    (a lexer recursion, a Bytes copy), not who asked for it, and they
    multiply distinct stacks past any table bound; every other frame counts.
    A stack made only of skipped frames keeps its top frames; a frame
    without debug information reads [<unknown>]. *)

val frames_per_key : int

val callstack_frames : int

module For_testing : sig
  type block

  val observe_alloc : key:string -> n_samples:int -> block
  val observe_alloc_in_major : key:string -> n_samples:int -> block
  val observe_promote : block -> unit
  val observe_dealloc : block -> unit
  val set_sampling_rate : float -> unit
  (** The rate the estimator divides by, without starting Memprof. *)

  val reset : unit -> unit
end
