(** Masc_eio_env — per-domain Eio environment for OAS HTTP
    calls.

    The OAS provider completions use [cohttp-eio] for HTTP
    transport, which needs an Eio switch and net handle.
    {!init} is called at server bootstrap and may be called again
    by additional OCaml domains that own their own Eio handles.
    Every consumer that needs to issue an HTTP call later reaches
    the captured handles via {!get} or {!get_opt}.

    Internal storage is hidden. The current domain's [Domain.DLS]
    value is preferred. A process-wide fallback preserves legacy
    lookup semantics for domains that have not been explicitly
    initialised yet; callers that use the returned [Eio.Switch] or net
    handle across domains still need an ownership audit. *)

type t = {
  sw : Eio.Switch.t;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}
(** Captured Eio handles. [clock] is optional because some
    callers (e.g. tests, stdio mode) initialise without one;
    components that strictly require a clock should pattern
    match on [Some] and fail loudly rather than substitute a
    fallback. *)

val init :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit ->
  unit
(** Capture the runtime handles for the current OCaml domain.
    Last-writer-wins for both the domain-local slot and the process-wide
    compatibility fallback. Intended to be called at startup; re-init is
    permitted by harness tests and standalone executables. *)

val reset_for_test : unit -> unit
(** Clear the captured environment for direct test executable runs. *)

val get : unit -> t
(** Read the captured environment.

    @raise Invalid_argument when {!init} has not yet run.
    Callers in the boot path that may legitimately fire before
    {!init} should use {!get_opt} instead. *)

val get_opt : unit -> t option
(** Read the captured environment without raising. Returns
    [None] only when {!init} has not run in the process. Used by tests and
    by code paths that must degrade gracefully (runtime catalog runtime,
    masc_oas_bridge fallback, local-runtime probes, oas_worker_named
    scheduler). *)
