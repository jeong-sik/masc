let pending config =
  Workspace_backlog.read_backlog_r config
  |> Result.map (fun (backlog : Masc_domain.backlog) ->
    backlog.pending_completion_rejections)

let acknowledge config ~task_id ~verification_id =
  Workspace_utils_ops.with_file_lock_r
    config
    (Workspace_backlog.backlog_lock_path config)
    (fun () ->
      match Workspace_backlog.read_backlog_r config with
      | Error _ as error -> error
      | Ok backlog ->
        let remaining =
          List.filter
            (fun (pending : Masc_domain.pending_completion_rejection) ->
              not (String.equal pending.task_id task_id
                   && String.equal pending.verification_id verification_id))
            backlog.pending_completion_rejections
        in
        if List.length remaining = List.length backlog.pending_completion_rejections
        then Ok ()
        else
          Workspace_backlog.write_backlog_result config
            { backlog with pending_completion_rejections = remaining }
          |> Result.map (fun _ -> ()))
  |> function
  | Ok result -> result
  | Error error -> Error (Masc_domain.masc_error_to_string error)
