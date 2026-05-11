(** RFC-0070 Phase 3b-iv.1b — Mock {!Docker_client.S}.

    Test-fixture implementation: pre-registered FIFO queues of expected
    [(input, response)] pairs. Calls without a matching injection
    return [Error Daemon_unreachable] (typed, never a silent
    exception). Resetting the queues between tests is the caller's
    responsibility via {!reset}.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2

    Determinism contract: same injection sequence + same call sequence
    ⇒ identical [response] sequence. No clock, no Random, no I/O. The
    only mutable state is the per-method injection queue, which is
    explicitly reset by tests. *)

(** {1 The Mock client} *)

include Docker_client.S

(** {1 Injection API} *)

(** [inject_run plan response] enqueues [response] to be returned when
    {!run} is called with a plan that equals [plan] (via
    [Keeper_sandbox_plan.equal]).

    Strict FIFO: only the *front* of the queue is consulted. If the
    incoming plan does not equal the front, the queue is NOT scanned
    further — the call returns [Error Daemon_unreachable] and the
    queue is left intact. This guarantees test-failure on
    out-of-order or unexpected calls instead of papering them over. *)
val inject_run
  :  Keeper_sandbox_plan.t
  -> (Docker_response.exec_result, Docker_client.sandbox_error) result
  -> unit

val inject_exec
  :  container:Keeper_container_name.t
  -> cmd:string
  -> (Docker_response.exec_result, Docker_client.sandbox_error) result
  -> unit

val inject_ps_query
  :  labels:(string * string) list
  -> (Docker_response.ps_record list, Docker_client.sandbox_error) result
  -> unit

val inject_rm
  :  Keeper_container_name.t
  -> (unit, Docker_client.sandbox_error) result
  -> unit

(** {1 Fixture lifecycle} *)

(** [reset ()] empties every injection queue. Call between tests so
    leftover injections from one test do not influence another. *)
val reset : unit -> unit

(** [pending_calls ()] returns the total number of *unconsumed*
    injections across all queues. Tests should assert this equals
    [0] at the end to verify they did not register more expectations
    than they exercised. *)
val pending_calls : unit -> int
