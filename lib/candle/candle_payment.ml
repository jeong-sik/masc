let ( let* ) = Result.bind
type allocation = { keeper : string; weight : int; share_milli : int; amount_milli : int }
type t = {
  identity : Candle_appraisal.identity;
  grade : Candle_grade.t; total_milli : int; grade_trace : Candle_appraisal.trace;
  relations : Candle_appraisal.task_relation list; weights_trace : Candle_appraisal.trace;
  weight_max : int; deduction_rate : int; deduction_floor : int;
  distribution : Candle_math.distribution; unallocated_milli : int;
  overdue_hours : int; coefficient : int; allocations : allocation list;
}
let math result = Result.map_error Candle_math.error_to_string result
let make ~distribution ~identity ~grade ~total_milli ~grade_trace ~relations ~weights_trace
    ~weight_max ~deduction_rate ~deduction_floor ~overdue_hours ~weights =
  let* () = Candle_appraisal.validate_weights ~keepers:(List.map fst weights) ~weight_max weights in
  let* coefficient = math (Candle_math.deduction_coefficient ~rate:deduction_rate ~floor:deduction_floor ~overdue_hours) in
  let* shares = math (Candle_math.split ~rounding:distribution.Candle_math.share_rounding ~tie_break:distribution.tie_break ~total:total_milli weights) in
  let* allocations = List.fold_right (fun (keeper, share_milli) acc ->
    let* acc = acc in
    let* amount_milli = math (Candle_math.deduct ~rounding:distribution.deduction_rounding ~coefficient share_milli) in
    Ok ({keeper; weight=List.assoc keeper weights; share_milli; amount_milli} :: acc)) shares (Ok []) in
  let unallocated_milli = List.fold_left (fun left (_, share) -> left - share) total_milli shares in
  Ok {distribution;unallocated_milli;identity; grade; total_milli; grade_trace; relations; weights_trace; weight_max;
      deduction_rate; deduction_floor; overdue_hours; coefficient; allocations}

let validate_for_append paid =
  let* expected = make ~distribution:paid.distribution ~identity:paid.identity ~grade:paid.grade
    ~total_milli:paid.total_milli ~grade_trace:paid.grade_trace
    ~relations:paid.relations ~weights_trace:paid.weights_trace
    ~weight_max:paid.weight_max ~deduction_rate:paid.deduction_rate
    ~deduction_floor:paid.deduction_floor ~overdue_hours:paid.overdue_hours
    ~weights:(List.map (fun a -> a.keeper, a.weight) paid.allocations) in
  if expected.unallocated_milli <> paid.unallocated_milli || expected.coefficient <> paid.coefficient || expected.allocations <> paid.allocations
  then Error "new payment arithmetic does not match its evidence"
  else Ok ()

(* These are receipt invariants, independent of the formula that produced it.
   In particular, no split, remainder ordering or deduction is rerun here. *)
let validate_receipt paid =
  let in_range name lower upper value =
    if value < lower || value > upper
    then Error (Printf.sprintf "payment %s is outside %d..%d" name lower upper)
    else Ok () in
  let* () = in_range "total_milli" 0 max_int paid.total_milli in
  let* () = in_range "deduction_rate" 0 1000 paid.deduction_rate in
  let* () = in_range "deduction_floor" 0 1000 paid.deduction_floor in
  let* () = in_range "overdue_hours" 0 max_int paid.overdue_hours in
  let* () = in_range "coefficient" paid.deduction_floor 1000 paid.coefficient in
  let weights = List.map (fun a -> a.keeper, a.weight) paid.allocations in
  let* () = Candle_appraisal.validate_weights
    ~keepers:(List.map fst weights) ~weight_max:paid.weight_max weights in
  let rec shares remaining = function
    | [] ->
      if remaining = 0 then Ok ()
      else Error "payment shares do not sum to the recorded total"
    | allocation :: rest ->
      let* () = in_range "share_milli" 0 remaining allocation.share_milli in
      let* () = in_range "amount_milli" 0 allocation.share_milli allocation.amount_milli in
      if allocation.weight = 0 && allocation.share_milli <> 0
      then Error "a zero-weight recipient has a nonzero share"
      else
        (* Subtraction from the remaining total cannot overflow, even when
           damaged shares would overflow a sum before it could be checked. *)
        shares (remaining - allocation.share_milli) rest in
  let* () = in_range "unallocated_milli" 0 paid.total_milli paid.unallocated_milli in
  let* () = match paid.distribution.share_rounding with
    | Candle_math.Largest_remainder when paid.unallocated_milli <> 0 -> Error "largest remainder cannot leave unallocated money"
    | Candle_math.Largest_remainder | Candle_math.Down -> Ok () in
  shares (paid.total_milli - paid.unallocated_milli) paid.allocations

let allocation_json a = `Assoc ["keeper", `String a.keeper; "weight", `Int a.weight;
  "share_milli", `Int a.share_milli; "amount_milli", `Int a.amount_milli]
let distribution_json (p : Candle_math.distribution) = `Assoc [
  "share_rounding", `String (match p.share_rounding with Largest_remainder -> "largest_remainder" | Down -> "down");
  "remainder_tie_break", `String (match p.tie_break with Name_ascending -> "name_ascending" | Name_descending -> "name_descending");
  "deduction_rounding", `String (match p.deduction_rounding with Floor -> "down" | Ceil -> "up")]
let distribution_of_json json =
  let context = "distribution" in
  let* fields = Candle_json.object_fields ~context json in
  let choice key choices fields = Candle_json.field ~context key (fun json ->
    let* value = Candle_json.as_string json in
    match List.assoc_opt value choices with Some policy -> Ok policy | None -> Error ("unknown " ^ key)) fields in
  let* share_rounding, fields = choice "share_rounding" ["largest_remainder",Candle_math.Largest_remainder;"down",Candle_math.Down] fields in
  let* tie_break, fields = choice "remainder_tie_break" ["name_ascending",Candle_math.Name_ascending;"name_descending",Candle_math.Name_descending] fields in
  let* deduction_rounding, fields = choice "deduction_rounding" ["down",Candle_math.Floor;"up",Candle_math.Ceil] fields in
  let* () = Candle_json.finish ~context fields in
  Ok {Candle_math.share_rounding;tie_break;deduction_rounding}
let to_fields p = [
  "distribution", distribution_json p.distribution; "unallocated_milli", `Int p.unallocated_milli;
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
  let* distribution, fields = field "distribution" distribution_of_json fields in
  let* unallocated_milli, fields = field "unallocated_milli" Candle_appraisal.as_int fields in
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
  let paid = {distribution;unallocated_milli;identity={goal_id;request_id;verification_run_id};grade;total_milli;grade_trace;relations;
    weights_trace;weight_max;deduction_rate;deduction_floor;overdue_hours;coefficient;allocations} in
  let* () = validate_receipt paid in
  Ok paid
