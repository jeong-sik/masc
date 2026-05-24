(** Shell command allowlist + validation + exit-status classifier for
    the [masc_code_shell] tool surface. *)

val allowed_shell_commands : string list

val code_shell_command_context
  :  string
  -> (Masc_exec_command_gate.Shell_command_gate.parsed_context, string) result

val validate_code_shell_command : string -> (unit, string) result

type code_shell_exit_status =
  | Shell_ok
  | Shell_ok_expected_nonzero of string
  | Shell_error

val classify_code_shell_exit
  :  last_stage_bin:string option
  -> int
  -> code_shell_exit_status
