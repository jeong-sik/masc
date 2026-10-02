type t =
  { task_ids : string list option
  ; assignee : string option
  ; goal_id : string option
  ; query : string option
  }

let ( let* ) = Result.bind

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
