type error = Search_text_unavailable

type status = [ `OK | `Service_unavailable ]

let document (task : Masc_domain.task) =
  let revision = Digestif.SHA256.(digest_string task.description |> to_hex) in
  `Assoc [ "id", `String task.id; "description", `String task.description;
           "description_revision", `String revision ]

let read ~config =
  try
    match Workspace_backlog.read_backlog_r config with
    | Error _ -> Error Search_text_unavailable
    | Ok backlog -> Ok (`Assoc ["tasks", `List (List.map document backlog.tasks)])
  with
  | Sys_error _ | Unix.Unix_error _
  | Workspace_backlog.Backlog_read_failed _ -> Error Search_text_unavailable

let response result : status * Yojson.Safe.t =
  match result with
  | Ok json -> `OK, json
  | Error Search_text_unavailable ->
      `Service_unavailable, `Assoc ["error", `String "task search text unavailable"]
