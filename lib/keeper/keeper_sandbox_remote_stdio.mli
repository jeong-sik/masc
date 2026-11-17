(** Owned interactive exec-shim session for OpenSSH and microVM
    [Exec_per_request]. It never substitutes a carrier or a local payload. *)
type 'e failure =
  | Refused of Keeper_sandbox_remote.Stdio_request.refusal
  | Dispatch_declined of 'e
  | Process_unavailable of Process_eio.stdio_refusal
  | Host_timeout

val with_stdio :
  Keeper_sandbox_remote.Stdio_request.t ->
  on_dispatch:(unit -> (unit, 'e) result) ->
  on_receipt:(Keeper_sandbox_remote.execution_observation -> unit) ->
  on_stderr_chunk:(string -> unit) ->
  on_stdout_tail:(string -> unit) ->
  (input:Eio.Flow.source_ty Eio.Resource.t ->
   output:Eio.Flow.sink_ty Eio.Resource.t -> 'a) ->
  ('a * Keeper_sandbox_remote.Stdio_request.completion, 'e failure) result
(** Calls [on_dispatch] under the endpoint lease before spawning the request
    carrier or writing any request byte. Refusal sends no payload request.
    A partial first frame write may have dispatched: receipt evidence changes
    before that write, not after it succeeds.

    Without an active Eio fiber and initialized process runtime, returns
    [Process_unavailable (Runtime_unavailable _)] before probing or acquiring
    the lease. [on_receipt] receives [Execution_unavailable Request_not_sent]
    directly outside Eio; notification does not enter Eio cancellation protection.

    The callback borrows exact payload stdout and stdin. It must serialize
    writes and stop using both flows before returning. On normal return the
    process owner closes stdin, deliberately cancelling the shim payload,
    drains stderr and remaining stdout, then awaits the real carrier status.
    [on_stdout_tail] receives every stdout byte the callback left unread;
    [on_stderr_chunk] receives only payload stderr. The callback's value is
    not evidence that the payload exited successfully.

    Callback exceptions and cancellation propagate after process cleanup.
    [on_receipt] runs once even on those paths and carries only this call's
    last proven boundary. If it also fails, the primary exception and backtrace
    are preserved and the receipt failure is reported separately. A receipt
    failure after a normal return propagates. A host timeout or interrupted drain may leave the
    remote effect unknown; neither authorizes retry. MCP response retention
    belongs inside the callback, before its borrowed channel closes. *)
