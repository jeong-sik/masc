open Result.Syntax
type detail =
  { task : Masc_domain.task
  ; canonical_goal_id : string option
  ; diagnostics : Masc_domain.task_decode_diagnostics }
let validate json = Agent_core.Execution_json.validate ~context:"original Task inspection" json
  |> Result.map_error Agent_core.Execution_json.validation_error_to_string
let nonblank = function
  | `String text when String.trim text <> "" && text=String.trim text -> Ok text
  | _ -> Error "expected an exact nonblank Task identity"
let detail ~task_id json =
  let* () = validate json in
  let* envelope = Agent_core.Execution_json.object_fields ~context:"original Task detail"
      ~required:["task"] ~optional:[] json in
  let row=List.assoc "task" envelope in
  let* fields = match row with `Assoc fields -> Ok fields | _ -> Error "Task detail is not an object" in
  let* id = match List.assoc_opt "id" fields with Some json -> nonblank json | None -> Error "Task detail has no identity" in
  let* () = if id=task_id then Ok () else Error "Task detail differs from the original source Task" in
  let* canonical_goal_id = match List.assoc_opt "goal_id" fields with
    | Some `Null -> Ok None
    | Some json -> nonblank json |> Result.map Option.some
    | None -> Error "Task detail lacks its canonical Goal observation" in
  let* task,diagnostics = Masc_domain.task_of_yojson_with_diagnostics row in
  Ok {task;canonical_goal_id;diagnostics}
let history ~task_id json =
  let* () = validate json in
  let* rows = match json with `List rows -> Ok rows | _ -> Error "Task history is not a list" in
  let* () = List.fold_left (fun prior row ->
    let* () = prior in
    let* fields = match row with `Assoc fields -> Ok fields | _ -> Error "Task history row is not an object" in
    let identities=List.filter_map (fun name -> List.assoc_opt name fields) ["task";"task_id"] in
    if identities=[] then Error "Task history row has no original Task identity"
    else List.fold_left (fun prior identity -> let* () = prior in let* id=nonblank identity in
      if id=task_id then Ok () else Error "Task history row differs from the original source Task") (Ok ()) identities
  ) (Ok ()) rows in
  Tui_decode.decode_task_history json
