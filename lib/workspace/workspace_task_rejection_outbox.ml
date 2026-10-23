type standing = Current | Obsolete

let pending config =
  Workspace_backlog.read_backlog_r config
  |> Result.map (fun (backlog : Masc_domain.backlog) ->
    backlog.pending_completion_rejections)

let same_identity ~task_id ~verification_id
      (item : Masc_domain.pending_completion_rejection) =
  String.equal item.task_id task_id
  && String.equal item.verification_id verification_id

let standing_in_backlog (backlog : Masc_domain.backlog)
      ~task_id ~verification_id ~producer ~reason ~authority =
  let relations = List.filter
    (fun (item : Masc_domain.pending_completion_rejection) ->
      String.equal item.task_id task_id)
    (backlog.pending_completion_rejections @ backlog.delivered_completion_rejections)
  in
  match relations with
  | [] ->
    (match List.find_opt (fun (task : Masc_domain.task) ->
       String.equal task.id task_id) backlog.tasks with
     | Some {task_status=Masc_domain.InProgress {assignee; _}; _}
       when String.equal assignee producer ->
       Error "completion rejection relation is unavailable for its active producer"
     | Some {task_status=(Masc_domain.Todo | Masc_domain.Claimed _
         | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
         | Masc_domain.Done _ | Masc_domain.Cancelled _); _}
     | None -> Ok Obsolete)
  | _ :: _ :: _ -> Error "multiple current completion rejection relations"
  | [item] ->
    if not (String.equal item.verification_id verification_id) then Ok Obsolete
    else if not (String.equal item.producer producer
                 && String.equal item.reason reason && item.authority = authority)
    then Error "completion rejection payload conflicts with the current relation"
    else
      match List.find_opt (fun (task : Masc_domain.task) ->
        String.equal task.id task_id) backlog.tasks with
      | Some { task_status = Masc_domain.InProgress {assignee; _}; _ }
        when String.equal assignee producer -> Ok Current
      | Some { task_status = (Masc_domain.Todo | Masc_domain.Claimed _
          | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
          | Masc_domain.Done _ | Masc_domain.Cancelled _); _ }
      | None -> Error "current completion rejection conflicts with its Task owner or state"

let standing config ~task_id ~verification_id ~producer ~reason ~authority =
  Result.bind (Workspace_backlog.read_backlog_r config)
    (fun backlog -> standing_in_backlog backlog
      ~task_id ~verification_id ~producer ~reason ~authority)

let flatten_lock = function
  | Ok result -> result
  | Error error -> Error (Masc_domain.masc_error_to_string error)

let acknowledge config ~task_id ~verification_id =
  Workspace_utils_ops.with_file_lock_r config
    (Workspace_backlog.backlog_lock_path config) (fun () ->
      let open Result.Syntax in
      let* backlog = Workspace_backlog.read_backlog_r config in
      let exact, remaining = List.partition (same_identity ~task_id ~verification_id)
        backlog.pending_completion_rejections in
      match exact with
      | [] -> Ok ()
      | [item] ->
        Workspace_backlog.write_backlog_result config
          { backlog with pending_completion_rejections = remaining;
            delivered_completion_rejections =
              item :: backlog.delivered_completion_rejections }
        |> Result.map (fun _ -> ())
      | _ :: _ :: _ -> Error "duplicate pending completion rejection identity")
  |> flatten_lock

type 'a publication = Published of 'a | Superseded

let deliver_if_pending config ~task_id ~verification_id ~producer ~reason ~authority
      ~deliver =
  Workspace_utils_ops.with_file_lock_r config
    (Workspace_backlog.backlog_lock_path config) (fun () ->
      Workspace_utils_ops.commit_under_held_lease config
        (Workspace_backlog.backlog_lock_path config) (fun () ->
          let open Result.Syntax in
          let* backlog = Workspace_backlog.read_backlog_r config in
          if not (List.exists (same_identity ~task_id ~verification_id)
            backlog.pending_completion_rejections)
          then Ok Superseded
          else
            let* current = standing_in_backlog backlog
              ~task_id ~verification_id ~producer ~reason ~authority in
            match current with
            | Obsolete -> Ok Superseded
            | Current -> Result.map (fun receipt -> Published receipt) (deliver ()))
      |> function
      | Ok result -> result
      | Error refusal ->
        Error (Workspace_utils_ops.lease_commit_refusal_to_string refusal))
  |> flatten_lock
