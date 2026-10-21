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
let source = function
  | `String "activity-events" -> Ok Tui_decode.Task_activity
  | `String "events" -> Ok Tui_decode.Task_audit
  | _ -> Error "Unknown Task history source"
let source_name = function Tui_decode.Task_activity -> "activity-events" | Tui_decode.Task_audit -> "events"
let original_ids fields = List.filter_map (fun key -> List.assoc_opt key fields) ["task";"task_id"]
let exact_ids ~task_id identities =
  if identities=[] then Error "Task observation lacks its original Task identity"
  else List.fold_left (fun prior identity -> let* ()=prior in let* id=nonblank identity in
    if id=task_id then Ok () else Error "Task observation has a conflicting original Task") (Ok ()) identities
let entity = function
  | `Null -> Ok None
  | json ->
    let* fields=Agent_core.Execution_json.object_fields ~context:"Task history entity"
      ~required:["kind";"id"] ~optional:[] json in
    let* kind=nonblank (List.assoc "kind" fields) in
    let* id=nonblank (List.assoc "id" fields) in Ok (Some (kind,id))
let history ~task_id json =
  let* () = validate json in
  let* rows = match json with `List rows -> Ok rows | _ -> Error "Task history is not a list" in
  let* reversed=List.fold_left (fun prior row ->
    let* acc=prior in
    let* envelope=Agent_core.Execution_json.object_fields ~context:"Task physical observation"
      ~required:["source";"file";"offset";"event"] ~optional:[] row in
    let* source=source (List.assoc "source" envelope) in
    let* file=nonblank (List.assoc "file" envelope) in
    let* ()=match String.split_on_char '/' file with
      | [store;month;name] when store=source_name source ->
        (match Dated_jsonl.Layout.year_and_month_of_directory_name month with
         | Some (year,month) when Dated_jsonl.Layout.day_file_name_is_valid ~year ~month name -> Ok ()
         | Some _ | None -> Error "Task observation has an invalid dated file")
      | _ -> Error "Task observation file differs from its declared source" in
    let* offset=match List.assoc "offset" envelope with `Int offset when offset>=0 -> Ok offset
      | _ -> Error "Invalid original Task byte offset" in
    let origin : Tui_decode.task_history_origin={tho_source=source;tho_file=file;tho_offset=offset} in
    let raw=List.assoc "event" envelope in
    let* fields=match raw with `Assoc fields -> Ok fields | _ -> Error "Task history event is not an object" in
    let* event=match source with
      | Tui_decode.Task_audit ->
        let* ()=exact_ids ~task_id (original_ids fields) in
        (match Tui_decode.decode_task_history (`List [raw]) with
         | Ok [event] -> Ok {event with th_origin=Some origin}
         | Ok _ -> Error "Task audit observation count changed" | Error error -> Error error)
      | Tui_decode.Task_activity ->
        let* _fields=Agent_core.Execution_json.object_fields ~context:"canonical Task activity"
          ~required:["seq";"ts_ms";"ts_iso";"kind";"actor";"subject";"payload";"tags"]
          ~optional:["context"] raw in
        let ids fields=Option.to_list (List.assoc_opt "task_id" fields) in
        let* ()=match List.assoc_opt "tags" fields with
          | Some (`List tags) when List.for_all (function `String _ -> true | _ -> false) tags -> Ok ()
          | Some _ | None -> Error "Invalid canonical activity tags" in
        let* event=match Activity_graph.event_of_yojson raw with
          | Some event -> Ok event | None -> Error "Invalid canonical Task activity" in
        let* actor=match List.assoc_opt "actor" fields with Some json -> entity json
          | None -> Error "Task activity lacks actor observation" in
        let* subject=match List.assoc_opt "subject" fields with Some json -> entity json
          | None -> Error "Task activity lacks subject observation" in
        let payload=match event.payload with `Assoc fields -> fields | _ -> [] in
        let* context=match List.assoc_opt "context" fields with
          | None -> Ok [] | Some (`Assoc fields) -> Ok fields | Some _ -> Error "Invalid Task context" in
        let identities=ids payload @ ids context
          @ (match subject with Some ("task",id) -> [`String id] | Some _ | None -> []) in
        let* ()=exact_ids ~task_id identities in
        let string key=match List.assoc_opt key payload with Some (`String value) -> Some value | _ -> None in
        Ok {Tui_decode.th_origin=Some origin;th_ts=event.ts_iso;th_label=event.kind;
          th_actor=Option.map (fun (_,id) -> id) actor;
          th_from_status=string "from_status";th_to_status=string "to_status";
          th_note=Some (Yojson.Safe.pretty_to_string event.payload)} in
    if List.exists (fun (prior:Tui_decode.task_history_event) -> prior.th_origin=Some origin) acc
    then Error "Task history repeated one physical observation" else Ok (event::acc)
  ) (Ok []) rows in
  Ok (List.rev reversed)

let history_verification_id row =
  let* envelope=Agent_core.Execution_json.object_fields ~context:"Task verification observation"
    ~required:["source";"file";"offset";"event"] ~optional:[] row in
  let* source=source (List.assoc "source" envelope) in
  let* event=match List.assoc "event" envelope with
    | `Assoc fields -> Ok fields
    | _ -> Error "Task history event is not an object" in
  let fields=match source with
    | Tui_decode.Task_audit -> event
    | Tui_decode.Task_activity ->
      (match List.assoc_opt "payload" event with
       | Some (`Assoc fields) -> fields
       | Some _ | None -> []) in
  match List.filter (fun (name,_) -> name="verification_id") fields with
  | [] | [_,`Null] -> Ok None
  | [_,json] -> Result.map Option.some (nonblank json)
  | _ -> Error "Task history has duplicate verification identities"

type history_source_state = Source_observed | Source_not_created
type history =
  { history_task_id : string
  ; history_sources : (Tui_decode.task_history_source * history_source_state) list
  ; history_events : Tui_decode.task_history_event list
  ; history_records : Yojson.Safe.t list
  ; history_verifications : string list
  ; history_next_cursor : string option
  ; history_cursors : string list }
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
    ~required:["schema";"task_id";"cursor";"sources";"events";"next_cursor"] ~optional:[] json in
  let* ()=match List.assoc "schema" fields with
    | `String "masc.task-history.page/v2" -> Ok () | _ -> Error "Unsupported Task history page schema" in
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
  let* sources=match List.assoc "sources" fields with
    | `List rows -> List.fold_left (fun prior row ->
      let* acc=prior in
      let* fields=Agent_core.Execution_json.object_fields ~context:"Task history source coverage"
        ~required:["source";"state"] ~optional:[] row in
      let* source=source (List.assoc "source" fields) in
      let* state=match List.assoc "state" fields with
        | `String "observed" -> Ok Source_observed | `String "not-created" -> Ok Source_not_created
        | _ -> Error "Unknown Task source observation" in
      if List.mem_assoc source acc then Error "Repeated Task history source" else Ok (acc @ [source,state])) (Ok []) rows
    | _ -> Error "Missing Task source observations" in
  let* ()=if List.mem_assoc Tui_decode.Task_activity sources && List.mem_assoc Tui_decode.Task_audit sources
    && List.exists (fun (_,state) -> state=Source_observed) sources then Ok () else Error "Incomplete Task source observations" in
  let* ()=match request.hr_prefix with
    | Some prefix when prefix.history_sources<>sources -> Error "Task history source coverage changed"
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
      let* value=history_verification_id row in
      match value with
      | None -> Ok (seen,ids)
      | Some id when Verification_ids.mem id seen -> Ok (seen,ids)
      | Some id -> Ok (Verification_ids.add id seen,id::ids)) (Ok (verification_seen,List.rev prefix)) rows
    | _ -> Error "Task history events are not a list" in
  let history_verifications=List.rev rev_ids in
  let* ()=List.fold_left (fun prior (event:Tui_decode.task_history_event) ->
    let* ()=prior in match event.th_origin with
    | Some origin when List.assoc_opt origin.tho_source sources=Some Source_observed -> Ok ()
    | Some _ | None -> Error "Task observation came from an unobserved source") (Ok ()) events in
  let* ()=if List.length events<=request.hr_limit then Ok () else Error "Task history page exceeds its requested demand" in
  let* events=match request.hr_prefix with
    | None -> Ok events
    | Some prefix ->
      if List.exists (fun (event:Tui_decode.task_history_event) ->
        List.exists (fun (prior:Tui_decode.task_history_event) -> prior.th_origin=event.th_origin) prefix.history_events) events
      then Error "Task continuation repeated an original physical observation"
      else Ok (prefix.history_events @ events) in
  Ok {history_task_id=id;history_sources=sources;history_events=events;history_records;history_verifications;history_next_cursor=next;history_cursors=seen}


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
