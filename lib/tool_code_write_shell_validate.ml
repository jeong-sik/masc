(** Shell command allowlist + validation + exit-status classifier for
    the [masc_code_shell] tool surface.

    Pure helpers — verbatim extract from [Tool_code_write]. Delegates
    to [Exec_policy.command_context_coding_with_allowlist] for
    the heavy parsing; this module owns the tool-specific
    [allowed_shell_commands] table (which extends [Dev_exec_allowlist.dev]
    with [diff/patch/mkdir/ocamlfind/tsc]) and the
    [classify_code_shell_exit] disposition over [code × last_stage_bin].

    The [add_unique] helper that builds the allowlist also stays in
    the parent (line 51) — duplicated here as a 2-line local because
    it's used by exactly one site. *)

module Exec_shell_gate = Masc_exec_command_gate.Shell_command_gate

let add_unique acc item =
  if List.exists (String.equal item) acc then acc else acc @ [ item ]

(* Shell command allowlist.  Keep this aligned with keeper_bash/dev shell so
   safe coding probes do not fail only because they entered through
   masc_code_shell.  Tool-specific extras are kept here. *)
let allowed_shell_commands =
  List.fold_left add_unique Dev_exec_allowlist.dev
    [ "diff"; "patch"; "mkdir"; "ocamlfind"; "tsc" ]

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
