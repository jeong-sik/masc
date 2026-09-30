(** What the ledger says a confirmation owes (RFC-goal-candle-ledger 3.1, 3.2).

    Pure: it reads a list of events and answers. It writes nothing and does not
    know where the events came from. *)

val owed_pass :
  goal_id:string
  -> request_id:string
  -> passed_at:string
  -> Candle_event.t list
  -> Candle_time.t option
(** The pass a new [PayoutOwed] is written for when the operator confirms the
    result of [request_id], made at [passed_at] (the text the verification
    ledger holds). [Some] carries the pass time as the Goal's [Snapshot] wrote
    it. [None] when nothing is to be written:
    - no [Snapshot] of the Goal names that request and pass time. Candle was not
      on when the Goal passed, so the Goal has nothing to be paid for.
    - the Goal already has a [PayoutOwed]. A payout is owed once per Goal, and
      confirming again, or confirming a later pass after a reopen, adds no
      second one. *)
