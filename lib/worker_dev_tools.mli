(** Worker_dev_tools — file_read / file_write / shell_exec for Fleet
    autonomous-coding agents.

    Surface composition:

    - {!Shell_safety_types} re-exported via [include] (line 13 of the .ml).
      Provides [destructive_class], destructive pattern metadata, and
      command-log hash helpers.
    - {!Exec_policy} re-exported for compatibility. Provides [block_reason],
      command-validation gates, Shell IR path validation, mutation classifiers,
      and log-redaction helpers.
    - {!Gh_command_validation} re-exported via [include]. Provides
      [gh_reversibility] + [gh] command validators.
    - This module's own surface: attribution helper and the Agent SDK tool
      factories ({!make_tools}, {!make_readonly_tools}).

    Internal helpers stay hidden: [mkdir_p], the underlying file_read/
    file_write/shell_exec tool builders, and parser-reason tag helpers. *)

include module type of Shell_safety_types

(** {1 Command validation} *)

(** Closed taxonomy of reasons {!validate_command} /
    {!validate_command_coding} reject a candidate shell command.  The
    [Command_not_allowed] payload carries the offending command name
    so the caller can render an actionable hint. *)
type block_reason = Exec_policy.block_reason =
  | Empty_command
  | Chain_or_redirect
  | Injection
  | Process_substitution
  | Unsafe_redirect
  | Pipes_not_allowed
  | Direct_dune_invocation
  | Command_not_allowed of string

(** Render a {!block_reason} as the operator-visible error string
    embedded in tool result payloads.  Wording is pinned (LLM
    prompt-conditioning depends on the exact alternatives listed for
    {!Chain_or_redirect}, {!Injection}, etc.). *)
val block_reason_to_string : block_reason -> string

val block_reason_to_string_with_allowlist :
  allowed_commands:string list -> block_reason -> string
(** Render a {!block_reason} with a caller-specific allowlist in the
    [Command_not_allowed] hint. Use this when the caller deliberately
    passes a narrower allowlist than {!validate_command_coding}; otherwise
    the generic hint can name commands that the caller still rejects. *)

(** The default dev allowlist (cat, cargo, dune-local.sh, git, rg, ...).  Used by
    {!validate_command} internally and by the Shell IR coding gate.  Order is
    the source of truth; do not re-sort without confirming all validation
    consumers are tolerant. *)
val dev_allowed_commands : string list

(** Strict (allowlist + no shell metacharacters) validator used by the
    default [shell_exec] tool.  Rejects empty input, chaining, and any
    command outside the dev allowlist (rg / grep / dune-local.sh / git / ...).
    Bare [dune] is intentionally rejected; local agents must use
    [scripts/dune-local.sh] so builds share the host-wide lock.
    [?caller] is accepted for call-site compatibility; strict validation
    keeps the existing single-command wire shape. *)
val validate_command
  :  ?caller:Masc_exec_command_gate.Shell_command_gate.caller
  -> string
  -> (unit, block_reason) result

(** Relaxed validator for Coding/Full preset keepers.  The authoritative
    verdict comes from {!Masc_exec_command_gate.Shell_command_gate.gate}:
    parsed pipelines validate every stage against the dev allowlist,
    redirects are rejected for the coding shell path, and parser
    bailouts fail closed with the existing {!block_reason} wire shape. *)
val validate_command_coding
  :  ?caller:Masc_exec_command_gate.Shell_command_gate.caller
  -> string
  -> (unit, block_reason) result
(** [?caller] is forwarded to {!Masc_exec_command_gate.Shell_command_gate.gate}
    for telemetry partitioning.  It does not select a fallback: the
    Shell IR facade verdict is authoritative for all callers. *)

(** Customizable variant of {!validate_command_coding} for callers that
    need a non-default allowlist.  [allow_pipes] defaults to [true];
    setting it to [false] yields {!Pipes_not_allowed} for any pipeline
    longer than one segment.  [?caller] is forwarded to
    {!Masc_exec_command_gate.Shell_command_gate.gate} for telemetry partitioning. *)
val validate_command_coding_with_allowlist
  :  ?caller:Masc_exec_command_gate.Shell_command_gate.caller
  -> ?allow_pipes:bool
  -> allowed_commands:string list
  -> string
  -> (unit, block_reason) result

(** Variant of {!validate_command_coding_with_allowlist} for callers that need
    to keep the authoritative Shell IR context for execution or follow-up
    validation. *)
val command_context_coding_with_allowlist
  :  ?caller:Masc_exec_command_gate.Shell_command_gate.caller
  -> ?allow_pipes:bool
  -> allowed_commands:string list
  -> string
  -> (Masc_exec_command_gate.Shell_command_gate.parsed_context, block_reason) result

(** When [workdir] is supplied, gate every literal path-bearing argv/redirect
    value in [shell_ir] against the path allowlist.
    Values may stay under [workdir],
    [/tmp], the owning worktree repo root, or a registered repository path
    allowed by {!Keeper_repo_mapping} when both [keeper_id] and [base_path]
    are supplied. Returns [Error msg] with the rejected value when a path
    escapes the allowlist.
    Returns [Ok ()] unconditionally when [workdir = None]. *)
val validate_shell_ir_paths
  :  ?keeper_id:string
  -> ?base_path:string
  -> ?workdir:string
  -> Masc_exec.Shell_ir.t
  -> (unit, string) result

(** Compatibility wrapper for legacy string call sites. Prefer
    {!validate_shell_ir_paths} when the caller already has Shell IR. *)
val validate_command_paths
  :  ?keeper_id:string
  -> ?base_path:string
  -> ?workdir:string
  -> string
  -> (unit, string) result

(** Return literal path values in [cmd] that should have their containing
    sandbox materialized before execution. This includes explicit existing-directory
    requirements (for example [git -C <dir>] and [--work-tree=<dir>]) and
    path arguments to read/list/search commands such as [cat], [find], [ls],
    and [rg]. Callers may use this to repair an expected sandbox directory
    before delegating to {!validate_command_paths}; the validator remains
    the authority for out-of-sandbox paths. *)
val existing_dir_path_values_of_shell_ir : Masc_exec.Shell_ir.t -> string list

(** Shell IR authority variant of {!existing_dir_path_values}. Prefer this
    when the caller already has typed Shell IR so argv tokens are not
    reconstructed through a diagnostic command string. *)
val existing_dir_path_values : string -> string list

(** {1 Bash safety classifiers} *)

(** [true] iff the command performs a write/mutating operation
    (git push/commit, dune clean, npm publish, mv, cp, mkdir,
    chmod, ...).  Read-only commands (git status, rg)
    return [false].

    RFC-0160 S1: IR-typed signature; caller provides parsed
    [Shell_ir.t] instead of raw string. *)
val is_write_operation : Masc_exec.Shell_ir.t -> bool

(** [true] iff [ir] is a git branch-switch / branch-mutation command
    (checkout, switch, branch -c/-m/-D, ...). *)
val is_git_branch_switch : Masc_exec.Shell_ir.t -> bool

(** [true] iff [ir] is *structurally* destructive at the bash layer:
    [rm -rf], forced [git push --force] / protected-branch push,
    [git reset --hard].

    RFC-0160 S1: dropped {!Eval_gate.detect_destructive} evasion
    fallback — typed argv eliminates raw-shell evasion by construction.
    Callers receiving raw strings must run [Eval_gate.detect_destructive]
    separately {i before} parsing. *)
val is_destructive_bash_operation : Masc_exec.Shell_ir.t -> bool

(** Transitional string wrappers (DEPRECATED — removed in RFC-0160 S4). *)
val is_write_operation_of_string : string -> bool
val is_git_branch_switch_of_string : string -> bool
val is_destructive_bash_operation_of_string : string -> bool

(** {1 Logging redaction} *)

(** Redact embedded credentials before a command is committed to a log
    line.  Strips [https://user:pw@] URL credentials, inline
    [token=]/[password=]/[api-key=] assignments, and the value
    following [--token]/[--password]/[--auth-token]/[--api-key]
    flags.  The result is suitable for human/log consumption but not
    for re-execution. *)
val sanitize_command_for_log : string -> string

(** UTF-8-safe truncation to [max_len] characters (default [240]),
    appending [...] when truncated. *)
val truncate_for_log : ?max_len:int -> string -> string

(** {1 Attribution} *)

(** Convert the result of {!validate_command} (or any validator that
    yields [block_reason]) into the {!Attribution} envelope consumed by
    the dashboard.  [Ok ()] yields a [passed] attribution; [Error br]
    yields a [policy_failed] attribution carrying the block reason tag,
    the offending command name (when {!Command_not_allowed}), and the
    operator-visible error string. *)
val attribution_of_validation : cmd:string -> (unit, block_reason) result -> Attribution.t

(** Effective [shell_exec] timeout after applying load-bearing timeout floors.
    Caller-supplied short timeouts are preserved for trivial commands, but
    git, recursive scans, and local Dune wrapper invocations are floored at the
    shared [Tool_dispatch] timeout floor. *)
val effective_shell_exec_timeout_sec : command:string -> requested:float -> float

(** {1 OAS tool factories} *)

(** Closed sum classifying the producer error categories emitted by the
    in-tree shell/file tools. Five variants mirror the categorised tags:
    [Path_blocked], [File_read_error], [File_write_error],
    [Command_blocked], [Shell_error].

    Raw strings stay only at the telemetry/wire boundary
    ([tool_exec_error_kind_to_string]); adding a new variant becomes a
    compile obligation at every observer call site. *)
type tool_exec_error_kind =
  | Path_blocked
  | File_read_error
  | File_write_error
  | Command_blocked
  | Shell_error

val tool_exec_error_kind_to_string : tool_exec_error_kind -> string

(** Per-call observer hook invoked at the end of every tool execution.

    Receives the tool name, success flag, elapsed wall-clock duration,
    and (on failure) a categorized [error_kind] tag plus the
    operator-visible [error_message].  Both error fields are
    [None] on success and on failure paths that have not yet been
    wired (the consumer should treat absence as
    [error_kind="unknown"] in metric labels).

    The categorized tags this module produces are:
    - [path_blocked] — file_read/file_write path outside allowed dirs
    - [file_read_error] — Sys_error from In_channel.with_open_text
    - [file_write_error] — Sys_error from Out_channel.with_open_bin
    - [command_blocked] — shell_exec command failed validate_command
    - [shell_error] — non-zero exit / Sys_error during shell exec

    Issue #10358: closes the 17.3% blank-error gap for tool_called
    rows fed via [worker_container.build_local_shell_tools]. *)
type tool_exec_observer =
  tool_name:string
  -> success:bool
  -> duration_ms:int
  -> ?error_kind:tool_exec_error_kind
  -> ?error_message:string
  -> unit
  -> unit

(** Build the full Fleet dev toolset: [file_read], [file_write], and
    [shell_exec].  [shell_exec] uses the strict {!validate_command}
    gate and the dev allowlist.  All tools resolve paths relative to
    [workdir] when supplied; absolute paths still pass the
    in-allowed-directories check. *)
val make_tools
  :  proc_mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> ?workdir:string
  -> ?on_exec:tool_exec_observer
  -> unit
  -> Agent_sdk.Tool.t list

(** Build the read-only subset: [file_read] + a [shell_exec] gated to
    a smaller read-only command allowlist (rg, grep, ls, cat, ...).
    [file_write] is intentionally absent. *)
val make_readonly_tools
  :  proc_mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> ?workdir:string
  -> ?on_exec:tool_exec_observer
  -> unit
  -> Agent_sdk.Tool.t list

(** {1 Gh CLI cascade} *)

include module type of Gh_command_validation
