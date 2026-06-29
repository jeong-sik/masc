(** Shared execution policy for shell-like tool frontends.

    This module owns the command/Shell IR policy substrate used by
    [tool_execute] and code-shell surfaces. Tool bundles should adapt to this
    policy layer instead of becoming the policy owner. *)

type block_reason =
  | Empty_command
  | Chain_or_redirect
  | Injection
  | Process_substitution
  | Unsafe_redirect
  | Pipes_not_allowed
  | Direct_dune_invocation

val block_reason_to_string : block_reason -> string

type parse_mode = Strict | Tool_execute

(** Classification of path-like token prefixes. *)
type path_prefix =
  | Root_relative
  | Current_dir
  | Parent_dir
  | Home_dir
  | Dot_entry
  | Not_a_path

val classify_path_prefix : string -> path_prefix

val parse_string_to_ir :
  mode:parse_mode -> string -> (Masc_exec.Shell_ir.t, block_reason) result

val command_context :
  Masc_exec.Shell_ir.t ->
  (Masc_exec_command_gate.Shell_command_gate.parsed_context, block_reason) result

val validate_command : Masc_exec.Shell_ir.t -> (unit, block_reason) result

val command_context_tool_execute :
  ?allow_pipes:bool ->
  Masc_exec.Shell_ir.t ->
  (Masc_exec_command_gate.Shell_command_gate.parsed_context, block_reason) result

val validate_command_tool_execute :
  ?allow_pipes:bool ->
  Masc_exec.Shell_ir.t ->
  (unit, block_reason) result

val simple_literal_args : Masc_exec.Shell_ir.simple -> string list option

val path_argument_values : string -> string list -> string list

(** Filesystem path normalization and allowlist checks. Exposed so callers can
    reach [validate_path] via [Exec_policy.Paths] (e.g. test keepers). *)
module Paths = Exec_policy_paths
val existing_dir_path_values_of_shell_ir : Masc_exec.Shell_ir.t -> string list

val existing_sibling_dirs_hint : ?workdir:string -> string -> string option
(** For a required directory [path] that is missing on disk, enumerate the
    real child-directory names under its nearest existing ancestor (read via
    [Sys.readdir]) and render them as a [Cwd_not_directory] hint. Grounds
    caller self-correction in filesystem truth (e.g. a stale
    ["repos/masc-mcp"] yields the real ["repos/"] entries) without a rename
    table or any substring/similarity matching. [None] when no existing
    ancestor directory has child directories to surface. *)

val validate_shell_ir_paths :
  ?keeper_id:string ->
  ?base_path:string ->
  ?workdir:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result

(** RFC-0160 S1: IR-typed structural mutation classifiers. *)

val is_git_branch_switch : Masc_exec.Shell_ir.t -> bool
val is_destructive_bash_operation : Masc_exec.Shell_ir.t -> bool

(** Flatten all literal stage words from a parsed shell IR.
    Replaces the historical string-era extractors. *)
val flat_stage_words : Masc_exec.Shell_ir.t -> string list

(** All typed callers now route through {!parse_string_to_ir} +
    {!Exec_policy_mutation_classifier.flat_stage_words}. *)

val sanitize_command_for_log : string -> string
val sanitize_command_for_log_of_ir :
  fallback_cmd:string -> Masc_exec.Shell_ir.t -> string
val truncate_for_log : ?max_len:int -> string -> string

val block_reason_tag : block_reason -> string

val attribution_of_validation :
  cmd:string -> (unit, block_reason) result -> Attribution.t

(** RFC-0215 GADT safety verification types. *)

type safe = Typed_capabilities.safe
type unsafe = Typed_capabilities.unsafe
type 'a verified_ir = 'a Typed_capabilities.verified_ir

val verify_static_safe_ir :
  Masc_exec.Shell_ir.t ->
  (safe verified_ir, block_reason) result
