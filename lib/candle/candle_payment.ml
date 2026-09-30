let ( let* ) = Result.bind
type allocation = { keeper : string; weight : int; share_milli : int; amount_milli : int }
type t = {
  identity : Candle_appraisal.identity;
  grade : Candle_grade.t; total_milli : int; grade_trace : Candle_appraisal.trace;
  relations : Candle_appraisal.task_relation list; weights_trace : Candle_appraisal.trace;
  weight_max : int; deduction_rate : int; deduction_floor : int;
  overdue_hours : int; coefficient : int; allocations : allocation list;
}
let math result = Result.map_error Candle_math.error_to_string result
let make ~identity ~grade ~total_milli ~grade_trace ~relations ~weights_trace
    ~weight_max ~deduction_rate ~deduction_floor ~overdue_hours ~weights =
  let* () = Candle_appraisal.validate_weights ~keepers:(List.map fst weights) ~weight_max weights in
  let* coefficient = math (Candle_math.deduction_coefficient ~rate:deduction_rate ~floor:deduction_floor ~overdue_hours) in
  let* shares = math (Candle_math.split ~total:total_milli weights) in
  let* allocations = List.fold_right (fun (keeper, share_milli) acc ->
    let* acc = acc in
    let* amount_milli = math (Candle_math.deduct ~coefficient share_milli) in
    Ok ({keeper; weight=List.assoc keeper weights; share_milli; amount_milli} :: acc)) shares (Ok []) in
  Ok {identity; grade; total_milli; grade_trace; relations; weights_trace; weight_max;
      deduction_rate; deduction_floor; overdue_hours; coefficient; allocations}
let allocation_json a = `Assoc ["keeper", `String a.keeper; "weight", `Int a.weight;
  "share_milli", `Int a.share_milli; "amount_milli", `Int a.amount_milli]
let to_fields p = [
  "goal_id", `String p.identity.goal_id; "request_id", `String p.identity.request_id;
  "verification_run_id", `String p.identity.verification_run_id;
  "grade", `String (Candle_grade.to_string p.grade); "total_milli", `Int p.total_milli;
  "grade_trace", Candle_appraisal.trace_json p.grade_trace;
  "relations", `List (List.map Candle_appraisal.relation_json p.relations);
  "weights_trace", Candle_appraisal.trace_json p.weights_trace;
  "weight_max", `Int p.weight_max; "deduction_rate", `Int p.deduction_rate;
  "deduction_floor", `Int p.deduction_floor; "overdue_hours", `Int p.overdue_hours;
  "coefficient", `Int p.coefficient; "allocations", `List (List.map allocation_json p.allocations)]
let to_yojson p = `Assoc (to_fields p)
let allocation_of_json json =
  let context = "allocation" in
  let* fields = Candle_json.object_fields ~context json in
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* keeper, fields = field "keeper" Candle_json.as_non_blank fields in
  let* weight, fields = field "weight" Candle_appraisal.as_int fields in
  let* share_milli, fields = field "share_milli" Candle_appraisal.as_int fields in
  let* amount_milli, fields = field "amount_milli" Candle_appraisal.as_int fields in
  let* () = Candle_json.finish ~context fields in Ok {keeper; weight; share_milli; amount_milli}
let of_yojson json =
  let context = "payment" in
  let* fields = Candle_json.object_fields ~context json in
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* verification_run_id, fields = field "verification_run_id" Candle_json.as_non_blank fields in
  let* grade, fields = field "grade" Candle_appraisal.grade_of_json fields in
  let* total_milli, fields = field "total_milli" Candle_appraisal.as_int fields in
  let* grade_trace, fields = field "grade_trace" Candle_appraisal.trace_of_json fields in
  let* relations, fields = field "relations" (Candle_json.as_list Candle_appraisal.relation_of_json) fields in
  let* weights_trace, fields = field "weights_trace" Candle_appraisal.trace_of_json fields in
  let* weight_max, fields = field "weight_max" Candle_appraisal.as_int fields in
  let* deduction_rate, fields = field "deduction_rate" Candle_appraisal.as_int fields in
  let* deduction_floor, fields = field "deduction_floor" Candle_appraisal.as_int fields in
  let* overdue_hours, fields = field "overdue_hours" Candle_appraisal.as_int fields in
  let* coefficient, fields = field "coefficient" Candle_appraisal.as_int fields in
  let* allocations, fields = field "allocations" (Candle_json.as_list allocation_of_json) fields in
  let* () = Candle_json.finish ~context fields in
  let* paid = make ~identity:{goal_id;request_id;verification_run_id} ~grade ~total_milli ~grade_trace ~relations
    ~weights_trace ~weight_max ~deduction_rate ~deduction_floor ~overdue_hours
    ~weights:(List.map (fun a -> a.keeper, a.weight) allocations) in
  if paid.coefficient <> coefficient || paid.allocations <> allocations then Error "payment arithmetic does not match its evidence"
  else Ok paid
