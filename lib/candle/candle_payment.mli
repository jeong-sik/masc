(** A paid fact retaining its calculation inputs and the amounts actually
    issued. [make] computes a new payment; the strict decoder preserves an
    existing receipt without applying today's rounding or allocation rules.
    The payout producer must still prove the obligation is open and its
    candidates are the same. *)
type allocation = { keeper : string; weight : int; share_milli : int; amount_milli : int }
type t = private {
  identity : Candle_appraisal.identity;
  grade : Candle_grade.t; total_milli : int; grade_trace : Candle_appraisal.trace;
  relations : Candle_appraisal.task_relation list; weights_trace : Candle_appraisal.trace;
  weight_max : int; deduction_rate : int; deduction_floor : int;
  overdue_hours : int; coefficient : int; allocations : allocation list;
}
val make : identity:Candle_appraisal.identity -> grade:Candle_grade.t -> total_milli:int
  -> grade_trace:Candle_appraisal.trace -> relations:Candle_appraisal.task_relation list
  -> weights_trace:Candle_appraisal.trace -> weight_max:int -> deduction_rate:int
  -> deduction_floor:int -> overdue_hours:int -> weights:(string * int) list -> (t, string) result
val validate_for_append : t -> (unit, string) result
(** Require the current payout arithmetic for a new [Paid] row. The ledger
    writer calls this before its atomic append. Never use it to replay stored
    rows: their recorded allocations, not today's calculation, are facts. *)

val to_fields : t -> (string * Yojson.Safe.t) list
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
(** Closed receipt decoder. Enforces integer ranges, unique recipients,
    admissible weights, nonnegative amounts no greater than their shares,
    and shares summing exactly to the recorded total. It reads no current
    policy and does not recalculate the coefficient or allocations. *)
