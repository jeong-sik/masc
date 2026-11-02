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
(** The first [Snapshot] of the same Goal, request, verifier run and pass time;
    used when replaying previously settled history. *)

val current_pass_of : waiting -> Candle_event.t list -> (pass, string) result
(** The confirmed Snapshot for a new decision. Identical repeated facts are
    accepted; conflicting Snapshots with the same run and pass time are refused. *)

type pass_observation = Missing_snapshot | Conflicting_snapshots | Matching_snapshot of pass

val observe_current_pass : waiting -> Candle_event.t list -> pass_observation
(** The same decision as [current_pass_of], with distinct typed reasons for an
    absent Snapshot and conflicting Snapshots. *)

type candidates =
  { candidate_task_ids : string list
  ; candidate_keepers : string list
  ; candidate_task_keepers : (string * string option) list
  }

type boundary = Goal_created | Human_confirmed

type window_issue =
  | Same_second of { task_id : string; boundary : boundary; completed_at : Candle_time.t }
  | Task_missing of { task_id : string }
  | Task_unobserved of { task_id : string }
  | Unfenced_nonterminal of { task_id : string }
  | Reversed_window of { goal_created_at : Candle_time.t; confirmed_at : Candle_time.t }

val window_issues :
  goal_created_at:Candle_time.t
  -> confirmed_at:Candle_time.t
  -> (string * Candle_event.task_lookup) list
  -> window_issue list
(** A whole-second completion equal to either applicable endpoint has no
    recoverable ordering. A missing Task's status and completion are unknown.
    A reversed Goal window has no trustworthy ordering. None of these facts
    proves a contribution or its absence. *)

val window_issue_to_string : window_issue -> string

type observation_provenance = Unfenced | Backlog_fenced

val observation_issues :
  provenance:observation_provenance
  -> goal_created_at:Candle_time.t
  -> confirmed_at:Candle_time.t
  -> (string * Candle_event.task_lookup) list
  -> window_issue list
(** Also refuses historical nonterminal observations whose order against Task
    commits was not protected by the backlog fence. *)

val snapshot_independent_issues :
  provenance:observation_provenance -> (string * Candle_event.task_lookup) list -> window_issue list
(** Issues that remain observable even if the matching Snapshot is absent or
    conflicting. Time-boundary issues cannot be decided by this function. *)

type held_window =
  { passed_at : Candle_time.t
  ; confirmed_at : Candle_time.t
  ; tasks : (string * Candle_event.task_lookup) list
  ; task_keepers : (string * Candle_event.keeper_observation) list
  }

val held_window_of : waiting -> Candle_event.t list -> held_window option
(** The frozen observation for an unresolved payout window, if one exists. *)

val candidate_observations_of :
  waiting -> Candle_event.t list -> ((string * Candle_event.task_lookup) list * observation_provenance) option
(** Task observations in an existing [Candidates] row. *)

val classify_keepers :
  is_keeper:(string -> bool) option
  -> (string * Candle_event.task_lookup) list
  -> (string * Candle_event.keeper_observation) list
(** Freeze the Keeper decision for each observation, including Tasks whose
    eligibility has not yet been decided. [None] preserves an unavailable
    Keeper registry as unknown rather than guessing that an assignee is not a
    Keeper. *)

val classify_fragments :
  is_keeper:(string -> bool) option
  -> (string * Candle_event.task_lookup) list
  -> (string * Candle_event.task_lookup) list
(** Preserve the Keeper classification for every identifiable partial row,
    without turning conflicting rows into a definite Task assignee. *)

val candidates_of : waiting -> Candle_event.t list -> candidates option
(** What the [Candidates] row written for the payout's request and verifier run decided. *)

val validate_durable_candidates : waiting -> Candle_event.t list -> (unit, string) result
(** Validate the durable [Snapshot] and [Candidates] invariants for [waiting]
    (exact linked-task coverage, eligible subset equality, and per-task Keeper
    eligibility consistency) before spending model calls in appraisal. *)

val validate_settlement : waiting -> Candle_event.t list -> Candle_event.body -> (unit, string) result
(** Cross-record admission: exact confirmed run, Snapshot-linked completed Task
    eligibility within the confirmed window, durable candidate Task coverage,
    unique relation decisions and exactly the eligible related Keeper recipients.
    Payment arithmetic alone cannot prove recipient eligibility. Call before the
    atomic append. *)

val validate_record : Candle_event.t list -> Candle_event.body -> (unit, string) result
(** Admit a new settlement or candidate-window observation against preceding
    rows in file order, under today's rules. A hold must match the open payout
    and complete linked-Task observations; later Candidates, replacement
    obligations and settlements for that Goal are refused. A settlement otherwise requires a matching Snapshot
    and durable Candidates whose list equals today's eligible subset. *)

val validate_replay : Candle_event.t list -> Candle_event.body -> (unit, string) result
(** Read a stored settlement back against preceding rows in file order. It
    checks everything {!validate_record} checks except that the Candidates
    row's candidate list equals today's eligibility rule: that list was decided
    when the row was written, and re-deciding it under a later rule would make
    one old row unreadable for every Goal. The list must still name observed,
    Snapshot-linked tasks, and the open obligation, durable Candidates, relation
    coverage, recipient eligibility and weights are checked as before. A prior
    held-window fact is never bypassed by replay. *)

val decide_candidates :
  goal_created_at:Candle_time.t
  -> confirmed_at:Candle_time.t
  -> is_keeper:(string -> bool)
  -> (string * Candle_event.task_lookup) list
  -> (candidates, window_issue list) result
(** A candidate Task was found, is [done], and was completed after the Goal was
    created and no later than the confirmation. Returns all unresolved window
    issues rather than deciding a partial set. A candidate keeper is a name
    that [is_keeper] accepts among the candidate Tasks' assignees, listed once,
    in name order. *)
