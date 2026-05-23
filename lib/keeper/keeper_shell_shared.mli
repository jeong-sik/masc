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
      {!auto_correct_path}).
    - {b docker dispatch aliases} re-exported from
      {!Keeper_shell_docker} so callers (tests, doc refs) that
      historically pointed at this module continue to compile. *)

include module type of Keeper_shell_variant

include module type of Keeper_shell_timeout

(** {1 Git-token helpers} *)

val git_global_option_takes_value : string -> bool
(** [-c], [-C], [--exec-path], [--git-dir], [--work-tree],
    [--namespace], [--super-prefix], [--config-env]. *)

val git_global_option_has_inline_value : string -> bool
(** [--exec-path=…], [--git-dir=…], etc. *)

val first_git_subcommand : string list -> string option
(** Skip leading [git] global options and return the first
    subcommand token, or [None] when [tokens] terminates without
    one. *)

(** {1 Process status helpers} *)

val process_status_is_timeout : Unix.process_status -> bool
(** [WSIGNALED Sys.sigterm] or [WEXITED 124] (Process_eio's
    Eio.Time.Timeout exit code). *)

val replace_all_substrings :
  needle:string -> replacement:string -> string -> string
(** Naive linear-scan substring replacement.  Returns [text]
    unchanged when [needle] is empty or absent. *)

val rewrite_turn_runtime_paths_to_host :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string ->
  string
(** Rewrite occurrences of the keeper's docker container root with
    its host playground absolute path so the LLM-facing output
    references real host paths. *)

val rewrite_docker_host_paths_to_container :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string ->
  string
(** Rewrite host playground root occurrences in keeper-issued Docker
    commands to the corresponding in-container playground root before
    execution. *)

val run_argv_with_status_retry_eintr :
  ?cwd:string ->
  timeout_sec:float ->
  string list ->
  Unix.process_status * string
(** {!Process_eio.run_argv_with_status} wrapper that retries up to
    8 times when the process exits 127 with "interrupted system
    call" output.  Other statuses are returned unchanged. *)

val shell_command_available : string -> bool
(** PATH executable probe for keeper shell read fallback selection.
    This intentionally avoids [/bin/sh -c] and does not treat empty
    PATH entries as the current directory. *)

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

(** {1 Path resolution} *)

val resolve_keeper_shell_read_cwd :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result

val resolve_keeper_shell_write_cwd :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result

val auto_correct_path :
  meta:Keeper_types.keeper_meta -> string -> string option
(** Auto-correct common LLM-hallucinated path prefixes
    ([/repos/…], [repos/…], [playground/…]) into the keeper's
    real playground bundle path.  Sanitization of [meta.name]
    happens through {!Playground_paths}. *)

val resolve_keeper_shell_read_path :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result
(** Resolve the [path] arg against the keeper's read root, with
    {!auto_correct_path} as a fallback when the initial resolution
    fails.  Guards against playground-prefix doubling when both
    [cwd] and [path] independently include the playground prefix. *)

(** {1 Sandbox dispatch and command semantics} *)

val effective_sandbox_profile :
  meta:Keeper_types.keeper_meta ->
  in_playground:bool ->
  Keeper_types.sandbox_profile * Keeper_types.network_mode
(** Alias of {!Keeper_shell_docker.effective_sandbox_profile}. *)

val stages_targets_git_or_gh :
  Keeper_shell_command_semantics.parsed_stage list -> bool
(** [true] when any effective stage's executable is [git] or [gh].
    Callers pre-parse with [Shell_command_gate.parse_to_ir_opt]
    and pass [effective_stages_of_ir]. *)

val stages_targets_gh :
  Keeper_shell_command_semantics.parsed_stage list -> bool
(** [true] when any effective stage's executable is [gh]. *)

val ensure_keeper_sandbox_runtime :
  timeout_sec:float -> (string list, string) result
(** Alias of {!Keeper_shell_docker.ensure_keeper_sandbox_runtime}. *)

val command_uses_nested_container_runtime : string -> bool
(** Alias of {!Keeper_shell_docker.command_uses_nested_container_runtime}. *)

val run_docker_shell_command_with_status :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  git_creds_enabled:bool ->
  network_mode:Keeper_types.network_mode ->
  (Keeper_shell_docker.docker_shell_result, string) result
(** Alias of {!Keeper_shell_docker.run_docker_shell_command_with_status}. *)

val run_docker_credentialed_bash :
  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  unit ->
  string
(** Alias of {!Keeper_shell_docker.run_docker_credentialed_bash}. *)

val run_docker_bash :
  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  network_mode:Keeper_types.network_mode ->
  string
(** Alias of {!Keeper_shell_docker.run_docker_bash}. *)
