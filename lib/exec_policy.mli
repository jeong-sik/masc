(** Shared execution policy for shell-like tool frontends.

    This module owns the command/Shell IR policy substrate used by
    [worker_dev_tools], [keeper_bash], and code-shell surfaces. Tool bundles
    should adapt to this policy layer instead of becoming the policy owner. *)

type block_reason =
  | Empty_command
  | Chain_or_redirect
  | Injection
  | Process_substitution
  | Unsafe_redirect
  | Pipes_not_allowed
  | Direct_dune_invocation
  | Command_not_allowed of string

val block_reason_to_string : block_reason -> string

val block_reason_to_string_with_allowlist :
  allowed_commands:string list -> block_reason -> string

val dev_allowed_commands : string list

val command_context_with_allowlist :
  ?caller:Masc_exec_command_gate.Shell_command_gate.caller ->
  allowed_commands:string list ->
  string ->
  (Masc_exec_command_gate.Shell_command_gate.parsed_context, block_reason) result

val validate_command_with_allowlist :
  ?caller:Masc_exec_command_gate.Shell_command_gate.caller ->
  allowed_commands:string list ->
  string ->
  (unit, block_reason) result

val validate_command :
  ?caller:Masc_exec_command_gate.Shell_command_gate.caller ->
  string ->
  (unit, block_reason) result

val command_context_coding_with_allowlist :
  ?caller:Masc_exec_command_gate.Shell_command_gate.caller ->
  ?allow_pipes:bool ->
  allowed_commands:string list ->
  string ->
  (Masc_exec_command_gate.Shell_command_gate.parsed_context, block_reason) result

val validate_command_coding_with_allowlist :
  ?caller:Masc_exec_command_gate.Shell_command_gate.caller ->
  ?allow_pipes:bool ->
  allowed_commands:string list ->
  string ->
  (unit, block_reason) result

val validate_command_coding :
  ?caller:Masc_exec_command_gate.Shell_command_gate.caller ->
  string ->
  (unit, block_reason) result

val simple_literal_args : Masc_exec.Shell_ir.simple -> string list option

val existing_dir_path_values_of_shell_ir : Masc_exec.Shell_ir.t -> string list

val validate_shell_ir_paths :
  ?keeper_id:string ->
  ?base_path:string ->
  ?workdir:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result

(** RFC-0160 S1: IR-typed structural mutation classifiers. *)
val is_write_operation : Masc_exec.Shell_ir.t -> bool
val is_git_branch_switch : Masc_exec.Shell_ir.t -> bool
val is_destructive_bash_operation : Masc_exec.Shell_ir.t -> bool

(** Flatten all literal stage words from a parsed shell IR.
    Replaces the historical string-era extractors. *)
val flat_stage_words : Masc_exec.Shell_ir.t -> string list

val sanitize_command_for_log : string -> string
val sanitize_command_for_log_of_ir :
  fallback_cmd:string -> Masc_exec.Shell_ir.t -> string
val truncate_for_log : ?max_len:int -> string -> string

val block_reason_tag : block_reason -> string

val attribution_of_validation :
  cmd:string -> (unit, block_reason) result -> Attribution.t
