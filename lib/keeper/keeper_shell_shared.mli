(** Keeper_shell_shared — shared helpers for keeper_shell / keeper_bash
    pipelines.

    Co-locates SSOT pieces shared across the per-op dispatchers
    (keeper_shell_ops, keeper_shell_bash, keeper_shell_docker):

    - {b shell op SSOT} ({!shell_op}, {!shell_op_to_string},
      {!all_shell_ops}, {!valid_shell_op_strings}) — adding a
      constructor forces compilation across the dispatcher and tool
      schema (issue #8524).
    - {b shell timeouts} ({!io_timeout_sec}, {!read_timeout_sec},
      {!user_timeout_max_sec}, {!gh_min_timeout_sec},
      {!git_meta_timeout_sec}, {!clamp_shell_timeout}).
    - {b path resolution / autocorrect} for keeper_shell read/write
      ({!resolve_keeper_shell_read_cwd},
      {!resolve_keeper_shell_write_cwd},
      {!resolve_keeper_shell_read_path},
      {!auto_correct_path}). *)

include module type of Keeper_shell_variant

include module type of Keeper_shell_timeout


(** {1 Process status helpers} *)

val process_status_is_timeout : Unix.process_status -> bool
(** [WSIGNALED Sys.sigterm] or [WEXITED 124] (Process_eio's
    Eio.Time.Timeout exit code). *)

val run_argv_with_status_retry_eintr :
  ?cwd:string ->
  timeout_sec:float ->
  string list ->
  Unix.process_status * string
(** {!Process_eio.run_argv_with_status} wrapper that retries up to
    8 times when the process exits 127 with "interrupted system
    call" output.  Other statuses are returned unchanged. *)

(** {1 Playground repo cache} *)

val update_playground_repo_cache :
  playground_dir:string ->
  repo_name:string ->
  repo_path:string ->
  action:string ->
  shallow:bool ->
  unit
(** Best-effort upsert of [<playground_dir>/.playground_state.json]
    after a successful clone/pull.  Reads git metadata from
    [repo_path]; failures are logged at warn but do not propagate.
    Re-raises {!Eio.Cancel.Cancelled} so a turn cancel still
    propagates. *)


