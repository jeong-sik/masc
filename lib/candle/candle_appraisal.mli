(** Closed appraisal requests. Only [input] reaches the model; payout identity
    and execution traces are audit metadata, never extra grading evidence. *)
type identity = { goal_id : string; request_id : string; verification_run_id : string }
type goal = { title : string; metric : string option; target_value : string option }
type task = { task_id : string; title : string; keeper : string }
type relation = Related | Unrelated
type trace = { run_id : string; slot_id : string }
type task_relation = { task_id : string; relation : relation; trace : trace }
type request =
  | Grade of goal
  | Relation of { goal : goal; task_title : string }
  | Weights of { goal : goal; tasks : task list; keepers : string list; weight_max : int }
type decision = Grade_decided of Candle_grade.t | Relation_decided of relation
  | Weights_decided of (string * int) list
type answer = { decision : decision; trace : trace }
type error =
  | Transport_unavailable of string
  | Invalid_response of string
  | Execution_rejected of string
      (** A typed request, authentication or configuration refusal prevents
          the declared executions from serving this request. Keep the obligation pending and await a
          change event instead of replaying the same appraisal on a pulse. *)
type runner = identity:identity -> request -> (answer, error) result
val stage : request -> string
val input : request -> Yojson.Safe.t
val schema : request -> Yojson.Safe.t
val decode : request -> Yojson.Safe.t -> (decision, string) result
val decision_json : decision -> Yojson.Safe.t
val validate_weights : keepers:string list -> weight_max:int -> (string * int) list -> (unit, string) result
val trace_json : trace -> Yojson.Safe.t
val trace_of_json : Yojson.Safe.t -> (trace, string) result
val relation_json : task_relation -> Yojson.Safe.t
val relation_of_json : Yojson.Safe.t -> (task_relation, string) result
val grade_of_json : Yojson.Safe.t -> (Candle_grade.t, string) result
val as_int : Yojson.Safe.t -> (int, string) result

val error_to_string : error -> string
