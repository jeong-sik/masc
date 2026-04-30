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
    - {b readonly classification + diagnosis}
      ({!readonly_shell_token_match},
      {!readonly_hint_of_category},
      {!diagnosis_of_readonly_category},
      {!diagnosis_of_block_reason}).
    - {b path resolution / autocorrect} for keeper_shell read/write
      ({!resolve_keeper_shell_read_cwd},
      {!resolve_keeper_shell_write_cwd},
      {!resolve_keeper_shell_read_path},
      {!auto_correct_path}).
    - {b docker dispatch aliases} re-exported from
      {!Keeper_shell_docker} so callers (tests, doc refs) that
      historically pointed at this module continue to compile. *)

(** {1 Shell op SSOT (issue #8524)} *)

type shell_op =
  | Pwd
  | Ls
  | Cat
  | Rg
  | Git_status
  | Find
  | Head
  | Tail
  | Wc
  | Tree
  | Git_log
  | Git_diff
  | Git_worktree
  | Git_clone
  | Gh

val shell_op_to_string : shell_op -> string
val all_shell_ops : shell_op list
val valid_shell_op_strings : string list

(** {1 Shell timeouts} *)

val env_float : string -> float -> float
(** [env_float name default] reads [name] from the process env and
    parses it as a float; falls back to [default] on missing or
    malformed values.  Used by the timeout constants below. *)

val io_timeout_sec : float
(** Network/disk-bound commands (git status, ls on large dirs,
    custom bash).  Default 30s, env: [MASC_KEEPER_IO_TIMEOUT_SEC]. *)

val read_timeout_sec : float
(** Fast read-only commands (cat, rg, head, tail, find, git_log,
    tree).  Default 15s, env: [MASC_KEEPER_READ_TIMEOUT_SEC]. *)

val user_timeout_max_sec : float
(** Upper bound for user-provided [timeout_sec] in keeper_bash.
    Default 180s, env: [MASC_KEEPER_USER_TIMEOUT_MAX_SEC]. *)

val gh_min_timeout_sec : float
(** Floor for gh op [timeout_sec] (15s).  Hardcoded — operators
    cannot lower; sub-network-latency timeouts cause cascading 401
    retries (#8688). *)

val git_meta_timeout_sec : float
(** Ceiling for lightweight git metadata commands (rev-parse,
    log --oneline).  Default 5s, env:
    [MASC_KEEPER_GIT_META_TIMEOUT_SEC]. *)

val clamp_shell_timeout :
  ?min_sec:float -> default:float -> Yojson.Safe.t -> float
(** [clamp_shell_timeout ?min_sec ~default args] reads the
    optional [timeout_sec] field from [args], clamps it to
    [\[min_sec, user_timeout_max_sec\]] (default [min_sec=1.0]),
    and falls back to [default] when absent. *)

(** {1 Word + git-token tokenization} *)

val lowercase_shell_words : string -> string list
(** Re-export of {!Keeper_exec_shared.lowercase_shell_words}.  Splits
    [text] into space-separated tokens with [String.lowercase_ascii]
    applied to each. *)

val git_global_option_takes_value : string -> bool
(** [-c], [-C], [--exec-path], [--git-dir], [--work-tree],
    [--namespace], [--super-prefix], [--config-env]. *)

val git_global_option_has_inline_value : string -> bool
(** [--exec-path=…], [--git-dir=…], etc. *)

val first_git_subcommand : string list -> string option
(** Skip leading [git] global options and return the first
    subcommand token, or [None] when [tokens] terminates without
    one. *)

(** {1 Readonly classification + diagnosis} *)

val readonly_shell_token_match : string list -> (string * string) option
(** [(matched_prefix, category)] when the token list contains a
    write command that the readonly shell must reject.  Categories
    are {!readonly_hint_of_category} keys: ["git_write"],
    ["package_install"], ["destructive"]. *)

val readonly_hint_of_category : string -> string
(** Human-readable rewrite hint per category, ending with explicit
    Good:/Bad: examples so small-LLM keepers can self-correct
    without a retry loop (#8688).  Categories: ["chaining"],
    ["redirect"], ["git_write"], ["package_install"],
    ["destructive"]; unknown categories yield a generic message. *)

val diagnosis_of_readonly_category : string -> Exec_core.diagnosis option
(** Machine-parseable counterpart of {!readonly_hint_of_category}.
    Returns [None] for unknown categories. *)

val diagnosis_of_block_reason :
  Worker_dev_tools.block_reason -> Exec_core.diagnosis option
(** Map a {!Worker_dev_tools.block_reason} to a structured
    diagnosis (rule_id + explanation + suggested rewrite or
    [tool_suggestion]). *)

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
(** [command -v <name>] probe inside [/bin/sh -c], with
    {!Env_config_exec_timeout.timeout_sec} budget for the
    [Shell_probe] caller bucket. *)

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

(** {1 Docker dispatch aliases (re-exported from Keeper_shell_docker)} *)

val effective_sandbox_profile :
  meta:Keeper_types.keeper_meta ->
  in_playground:bool ->
  Keeper_types.sandbox_profile * Keeper_types.network_mode
(** Alias of {!Keeper_shell_docker.effective_sandbox_profile}. *)

val cmd_targets_git_or_gh : string -> bool
(** Alias of {!Keeper_shell_docker.cmd_targets_git_or_gh}. *)

val cmd_targets_gh : string -> bool
(** Local definition — first whitespace-separated word equals
    ["gh"]. *)

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

val run_docker_with_git_bash :
  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  unit ->
  string
(** Alias of {!Keeper_shell_docker.run_docker_with_git_bash}. *)

val run_docker_hardened_bash :
  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  network_mode:Keeper_types.network_mode ->
  string
(** Alias of {!Keeper_shell_docker.run_docker_hardened_bash}. *)
