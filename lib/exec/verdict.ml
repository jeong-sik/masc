module Trusted_argv = struct
  type t = {
    bin : Exec_program.t;
    args : Shell_ir.arg list;
    env : (string * Shell_ir.arg) list;
    cwd : Path_scope.t option;
    redirects : Redirect_scope.t list;
  }

  let bin t = t.bin
  let args t = t.args
  let env t = t.env
  let cwd t = t.cwd
  let redirects t = t.redirects
end

type confirm_token = {
  risk_class : Exec_program.risk_class;
  ttl_sec : float;
}

type request = {
  caps : Capability.t list;
  summary : string;
  bin : Exec_program.t;
  raw_source : string;
}

type deny_reason =
  | Unknown_bin of string
  | Path_escape of Path_scope.t
  | Destructive_git of Git_op.t
  | Destructive_db of Db_op.t
  | Destructive_repo_hosting_cli of Exec_program.t
  | Catastrophic_program of Exec_program.t
  | Policy_deny of { rule : string }
  | Parse_too_complex of Parsed.reason_too_complex
  | Parse_failed

type t =
  | Allow of Trusted_argv.t
  | Suggest_confirm of Trusted_argv.t * confirm_token
  | Ask of request
  | Deny of { caps : Capability.t list; reason : deny_reason }

let trust ~caps:_ (s : Shell_ir.simple) : Trusted_argv.t =
  {
    bin = s.bin;
    args = s.args;
    env = s.env;
    cwd = s.cwd;
    redirects = s.redirects;
  }

let reason_too_complex_to_string : Parsed.reason_too_complex -> string =
  function
  | `Heredoc -> "heredoc"
  | `Here_string -> "here-string"
  | `Cmd_subst -> "command substitution"
  | `Proc_subst -> "process substitution"
  | `Subshell -> "subshell"
  | `Arith_expansion -> "arithmetic expansion"
  | `Control_flow -> "control flow"
  | `Logic_op -> "logic operator"
  | `Function_def -> "function definition"
  | `Glob_brace -> "brace expansion"
  | `Background -> "background job"
  | `Redirect -> "redirect"
  | `Unknown_construct s -> Printf.sprintf "unknown construct: %s" s

(* Exhaustive over [deny_reason] so a new constructor forces an update here
   rather than collapsing to a generic string at the call site. *)
let deny_reason_to_string : deny_reason -> string = function
  | Unknown_bin bin -> Printf.sprintf "unknown binary: %s" bin
  | Path_escape ps ->
    Format.asprintf "path escapes workspace: %a" Path_scope.pp ps
  | Destructive_git g ->
    Format.asprintf "destructive git operation: %a" Git_op.pp g
  | Destructive_db op ->
    Format.asprintf "destructive database operation: %a" Db_op.pp op
  | Destructive_repo_hosting_cli bin ->
    Printf.sprintf
      "destructive repository-hosting CLI operation not permitted: %s"
      (Exec_program.to_string bin)
  | Catastrophic_program bin ->
    Printf.sprintf "catastrophic program not permitted: %s"
      (Exec_program.to_string bin)
  | Policy_deny { rule } -> Printf.sprintf "policy rule denied: %s" rule
  | Parse_too_complex reason ->
    Printf.sprintf "command too complex to classify: %s"
      (reason_too_complex_to_string reason)
  | Parse_failed -> "command could not be parsed"
