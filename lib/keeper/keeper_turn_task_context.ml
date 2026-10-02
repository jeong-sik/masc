(** Immutable workspace Task/Goal observation taken before a turn runs. *)
type goal = { goal_id : string; phase : Goal_phase.t; criterion : Goal_store.criterion }
type source_error =
  | Goal_links_unavailable of string
  | Goal_source_unavailable of Goal_store_unavailable.t
  | Linked_goal_missing of string

type t =
  | No_task
  | Admission_not_recorded
  | Task_source_unavailable of string
  | Task of { task_id : Keeper_id.Task_id.t; goals : (goal list, source_error) result }

let capture ~config = function
  | Error detail -> Task_source_unavailable detail
  | Ok None -> No_task
  | Ok (Some task_id) ->
    let ( let* ) = Result.bind in
    let goals =
      let* links = Workspace_goal_index.read_goal_task_links_authoritative_r config
        |> Result.map_error (fun detail -> Goal_links_unavailable detail) in
      let ids = List.filter_map (fun (goal_id, tasks) ->
          if List.mem (Keeper_id.Task_id.to_string task_id) tasks then Some goal_id else None) links in
      if ids = [] then Ok [] else
      let* rows = Goal_store.list_goals_result config ()
        |> Result.map_error (fun error -> Goal_source_unavailable error) in
      List.fold_right (fun goal_id rest ->
        let* rest = rest in
        match List.find_opt (fun (goal : Goal_store.goal) -> goal.id = goal_id) rows with
        | None -> Error (Linked_goal_missing goal_id)
        | Some goal -> Ok ({ goal_id; phase = goal.phase;
            criterion = Goal_store.criterion_of_goal goal } :: rest)) ids (Ok [])
    in
    Task { task_id; goals }

let source_error_to_json = function
  | Goal_links_unavailable detail -> `Assoc ["kind", `String "goal_links_unavailable"; "detail", `String detail]
  | Goal_source_unavailable error -> `Assoc ["kind", `String "goal_source_unavailable";
      "error", Goal_store_unavailable.record_to_yojson error]
  | Linked_goal_missing goal_id -> `Assoc ["kind", `String "linked_goal_missing"; "goal_id", `String goal_id]

let to_json = function
  | Admission_not_recorded -> `Assoc ["kind", `String "admission_not_recorded"]
  | No_task -> `Assoc ["kind", `String "no_task"]
  | Task_source_unavailable detail -> `Assoc ["kind", `String "task_source_unavailable"; "detail", `String detail]
  | Task { task_id; goals } ->
    let goals = match goals with
      | Error error -> `Assoc ["kind", `String "unavailable"; "error", source_error_to_json error]
      | Ok goals -> `Assoc ["kind", `String "observed"; "goals", `List (List.map (fun goal ->
          `Assoc ["goal_id", `String goal.goal_id; "phase", `String (Goal_phase.to_string goal.phase);
            "criterion", Goal_store.criterion_to_yojson goal.criterion]) goals)] in
    `Assoc ["kind", `String "task"; "task_id", `String (Keeper_id.Task_id.to_string task_id); "goals", goals]

module W = Keeper_memory_os_types
let ( let* ) = Result.bind
let fields = function `Assoc fields -> Ok fields | _ -> W.wire_here W.Expected_object
let exact = W.exact_field_names_result
let value key fields = W.wire_json_field key fields
let text key fields = W.wire_string_field key fields
let parsed result = Result.map_error (fun detail -> W.{path=[];reason=Invalid_task_context detail}) result
let nonblank key fields =
  let* s = text key fields in
  if String.trim s = "" then W.wire_fail [W.Wire_field key] W.Blank_string else Ok s
let list parse = function
  | `List values ->
    List.fold_right (fun value rest -> let* item = parse value in let* rest = rest in Ok (item :: rest)) values (Ok [])
  | _ -> W.wire_here W.Expected_array

let source_error_of_json json =
  let* f = fields json in
  let* kind = text "kind" f in
  match kind with
  | "goal_links_unavailable" ->
    let* () = exact ["kind";"detail"] f in
    let* detail = text "detail" f in Ok (Goal_links_unavailable detail)
  | "goal_source_unavailable" ->
    let* () = exact ["kind";"error"] f in
    let* error = value "error" f in
    let* error = parsed (Goal_store_unavailable.record_of_yojson error) in
    Ok (Goal_source_unavailable error)
  | "linked_goal_missing" ->
    let* () = exact ["kind";"goal_id"] f in
    let* goal_id = nonblank "goal_id" f in Ok (Linked_goal_missing goal_id)
  | _ -> W.wire_fail [W.Wire_field "kind"] (W.Unknown_token kind)

let goal_of_json json =
  let* f = fields json in
  let* () = exact ["goal_id";"phase";"criterion"] f in
  let* goal_id = nonblank "goal_id" f in
  let* raw_phase = text "phase" f in
  let* phase = match Goal_phase.of_string raw_phase with
    | Some phase -> Ok phase | None -> W.wire_fail [W.Wire_field "phase"] (W.Unknown_token raw_phase) in
  let* criterion = value "criterion" f in
  let* criterion = parsed (Goal_store.criterion_of_yojson criterion) in
  Ok {goal_id;phase;criterion}

let goals_of_json json =
  let* f = fields json in
  let* kind = text "kind" f in
  match kind with
  | "observed" ->
    let* () = exact ["kind";"goals"] f in
    let* values = value "goals" f in
    let* goals = list goal_of_json values in
    let ids = List.map (fun goal -> goal.goal_id) goals in
    if List.length ids <> List.length (List.sort_uniq String.compare ids)
    then W.wire_here (W.Invalid_task_context "duplicate Goal ids") else Ok (Ok goals)
  | "unavailable" ->
    let* () = exact ["kind";"error"] f in
    let* error = value "error" f in
    let* error = source_error_of_json error in Ok (Error error)
  | _ -> W.wire_fail [W.Wire_field "kind"] (W.Unknown_token kind)

let of_json json =
  let* f = fields json in
  let* kind = text "kind" f in
  match kind with
  | "admission_not_recorded" ->
    let* () = exact ["kind"] f in Ok Admission_not_recorded
  | "no_task" -> let* () = exact ["kind"] f in Ok No_task
  | "task_source_unavailable" ->
    let* () = exact ["kind";"detail"] f in
    let* detail = text "detail" f in Ok (Task_source_unavailable detail)
  | "task" ->
    let* () = exact ["kind";"task_id";"goals"] f in
    let* raw = text "task_id" f in
    let* task_id = parsed (Keeper_id.Task_id.of_string raw) in
    let* goals = value "goals" f in
    let* goals = goals_of_json goals in Ok (Task {task_id;goals})
  | _ -> W.wire_fail [W.Wire_field "kind"] (W.Unknown_token kind)
