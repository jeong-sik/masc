(** Shell command allowlist + validation + exit-status classifier for
    the [masc_code_shell] tool surface.

    Pure helpers — verbatim extract from [Tool_code_write]. Delegates
    to [Exec_policy.command_context_coding_with_allowlist] for
    the heavy parsing; the [allowed_shell_commands] compatibility surface
    is derived from [Dev_exec_allowlist.code_shell], keeping the executable
    vocabulary owned by [Masc_exec.Bin]. This module owns only the
    [classify_code_shell_exit] disposition over [code] and [last_stage_bin]. *)

module Exec_shell_gate = Masc_exec_command_gate.Shell_command_gate

let allowed_shell_commands = Dev_exec_allowlist.code_shell

let code_shell_command_context command =
  match Exec_policy.parse_string_to_ir ~mode:Coding command with
  | Error reason ->
    Error
      (Exec_policy.block_reason_to_string_with_allowlist
         ~allowed_commands:allowed_shell_commands
         reason)
  | Ok ir ->
    (match
       Exec_policy.command_context_coding_with_allowlist
         ~caller:Exec_shell_gate.Tool_code_write
         ~allow_pipes:true
         ~allowed_commands:allowed_shell_commands
         ir
     with
     | Ok ctx -> Ok ctx
     | Error reason ->
       Error
         (Exec_policy.block_reason_to_string_with_allowlist
            ~allowed_commands:allowed_shell_commands
            reason))
;;

let validate_code_shell_command (command : string) : (unit, string) Result.t =
  code_shell_command_context command |> Result.map (fun _ -> ())

type code_shell_exit_status =
  | Shell_ok
  | Shell_ok_expected_nonzero of string
  | Shell_error

let classify_code_shell_exit ~last_stage_bin code =
  match code with
  | 0 -> Shell_ok
  | 1 -> (
      match last_stage_bin with
      | Some ("rg" | "grep") -> Shell_ok_expected_nonzero "no_matches"
      | Some "diff" -> Shell_ok_expected_nonzero "differences"
      | Some _ | None -> Shell_error)
  | _ -> Shell_error
