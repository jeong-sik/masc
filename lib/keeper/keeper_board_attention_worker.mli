(** Bounded, per-keeper-fair Board-attention judge/delivery dispatcher.

    Replaces the pre-redesign [start_async]/[resume_pending] path (one forked
    fiber per candidate, no concurrency bound, re-fired on every observe
    cycle — issue #24886, root #21960) with a single boot-scanning dispatcher
    fiber feeding a fixed pool of judge/delivery worker fibers through a
    bounded {!Eio.Stream.t}. Producers ([notify]/[record_and_notify]) never
    fork and never touch the stream; they only mark a keeper's ledger dirty
    and wake the dispatcher, so calling them from any domain (including an
    [Executor_pool] worker domain) is safe.

    {b Three independent concurrency bounds, each with a distinct
    justification — do not collapse them into one knob}:
    - [per_keeper_max_concurrency]: lane isolation/fairness. Live ledgers are
      skewed (one keeper's backlog can be an order of magnitude larger than
      another's); without a per-keeper cap, a sequential or unfair drain
      lets one keeper's backlog starve every other keeper's turn at the
      shared judge pool. This module enforces it via round-robin dispatch
      plus a per-keeper in-flight reservation, entirely within this
      dispatcher — judge execution is never routed through
      [Keeper_lane]/keeper turn lanes, so it cannot serialize with, or
      crash-couple to, a keeper's own turn.
    - [effective_max_concurrency] (K): process-wide resource bound on total
      Board-attention judge/delivery fibers, independent of keeper count.
    - Provider-account admission (e.g. an OAS endpoint-level rate limiter):
      out of scope for this module — it protects the shared judge
      endpoint's account/quota, a concern this dispatcher does not own. *)

val start : sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t -> base_path:string -> unit -> unit
(** Spawn the dispatcher fiber and its fixed pool of {!effective_max_concurrency}
    judge/delivery worker fibers on [sw]. On its first pass the dispatcher
    marks every existing ledger file under [base_path]'s
    [board_attention_candidates/] directory dirty, so a durable backlog from
    before this process started is still drained (bounded by the worker
    pool, not re-fired all at once). Call once at server bootstrap. *)

val notify : base_path:string -> keeper_name:string -> unit
(** Mark [keeper_name]'s ledger dirty and wake the dispatcher. Domain-safe,
    non-blocking, and idempotent-coalescing: concurrent calls for the same
    [(base_path, keeper_name)] before the dispatcher's next pass collapse
    into one dirty entry. Never forks a fiber and never touches
    {!Eio.Switch.t}, so it is safe to call from any domain. *)

val record_and_notify :
  base_path:string ->
  Keeper_board_attention_candidate.candidate ->
  (Keeper_board_attention_candidate.candidate, string) result
(** Durably records [candidate] (identity-deduplicated, see
    {!Keeper_board_attention_candidate.record}) and then calls {!notify}.
    Returns after the row is durably committed; the dispatcher/worker pool
    processes it asynchronously. *)

val effective_max_concurrency : unit -> int
(** The configured {!Keeper_config.board_attention_max_concurrency} (K), the
    process-wide sum bound, further capped by the structured-judge runtime
    binding's declared [max_concurrent], mirroring
    {!Hitl_summary_worker.max_concurrency}. *)

module For_testing : sig
  val effective_max_concurrency : configured:int -> runtime_limit:int option -> int

  val start_with_judge :
    sw:Eio.Switch.t ->
    clock:float Eio.Time.clock_ty Eio.Resource.t ->
    base_path:string ->
    max_concurrency:int ->
    per_keeper_max_concurrency:int ->
    judge:
      (Keeper_board_attention_candidate.candidate ->
       (Keeper_board_attention_candidate.judgment, Keeper_board_attention_candidate.judge_error) result) ->
    unit ->
    unit
  (** As {!start}, but with an injectable [judge] and explicit
      [max_concurrency]/[per_keeper_max_concurrency] instead of the
      production runtime/config-derived values, so tests can drive the
      dispatcher deterministically without a live provider call. *)

  val in_flight_count : unit -> int
  (** Current value of the global in-flight gauge. Read-only observation, not
      a mutation, safe for tests to assert against without resetting any
      state. *)

  val per_keeper_in_flight_count : base_path:string -> keeper_name:string -> int
  (** Current reserved-or-processing count for one keeper lane (reserved at
      dispatch time, released when the worker finishes). Read-only
      observation. *)

  val is_dirty : base_path:string -> keeper_name:string -> bool
  (** Whether [(base_path, keeper_name)] is currently marked dirty (queued for
      the dispatcher's next pass but not yet swept). Read-only observation,
      used to prove a code path did or did not call {!notify}. *)
end
