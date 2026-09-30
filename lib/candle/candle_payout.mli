(** What the ledger says about a Goal's payout (RFC-goal-candle-ledger 3.1, 3.2,
    3.4).

    Pure: it reads a list of events and answers. It writes nothing and does not
    know where the events came from. *)

type waiting =
  { goal_id : string
  ; request_id : string  (** The verification request the operator confirmed. *)
  ; verification_run_id : string  (** The confirmed verifier run, never a timestamp-derived id. *)
  ; passed_at : Candle_time.t
  ; confirmed_at : Candle_time.t
  }
(** A confirmed pass whose payout has not finished. *)

type state =
  | No_obligation  (** Nothing is owed: no [PayoutOwed] is left open. *)
  | Waiting of waiting  (** The last [PayoutOwed], still open. *)
  | Failed of waiting (** Deterministic failure for this exact verifier run. *)
  | Settled  (** The Goal was paid, or found to have nobody to pay. *)

val state : goal_id:string -> Candle_event.t list -> state
(** A Goal is [Settled] once it has a [Paid] or [Unattributed] row. A deterministic
    [Payout_failed] is [Failed], distinct from no obligation. Otherwise it is [Waiting]
    for the payout of its last [PayoutOwed], if it has one. The Goal's phase is
    not consulted: reopening or dropping the Goal leaves the payout as it was. *)

val waiting : Candle_event.t list -> waiting list
(** Every Goal that is [Waiting], in the order of their first [PayoutOwed]. *)

val owed_pass :
  goal_id:string
  -> request_id:string
  -> verification_run_id:string
  -> passed_at:string
  -> Candle_event.t list
  -> Candle_time.t option
(** The pass a new [PayoutOwed] is written for when the operator confirms the
    result of [verification_run_id] for [request_id], made at [passed_at] (the text the verification
    ledger holds). [Some] carries the pass time as the Goal's [Snapshot] wrote
    it. [None] when nothing is to be written:
    - no [Snapshot] of the Goal names that request, verifier run and pass time. Candle was not
      on when the Goal passed, so the Goal has nothing to be paid for.
    - the Goal already owes a payout, open or settled. A payout is owed once per
      Goal, and confirming again, or confirming a later pass after a reopen,
      adds no second one. A [Failed] obligation admits a different, not-yet-failed
      verifier run, so a corrected due date can be verified and confirmed again. *)

type pass =
  { goal_created_at : Candle_time.t
  ; goal : Candle_appraisal.goal
  ; due_date : string option
  ; linked_task_ids : string list
  }
(** What the payout of a [Waiting] Goal takes from its [Snapshot]. *)

val pass_of : waiting -> Candle_event.t list -> pass option
(** The [Snapshot] of the same Goal, request, verifier run and pass time as the payout. *)

type candidates =
  { candidate_task_ids : string list
  ; candidate_keepers : string list
  }

val candidates_of : waiting -> Candle_event.t list -> candidates option
(** What the [Candidates] row written for the payout's request and verifier run decided. *)

val validate_settlement : waiting -> Candle_event.t list -> Candle_event.body -> (unit, string) result
(** Cross-record admission: exact confirmed run, durable candidate Task coverage,
    unique relation decisions and exactly the eligible related Keeper recipients.
    Payment arithmetic alone cannot prove recipient eligibility. Call before the
    atomic append, or against the preceding ledger when validating a fold. *)

val decide_candidates :
  goal_created_at:Candle_time.t
  -> confirmed_at:Candle_time.t
  -> is_keeper:(string -> bool)
  -> (string * Candle_event.task_lookup) list
  -> candidates
(** A candidate Task was found, is [done], and was completed after the Goal was
    created and no later than the confirmation. A candidate keeper is a name
    that [is_keeper] accepts among the candidate Tasks' assignees, listed once,
    in name order. *)
