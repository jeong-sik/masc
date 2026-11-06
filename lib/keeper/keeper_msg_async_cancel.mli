(** The operator cancellation of a request in [Keeper_msg_async].

    [cancel_with_ops] checks the caller and the request id and then looks at
    the pending entry of this process. A request without one is read from
    disk: it is reported as not found, unreadable, rejected or already
    terminal, and an unfinished record gets [Cancel_worker_ownership_unknown]
    because another process may own its worker. A pending request in a
    terminal status is reported as already terminal. A queued or running one
    gets the [Cancelling] status, which is persisted, published and signalled
    to the worker switch with [CancelledByOperator]; a request that is already
    [Cancelling] is persisted and signalled again. The result says whether the
    status is durably committed or only published.
    [cancel] uses [production_request_ops].
    [Keeper_msg_async] includes this module. *)
open Keeper_msg_async_types
open Keeper_msg_async_locks

val cancel_with_ops :
  request_ops ->
  base_path:string ->
  caller:string -> string -> cancel_result

val cancel : base_path:string -> caller:string -> string -> cancel_result
