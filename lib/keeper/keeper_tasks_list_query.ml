type t =
  { task_ids : string list option
  ; assignee : string option
  ; goal_id : string option
  ; query : string option
  }

type lifecycle_filter =
  | Active_tasks
  | Active_and_done_tasks
  | All_statuses
  | Exact_status of Masc_domain.Task_status_tag.t

open Result.Syntax

let nonblank field value =
  match value with
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error (field ^ " must be a non-blank string")
;;

let of_args = function
  | `Assoc fields ->
    let optional_string field =
      match List.assoc_opt field fields with
      | None | Some `Null -> Ok None
      | Some value -> Result.map Option.some (nonblank field value)
    in
    let* assignee = optional_string "assignee" in
    let* goal_id = optional_string "goal_id" in
    let* query = optional_string "query" in
    let* task_ids =
      match List.assoc_opt "task_ids" fields with
      | None | Some `Null -> Ok None
      | Some (`List (_ :: _ as values)) ->
        let rec parse acc = function
          | [] -> Ok (Some (List.sort_uniq String.compare acc))
          | value :: rest ->
            let* id = nonblank "task_ids entry" value in
            parse (id :: acc) rest
        in
        parse [] values
      | Some _ -> Error "task_ids must be a non-empty array of non-blank strings"
    in
    Ok { task_ids; assignee; goal_id; query }
  | _ -> Error "task list arguments must be an object"
;;

let to_yojson selection =
  let string = function None -> `Null | Some value -> `String value in
  `Assoc
    [ "task_ids", (match selection.task_ids with
        | None -> `Null
        | Some ids -> `List (List.map (fun id -> `String id) ids))
    ; "assignee", string selection.assignee
    ; "goal_id", string selection.goal_id
    ; "query", string selection.query
    ]
;;

let equal left right =
  Option.equal (List.equal String.equal) left.task_ids right.task_ids
  && Option.equal String.equal left.assignee right.assignee
  && Option.equal String.equal left.goal_id right.goal_id
  && Option.equal String.equal left.query right.query
;;

let matches selection ~goal_task_ids (task : Masc_domain.task) =
  let member ids = List.exists (String.equal task.id) ids in
  Option.fold ~none:true ~some:member selection.task_ids
  && Option.fold ~none:true ~some:member goal_task_ids
  && Option.fold ~none:true
       ~some:(fun assignee ->
         Option.equal String.equal (Some assignee)
           (Masc_domain.task_performer_of_status task.task_status))
       selection.assignee
  && Option.fold ~none:true
       ~some:(fun query ->
         let query = String.lowercase_ascii query in
         String_util.contains_substring (String.lowercase_ascii task.title) query
         || String_util.contains_substring (String.lowercase_ascii task.description) query)
       selection.query
;;

let lifecycle_filter_of_args ~selection = function
  | `Assoc fields ->
    let* status = match List.assoc_opt "status" fields with
      | None -> Ok None
      | Some `Null -> Ok (Some None)
      | Some (`String raw) ->
        (match Masc_domain.Task_status_tag.of_string raw with
         | Some status -> Ok (Some (Some status))
         | None -> Error (Printf.sprintf "status must be one of %s, got %S"
             (String.concat ", " Masc_domain.valid_task_status_strings) raw))
      | Some (`Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) ->
        Error "status must be a string" in
    let* include_done = match List.assoc_opt "include_done" fields with
      | None -> Ok None
      | Some (`Bool value) -> Ok (Some value)
      | Some _ -> Error "include_done must be a boolean" in
    (match status, include_done, selection.task_ids with
     | Some (Some status), _, _ -> Ok (Exact_status status)
     | (None | Some None), Some true, _ -> Ok Active_and_done_tasks
     | (None | Some None), Some false, _ -> Ok Active_tasks
     | None, None, Some _ -> Ok All_statuses
     | None, None, None | Some None, None, _ -> Ok Active_tasks)
  | _ -> Error "task list arguments must be an object"
;;

let lifecycle_filter_to_yojson = function
  | Active_tasks -> `Assoc ["kind", `String "active"]
  | Active_and_done_tasks -> `Assoc ["kind", `String "active_and_done"]
  | All_statuses -> `Assoc ["kind", `String "all_statuses"]
  | Exact_status status -> `Assoc ["kind", `String "status";
      "status", `String (Masc_domain.Task_status_tag.to_string status)]
;;

let lifecycle_filter_of_yojson = function
  | `Assoc ["kind", `String "active"] -> Some Active_tasks
  | `Assoc ["kind", `String "active_and_done"] -> Some Active_and_done_tasks
  | `Assoc ["kind", `String "all_statuses"] -> Some All_statuses
  | `Assoc ["kind", `String "status"; "status", `String status]
  | `Assoc ["status", `String status; "kind", `String "status"] ->
    Option.map (fun status -> Exact_status status) (Masc_domain.Task_status_tag.of_string status)
  | _ -> None
;;

let lifecycle_filter_equal left right = match left, right with
  | Active_tasks, Active_tasks | Active_and_done_tasks, Active_and_done_tasks
  | All_statuses, All_statuses -> true
  | Exact_status left, Exact_status right -> Masc_domain.Task_status_tag.equal left right
  | (Active_tasks | Active_and_done_tasks | All_statuses | Exact_status _), _ -> false
;;

let matches_lifecycle filter (task : Masc_domain.task) =
  match filter, task.task_status with
  | All_statuses, _ -> true
  | Exact_status status, _ ->
    Masc_domain.Task_status_tag.equal (Masc_domain.task_status_tag task.task_status) status
  | (Active_tasks | Active_and_done_tasks),
      (Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _) -> true
  | Active_and_done_tasks, Masc_domain.Done _ -> true
  | Active_tasks, Masc_domain.Done _
  | (Active_tasks | Active_and_done_tasks), Masc_domain.Cancelled _ -> false
;;
