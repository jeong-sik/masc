(** Worker_dev_tools — file_read / file_write / shell_exec for Fleet
    autonomous-coding agents.

    Surface composition:

    - {!Gate_diff_types} re-exported via [include] (line 13 of the .ml).
      Provides [destructive_class], [legacy_verdict], [shadow_verdict],
      [gate_diff] + their tag/diff helpers.
    - {!Gh_command_validation} re-exported via [include] (line 712 of
      the .ml). Provides [gh_reversibility] + [gh] command validators.
    - This module's own surface: [block_reason] type, command-validation
      gates, attribution helper, log-redaction helpers, and the OAS tool
      factories ({!make_tools}, {!make_readonly_tools}).

    Internal helpers stay hidden: path resolution, character-class
    classifiers, pipeline tokenization, command-name extraction,
    URL/credential redaction, [mkdir_p], the underlying file_read/
    file_write/shell_exec tool builders, parser-reason tag helpers,
    and the [classify_legacy] / [classify_shadow] private classifiers
    used by {!diff_command}. *)

include module type of Gate_diff_types

(** {1 Command validation} *)

(** Closed taxonomy of reasons {!validate_command} /
    {!validate_command_coding} reject a candidate shell command.  The
    [Command_not_allowed] payload carries the offending command name
    so the caller can render an actionable hint. *)
type block_reason =
  | Empty_command
  | Chain_or_redirect
  | Injection
  | Process_substitution
  | Unsafe_redirect
  | Pipes_not_allowed
  | Command_not_allowed of string

val block_reason_to_string : block_reason -> string
(** Render a {!block_reason} as the operator-visible error string
    embedded in tool result payloads.  Wording is pinned (LLM
    prompt-conditioning depends on the exact alternatives listed for
    {!Chain_or_redirect}, {!Injection}, etc.). *)

val validate_command : string -> (unit, block_reason) result
(** Strict (allowlist + no shell metacharacters) validator used by the
    default [shell_exec] tool.  Rejects empty input, chaining, and any
    command outside the dev allowlist (rg / grep / dune / git / ...). *)

val validate_command_coding : string -> (unit, block_reason) result
(** Relaxed validator for Coding/Full preset keepers.  Allows pipes
    and fd redirects; still blocks shell injection, process
    substitution, and unsafe redirects.  Validates every segment of
    the pipeline against the dev allowlist. *)

val validate_command_coding_with_allowlist :
  ?allow_pipes:bool ->
  allowed_commands:string list ->
  string ->
  (unit, block_reason) result
(** Customizable variant of {!validate_command_coding} for callers that
    need a non-default allowlist.  [allow_pipes] defaults to [true];
    setting it to [false] yields {!Pipes_not_allowed} for any pipeline
    longer than one segment. *)

val validate_command_paths :
  ?workdir:string -> string -> (unit, string) result
(** When [workdir] is supplied, gate every path-bearing token in [cmd]
    against {!Path_compat.validate_path}.  Returns [Error msg] with the
    rejected token (or a path-rewrite-syntax reminder) when a token
    escapes [workdir].  Returns [Ok ()] unconditionally when
    [workdir = None]. *)

(** {1 Bash safety classifiers} *)

val is_write_operation : string -> bool
(** [true] iff the command performs a write/mutating operation
    (git push/commit, dune clean, npm publish, mv, cp, mkdir,
    chmod, ...).  Read-only commands (git status, dune build, rg)
    return [false]. *)

val is_git_branch_switch : string -> bool
(** [true] iff [cmd] is a git branch-switch / branch-mutation command
    (checkout, switch, branch -c/-m/-D, ...).  Used by the keeper bash
    sandbox guard to redirect such operations to the explicit worktree
    flow.  Read-only listing forms are allowed (return [false]). *)

val is_destructive_bash_operation : string -> bool
(** [true] iff [cmd] is destructive at the bash layer: [rm -rf],
    forced [git push --force] / [git reset --hard], [git clean -fd],
    or anything {!Eval_gate.detect_destructive} flags.  Distinct from
    {!classify_destructive} (Gate_diff_types) which classifies the
    *kind* of destruction; this returns a boolean for the bash gate. *)

(** {1 Logging redaction} *)

val sanitize_command_for_log : string -> string
(** Redact embedded credentials before a command is committed to a log
    line.  Strips [https://user:pw@] URL credentials, inline
    [token=]/[password=]/[api-key=] assignments, and the value
    following [--token]/[--password]/[--auth-token]/[--api-key]
    flags.  The result is suitable for human/log consumption but not
    for re-execution. *)

val truncate_for_log : ?max_len:int -> string -> string
(** UTF-8-safe truncation to [max_len] characters (default [240]),
    appending [...] when truncated. *)

(** {1 Attribution} *)

val attribution_of_validation :
  cmd:string -> (unit, block_reason) result -> Attribution.t
(** Convert the result of {!validate_command} (or any validator that
    yields [block_reason]) into the {!Attribution} envelope consumed by
    the dashboard.  [Ok ()] yields a [passed] attribution; [Error br]
    yields a [policy_failed] attribution carrying the block reason tag,
    the offending command name (when {!Command_not_allowed}), and the
    operator-visible error string. *)

(** {1 OAS tool factories} *)

(** Per-call observer hook invoked at the end of every tool execution.

    Receives the tool name, success flag, elapsed wall-clock duration,
    and (on failure) a categorized [error_kind] tag plus the
    operator-visible [error_message].  Both error fields are
    [None] on success and on legacy failure paths that have not yet
    been wired (the consumer should treat absence as
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
  tool_name:string ->
  success:bool ->
  duration_ms:int ->
  ?error_kind:string ->
  ?error_message:string ->
  unit ->
  unit

val make_tools :
  proc_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  ?workdir:string ->
  ?on_exec:tool_exec_observer ->
  unit ->
  Agent_sdk.Tool.t list
(** Build the full Fleet dev toolset: [file_read], [file_write], and
    [shell_exec].  [shell_exec] uses the strict {!validate_command}
    gate and the dev allowlist.  All tools resolve paths relative to
    [workdir] when supplied; absolute paths still pass the
    in-allowed-directories check. *)

val make_readonly_tools :
  proc_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  ?workdir:string ->
  ?on_exec:tool_exec_observer ->
  unit ->
  Agent_sdk.Tool.t list
(** Build the read-only subset: [file_read] + a [shell_exec] gated to
    a smaller read-only command allowlist (rg, grep, ls, cat, ...).
    [file_write] is intentionally absent. *)

(** {1 Shadow AST gate observability} *)

val shadow_parse_outcome : string -> string
(** Parse [cmd] with {!Masc_exec_bash_parser.Bash.parse_string} and
    return a stable, telemetry-suitable tag:

    - ["parsed_simple"] — grammar accepts the command
    - ["parse_error"] — Menhir/Lex error
    - ["parse_aborted:<reason>"] — timeout/depth/token-limit
    - ["too_complex:<reason>"] — recognised-but-unsupported construct

    Never raises; the parser catches every internal exception. *)

val cross_check_command : legacy:'a -> string -> 'a * string
(** Pair the supplied [legacy] verdict with the {!shadow_parse_outcome}
    tag for [cmd].  Polymorphic in [legacy] — callers pass either the
    typed {!legacy_verdict} or the boolean form used by older test
    sites.  Pure (no side effects); dashboards consume the tuple to
    spot legacy/shadow drift without two parse passes. *)

val diff_command :
  string -> gate_diff * legacy_verdict * shadow_verdict
(** Run both the legacy substring gate and the shadow AST gate on
    [cmd], returning their reconciliation outcome alongside both
    verdicts.  Wraps {!classify_legacy} / {!classify_shadow} (private)
    and {!diff_of_verdicts} (Gate_diff_types). *)

(** {1 Gh CLI cascade} *)

include module type of Gh_command_validation
