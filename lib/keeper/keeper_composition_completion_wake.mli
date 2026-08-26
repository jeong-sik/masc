(** Keeper_composition_completion_wake — tell a Keeper that the async
    composition it submitted has finished.

    An async [keeper_compose_*] call returns a request id and does not wait.
    Before this module the result reached the submitter only if it went back
    and read that id. Measured over 2026-08-18..26 on the live store: 22
    submissions produced 12 reads, and a settled result waited a median of
    21.9s to be collected against a median 2.7ms of work — one waited 47
    minutes. The wrapper meant to keep a turn free was making the answer
    arrive later than running it inline would have.

    The stimulus is committed through the same fail-closed durable path the
    delegation answer uses, so a failed write is reported rather than
    swallowed. The live wake that follows is a hint: it only reaches a
    [Running] Keeper, and its failure is logged, because the committed
    stimulus is already in the queue the Keeper drains on its next admitted
    turn.

    The result body is not carried. It is already durable in the async
    request record and [keeper_composition_status] reads it by request id;
    copying it here would put the same bytes in two durable stores. *)

val deliver
  :  base_path:string
  -> keeper_name:string
  -> request_id:string
  -> composition_tool:string
  -> terminal:Keeper_event_queue.composition_terminal
  -> (unit, string) result

val on_worker_settled
  :  base_path:string
  -> composition_tool:string
  -> Keeper_msg_async.worker_settlement
  -> unit
(** Adapter for {!Keeper_msg_async.submit_with_request_id}'s
    [?on_worker_settled]. A settlement that is not durably canonical, or that
    reports a projection error, is logged and not delivered: telling a Keeper
    its work succeeded on evidence the store does not hold would be worse than
    leaving it to read the record itself. A non-terminal status is not a
    settlement to announce and is ignored. *)
