(** One row of [candle-ledger.jsonl] (RFC-goal-candle-ledger 3.1).

    A row is a flat JSON object: ["kind"], ["at"], then the fields of that kind.
    Reading is closed: an unknown kind, an unknown or missing or repeated field,
    a field of the wrong JSON kind and a value outside its type are all errors.
    A field with nothing to say is written as [null]; none is left out.

    The ledger records what happened. It does not compute: a payout's grade,
    weights, shares and coefficients arrive already decided, and the checks here
    only refuse a row that could not be true (a share above the total, a
    negative weight, an item in the wrong slot). *)

(** How much a Goal was worth. The RFC leaves the names and the count to the
    operator; these five are the RFC's example set. *)
type grade =
  | Trivial
  | Small
  | Medium
  | Large
  | Epic

val grades : grade list
val grade_to_wire : grade -> string
val grade_of_wire : string -> grade option

(** A Goal's due date as it stood when recorded. *)
type due =
  | No_due
  | Due_date of Candle_time.Date.t
  | Unreadable_due of string  (** The stored text, when it is not a calendar date. *)

type task_state =
  | Todo
  | Claimed
  | In_progress
  | Awaiting_verification
  | Done
  | Cancelled

(** One linked Task as read when [Payout_owed] was written. A linked Task that
    neither the backlog nor the archive held has no row. *)
type task_row =
  { task_id : string
  ; title : string
  ; assignee : Candle_keeper.t option
  ; state : task_state
  ; completed_at : Candle_time.t option
  }

type payout_line =
  { keeper : Candle_keeper.t
  ; weight : int
  ; share : Candle_milli.t  (** Before the late-completion deduction. *)
  ; coefficient_permille : int  (** [0, 1000]. *)
  ; amount : Candle_milli.t  (** What the keeper received. *)
  }

(** The values the deduction was computed from. *)
type deduction =
  { clock : Candle_time.t
  ; due : due
  ; rate_permille : int
  ; floor_permille : int
  }

(** A payout that cannot pay out more than it states. Built by {!make_paid}. *)
type paid = private
  { goal_id : string
  ; request_id : string
  ; grade : grade
  ; total : Candle_milli.t
  ; lane_slot : string
  ; lines : payout_line list
  ; deduction : deduction
  }

val make_paid :
  goal_id:string
  -> request_id:string
  -> grade:grade
  -> total:Candle_milli.t
  -> lane_slot:string
  -> lines:payout_line list
  -> deduction:deduction
  -> (paid, string) result
(** [Error] unless: the three ids are not blank; there is at least one line;
    each keeper is on one line; each weight is not negative; each coefficient is
    within [0, 1000]; each amount is at most its share; the shares add up to no
    more than [total]; [rate_permille] is not negative; [floor_permille] is
    within [0, 1000]. *)

type failure_reason = Due_unreadable

type unattributed_reason =
  | No_candidate
  | Lane_judged_no_contributor

type body =
  | Snapshot of
      { goal_id : string
      ; request_id : string  (** The verification request that passed. *)
      ; criterion_revision : string
      ; passed_at : Candle_time.t
      ; goal_created_at : Candle_time.t
      ; due : due
      ; title : string
      ; metric : string option
      ; target_value : string option
      ; linked_task_ids : string list
      }
  | Payout_owed of
      { goal_id : string
      ; request_id : string
      ; passed_at : Candle_time.t
      ; tasks : task_row list
      ; candidates : Candle_keeper.t list
      }
  | Payout_failed of
      { goal_id : string
      ; request_id : string
      ; reason : failure_reason
      }
  | Paid of paid
  | Unattributed of
      { goal_id : string
      ; reason : unattributed_reason
      }
  | Purchased of
      { keeper : Candle_keeper.t
      ; item : Candle_item.t
      ; cost : Candle_milli.t
      }
  | Equipped of
      { keeper : Candle_keeper.t
      ; wear : Candle_item.wear
      }

type t =
  { at : Candle_time.t
  ; body : body
  }

val kind : body -> string
(** The row's ["kind"]: [snapshot], [payout_owed], [payout_failed], [paid],
    [unattributed], [purchased], [equipped]. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val to_line : t -> (string, string) result
(** One JSON line, without the newline. [Error] when the line would not read
    back, so an event that cannot be read never reaches an append-only file. *)

val of_line : string -> (t, string) result
