(** Masc_eio_env — per-domain Eio environment for OAS HTTP
    calls.

    The OAS provider completions use [cohttp-eio] for HTTP
    transport, which needs an Eio switch and net handle.
    {!init} is called at server bootstrap and may be called again
    by additional OCaml domains that own their own Eio handles.
    Every consumer that needs to issue an HTTP call later reaches
    the captured handles via {!get} or {!get_opt}.

    Internal storage is hidden and domain-local. There is no
    process-wide fallback; an OCaml domain that performs OAS HTTP calls
    must call {!init} with handles, including a clock, owned by that
    domain. See [docs/oas-bridge-clock-timeout-contract.md] for the
    Provider timeout contract. *)

type t = {
  sw : Eio.Switch.t;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
}
(** Captured Eio handles. [clock] is passed to the OAS Provider transport,
    which owns the single LLM timeout boundary. *)

val init :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit ->
  unit
(** Capture the runtime handles for the current OCaml domain.
    Last-writer-wins for the current domain-local slot. Intended to be called
    at startup; re-init is permitted by harness tests and standalone
    executables. *)

val reset_for_test : unit -> unit
(** Clear the captured environment for direct test executable runs. *)

val get : unit -> t
(** Read the captured environment.

    @raise Invalid_argument when {!init} has not yet run.
    Callers in the boot path that may legitimately fire before
    {!init} should use {!get_opt} instead. *)

val get_opt : unit -> t option
(** Read the captured environment without raising. Returns
    [None] when {!init} has not run in the current OCaml domain. Used by
    tests and by code paths that must degrade explicitly rather than
    borrowing another domain's switch/net/clock handles. *)
