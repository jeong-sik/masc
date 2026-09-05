(** Alloc_profile — which call sites allocate, promote, and still hold the
    heap, sampled with [Gc.Memprof].

    [Heap_roots] sizes what a registered value reaches. It cannot see state
    that lives only on a fiber's stack, and it says nothing about who
    allocates. Memprof samples allocations at a fixed rate per word,
    records the allocating call stack, and reports promotion and
    deallocation of each sampled block, so the same samples give three
    tables keyed by call stack: words allocated since the profile started,
    words promoted to the major heap, and words still live now. Each is an
    estimate: a block of [s] words is expected to carry [s * rate] samples,
    so [samples / rate] estimates words.

    Cost is proportional to the sampling rate. The OCaml manual reports no
    visible effect at 1e-4; the process-wide profile uses
    {!default_sampling_rate}, a tenth of that. Every domain spawned by the
    starting domain while it samples shares the profile, so a profile started
    before the domain pool exists covers the pool.

    The callbacks run on whichever thread allocated, with no Eio context,
    so this module uses [Stdlib.Mutex] and performs no effect. *)

val default_sampling_rate : float

val start : sampling_rate:float -> unit
(** Start sampling in the current domain. A second call in a domain that
    already samples replaces its profile ([Gc.Memprof.start] semantics);
    call it once, before spawning domains. *)

val is_sampling : unit -> bool

type site_totals =
  { key : string  (** the call stack, top frame first, one frame per line *)
  ; samples : int
  ; words : int  (** estimated words: [samples / rate] *)
  }

type report =
  { sampling_rate : float
  ; sampling : bool
  ; live : site_totals list  (** sampled blocks not yet deallocated, largest first *)
  ; promoted : site_totals list  (** cumulative, largest first *)
  ; allocated : site_totals list  (** cumulative, largest first *)
  ; live_samples : int
  ; live_words : int
  ; allocated_samples : int
  ; allocated_words : int
  ; promoted_words : int
  }

val report : top:int -> report
(** The three tables cut to their [top] entries plus the totals they were
    cut from. *)

val report_to_yojson : report -> Yojson.Safe.t

module For_testing : sig
  type block

  val observe_alloc : key:string -> n_samples:int -> block
  val observe_promote : block -> unit
  val observe_dealloc : block -> unit
  val set_sampling_rate : float -> unit
  (** The rate the estimator divides by, without starting Memprof. *)

  val reset : unit -> unit
end
