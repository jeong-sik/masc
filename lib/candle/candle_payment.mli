(** A paid fact with enough evidence to replay its integer arithmetic. Only
    [make] and the strict decoder construct one. The ledger append still has
    to prove the obligation is open and its candidates are the same. *)
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
val to_fields : t -> (string * Yojson.Safe.t) list
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
