open Keeper_shell_bash_shape_messages

let arg_text = function
  | Masc_exec.Shell_ir.Lit text -> Some (String.lowercase_ascii text)
  | Masc_exec.Shell_ir.Var _ | Masc_exec.Shell_ir.Concat _ -> None

let simple_is_gh_pr_checks (simple : Masc_exec.Shell_ir.simple) =
  match Masc_exec.Bin.known simple.bin, simple.args with
  | Some Masc_exec.Bin.Gh, arg_pr :: arg_checks :: _ ->
    (match arg_text arg_pr, arg_text arg_checks with
     | Some "pr", Some "checks" -> true
     | _ -> false)
  | _ -> false

let rec parsed_keeper_bash_shape_block = function
  | Masc_exec.Shell_ir.Pipeline _ -> Some Pipe_or_redirect
  | Masc_exec.Shell_ir.Simple simple ->
    if simple.redirects <> []
    then Some Pipe_or_redirect
    else if simple_is_gh_pr_checks simple
    then Some Gh_pr_checks
    else None
