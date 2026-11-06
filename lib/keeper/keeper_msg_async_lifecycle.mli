(** The reservation of a request and the changes of its status in
    [Keeper_msg_async].

    [reserve_new_request] draws a request id that no stored or reserved request
    uses and adds a [Queued] entry with its own transition lock to the pending
    table. [remove_runtime_if_owned] and
    [detach_runtime_preserving_reservation_if_owned] drop that entry again when
    the caller still owns the lock; the second keeps the request id reserved.
    [set_status_protected] changes the status of a pending entry under its
    transition lock, persists the new entry and returns the
    [worker_settlement], or [None] when the entry is gone or must keep its
    status. The settlement says whether the new entry is durable or only held
    in this process. An integrity failure is settled from the canonical record
    when that record is terminal, and is reported as a projection error
    otherwise. [with_canonical_request_read] runs a read under the transition
    lock of the request, when it has one, and then under its store lock.
    [with_lock] runs a function under the table mutex,
    [transition_lock_for_key] finds the lock of a pending request and
    [clear_active_switch] forgets the switch of a request.
    [operator_cancel_reason], [operator_cancelling_status],
    [operator_cancelled_status] and [runtime_cancelled_status] are the reason
    and the statuses that cancellation uses.
    [Keeper_msg_async] includes this module. *)
open Keeper_msg_async_types
open Keeper_msg_async_state
open Keeper_msg_async_locks

val with_lock : (unit -> 'a) -> 'a

val reserve_new_request :
  ops:request_ops ->
  base_path:string ->
  submitted_by:string ->
  keeper_name:string ->
  request_context:(string * Yojson.Safe.t) list option ->
  (string * entry *
   Request_key.t * Eio.Mutex.t,
   access_rejection)
  result

val remove_runtime_if_owned :
  Request_key.t -> Eio.Mutex.t -> unit

val detach_runtime_preserving_reservation_if_owned :
  Request_key.t -> Eio.Mutex.t -> unit

val transition_lock_for_key :
  Request_key.t -> Eio.Mutex.t option

val with_canonical_request_read :
  base_path:string ->
  caller:string -> request_id:string -> (unit -> 'a) -> 'a

val set_status_protected :
  ops:request_ops ->
  ?preserve_terminal:bool ->
  Request_key.t ->
  request_status ->
  worker_settlement option

val clear_active_switch :
  Request_key.t -> unit

val operator_cancel_reason : string

val operator_cancelling_status :
  unit -> request_status

val operator_cancelled_status : unit -> request_status

val runtime_cancelled_status : unit -> request_status
