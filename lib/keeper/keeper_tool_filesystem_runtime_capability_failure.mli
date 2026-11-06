(** The reports of a failed capability write in
    [Keeper_tool_filesystem_runtime].

    [capability_write_failure_json] and [capability_recovery_failure_json]
    render a write failure and a recovery failure as JSON.
    [capability_write_primary_failure_json] and
    [capability_write_cleanup_failure_json] render the primary failure and a
    cleanup failure of a write error.
    [observe_capability_write_error] logs the primary failure and the cleanup
    failures of a capability write error, and
    [observe_capability_directory_sync_error] logs those of a failed directory
    sync. [observe_capability_write_failure_backtrace],
    [observe_capability_recovery_failure],
    [observe_capability_write_primary_failure] and
    [observe_capability_write_cleanup_failure] are the log lines they are
    built from; each starts with [WRITE_AUDIT].
    [Keeper_tool_filesystem_runtime] includes this module. *)

val capability_write_failure_json :
  Fs_compat.capability_write_failure ->
  Yojson.Safe.t

val capability_recovery_failure_json :
  Fs_compat.capability_recovery_failure ->
  Yojson.Safe.t

val capability_write_primary_failure_json :
  Fs_compat.capability_write_primary_failure ->
  Yojson.Safe.t

val capability_write_cleanup_failure_json :
  Fs_compat.capability_write_cleanup_failure ->
  Yojson.Safe.t

val observe_capability_recovery_failure :
  keeper_name:string ->
  target:string -> Fs_compat.capability_recovery_failure -> unit

val observe_capability_write_primary_failure :
  keeper_name:string ->
  target:string -> Fs_compat.capability_write_primary_failure -> unit

val observe_capability_write_cleanup_failure :
  keeper_name:string ->
  target:string -> Fs_compat.capability_write_cleanup_failure -> unit

val observe_capability_write_error :
  keeper_name:string ->
  target:string -> Fs_compat.capability_write_error -> unit

val observe_capability_directory_sync_error :
  keeper_name:string ->
  target:string -> Fs_compat.capability_directory_sync_error -> unit
