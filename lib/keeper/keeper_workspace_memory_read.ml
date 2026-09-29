let failure ~failure_class detail =
  Keeper_tool_execution.failure_data ~class_:failure_class ~message:detail
    (`Assoc ["ok", `Bool false; "error", `String detail])

let handle ~base_path ~args =
  match args with
  | `Assoc [] ->
    (match Domain_pool_ref.submit_io_or_inline (fun () ->
       Workspace_memory_ledger_view.summary ~base_path) with
     | Ok json -> Keeper_tool_execution.success_data
         (`Assoc ["ok", `Bool true; "workspace_memory", json])
     | Error detail -> failure ~failure_class:Tool_result.Dependency_unavailable detail)
  | `Assoc ["id", `String id] when String.trim id <> "" ->
    (match Domain_pool_ref.submit_io_or_inline (fun () ->
       Workspace_memory_ledger_view.detail ~base_path ~id) with
     | Ok json -> Keeper_tool_execution.success_data
         (`Assoc ["ok", `Bool true; "workspace_memory", json])
     | Error detail -> failure ~failure_class:Tool_result.Dependency_unavailable detail)
  | _ -> failure ~failure_class:Tool_result.Policy_rejection
      "Expected an object with optional nonblank claim or conflict id"
