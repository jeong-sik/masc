(** Server_dashboard_http_runtime_support — execution-mode and
    optional offload-pool surface for dashboard compute.

    Dashboard handlers may either run inline on the request fiber
    (sharing the request switch and budget) or be offloaded to a
    read-only [Eio.Executor_pool] so a slow batch query cannot
    starve other dashboard tabs. The pool itself is owned by
    {!Executor_pool_ref} (process-wide single-writer); this
    module is a thin orchestration layer that picks the strategy
    and falls back to inline compute when no pool is registered.

    Internal helper [create] (currently a [unit -> unit]
    placeholder) and the [default_state] singleton it produces
    are hidden — callers consume {!default} for the
    process-wide handle. *)

type dashboard_compute_mode =
  | Inline_shared
      (** Run the compute on the caller's switch / budget. *)
  | Offloaded_readonly
      (** Submit the compute to the registered executor pool with
          weight 1.0. Falls back to inline when no pool is
          registered or when the submit raises (logged at warn). *)

type runtime = {
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t;
}
(** Runtime capabilities a compute may need beyond the request
    switch. Currently passed through unused; the field is
    captured so a future "pool-side network" use-case does not
    have to thread the resource separately. *)

type t
(** Opaque handle to the runtime-support state. The current
    implementation has no per-handle state (the executor pool
    lives in {!Executor_pool_ref}); the type is kept abstract so
    a future stateful expansion (e.g. per-pool metrics) does not
    break callers. *)

val default : unit -> t
(** Return the process-wide handle. Identity-stable across
    calls. *)

val set_executor_pool : Eio.Executor_pool.t -> unit
(** Register the executor pool for [Offloaded_readonly] compute.
    Last-writer-wins via {!Executor_pool_ref}.[set]; the slot is
    intended to be filled exactly once at server startup. *)

val run_dashboard_compute :
  t ->
  ?mode:dashboard_compute_mode ->
  ?runtime:runtime ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  config:Coord.config ->
  (config:Coord.config -> sw:Eio.Switch.t -> 'a) ->
  'a
(** Dispatch [compute] under the chosen [mode] (defaults to
    [Offloaded_readonly]).

    [Inline_shared] forwards [sw] / [config] straight to
    [compute]; [Offloaded_readonly] submits the compute to
    {!Executor_pool_ref}'s pool with weight 1.0 and runs it under
    a nested [Eio.Switch.run].

    [Eio.Cancel.Cancelled] is propagated from either path. Any
    other exception during the offload is logged at
    [Log.Dashboard.warn] and the call falls back to inline
    compute so a transient pool failure cannot blank a dashboard
    tab. *)
