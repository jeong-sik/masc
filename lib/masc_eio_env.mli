(** Masc_eio_env — per-domain Eio environment for OAS HTTP
    calls.

    The OAS provider completions use [cohttp-eio] for HTTP
    transport, which needs an Eio switch and net handle.
    {!init} is called once per OCaml domain (in
    [server_runtime_bootstrap] and in each standalone executable);
    every consumer that needs to issue an HTTP call later reaches
    the captured handles via {!get} or {!get_opt}.

    Internal storage (the [Domain.DLS] slot) is hidden — callers
    consume only the {!type-t} record and the accessors.  Using
    domain-local storage removes the previous module-level Atomic
    global and matches the domain-local nature of [Eio.Switch]. *)

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
    Last-writer-wins on [Domain.DLS.set]; intended to be called
    exactly once per domain at startup but a re-init is permitted
    (used by the harness test suite). *)

val reset_for_test : unit -> unit
(** Clear the captured environment for direct test executable runs. *)

val get : unit -> t
(** Read the captured environment.

    @raise Invalid_argument when {!init} has not yet run.
    Callers in the boot path that may legitimately fire before
    {!init} should use {!get_opt} instead. *)

val get_opt : unit -> t option
(** Read the captured environment without raising. Returns
    [None] when {!init} has not run — used by tests and by
    code paths that must degrade gracefully (runtime catalog
    runtime, masc_oas_bridge fallback, local-runtime probes,
    oas_worker_named scheduler). *)
