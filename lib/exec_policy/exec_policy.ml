(** Shared execution policy for shell-like tool frontends.

    This module is the common policy substrate behind Execute and code-shell
    callers. *)

module Paths = Exec_policy_paths
module Log_sanitize = Exec_policy_log_sanitize

module Literal_words = Exec_policy_literal_words
module Exec_shell_gate = Masc_exec_command_gate.Shell_command_gate

let resolve_path = Paths.resolve_path
let validate_path = Paths.validate_path

type block_reason =
  | Empty_command
  | Chain_or_redirect
  | Injection
  | Process_substitution
  | Unsafe_redirect
  | Pipes_not_allowed

let block_reason_to_string = function
  | Empty_command -> "command must not be empty"
  | Chain_or_redirect ->
    "Blocked: chaining (&&/||/;) and redirects (|/>) are not allowed. Run ONE command \
     per call. To change directory, use the `cwd` argument instead of `cd` - Good: \
     cwd='repos/project', cmd='ls'. Bad: cmd='cd repos/project && ls'. For pipelines \
     like `rg foo | wc -l`, run the primary command and process \
     output at the LLM layer. To write files, use Write."
  | Injection ->
    "Shell injection syntax (;, &&, standalone &, `, $) not allowed. Run ONE command per \
     call. To change directory, use the `cwd` argument - Good: cwd='repos/masc', \
     cmd='ls'. Bad: cmd='cd repos/masc && ls' or cmd='cmd1 ; cmd2'. \
     Relative paths resolve from `cwd` (defaults to playground root). For file writes, \
     use Edit or Write."
  | Process_substitution -> "Process substitution (<(...) or >(...)) is not allowed."
  | Unsafe_redirect ->
    "Redirect syntax is not allowed in this shell surface. Consume stdout/stderr \
     directly from the tool response, and use a dedicated write tool for files."
  | Pipes_not_allowed -> "Pipes are not allowed. Run one command per call."
;;


let strict_syntax_policy : Exec_shell_gate.syntax_policy =
  { allow_pipes = false; redirect_allowed = false }
;;

let tool_execute_syntax_policy ?(allow_pipes = true) ()
  : Exec_shell_gate.syntax_policy =
  { allow_pipes; redirect_allowed = false }
;;

let rec shell_ir_literal_text = function
  | Masc_exec.Shell_ir.Lit (text, _) -> Some text
  | Masc_exec.Shell_ir.Concat parts ->
    let rec loop acc = function
      | [] -> Some (String.concat "" (List.rev acc))
      | part :: rest ->
        (match shell_ir_literal_text part with
         | Some text -> loop (text :: acc) rest
         | None -> None)
    in
    loop [] parts
  | Masc_exec.Shell_ir.Var (_, _) -> None
;;

let simple_literal_args (simple : Masc_exec.Shell_ir.simple) =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | arg :: rest ->
      (match shell_ir_literal_text arg with
       | Some text -> loop (text :: acc) rest
       | None -> None)
  in
  loop [] simple.Masc_exec.Shell_ir.args
;;

let meta_has_unquoted_glob (meta : Masc_exec.Shell_ir.arg_meta) =
  meta.glob && not meta.quoted
;;

let rec shell_ir_arg_has_unquoted_glob = function
  | Masc_exec.Shell_ir.Lit (_, meta)
  | Masc_exec.Shell_ir.Var (_, meta) -> meta_has_unquoted_glob meta
  | Masc_exec.Shell_ir.Concat parts ->
    List.exists shell_ir_arg_has_unquoted_glob parts
;;

let simple_has_unquoted_glob (simple : Masc_exec.Shell_ir.simple) =
  List.exists
    shell_ir_arg_has_unquoted_glob
    simple.Masc_exec.Shell_ir.args
  || List.exists
       (fun (_, arg) -> shell_ir_arg_has_unquoted_glob arg)
       simple.Masc_exec.Shell_ir.env
;;

let rec shell_ir_has_unquoted_glob = function
  | Masc_exec.Shell_ir.Simple simple -> simple_has_unquoted_glob simple
  | Masc_exec.Shell_ir.Pipeline stages ->
    List.exists shell_ir_has_unquoted_glob stages
;;

let validate_no_unquoted_glob ast =
  if shell_ir_has_unquoted_glob ast then Error Injection else Ok ()
;;

let block_reason_of_exec_reject : Exec_shell_gate.reject_reason -> block_reason =
  function
  | Pipes_not_allowed _ -> Pipes_not_allowed
  | Redirect_disallowed_in_caller _ -> Unsafe_redirect
;;

let block_reason_of_exec_too_complex
      (reason : Exec_shell_gate.too_complex_reason)
  : block_reason =
  match reason with
  | Unsupported_construct `Proc_subst -> Process_substitution
  | Unsupported_construct (`Heredoc | `Here_string | `Redirect) -> Unsafe_redirect
  | Unsupported_nested_pipeline
  | Unsupported_construct
      ( `Cmd_subst
      | `Subshell
      | `Arith_expansion
      | `Control_flow
      | `Logic_op
      | `Function_def
      | `Glob_brace
      | `Background
      | `Unknown_construct _ ) -> Injection
;;

type parse_mode = Strict | Tool_execute

let parse_string_to_ir ~mode cmd =
  let trimmed = String.trim cmd in
  if trimmed = ""
  then Error Empty_command
  else (
    match Masc_exec_bash_parser.Bash.parse_string trimmed with
    | (Masc_exec.Parsed.Parse_error _ | Masc_exec.Parsed.Parse_aborted _) ->
      Error (match mode with Strict -> Chain_or_redirect | Tool_execute -> Injection)
    | Masc_exec.Parsed.Too_complex reason ->
      Error (block_reason_of_exec_too_complex (Unsupported_construct reason))
    | Masc_exec.Parsed.Parsed ir -> Ok ir)
;;

let command_context ir =
  let verdict =
    Exec_shell_gate.gate_typed
      ~ir
      ~syntax_policy:strict_syntax_policy
      ~sandbox:Exec_shell_gate.host_sandbox
      ()
  in
  match verdict with
  | Allow context ->
    (match validate_no_unquoted_glob context.Exec_shell_gate.ast with
     | Error _ as err -> err
     | Ok () -> Ok context)
  | Reject { reason; _ } -> Error (block_reason_of_exec_reject reason)
  | Cannot_parse _ -> Error Chain_or_redirect
  | Too_complex { reason } -> Error (block_reason_of_exec_too_complex reason)
;;

let validate_command ir =
  command_context ir |> Result.map (fun _ -> ())
;;

let command_context_tool_execute
      ?(allow_pipes = true)
      ir
  =
  let verdict =
    Exec_shell_gate.gate_typed
      ~ir
      ~syntax_policy:(tool_execute_syntax_policy ~allow_pipes ())
      ~sandbox:Exec_shell_gate.host_sandbox
      ()
  in
  match verdict with
  | Allow context ->
    (match validate_no_unquoted_glob context.Exec_shell_gate.ast with
     | Error _ as err -> err
     | Ok () -> Ok context)
  | Reject { reason; _ } ->
    (match reason with
     | Pipes_not_allowed _ -> Error Pipes_not_allowed
     | _ -> Error (block_reason_of_exec_reject reason))
  | Cannot_parse _ -> Error Injection
  | Too_complex { reason } -> Error (block_reason_of_exec_too_complex reason)
;;

let validate_command_tool_execute ?allow_pipes ir =
  command_context_tool_execute
    ?allow_pipes
    ir
  |> Result.map (fun _ -> ())
;;

let path_is_existing_dir ?workdir path =
  let resolved = resolve_path ?base_dir:workdir path in
  try Sys.file_exists resolved && Sys.is_directory resolved with
  | Sys_error _ -> false
;;

(* Largest number of sibling directory names surfaced in a
   [Cwd_not_directory] hint. Bounds the operator-facing message when the
   nearest existing ancestor holds many entries. *)
let max_cwd_hint_siblings = 12

let existing_sibling_dirs_hint ?workdir path =
  let resolved = resolve_path ?base_dir:workdir path in
  let is_dir p = try Sys.is_directory p with Sys_error _ -> false in
  let rec nearest_existing_ancestor p =
    let parent = Filename.dirname p in
    if String.equal parent p
    then None (* reached the filesystem root without an existing directory *)
    else if is_dir parent
    then Some parent
    else nearest_existing_ancestor parent
  in
  match nearest_existing_ancestor resolved with
  | None -> None
  | Some ancestor ->
    (match Sys.readdir ancestor with
     | exception Sys_error _ -> None
     | entries ->
       let dirs =
         entries
         |> Array.to_list
         |> List.filter (fun e -> is_dir (Filename.concat ancestor e))
         |> List.sort String.compare
       in
       (match dirs with
        | [] -> None
        | _ ->
          let total = List.length dirs in
          let shown, omitted =
            if total > max_cwd_hint_siblings
            then
              ( List.filteri (fun i _ -> i < max_cwd_hint_siblings) dirs
              , total - max_cwd_hint_siblings )
            else dirs, 0
          in
          let suffix =
            if omitted > 0 then Printf.sprintf ", +%d more" omitted else ""
          in
          Some
            (Printf.sprintf
               "(existing directories under %s/: %s%s)"
               (Filename.basename ancestor)
               (String.concat ", " shown)
               suffix)))
;;

let validate_shell_ir_paths ?workdir shell_ir =
  match workdir with
  | None -> Ok ()
  | Some _ ->
      let validate_path_value ~requires_existing_dir value =
        if String.equal value "/dev/null"
        then Ok ()
        else if not (validate_path ?workdir value)
        then
          Error
            (Keeper_path_check_error.(
               to_message
                 (Path_outside_whitelist
                    { path = value; for_keeper_command = true })))
        else if requires_existing_dir && not (path_is_existing_dir ?workdir value)
        then
          Error
            (Keeper_path_check_error.(
               to_message
                 (Cwd_not_directory
                    { path = value
                    ; hint = existing_sibling_dirs_hint ?workdir value
                    })))
        else Ok ()
      in
      let rec validate_redirects = function
        | [] -> Ok ()
        | Masc_exec.Redirect_scope.File { target; _ } :: rest ->
          let target = Masc_exec.Path_scope.raw target in
          (match validate_path_value ~requires_existing_dir:false target with
           | Ok () -> validate_redirects rest
           | Error _ as err -> err)
        | Masc_exec.Redirect_scope.Fd_to_fd _ :: rest -> validate_redirects rest
      in
      let validate_cwd = function
        | None -> Ok ()
        | Some cwd ->
          Masc_exec.Path_scope.raw cwd
          |> validate_path_value ~requires_existing_dir:true
      in
      let validate_simple (simple : Masc_exec.Shell_ir.simple) =
        match validate_cwd simple.cwd with
        | Error _ as err -> err
        | Ok () -> validate_redirects simple.redirects
      in
      let rec validate_parsed_shell_ir = function
        | Masc_exec.Shell_ir.Simple simple -> validate_simple simple
        | Masc_exec.Shell_ir.Pipeline stages ->
          let rec loop = function
            | [] -> Ok ()
            | Masc_exec.Shell_ir.Simple simple :: rest ->
              (match validate_simple simple with
               | Ok () -> loop rest
               | Error _ as err -> err)
            | Masc_exec.Shell_ir.Pipeline nested :: rest ->
              (match validate_parsed_shell_ir (Masc_exec.Shell_ir.Pipeline nested) with
               | Ok () -> loop rest
               | Error _ as err -> err)
          in
          loop stages
      in
      validate_parsed_shell_ir shell_ir
;;


let flat_stage_words = Literal_words.flat_stage_words

let sanitize_command_for_log cmd =
  let trimmed = String.trim cmd in
  if trimmed = ""
  then Log_sanitize.sanitize_command_for_log cmd
  else (
    match parse_string_to_ir ~mode:Tool_execute trimmed with
    | Ok ir -> Log_sanitize.sanitize_command_for_log_of_ir ~fallback_cmd:cmd ir
    | Error _ -> Log_sanitize.sanitize_command_for_log cmd)
;;

let sanitize_command_for_log_of_ir = Log_sanitize.sanitize_command_for_log_of_ir
let truncate_for_log = Log_sanitize.truncate_for_log

let block_reason_tag = function
  | Empty_command -> "empty_command"
  | Chain_or_redirect -> "chain_or_redirect"
  | Injection -> "injection"
  | Process_substitution -> "process_substitution"
  | Unsafe_redirect -> "unsafe_redirect"
  | Pipes_not_allowed -> "pipes_not_allowed"
;;

let attribution_of_validation ~cmd (result : (unit, block_reason) result) : Attribution.t =
  match result with
  | Ok () ->
    let evidence : Yojson.Safe.t = `Assoc [ "cmd", `String cmd ] in
    Attribution.passed ~origin:Det ~gate:"exec_policy" ~evidence
  | Error br ->
    let evidence : Yojson.Safe.t =
      `Assoc [ "cmd", `String cmd; "block_reason", `String (block_reason_tag br) ]
    in
    Attribution.policy_failed
      ~origin:Det
      ~gate:"exec_policy"
      ~evidence
      ~reason:(block_reason_to_string br)
;;
