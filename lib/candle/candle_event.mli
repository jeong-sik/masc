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

type task_lookup =
  | Found of
      { title : string
      ; assignee : string option
            (** Who did or is doing the work, as the Task's status names them. *)
      ; status : task_status
      }
  | Deleted  (** Neither store has the Task, and the Goal no longer links it. *)
(** What reading one linked Task found. A Task that could not be read has no row
    here: nothing is written until every linked Task reads. *)

type attribution = {
  grade : Candle_grade.t;
  grade_trace : Candle_appraisal.trace;
  relations : Candle_appraisal.task_relation list;
}
type unattributed_reason = No_candidates | All_unrelated of attribution | No_related_keepers of attribution
(** Nobody could be paid. *)

type body =
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
  | Candidates of
      { goal_id : string
      ; request_id : string
      ; verification_run_id : string
      ; tasks : (string * task_lookup) list
            (** One entry per Task the [Snapshot] linked, in its order. *)
      ; candidate_task_ids : string list
      ; candidate_keepers : string list
      }
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
  | Payout_failed of { goal_id : string; request_id : string; verification_run_id : string; due_date : string }

type t =
  { at : Candle_time.t
  ; body : body
  }

val kind : body -> string
(** The row's ["kind"]: [snapshot], [payout_owed], [candidates] or
    [unattributed], [paid], [purchased] or [payout_failed]. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val to_line : t -> (string, string) result
(** One JSON line, without the newline. [Error] when the line would not read
    back, so an event that cannot be read never reaches an append-only file. *)

val of_line : string -> (t, string) result
