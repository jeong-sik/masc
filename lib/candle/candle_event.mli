(** One row of [candle-ledger.jsonl] (RFC-goal-candle-ledger 3.1).

    A row is a flat JSON object: ["kind"], ["at"], then the fields of that kind.
    Reading is closed: an unknown kind, an unknown or missing or repeated field,
    a field of the wrong JSON kind and a value outside its type are all errors.
    A field with nothing to say is written as [null]; none is left out.

    The ledger records what happened. It does not compute. A kind is added by
    the change that first writes it, together with the readers that need it. *)

type task_status =
  | Todo
  | Claimed
  | In_progress
  | Awaiting_verification
  | Done of { completed_at : Candle_time.t }
      (** When the Task was completed. Only a done Task has one. *)
  | Cancelled
(** A Task's status as the backlog spells it. *)

type task_found =
  { title : string
  ; assignee : string option
  ; status : task_status
  }

type keeper_observation =
  | Keeper_name of string
  | Not_keeper of string
  | No_assignee
  | Keeper_unknown
(** Whether the observed assignee was a Keeper. An unreadable or deleted Task
    cannot be classified as a non-Keeper. *)

type assignee_observation = Assigned of string | Unassigned | Unreadable_assignee
type status_observation = Observed_status of task_status | Unreadable_status
type task_fragment =
  { title : string option
  ; assignee : assignee_observation
  ; status : status_observation
  ; keeper : keeper_observation
  }

type task_lookup =
  | Found of task_found
  | Found_uncertain of task_fragment list
      (** Readable rows whose source damage or duplication prevents trusting
          their uniqueness; at least one is required in a serialized event. *)
  | Deleted  (** Neither store has the Task and the Goal no longer links it;
                the original status and assignee remain unknown. *)
  | Unobserved (** The source could not establish this Task's state. *)
(** What reading one linked Task found. [Unobserved] can accompany a retained
    boundary observation but cannot be used to decide a candidate set. *)

type attribution = {
  grade : Candle_grade.t;
  grade_trace : Candle_appraisal.trace;
  relations : Candle_appraisal.task_relation list;
}
type unattributed_reason = No_candidates | All_unrelated of attribution | No_related_keepers of attribution
(** Nobody could be paid. *)

type equipment_choice = Default | Item of Keeper_portrait_item.t

type candidate_observation =
  { goal_id : string
  ; request_id : string
  ; verification_run_id : string
  ; tasks : (string * task_lookup) list
  ; candidate_task_ids : string list
  ; candidate_keepers : string list
  ; candidate_task_keepers : (string * string option) list
  }

type body =
  | Half_life_set of Candle_decay.half_life
      (** An explicit configuration boundary; subsequent intervals use it.
          Earlier payments and purchases keep their preceding policy. *)
  | Snapshot of
      { goal_id : string
      ; request_id : string  (** The verification request that passed. *)
      ; verification_run_id : string  (** The exact verifier run that produced the result. *)
      ; criterion_revision : string
      ; passed_at : Candle_time.t  (** When the verifier's passing result was made. *)
      ; goal_created_at : Candle_time.t
      ; due_date : string option
            (** The Goal's due date exactly as the Goal held it, readable or
                not. The Goal's due-date reader (Goal_due) is the one place
                that says what it means, so the ledger does not interpret it. *)
      ; title : string
      ; metric : string option
      ; target_value : string option
      ; linked_task_ids : string list  (** The Tasks linked to the Goal when it passed. *)
      }
  | Payout_owed of
      { goal_id : string
      ; request_id : string  (** The verification request the operator confirmed. *)
      ; verification_run_id : string  (** The verifier run the operator confirmed. *)
      ; passed_at : Candle_time.t  (** When that request's passing result was made. *)
      ; confirmed_at : Candle_time.t  (** When the operator confirmed it. *)
      }
  | Candidates of candidate_observation
      (** Historical observation without Task commit serialization proof. *)
  | Candidates_fenced of candidate_observation
      (** Observation and ledger append ran under the held backlog lease fence. *)
  | Candidate_window_held of
      { goal_id : string
      ; request_id : string
      ; verification_run_id : string
      ; passed_at : Candle_time.t
      ; confirmed_at : Candle_time.t
      ; tasks : (string * task_lookup) list
            (** The complete linked-Task observation at the time of the hold. *)
      ; task_keepers : (string * keeper_observation) list
            (** Frozen Keeper classification for every observed Task. *)
      }
      (** Some linked Task's ordering or original status cannot be determined.
          This is an observation, not a candidate decision or settlement. *)
  | Unattributed of
      { goal_id : string
      ; request_id : string
      ; verification_run_id : string
      ; reason : unattributed_reason
      }
  | Paid of Candle_payment.t
  | Purchased of
      { keeper : string
      ; item : Keeper_portrait_item.t
      ; amount_milli : int
      }
  | Granted of { keeper : string; amount_milli : int; reason : string }
      (** An operator gift outside any Goal: the reason names the occasion and
          is the duplicate key with the keeper. A zero or negative amount and
          a blank keeper or reason fail the decode. *)
  | Gifted of { from_keeper : string; to_keeper : string; amount_milli : int; reason : string }
      (** A keeper-to-keeper money gift: a transfer, never issuance. The
          (from, to, reason) triple is the duplicate key. A zero or negative
          amount, blank names or reason, and a gift to self fail the
          decode. *)
  | Gifted_item of { from_keeper : string; to_keeper : string; item : Keeper_portrait_item.t }
      (** A keeper-to-keeper item gift: ownership moves, and a worn item
          comes off the giver. Blank names, an unknown item, and a gift to
          self fail the decode. *)
  | Equipped of { keeper : string; slot : Keeper_portrait_item.slot; choice : equipment_choice }
  | Payout_failed of { goal_id : string; request_id : string; verification_run_id : string; due_date : string }

type t =
  { at : Candle_time.t
  ; body : body
  }

val kind : body -> string
(** The closed row-kind discriminator, including payouts, purchases and equipment choices. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val to_line : t -> (string, string) result
(** One JSON line, without the newline. [Error] when the line would not read
    back, so an event that cannot be read never reaches an append-only file. *)

val of_line : string -> (t, string) result
