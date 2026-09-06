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

let block_reason_tag = function
  | Empty_command -> "empty_command"
  | Chain_or_redirect -> "chain_or_redirect"
  | Injection -> "injection"
  | Process_substitution -> "process_substitution"
  | Unsafe_redirect -> "unsafe_redirect"
  | Pipes_not_allowed -> "pipes_not_allowed"
;;

(* The short block reasons are model-facing next-move guidance, so their
   sentences live in managed templates (config/prompts/exec_policy.md) and
   this module only picks the key. A template that does not render is logged
   and falls back to the bare variant tag, never to prose written here
   (#32848 precedent). The long chaining/injection/redirect wording stays
   inline for now: it is multi-paragraph setup documentation, outside the
   class-(ii) sentence slice. *)
let render_block_reason key reason =
  match Prompt_registry.render_prompt_template key [] with
  | Ok text -> String.trim text
  | Error detail ->
    Log.Misc.warn
      "exec_policy block reason %s did not render, falling back to the bare tag: %s"
      key
      detail;
    block_reason_tag reason
;;

let block_reason_to_string = function
  | Empty_command ->
    render_block_reason Prompt_names.exec_policy_block_reason_empty_command Empty_command
  | Chain_or_redirect ->
    "Blocked: chaining (&&/||/;) and redirects (|/>) are not allowed. Run ONE command \
     per call. To change directory, use the `cwd` argument instead of `cd` - Good: \
     cwd='<dir>', cmd='ls'. Bad: cmd='cd <dir> && ls'. For pipelines \
     like `rg foo | wc -l`, run the primary command and process \
     output at the LLM layer. To write files, use Write."
  | Injection ->
    "Shell injection syntax (;, &&, standalone &, `, $) not allowed. Run ONE command per \
     call. To change directory, use the `cwd` argument - Good: cwd='<dir>', \
     cmd='ls'. Bad: cmd='cd <dir> && ls' or cmd='cmd1 ; cmd2'. \
     Relative paths resolve from `cwd` (defaults to playground root). For file writes, \
     use Edit or Write."
  | Process_substitution ->
    render_block_reason
      Prompt_names.exec_policy_block_reason_process_substitution
      Process_substitution
  | Unsafe_redirect ->
    "Redirect syntax is not allowed in this shell surface. Consume stdout/stderr \
     directly from the tool response, and use a dedicated write tool for files."
  | Pipes_not_allowed ->
    render_block_reason
      Prompt_names.exec_policy_block_reason_pipes_not_allowed
      Pipes_not_allowed
;;


let tool_execute_syntax_policy ?(allow_pipes = true) ()
  : Exec_shell_gate.syntax_policy =
  { allow_pipes; redirect_allowed = false }
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
  | Masc_exec.Shell_ir.Sequence { head; tail } ->
    shell_ir_has_unquoted_glob head
    || List.exists (fun (_connector, part) -> shell_ir_has_unquoted_glob part) tail
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
      | `Param_expansion
      | `Control_flow
      | `Function_def
      | `Glob_brace
      | `Background
      (* A character no token class claims. Nothing is known about it beyond
         that the lexer refused it, so it takes the strictest class rather
         than the nearest-looking one. *)
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
          let vars =
            [ "ancestor", Filename.basename ancestor
            ; "dirs", String.concat ", " shown
            ; "suffix", suffix
            ]
          in
          (match
             Prompt_registry.render_prompt_template
               Prompt_names.exec_policy_cwd_existing_siblings_hint
               vars
           with
           | Ok text -> Some (String.trim text)
           | Error detail ->
             (* Bare data, never inline prose: the sibling list still reaches
                the model when the managed hint template is missing. *)
             Log.Misc.warn
               "exec_policy cwd hint did not render, falling back to the bare data: %s"
               detail;
             Some (String.concat ", " shown ^ suffix))))
;;

let validate_shell_ir_paths ?(requires_existing_dir = true) ?workdir shell_ir =
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
          let target =
            Masc_exec.Path_scope.raw (Masc_exec.Redirect_scope.target_as_written target)
          in
          (match validate_path_value ~requires_existing_dir:false target with
           | Ok () -> validate_redirects rest
           | Error _ as err -> err)
        (* A literal names no path, so there is no path boundary to check. *)
        | (Masc_exec.Redirect_scope.Fd_to_fd _ | Masc_exec.Redirect_scope.Literal _)
          :: rest -> validate_redirects rest
      in
      let validate_cwd = function
        | None -> Ok ()
        | Some cwd ->
          Masc_exec.Path_scope.raw cwd
          |> validate_path_value ~requires_existing_dir
      in
      let validate_simple (simple : Masc_exec.Shell_ir.simple) =
        match validate_cwd simple.cwd with
        | Error _ as err -> err
        | Ok () -> validate_redirects simple.redirects
      in
      let rec validate_parsed_shell_ir = function
        | Masc_exec.Shell_ir.Simple simple -> validate_simple simple
        | Masc_exec.Shell_ir.Pipeline stages -> validate_each stages
        | Masc_exec.Shell_ir.Sequence { head; tail } ->
          (match validate_parsed_shell_ir head with
           | Error _ as err -> err
           | Ok () -> validate_each (List.map snd tail))
      and validate_each = function
        | [] -> Ok ()
        | part :: rest ->
          (match validate_parsed_shell_ir part with
           | Ok () -> validate_each rest
           | Error _ as err -> err)
      in
      validate_parsed_shell_ir shell_ir
;;


let flat_stage_words = Literal_words.flat_stage_words

let sanitize_command_for_log_of_ir = Log_sanitize.sanitize_command_for_log_of_ir
let truncate_for_log = Log_sanitize.truncate_for_log
