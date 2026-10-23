let backlog_lock_path (_:Workspace_utils_backend_setup.config) = "explicit-backlog-lock-port"
let read_backlog_r (config:Workspace_utils_backend_setup.config) =
  config.read_attempts <- config.read_attempts + 1;
  config.read_scopes <- (config.lock_held,config.fence_held)::config.read_scopes;
  match config.read_failure with
  | Some detail -> Error detail
  | None -> Ok config.snapshot
let write_backlog_result (config:Workspace_utils_backend_setup.config) snapshot =
  if not config.lock_held then failwith "write without backlog lock";
  if config.fence_held then failwith "recursive writer inside publication fence";
  config.write_attempts <- config.write_attempts + 1;
  match config.write_failure with
  | Some detail -> Error detail
  | None -> config.snapshot <- snapshot;
    config.committed_writes <- config.committed_writes + 1;
    Ok ()
