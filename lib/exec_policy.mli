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
val existing_dir_path_values : string -> string list

val validate_shell_ir_paths :
  ?keeper_id:string ->
  ?base_path:string ->
  ?workdir:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result

val validate_command_paths :
  ?keeper_id:string ->
  ?base_path:string ->
  ?workdir:string ->
  string ->
  (unit, string) result

val is_write_operation : string -> bool
val is_git_branch_switch : string -> bool
val is_destructive_bash_operation : string -> bool

val sanitize_command_for_log : string -> string
val truncate_for_log : ?max_len:int -> string -> string
