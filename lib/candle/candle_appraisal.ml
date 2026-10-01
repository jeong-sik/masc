let ( let* ) = Result.bind
type identity = { goal_id : string; request_id : string; verification_run_id : string }
type goal = { title : string; metric : string option; target_value : string option }
type task = { task_id : string; title : string; keeper : string }
type relation = Related | Unrelated
type trace = { run_id : string; slot_id : string }
type task_relation = { task_id : string; relation : relation; trace : trace }
type request = Grade of goal | Relation of { goal : goal; task_title : string }
  | Weights of { goal : goal; tasks : task list; keepers : string list; weight_max : int }
type decision = Grade_decided of Candle_grade.t | Relation_decided of relation
  | Weights_decided of (string * int) list
type answer = { decision : decision; trace : trace }
type error = Transport_unavailable of string | Invalid_response of string | Execution_rejected of string
type runner = identity:identity -> request -> (answer, error) result
let as_int = function `Int n -> Ok n | _ -> Error "expected integer"
let grade_of_json json =
  let* value = Candle_json.as_string json in
  match Candle_grade.of_string value with Some grade -> Ok grade | None -> Error "unknown grade"
let relation_text = function Related -> "related" | Unrelated -> "unrelated"
let relation_of_text = function
  | `String "related" -> Ok Related | `String "unrelated" -> Ok Unrelated
  | _ -> Error "expected related or unrelated"
let nullable = function None -> `Null | Some s -> `String s
let goal_json (g : goal) = `Assoc ["title", `String g.title; "metric", nullable g.metric;
  "target_value", nullable g.target_value]
let stage = function Grade _ -> "grade" | Relation _ -> "relation" | Weights _ -> "weights"
let input = function
  | Grade g -> `Assoc ["goal", goal_json g]
  | Relation r -> `Assoc ["goal", goal_json r.goal; "task_title", `String r.task_title]
  | Weights w -> `Assoc ["goal", goal_json w.goal;
      "tasks", `List (List.map (fun (t : task) -> `Assoc ["title", `String t.title; "assignee", `String t.keeper]) w.tasks);
      "keepers", `List (List.map (fun s -> `String s) w.keepers); "weight_max", `Int w.weight_max]
let object_schema properties = `Assoc ["type", `String "object";
  "properties", `Assoc properties; "required", `List (List.map (fun (key, _) -> `String key) properties);
  "additionalProperties", `Bool false]
let enum values = `Assoc ["type", `String "string"; "enum", `List (List.map (fun s -> `String s) values)]
let schema = function
  | Grade _ -> object_schema ["grade", enum (List.map Candle_grade.to_string Candle_grade.all)]
  | Relation _ -> object_schema ["relation", enum ["related"; "unrelated"]]
  | Weights w -> object_schema ["weights", object_schema (List.map (fun name -> name,
      `Assoc ["type", `String "integer"; "minimum", `Int 0; "maximum", `Int w.weight_max]) w.keepers)]
let validate_weights ~keepers ~weight_max weights =
  let names = List.map fst weights in
  if List.length names <> List.length (List.sort_uniq String.compare names) then Error "duplicate keeper weight"
  else if List.sort String.compare names <> List.sort String.compare keepers then Error "weights must name exactly the related candidate keepers"
  else if weight_max < 1 || List.exists (fun (_, n) -> n < 0 || n > weight_max) weights then Error "weight outside configured range"
  else if not (List.exists (fun (_, n) -> n > 0) weights) then Error "weight sum must be positive"
  else Ok ()
let weights_of_json json =
  let* fields = Candle_json.object_fields ~context:"weights" json in
  List.fold_right (fun (name, value) rest ->
    let* rest = rest in let* n = as_int value in Ok ((name, n) :: rest)) fields (Ok [])
let decode request json =
  let context = "candle appraisal " ^ stage request in
  let* fields = Candle_json.object_fields ~context json in
  let* decision, remaining = match request with
    | Grade _ -> let* grade, rest = Candle_json.field ~context "grade" grade_of_json fields in
      Ok (Grade_decided grade, rest)
    | Relation _ -> let* relation, rest = Candle_json.field ~context "relation" relation_of_text fields in
      Ok (Relation_decided relation, rest)
    | Weights w -> let* weights, rest = Candle_json.field ~context "weights" weights_of_json fields in
      let* () = validate_weights ~keepers:w.keepers ~weight_max:w.weight_max weights in
      Ok (Weights_decided weights, rest) in
  let* () = Candle_json.finish ~context remaining in Ok decision
let decision_json = function
  | Grade_decided g -> `Assoc ["grade", `String (Candle_grade.to_string g)]
  | Relation_decided r -> `Assoc ["relation", `String (relation_text r)]
  | Weights_decided weights -> `Assoc ["weights", `Assoc (List.map (fun (k, n) -> k, `Int n) weights)]
let trace_json t = `Assoc ["run_id", `String t.run_id; "slot_id", `String t.slot_id]
let trace_of_json json =
  let context = "appraisal trace" in
  let* fields = Candle_json.object_fields ~context json in
  let* run_id, fields = Candle_json.field ~context "run_id" Candle_json.as_non_blank fields in
  let* slot_id, fields = Candle_json.field ~context "slot_id" Candle_json.as_non_blank fields in
  let* () = Candle_json.finish ~context fields in Ok {run_id; slot_id}
let relation_json (r : task_relation) = `Assoc ["task_id", `String r.task_id;
  "relation", `String (relation_text r.relation); "trace", trace_json r.trace]
let relation_of_json json =
  let context = "task relation" in
  let* fields = Candle_json.object_fields ~context json in
  let* task_id, fields = Candle_json.field ~context "task_id" Candle_json.as_non_blank fields in
  let* relation, fields = Candle_json.field ~context "relation" relation_of_text fields in
  let* trace, fields = Candle_json.field ~context "trace" trace_of_json fields in
  let* () = Candle_json.finish ~context fields in Ok {task_id; relation; trace}

let error_to_string = function Transport_unavailable detail | Invalid_response detail | Execution_rejected detail -> detail
