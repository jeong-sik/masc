(** The submission of a request and its background worker in
    [Keeper_msg_async].

    A submission checks the request context, the caller and the Keeper name,
    waits for the submission lane of the Keeper within one admission deadline,
    reserves a request id, writes the [Queued] record durably and calls
    [on_accepted]. It then starts the worker on [background_sw] and returns
    [Durably_accepted]. A failed first write returns
    [Initial_persistence_failed] and drops the reservation; when the record
    may have been published and cannot be removed again, it returns
    [Reconciliation_required]. A failing [on_accepted] marks the request
    [Persistence_failed], and a worker that cannot start marks it [Lost].
    The worker marks the request [Running], runs [f] and writes the outcome:
    [Done] for a finished result, [Lost] for an interrupted worker and
    [Waiting_for_dependencies] for a result that waits on dependencies. A
    cancelled worker calls [on_worker_aborted] before its status is written,
    and [on_worker_settled] is called with each settlement.
    [submit_worker_with_request_id] takes a function that returns a
    [worker_outcome]. [submit_with_request_id] and [submit] take a function
    that returns a [Tool_result.result], and the function of [submit] does not
    receive the request id. [submit_with_ops] takes the [request_ops]
    explicitly.
    [Keeper_msg_async] includes this module. *)
open Keeper_msg_async_types
open Keeper_msg_async_state
open Keeper_msg_async_locks

val submit_worker_with_request_id :
  ?request_context:(string * Yojson.Safe.t) list ->
  ?on_accepted:(string -> (unit, string) result) ->
  ?on_worker_aborted:(worker_abort_reason ->
                      (unit, string) result) ->
  ?on_worker_settled:(worker_settlement -> unit) ->
  background_sw:Eio.Switch.t ->
  base_path:string ->
  caller:string ->
  f:(request_id:string ->
     Eio.Switch.t -> worker_outcome) ->
  keeper_name:string ->
  unit ->
  (submit_outcome,
   submit_error)
  result

val submit_with_ops :
  request_ops ->
  ?request_context:(string * Yojson.Safe.t) list ->
  ?on_accepted:(string -> (unit, string) result) ->
  ?on_worker_aborted:(worker_abort_reason ->
                      (unit, string) result) ->
  ?on_worker_settled:(worker_settlement -> unit) ->
  background_sw:Eio.Switch.t ->
  base_path:string ->
  caller:string ->
  f:(request_id:string -> Eio.Switch.t -> Tool_result.result) ->
  keeper_name:string ->
  unit ->
  (submit_outcome,
   submit_error)
  result

val submit_with_request_id :
  ?request_context:(string * Yojson.Safe.t) list ->
  ?on_accepted:(string -> (unit, string) result) ->
  ?on_worker_aborted:(worker_abort_reason ->
                      (unit, string) result) ->
  ?on_worker_settled:(worker_settlement -> unit) ->
  background_sw:Eio.Switch.t ->
  base_path:string ->
  caller:string ->
  f:(request_id:string -> Eio.Switch.t -> Tool_result.result) ->
  keeper_name:string ->
  unit ->
  (submit_outcome,
   submit_error)
  result

val submit :
  ?request_context:(string * Yojson.Safe.t) list ->
  ?on_accepted:(string -> (unit, string) result) ->
  ?on_worker_aborted:(worker_abort_reason ->
                      (unit, string) result) ->
  ?on_worker_settled:(worker_settlement -> unit) ->
  background_sw:Eio.Switch.t ->
  base_path:string ->
  caller:string ->
  f:(Eio.Switch.t -> Tool_result.result) ->
  keeper_name:string ->
  unit ->
  (submit_outcome,
   submit_error)
  result
