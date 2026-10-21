module Verification_ids = Set.Make (String)
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
let detail ?previous ~task_id json =
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
  let task=match previous with
    | Some previous when Masc_domain.equal_task previous.task task -> previous.task
    | Some _ | None -> task in
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

type history =
  { history_task_id : string; history_events : Tui_decode.task_history_event list
  ; history_records : Yojson.Safe.t list; history_verifications : string list; history_next_cursor : string option; history_cursors : string list }
type history_request =
  { hr_task_id : string; hr_limit : int; hr_cursor : string option; hr_prefix : history option }
let history_first ~task_id ~limit =
  {hr_task_id=task_id;hr_limit=max 1 limit;hr_cursor=None;hr_prefix=None}
let history_earlier ~task_id ~limit prefix =
  if prefix.history_task_id<>task_id then None else match prefix.history_next_cursor with
  | None -> None
  | Some cursor -> Some {hr_task_id=task_id;hr_limit=max 1 limit;hr_cursor=Some cursor;hr_prefix=Some prefix}
let history_page ~request json =
  let* ()=validate json in
  let* fields=Agent_core.Execution_json.object_fields ~context:"original Task history page"
    ~required:["schema";"task_id";"cursor";"events";"next_cursor"] ~optional:[] json in
  let* ()=match List.assoc "schema" fields with
    | `String "masc.task-history.page/v1" -> Ok () | _ -> Error "Unsupported Task history page schema" in
  let* id=nonblank (List.assoc "task_id" fields) in
  let* ()=if id=request.hr_task_id then Ok () else Error "Task history page differs from its original Task" in
  let cursor name = match List.assoc name fields with
    | `Null -> Ok None | json -> Result.map Option.some (nonblank json) in
  let* echo=cursor "cursor" in
  let* ()=if echo=request.hr_cursor then Ok () else Error "Task history page differs from its original cursor" in
  let* next=cursor "next_cursor" in
  let seen=match request.hr_prefix with None -> [] | Some prefix -> prefix.history_cursors in
  let seen=match echo with None -> seen | Some cursor -> cursor::seen in
  let* ()=match next with Some cursor when List.mem cursor seen -> Error "Task history cursor did not advance"
    | Some _ | None -> Ok () in
  let raw_events=List.assoc "events" fields in
  let* events=history ~task_id:id raw_events in
  let prefix=match request.hr_prefix with None -> [] | Some prefix -> prefix.history_verifications in
  let verification_seen=List.fold_left (fun seen id -> Verification_ids.add id seen) Verification_ids.empty prefix in
  let* history_records=match raw_events with
    | `List rows -> Ok (match request.hr_prefix with None -> rows | Some prefix -> prefix.history_records @ rows)
    | _ -> Error "Task history events are not a list" in
  let* _,rev_ids=match raw_events with
    | `List rows -> List.fold_left (fun prior row ->
      let* seen,ids=prior in
      let* value=match row with
        | `Assoc fields ->
          (match List.filter (fun (name,_) -> name="verification_id") fields with
           | [] | [_,`Null] -> Ok None
           | [_,json] -> Result.map Option.some (nonblank json)
           | _ -> Error "Task history has duplicate verification identities")
        | _ -> Error "Task history event is not an object" in
      match value with
      | None -> Ok (seen,ids)
      | Some id when Verification_ids.mem id seen -> Ok (seen,ids)
      | Some id -> Ok (Verification_ids.add id seen,id::ids)) (Ok (verification_seen,List.rev prefix)) rows
    | _ -> Error "Task history events are not a list" in
  let history_verifications=List.rev rev_ids in
  let* ()=if List.length events<=request.hr_limit then Ok () else Error "Task history page exceeds its requested demand" in
  let events=match request.hr_prefix with None -> events | Some prefix -> prefix.history_events @ events in
  Ok {history_task_id=id;history_events=events;history_records;history_verifications;history_next_cursor=next;history_cursors=seen}

type deletion_cleanup = Cleanup_required | Cleanup_verified
type deletion_observation = {
  deletion_id : string; requested_at : string; cleanup : deletion_cleanup;
}
type observation = In_backlog of detail | In_archive of detail | Not_observed
  | Deletion_recorded of deletion_observation
let observation ~task_id json =
  let* ()=validate json in
  let* fields=Agent_core.Execution_json.object_fields ~context:"original Task observation"
    ~required:["schema";"task_id";"observation";"task";"deletion"] ~optional:[] json in
  let* ()=match List.assoc "schema" fields with
    | `String "masc.task-inspection/v1" -> Ok () | _ -> Error "Unsupported original Task observation schema" in
  let* id=nonblank (List.assoc "task_id" fields) in
  let* ()=if id=task_id then Ok () else Error "Task observation names another original Task" in
  let task=List.assoc "task" fields and deletion=List.assoc "deletion" fields in
  match List.assoc "observation" fields,task,deletion with
  | `String "backlog",(`Assoc _ as task),`Null ->
    detail ~task_id (`Assoc ["task",task]) |> Result.map (fun task -> In_backlog task)
  | `String "archive",(`Assoc _ as task),`Null ->
    detail ~task_id (`Assoc ["task",task]) |> Result.map (fun task -> In_archive task)
  | `String "not_observed",`Null,`Null -> Ok Not_observed
  | `String "deletion_recorded",`Null,(`Assoc _ as deletion) ->
    let* fields=Agent_core.Execution_json.object_fields ~context:"original Task deletion observation"
      ~required:["deletion_id";"requested_at";"cleanup"] ~optional:[] deletion in
    let* deletion_id=nonblank (List.assoc "deletion_id" fields) in
    let* requested_at=nonblank (List.assoc "requested_at" fields) in
    let* cleanup=match List.assoc "cleanup" fields with
      | `String "required" -> Ok Cleanup_required
      | `String "verified" -> Ok Cleanup_verified
      | _ -> Error "Invalid original Task deletion cleanup observation" in
    Ok (Deletion_recorded {deletion_id;requested_at;cleanup})
  | _ -> Error "Invalid original Task observation shape or state"
