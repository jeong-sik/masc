(** Shell command allowlist + validation + exit-status classifier for
    the [masc_code_shell] tool surface.

    Pure helpers — verbatim extract from [Tool_code_write]. Delegates
    to [Keeper_shell_ir.coding_command_context] for the heavy parsing and
    policy checks; the [allowed_shell_commands] compatibility surface
    is derived from [Dev_exec_allowlist.code_shell], keeping the executable
    vocabulary owned by [Masc_exec.Bin]. This module owns only the
    [classify_code_shell_exit] disposition over [code] and [last_stage_bin]. *)

module Exec_shell_gate = Masc_exec_command_gate.Shell_command_gate

let allowed_shell_commands = Dev_exec_allowlist.code_shell

let code_shell_command_context command =
  Keeper_shell_ir.coding_command_context
    ~caller:Exec_shell_gate.Tool_code_write
    ~allow_pipes:true
    ~allowed_commands:allowed_shell_commands
    command
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
