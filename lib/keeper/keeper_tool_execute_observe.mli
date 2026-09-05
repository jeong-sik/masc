(** The observe stage of a [tool_execute] call (RFC-0422).

    Between the gate's tables and its judge sits one run of the request
    inside the executor's box: no write outside a scratch, no socket, both
    refused by the guest kernel. This module owns that run for one call. It
    resolves where the box is ({!Keeper_sandbox_shell_ir_target.observe_route}),
    dispatches the same Shell IR the real call would dispatch, and turns what
    came back into the gate's {!Keeper_gate.observation}. A clean run's
    output is kept here, because it {e is} the call's result: the gate that
    allows on {!Keeper_gate.Observed_in_box} must not run the call again.

    The stage is a value the gate calls at most once, at the one point where
    it would otherwise pay the judge; a caller that never reaches that point
    never resolves the route, so an always-allowed keeper spends no box run
    and no guest acquisition. *)

type t

val create
  :  route:(unit -> Keeper_sandbox_shell_ir_target.observe_route)
  -> dispatch:
       (Masc_exec.Sandbox_target.t
        -> ( Masc_exec.Exec_dispatch.dispatch_result
           , Keeper_tooling.Execute_shell_ir.dispatch_error )
           result)
  -> t
(** [route] says where the box is for this call; [dispatch] runs the call's
    Shell IR against a sandbox target and is what the real dispatch would do
    with the same target, output streaming aside. *)

val observe : t -> unit -> Keeper_gate.observation
(** The closure the gate receives. Resolves the route, runs the dispatch
    against the boxed target, and reads the answer: exit 0 is
    {!Keeper_gate.Observed_clean} and the result is kept; any other status
    is {!Keeper_gate.Observed_refused} with that status and the run's
    stderr; a route with no box, or a dispatch the typed gate refused before
    anything ran, is {!Keeper_gate.Observation_unavailable} with the reason
    or the refusal's closed tag. *)

val observed_result : t -> Masc_exec.Exec_dispatch.dispatch_result option
(** The clean run's result, [Some] exactly when {!observe} answered
    {!Keeper_gate.Observed_clean}. The caller returns it as the call's
    output instead of dispatching a second time. *)

val outcome : t -> Keeper_gate.observation option
(** What {!observe} answered the gate, [None] until the gate asked. A caller
    whose request was deferred reads a refusal here to tell the keeper what
    the box refused (RFC-0422 §3.3), with the same bytes the judge sees. *)
