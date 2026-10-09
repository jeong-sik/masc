module Read = Masc.Keeper_native_task_read
module Task = Runtime_native_tasks
let ( let* ) = Result.bind

type error =
  | Transport of string
  | Http_refused of int
  | Invalid_json of string
  | Invalid_response of Read.decode_error
  | Service of Read.failure
  | Persistence of Read.receiver * Read.error_code
  | Receiver_read of Read.receiver * error
type task =
  { store_id : string; origin : Task.origin; status : Task.status option; terminal : Task.terminal option
  ; subagent_type : string option; usage : Task.usage option
  ; last_tool_name : string option; skip_transcript : bool option; ambient : bool option
  ; is_backgrounded : bool option; end_time : int option; total_paused_ms : int option
  ; reason : Task.reason option; boundary : Task.boundary }
type store =
  { receiver : Read.receiver; store_id : string; cursor : Read.cursor option; tasks : task list
  ; error : error option; health : Read.health; cleanup : string list }
type t =
  { keeper_name : string option; inventory : Read.receivers option; stores : store list; error : error option }
let empty = {keeper_name=None;inventory=None;stores=[];error=None}
let failed previous error = {previous with error=Some error}
let tasks state = List.concat_map (fun (store:store) -> store.tasks) state.stores
let errors state =
  Option.to_list state.error
  @ List.filter_map (fun (store:store) ->
      Option.map (fun error -> Receiver_read (store.receiver,error)) store.error) state.stores
  @ (match state.inventory with
     | None -> []
     | Some inventory -> List.filter_map (fun (entry:Read.entry) ->
         match entry.storage with
         | Read.Audited _ -> None
         | Read.Failed code -> Some (Persistence (entry.receiver,code))) inventory.receivers)

let code_text = function
  | Read.Store_missing -> "store missing"
  | Invalid_scope -> "invalid receiver scope"
  | Cursor_store_mismatch -> "store incarnation changed"
  | Cursor_ahead -> "cursor ahead of committed history"
  | Store_corrupt -> "store corrupt"
  | Conflicting_uuid -> "conflicting event UUID"
  | Sequence_exhausted -> "sequence exhausted"
  | Io_failed -> "I/O failed"
  | Directory_prepare_failed -> "directory unavailable"
  | Store_unavailable -> "store unavailable"
  | Commit_unconfirmed -> "commit unconfirmed"
  | Invalid_query -> "invalid query"
  | Invalid_keeper -> "invalid Keeper"
let receiver_text (receiver:Read.receiver) =
  receiver.receiver_generation ^ " / " ^ receiver.session_id
let rec error_text = function
  | Transport detail -> "transport: " ^ detail
  | Http_refused status -> Printf.sprintf "HTTP %d refused native-task read" status
  | Invalid_json detail -> "invalid JSON: " ^ detail
  | Invalid_response error -> Read.decode_error_to_string error
  | Service failure -> code_text failure.error
  | Persistence (receiver,code) -> receiver_text receiver ^ ": " ^ code_text code
  | Receiver_read (receiver,error) -> receiver_text receiver ^ ": " ^ error_text error

let health_diagnostics = function
  | Read.Unavailable code -> ["persistence health unavailable: " ^ code_text code]
  | Read.Process_only {issues;_} ->
      List.concat_map (fun (issue:Read.issue) ->
        Option.to_list (Option.map code_text issue.error)
        @ List.map (fun operation -> "cleanup failed: " ^ operation) issue.cleanup_failures) issues
let rec error_diagnostics = function
  | Service failure -> (match failure.health with None -> [] | Some health -> health_diagnostics health)
  | Receiver_read (_,error) -> error_diagnostics error
  | Transport _ | Http_refused _ | Invalid_json _ | Invalid_response _ | Persistence _ -> []
let diagnostics state =
  let inventory = match state.inventory with
    | None -> []
    | Some inventory -> health_diagnostics inventory.health
        @ List.map (fun operation -> "cleanup failed: " ^ operation) inventory.cleanup_failures in
  let retained = match state.inventory with
    | None -> []
    | Some inventory ->
        List.filter_map (fun (store:store) ->
          if List.exists (fun (entry:Read.entry) -> entry.receiver=store.receiver
            && match entry.storage with
               | Read.Audited cursor -> cursor.store_id=store.store_id
               | Read.Failed _ -> true) inventory.receivers
          then None else Some "retained receiver history absent from latest inventory") state.stores in
  List.sort_uniq String.compare (inventory @ retained @
    List.concat_map error_diagnostics (errors state) @
    List.concat_map (fun (store:store) -> health_diagnostics store.health
      @ List.map (fun operation -> "cleanup failed: " ^ operation) store.cleanup) state.stores)

let reported old fresh = match fresh with None -> old | Some _ -> fresh
let apply_observation ~store_id tasks (observation:Task.t) =
  let previous = List.find_opt (fun task -> task.origin=observation.origin) tasks in
  let task = match previous with
    | Some task -> task
    | None -> {store_id;origin=observation.origin;status=None;terminal=None;subagent_type=None;
        usage=None;last_tool_name=None;skip_transcript=None;ambient=None;
        is_backgrounded=None;end_time=None;total_paused_ms=None;reason=None;
        boundary=observation.boundary} in
  let task = match observation.event with
    | Task.Task_registered {subagent_type;skip_transcript;ambient;is_backgrounded} ->
        {task with subagent_type=reported task.subagent_type subagent_type;
          is_backgrounded=reported task.is_backgrounded is_backgrounded;
          skip_transcript=reported task.skip_transcript skip_transcript;
          ambient=reported task.ambient ambient}
    | Task_patched {status;is_backgrounded;end_time;total_paused_ms} ->
        {task with status=reported task.status status;
          is_backgrounded=reported task.is_backgrounded is_backgrounded;
          end_time=reported task.end_time end_time;
          total_paused_ms=reported task.total_paused_ms total_paused_ms}
    | Task_progress_reported {usage;last_tool_name} ->
        {task with usage=Some usage;last_tool_name=reported task.last_tool_name last_tool_name}
    | Task_terminal_reported {outcome;usage;skip_transcript;ambient;reason} ->
        {task with terminal=Some outcome;usage=reported task.usage usage;
          reason=reported task.reason reason;
          skip_transcript=reported task.skip_transcript skip_transcript;
          ambient=reported task.ambient ambient} in
  let task={task with boundary=observation.boundary} in
  match previous with
  | None -> tasks @ [task]
  | Some _ -> List.map (fun old -> if old.origin=task.origin then task else old) tasks

let decode ~fetch path =
  let* status, body = fetch path |> Result.map_error (fun detail -> Transport detail) in
  let parsed = match Yojson.Safe.from_string body with
    | json -> Read.of_json json |> Result.map_error (fun error -> Invalid_response error)
    | exception Yojson.Json_error detail -> Error (Invalid_json detail) in
  if Masc.Tui_decode.is_success_http_status status then
    let* response=parsed in
    match response with
    | Read.Failure _ -> Error (Invalid_response Read.Unexpected_response)
    | Read.Records _ | Read.Receivers _ -> Ok response
  else match parsed with
    | Ok (Read.Failure failure) -> Error (Service failure)
    | Ok (Read.Records _ | Read.Receivers _) | Error _ -> Error (Http_refused status)

let prefix keeper_name = "/api/v1/keepers/"
  ^ Uri.pct_encode ~component:(`Custom (`Path,"","/")) keeper_name ^ "/native-tasks/"
let records_path keeper_name (receiver:Read.receiver) after =
  let query = ["receiver_generation",receiver.receiver_generation;"session_id",receiver.session_id]
    @ (match after with None -> [] | Some (cursor:Read.cursor) ->
        ["store_id",cursor.store_id;"after_sequence",string_of_int cursor.after_sequence]) in
  Uri.with_query' (Uri.of_string (prefix keeper_name ^ "records")) query |> Uri.to_string

let read ~keeper_name ~fetch ~previous =
  let* ()=match previous.keeper_name with
    | None -> Ok ()
    | Some owner when owner=keeper_name -> Ok ()
    | Some _ -> Error (Invalid_response Read.Scope_mismatch) in
  let* response=decode ~fetch (prefix keeper_name ^ "receivers") in
  let* inventory=Read.receivers_of_response ~keeper_name response
    |> Result.map_error (fun error -> Invalid_response error) in
  let stores = List.fold_left (fun stores (entry:Read.entry) ->
    match entry.storage with
    | Read.Failed _ -> stores
    | Read.Audited advertised ->
        let same (store:store) = store.receiver=entry.receiver
          && store.store_id=advertised.store_id in
        let old=List.find_opt same stores in
        (* Discovery audited this complete committed boundary. An unchanged
           successful cursor needs no suffix HTTP read; failed reads still retry. *)
        if Option.exists (fun (store:store) ->
          store.cursor=Some advertised && store.error=None) old then stores else
        let after=Option.bind old (fun (store:store) -> store.cursor) in
        let request:Read.records_request={scope={keeper_name;receiver=entry.receiver};after} in
        let page = let* response=decode ~fetch (records_path keeper_name entry.receiver after) in
          let* page=Read.records_of_response ~request response
            |> Result.map_error (fun error -> Invalid_response error) in
          if page.next_cursor.store_id=advertised.store_id then Ok page
          else Error (Invalid_response Read.Cursor_mismatch) in
        let store = match page with
          | Ok page ->
              let tasks=List.fold_left (fun tasks (row:Read.record) ->
                apply_observation ~store_id:advertised.store_id tasks row.observation)
                (match old with None -> [] | Some store -> store.tasks) page.records in
              {receiver=entry.receiver;store_id=advertised.store_id;
                cursor=Some page.next_cursor;tasks;error=None;
                health=page.health;cleanup=page.cleanup_failures}
          | Error error -> (match old with
              | Some store -> {store with error=Some error}
              | None -> {receiver=entry.receiver;store_id=advertised.store_id;
                  cursor=None;tasks=[];
                  error=Some error;health=inventory.health;cleanup=[]}) in
        match old with
        | None -> stores @ [store]
        | Some _ -> List.map (fun old -> if same old then store else old) stores)
      previous.stores inventory.receivers in
  Ok {keeper_name=Some keeper_name;inventory=Some inventory;stores;error=None}
