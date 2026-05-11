(** Actor types — generic actor abstraction over Eio fibers.

    Single-Domain only.  RFC-0059 Phase 2 PR-5: primitive types for
    the actor model.  PR-6 (Domain pool) introduces parallel
    dispatch, PR-7 migrates the keeper heartbeat loop to actors.

    The actor record is parameterised by message type {b ['msg]}.
    Internal state is owned by the actor's own loop fiber
    (closure-captured) — deliberately {i not} exposed in the type —
    to enforce the "messages are the only inputs" invariant of the
    actor model.  External code interacts via {!Actor_mailbox.send};
    reading internal state requires sending a query message that
    responds via a callback or {!Eio.Promise}.

    {b Why ['msg] and not [unit]}: a stub iteration of this module
    used [unit mailbox], erasing the message type.  That makes the
    queue convey only "wake up" with no payload, which is not the
    actor model — it is a semaphore.  The typed queue lets the
    handler exhaustively pattern-match on a closed sum type, which
    is the OCaml way of catching "forgot to handle new message
    variant" at compile time. *)

type 'msg mailbox = 'msg Eio.Stream.t
(** Bounded message queue.  See {!Actor_mailbox.create} for capacity. *)

type 'msg t = {
  name : string;
  inbox : 'msg mailbox;
  stop_signal : bool Atomic.t;
}
(** An actor handle.  Externally observable surface: the [name] (for
    log attribution), the [inbox] for [send], and a [stop_signal]
    flag the loop checks at the top of each iteration. *)

type handler_outcome =
  | Continue
  | Stop
(** Return value of an actor message handler.  [Continue] re-enters
    the loop with the new state; [Stop] exits cleanly without
    waiting for the [stop_signal]. *)
