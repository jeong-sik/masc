type status = [ `OK | `Bad_request | `Conflict | `Service_unavailable ]
let read ~config ~task_id ~limit ~cursor : status * Yojson.Safe.t =
  let module History = Task.History_page in
  let open Result.Syntax in
  let result =
    let* task_id=match task_id with
      | Some id when id<>"" && id=String.trim id -> Ok id
      | Some _ | None -> Error History.Invalid_request in
    let* max_events=match limit with
      | Some text -> (match int_of_string_opt text with
        | Some n when n>0 && string_of_int n=text -> Ok n
        | Some _ | None -> Error History.Invalid_request)
      | None -> Error History.Invalid_request in
    let* cursor=match cursor with
      | None -> Ok None
      | Some text -> Result.map Option.some (History.cursor_of_string text) in
    History.read ~config ~task_id ~max_events ?cursor () in
  let error name = `Assoc ["error",`String name] in
  match result with
  | Ok page -> `OK,History.to_json page
  | Error History.Invalid_request -> `Bad_request,error "task_id and a positive page limit are required"
  | Error Invalid_cursor -> `Bad_request,error "invalid_task_history_cursor"
  | Error Source_changed -> `Conflict,error "task_history_source_changed"
  | Error (Invalid_event {file;offset}) -> `Service_unavailable,
    `Assoc ["error",`String "task_history_invalid_event";"file",`String file;"offset",`Int offset]
  | Error (Invalid_layout {entry}) -> `Service_unavailable,
    `Assoc ["error",`String "task_history_invalid_layout";"entry",`String entry]
  | Error Source_unavailable -> `Service_unavailable,error "task_history_unavailable"
