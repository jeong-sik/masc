open Keeper_types
open Keeper_exec_shared
open Keeper_shell_bash_redirects
open Keeper_shell_bash_shape_ir
open Keeper_shell_bash_shape_messages
open Keeper_shell_bash_task_state
open Keeper_shell_bash_words
module Task_probe = Keeper_shell_bash_task_probe

(* RFC-0084 host-config-cleanup-B — bash binary path migration.
   Resolves the host bash binary once at module-init from the typed
   [Host_config.host_bash] field; consumer sites reference the bound
   name so a future PR can flip the typed surface to PATH lookup. *)
let host_bash = (Host_config.host ()).host_bash

let elapsed_duration_ms ~start_time ~end_time =
  let elapsed_ms = (end_time -. start_time) *. 1000. in
  match classify_float elapsed_ms with
  | FP_nan | FP_infinite -> 0
  | _ when elapsed_ms <= 0. -> 0
  | _ when elapsed_ms < 1. -> 1
  | _ -> int_of_float elapsed_ms

let string_contains_char s ch = String.exists (Char.equal ch) s
let string_contains_substring s needle = String_util.contains_substring s needle

type native_tool_hint = {
  rule_id : string;
  tool_suggestion : string;
  rewrite : string;
  hint : string;
  alternatives : string list;
}

let gh_pr_native_tool_hint cmd =
  let make ~rule_id ~tool_suggestion ~rewrite ~hint ~alternatives =
    Some { rule_id; tool_suggestion; rewrite; hint; alternatives }
  in
  match cmd_gh_pr_native_subcommand cmd with
  | Some Gh_pr_list ->
    make
      ~rule_id:"gh_pr_list_requires_keeper_pr_list"
      ~tool_suggestion:"keeper_pr_list"
      ~rewrite:"Use keeper_pr_list with the same repo/state/search intent."
      ~hint:
        "Do not call gh pr list through keeper_bash. Use keeper_pr_list so PR \
         reads are routed through the native PR tool surface."
      ~alternatives:
        [ "keeper_pr_list repo=OWNER/REPO state=open"
        ; "keeper_pr_list repo=OWNER/REPO search=term"
        ]
  | Some Gh_pr_status ->
    make
      ~rule_id:"gh_pr_status_requires_keeper_pr_status"
      ~tool_suggestion:"keeper_pr_status"
      ~rewrite:"Use keeper_pr_status for PR state, checks, draft state, and mergeability."
      ~hint:
        "Do not call gh pr view/status/checks through keeper_bash. Use \
         keeper_pr_status so PR status reads are captured by the native PR \
         receipt path."
      ~alternatives:
        [ "keeper_pr_status pr=NUMBER repo=OWNER/REPO"
        ; "keeper_pr_status head=BRANCH repo=OWNER/REPO"
        ]
  | Some Gh_pr_diff ->
    make
      ~rule_id:"gh_pr_diff_requires_keeper_pr_review_read"
      ~tool_suggestion:"keeper_pr_review_read"
      ~rewrite:"Use keeper_pr_review_read for PR diff/review context reads."
      ~hint:
        "Do not call gh pr diff through keeper_bash. Use \
         keeper_pr_review_read so review context is read through the PR review \
         tool surface."
      ~alternatives:
        [ "keeper_pr_review_read pr=NUMBER repo=OWNER/REPO"
        ; "keeper_pr_status pr=NUMBER repo=OWNER/REPO"
        ]
  | Some Gh_pr_review ->
    make
      ~rule_id:"gh_pr_review_requires_keeper_pr_review_comment"
      ~tool_suggestion:"keeper_pr_review_comment"
      ~rewrite:"Use keeper_pr_review_comment for PR review comments or review actions."
      ~hint:
        "Do not call gh pr review/comment through keeper_bash. Use \
         keeper_pr_review_comment so review actions keep approval and audit \
         receipts."
      ~alternatives:
        [ "keeper_pr_review_comment pr=NUMBER repo=OWNER/REPO body=..."
        ; "keeper_pr_review_read pr=NUMBER repo=OWNER/REPO"
        ]
  | None -> None
;;

let native_tool_diagnosis hint =
  { Exec_core.rule_id = hint.rule_id
  ; explanation =
      "Raw GitHub PR commands are blocked in keeper_bash; the native PR tool \
       surface preserves routing, audit, and retry receipts."
  ; rewrite = Some hint.rewrite
  ; tool_suggestion = Some hint.tool_suggestion
  }
;;

let has_malformed_dev_null_redirect_token scan_text =
  scan_text
  |> String.split_on_char ' '
  |> List.exists (fun token ->
    match String.trim (String.lowercase_ascii token) with
    | "0/dev/null" | "1/dev/null" | "2/dev/null" -> true
    | _ -> false)

let strip_trailing_slashes text =
  let rec loop i =
    if i > 0 && Char.equal text.[i - 1] '/' then loop (i - 1) else i
  in
  let len = loop (String.length text) in
  if len = String.length text then text else String.sub text 0 len

let is_repo_wide_root text =
  let text = String.trim text |> strip_trailing_slashes in
  String.equal text "."
  || String.equal text "./"
  || String.equal text "repos"
  || String.equal text "./repos"

let is_scoped_read_root text =
  let text = String.trim text |> strip_trailing_slashes in
  String.starts_with ~prefix:"lib" text
  || String.starts_with ~prefix:"test" text
  || String.starts_with ~prefix:"bin" text
  || String.starts_with ~prefix:"docs" text
  || String.starts_with ~prefix:"src" text
  || String.starts_with ~prefix:"repos/" text
  || String.contains text '/'

let option_consumes_next_arg text =
  match text with
  | "-e" | "-f" | "-g" | "-m" | "-t" | "--after-context" | "--before-context"
  | "--context" | "--exclude" | "--exclude-dir" | "--glob" | "--include"
  | "--max-count" | "--regexp" | "--type" | "--type-add" -> true
  | _ -> false

let rec non_option_args = function
  | [] -> []
  | arg :: _ :: rest when option_consumes_next_arg arg.text -> non_option_args rest
  | arg :: rest when String.starts_with ~prefix:"--" arg.text ->
    non_option_args rest
  | arg :: rest
    when String.length arg.text > 1 && Char.equal arg.text.[0] '-' ->
    non_option_args rest
  | arg :: rest -> arg.text :: non_option_args rest

let grep_has_recursive_flag args =
  List.exists
    (fun arg ->
       String.equal arg.text "-r"
       || String.equal arg.text "-R"
       ||
       (String.length arg.text > 2
        && Char.equal arg.text.[0] '-'
        && not (String.starts_with ~prefix:"--" arg.text)
        && String.exists (function 'r' | 'R' -> true | _ -> false) arg.text))
    args

let grep_is_repo_wide args =
  if not (grep_has_recursive_flag args)
  then false
  else (
    let positional = non_option_args args in
    let paths =
      match positional with
      | _pattern :: paths -> paths
      | [] -> []
    in
    paths = []
    || List.exists is_repo_wide_root paths
    || not (List.exists is_scoped_read_root paths))

let find_is_repo_wide args =
  match non_option_args args with
  | root :: _ -> is_repo_wide_root root
  | [] -> true

let rg_has_files_mode args =
  List.exists (fun arg -> String.equal arg.text "--files") args

let rg_is_repo_wide args =
  let positional = non_option_args args in
  let paths =
    if rg_has_files_mode args
    then positional
    else (
      match positional with
      | _pattern :: paths -> paths
      | [] -> [])
  in
  paths = []
  || List.exists is_repo_wide_root paths
  || not (List.exists is_scoped_read_root paths)

let git_log_all_is_repo_wide args =
  match args with
  | subcmd :: rest when String.equal subcmd.text "log" ->
    List.exists (fun arg -> String.equal arg.text "--all") rest
  | _ -> false

let simple_command_is_repo_wide_scan words =
  match strip_command_wrappers words with
  | bin :: args ->
    (match command_name bin.text with
     | "grep" | "egrep" | "fgrep" -> grep_is_repo_wide args
     | "find" -> find_is_repo_wide args
     | "rg" -> rg_is_repo_wide args
     | "git" -> git_log_all_is_repo_wide args
     | _ -> false)
  | [] -> false

let rec command_has_repo_wide_scan cmd =
  let words = shell_words_with_boundaries cmd in
  let rec loop = function
    | word :: rest when word.starts_command ->
      simple_command_is_repo_wide_scan (word :: rest) || loop rest
    | _ :: rest -> loop rest
    | [] -> false
  in
  loop words
  ||
  match shell_c_payload words with
  | Some payload -> command_has_repo_wide_scan payload
  | None -> false

let quote_aware_shape_scan_text cmd =
  let len = String.length cmd in
  let buf = Buffer.create len in
  let add_space () = Buffer.add_char buf ' ' in
  let rec loop quote_state escaped i =
    if i >= len
    then Buffer.contents buf
    else if escaped
    then (
      add_space ();
      loop quote_state false (i + 1))
    else (
      match quote_state, cmd.[i] with
      | Single_quote, '\'' ->
        add_space ();
        loop No_quote false (i + 1)
      | Single_quote, _ ->
        add_space ();
        loop Single_quote false (i + 1)
      | Double_quote, '"' ->
        add_space ();
        loop No_quote false (i + 1)
      | Double_quote, '\\' ->
        add_space ();
        loop Double_quote true (i + 1)
      | Double_quote, '$' when i + 1 < len && Char.equal cmd.[i + 1] '(' ->
        Buffer.add_string buf "$(";
        loop Double_quote false (i + 2)
      | Double_quote, '`' ->
        Buffer.add_char buf '`';
        loop Double_quote false (i + 1)
      | Double_quote, _ ->
        add_space ();
        loop Double_quote false (i + 1)
      | No_quote, '\'' ->
        add_space ();
        loop Single_quote false (i + 1)
      | No_quote, '"' ->
        add_space ();
        loop Double_quote false (i + 1)
      | No_quote, '\\' ->
        add_space ();
        loop No_quote true (i + 1)
      | No_quote, ch ->
        Buffer.add_char buf ch;
        loop No_quote false (i + 1))
  in
  loop No_quote false 0

let raw_keeper_bash_shape_block cmd =
  let cmd, _ = strip_stderr_dev_null_redirects cmd in
  let scan_text = quote_aware_shape_scan_text cmd in
  let lower = String.lowercase_ascii scan_text in
  if string_contains_substring lower "gh pr checks"
  then Some Gh_pr_checks
  else if command_has_repo_wide_scan cmd
  then Some Repo_wide_scan
  else if has_malformed_dev_null_redirect_token scan_text
  then Some Pipe_or_redirect
  else if
    string_contains_char scan_text '|'
    || string_contains_char scan_text '>'
    || string_contains_char scan_text '<'
  then Some Pipe_or_redirect
  else if
    string_contains_substring scan_text "&&"
    || string_contains_substring scan_text "||"
    || string_contains_char scan_text ';'
    || string_contains_char scan_text '\n'
    || string_contains_char scan_text '\r'
  then Some Chaining
  else if
    string_contains_substring scan_text "$(" || string_contains_char scan_text '`'
  then Some Substitution
  else None

let keeper_bash_shape_block cmd =
  let cmd, _ = strip_stderr_dev_null_redirects cmd in
  let scan_text = quote_aware_shape_scan_text cmd in
  if command_has_repo_wide_scan cmd
  then Some Repo_wide_scan
  else if has_malformed_dev_null_redirect_token scan_text
  then Some Pipe_or_redirect
  else
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parsed ir -> parsed_keeper_bash_shape_block ir
  | Masc_exec.Parsed.Parse_error _
  | Masc_exec.Parsed.Parse_aborted _
  | Masc_exec.Parsed.Too_complex _ ->
    raw_keeper_bash_shape_block cmd

type safe_read_fallback = {
  primary_cmd : string;
  cwd_override : string option;
}

let safe_read_primary_rewrite primary_cmd =
  match keeper_bash_shape_block primary_cmd with
  | Some _ -> None
  | None ->
    if Worker_dev_tools.is_write_operation primary_cmd
    then None
    else (
      match
        Worker_dev_tools.validate_command_coding_with_allowlist
          ~caller:Shell_command_gate.Keeper_shell_bash
          ~allow_pipes:false
          ~allowed_commands:Worker_dev_tools.dev_allowed_commands
          primary_cmd
      with
      | Ok () -> Some { primary_cmd; cwd_override = None }
      | Error _ -> None)

type shell_logic_op =
  | Logic_and
  | Logic_or

let find_unquoted_logic_op op cmd =
  let first, second =
    match op with
    | Logic_and -> '&', '&'
    | Logic_or -> '|', '|'
  in
  let len = String.length cmd in
  let rec loop quote_state escaped i =
    if i + 1 >= len
    then None
    else if escaped
    then loop quote_state false (i + 1)
    else (
      match quote_state, cmd.[i] with
      | Single_quote, '\'' -> loop No_quote false (i + 1)
      | Single_quote, _ -> loop Single_quote false (i + 1)
      | Double_quote, '"' -> loop No_quote false (i + 1)
      | Double_quote, '\\' -> loop Double_quote true (i + 1)
      | Double_quote, _ -> loop Double_quote false (i + 1)
      | No_quote, '\'' -> loop Single_quote false (i + 1)
      | No_quote, '"' -> loop Double_quote false (i + 1)
      | No_quote, '\\' -> loop No_quote true (i + 1)
      | No_quote, ch when Char.equal ch first && Char.equal cmd.[i + 1] second ->
        Some i
      | No_quote, _ -> loop No_quote false (i + 1))
  in
  loop No_quote false 0

let strip_suffix_ci text suffix =
  let text_len = String.length text in
  let suffix_len = String.length suffix in
  if suffix_len > text_len
  then None
  else (
    let tail = String.sub text (text_len - suffix_len) suffix_len in
    if String.equal (String.lowercase_ascii tail) suffix
    then Some (String.sub text 0 (text_len - suffix_len) |> String.trim)
    else None)

let strip_trailing_dev_null_redirect cmd =
  let cmd = String.trim cmd in
  [
    "2>/dev/null";
    "1>/dev/null";
    ">/dev/null";
    "2>>/dev/null";
    "1>>/dev/null";
    ">>/dev/null";
    "2> /dev/null";
    "1> /dev/null";
    "> /dev/null";
    "2>> /dev/null";
    "1>> /dev/null";
    ">> /dev/null";
  ]
  |> List.find_map (strip_suffix_ci cmd)
  |> function
  | Some primary when not (String.equal primary "") -> Some primary
  | Some _ | None -> None

let literal_echo_is_safe text =
  match Masc_exec_bash_parser.Bash.parse_string text with
  | Masc_exec.Parsed.Parsed (Masc_exec.Shell_ir.Simple simple)
    when simple.env = []
         && simple.redirects = []
         && Option.is_none simple.cwd
         && String.equal (Masc_exec.Bin.to_string simple.bin) "echo" ->
    let rec literal_arg_text = function
      | Masc_exec.Shell_ir.Lit arg -> Some arg
      | Masc_exec.Shell_ir.Concat parts ->
        let rec loop acc = function
          | [] -> Some (String.concat "" (List.rev acc))
          | part :: rest ->
            (match literal_arg_text part with
             | Some text -> loop (text :: acc) rest
             | None -> None)
        in
        loop [] parts
      | Masc_exec.Shell_ir.Var _ -> None
    in
    let rec loop = function
      | [] -> true
      | arg :: rest ->
        (match literal_arg_text arg with
         | Some text -> (not (String.starts_with ~prefix:"-" text)) && loop rest
         | None -> false)
    in
    loop simple.args
  | _ -> false

let safe_relative_repos_cd_path text =
  let strip_simple_quotes s =
    let len = String.length s in
    if len >= 2
       && ((Char.equal s.[0] '\'' && Char.equal s.[len - 1] '\'')
           || (Char.equal s.[0] '"' && Char.equal s.[len - 1] '"'))
    then String.sub s 1 (len - 2)
    else s
  in
  let path = text |> String.trim |> strip_simple_quotes in
  let path =
    if String.starts_with ~prefix:"./" path
    then String.sub path 2 (String.length path - 2)
    else path
  in
  let unsafe =
    List.exists
      (String.contains path)
      [ ';'; '&'; '|'; '<'; '>'; '$'; '`'; '\n'; '\r' ]
  in
  if unsafe || not (String.starts_with ~prefix:"repos/" path)
  then None
  else (
    let segments = String.split_on_char '/' path in
    if List.exists (fun s -> s = "" || s = "." || s = "..") segments
    then None
    else Some path)

let safe_read_or_echo_fallback_of_command cmd =
  match find_unquoted_logic_op Logic_or cmd with
  | None -> None
  | Some split ->
    let left = String.sub cmd 0 split in
    let right =
      String.sub cmd (split + 2) (String.length cmd - split - 2) |> String.trim
    in
    if not (literal_echo_is_safe right)
    then None
    else
      let primary_cmd =
        match strip_trailing_dev_null_redirect left with
        | Some primary -> Some primary
        | None ->
          let primary = String.trim left in
          if String.equal primary "" then None else Some primary
      in
      Option.bind primary_cmd safe_read_primary_rewrite

let safe_cd_read_fallback_of_command cmd =
  match find_unquoted_logic_op Logic_and cmd with
  | None -> None
  | Some split ->
    let left = String.sub cmd 0 split |> String.trim in
    let right =
      String.sub cmd (split + 2) (String.length cmd - split - 2) |> String.trim
    in
    if not (String.starts_with ~prefix:"cd " left)
    then None
    else
      let path =
        String.sub left 3 (String.length left - 3)
        |> safe_relative_repos_cd_path
      in
      match path, safe_read_primary_rewrite right with
      | Some cwd_override, Some rewrite -> Some { rewrite with cwd_override = Some cwd_override }
      | _ -> None

let split_unquoted_single_pipeline cmd =
  let len = String.length cmd in
  let rec loop quote_state escaped pipe_pos i =
    if i >= len
    then pipe_pos
    else if escaped
    then loop quote_state false pipe_pos (i + 1)
    else (
      match quote_state, cmd.[i] with
      | Single_quote, '\'' -> loop No_quote false pipe_pos (i + 1)
      | Single_quote, _ -> loop Single_quote false pipe_pos (i + 1)
      | Double_quote, '"' -> loop No_quote false pipe_pos (i + 1)
      | Double_quote, '\\' -> loop Double_quote true pipe_pos (i + 1)
      | Double_quote, _ -> loop Double_quote false pipe_pos (i + 1)
      | No_quote, '\'' -> loop Single_quote false pipe_pos (i + 1)
      | No_quote, '"' -> loop Double_quote false pipe_pos (i + 1)
      | No_quote, '\\' -> loop No_quote true pipe_pos (i + 1)
      | No_quote, '|' when i + 1 < len && Char.equal cmd.[i + 1] '|' ->
        None
      | No_quote, '|' ->
        (match pipe_pos with
         | None -> loop No_quote false (Some i) (i + 1)
         | Some _ -> None)
      | No_quote, _ -> loop No_quote false pipe_pos (i + 1))
  in
  match loop No_quote false None 0 with
  | None -> None
  | Some split ->
    let left = String.sub cmd 0 split |> String.trim in
    let right =
      String.sub cmd (split + 1) (String.length cmd - split - 1)
      |> String.trim
    in
    if String.equal left "" || String.equal right "" then None else Some (left, right)

let is_positive_digits text =
  let len = String.length text in
  len > 0
  && String.for_all (function '0' .. '9' -> true | _ -> false) text
  && not (String.for_all (Char.equal '0') text)

let literal_head_limit_is_safe text =
  match shell_words_with_boundaries text |> strip_command_wrappers with
  | bin :: args when String.equal (command_name bin.text) "head" ->
    let head_arg_is_safe = function
      | [] -> true
      | [ arg ]
        when String.length arg.text > 1
             && Char.equal arg.text.[0] '-'
             && is_positive_digits
                  (String.sub arg.text 1 (String.length arg.text - 1)) ->
        true
      | [ flag; n ]
        when (String.equal flag.text "-n" || String.equal flag.text "--lines")
             && is_positive_digits n.text ->
        true
      | [ arg ] when String.starts_with ~prefix:"--lines=" arg.text ->
        let prefix = "--lines=" in
        is_positive_digits
          (String.sub arg.text (String.length prefix)
             (String.length arg.text - String.length prefix))
      | _ -> false
    in
    head_arg_is_safe args
  | _ -> false

let safe_read_head_pipeline_fallback_of_command cmd =
  match split_unquoted_single_pipeline cmd with
  | None -> None
  | Some (primary, head_stage) ->
    if not (literal_head_limit_is_safe head_stage)
    then None
    else
      let primary_rewrite =
        match safe_read_primary_rewrite primary with
        | Some _ as rewrite -> rewrite
        | None ->
          (match strip_trailing_dev_null_redirect primary with
           | Some stripped -> safe_read_primary_rewrite stripped
           | None -> safe_cd_read_fallback_of_command primary)
      in
      primary_rewrite

let safe_read_fallback_of_command ~write_enabled:_ ~stderr_dev_null_stripped cmd =
  match safe_read_or_echo_fallback_of_command cmd with
  | Some _ as rewrite -> rewrite
  | None ->
    (match safe_read_head_pipeline_fallback_of_command cmd with
     | Some _ as rewrite -> rewrite
     | None ->
       (match safe_cd_read_fallback_of_command cmd with
        | Some _ as rewrite -> rewrite
        | None ->
          (match strip_trailing_dev_null_redirect cmd with
           | Some primary_cmd -> safe_read_primary_rewrite primary_cmd
           | None ->
             if stderr_dev_null_stripped
             then safe_read_primary_rewrite cmd
             else None)))

let shape_block_allowed_by_active_validator ~write_enabled cmd = function
  | Pipe_or_redirect when write_enabled ->
    (match
       Worker_dev_tools.validate_command_coding
         ~caller:Shell_command_gate.Keeper_shell_bash
         cmd
     with
     | Ok () -> true
     | Error _ -> false)
  | Gh_pr_checks | Chaining | Substitution | Repo_wide_scan | Pipe_or_redirect ->
    false

module For_testing = struct
  let elapsed_duration_ms = elapsed_duration_ms

  let keeper_bash_shape_block_tag cmd =
    Option.map bash_shape_block_tag (keeper_bash_shape_block cmd)

  let raw_keeper_bash_shape_block_tag cmd =
    Option.map bash_shape_block_tag (raw_keeper_bash_shape_block cmd)

  let strip_stderr_dev_null_redirects = strip_stderr_dev_null_redirects

  let keeper_bash_shape_block_hint cmd =
    match keeper_bash_shape_block cmd with
    | Some block -> Some (bash_shape_block_hint ~cmd block)
    | None ->
      if Task_probe.looks_like_discovery cmd
      then Some Task_probe.hint
      else None
end

let workflow_rejection_field = "failure_class", `String "workflow_rejection"

let bash_shape_block_result ~cmd ~cmd_for_log ~env_snapshot block =
  Yojson.Safe.to_string
    (Exec_core.blocked_result_json
       ~cmd
       ~error:"keeper_bash_command_shape_blocked"
       ~reason:(bash_shape_block_reason block)
       ~hint:(bash_shape_block_hint ~cmd block)
       ~alternatives:(bash_shape_block_alternatives ~cmd block)
       ~diag:
         (Some
            {
              Exec_core.rule_id =
                "keeper_bash_" ^ bash_shape_block_tag block ^ "_blocked";
              explanation = bash_shape_block_reason block;
              rewrite = Some (bash_shape_block_hint ~cmd block);
              tool_suggestion =
                (match block with
                 | Gh_pr_checks -> Some "keeper_pr_status"
                 | _ when Task_probe.looks_like_discovery cmd ->
                   Some "keeper_tasks_list"
                 | Pipe_or_redirect -> Some "keeper_shell"
                 | Repo_wide_scan -> Some "keeper_shell"
                 | Chaining | Substitution -> None);
            })
       ~extra:
         [
           workflow_rejection_field;
           "cmd", `String cmd_for_log;
           "shape_block", `String (bash_shape_block_tag block);
           "execution_time_ms", `Int 0;
         ]
       ~env_snapshot
       ())

let has_typed_bash_input_key = function
  | `Assoc fields ->
    List.exists
      (fun (key, _) ->
         String.equal key "executable"
         || String.equal key "pipeline"
         || String.equal key "stages")
      fields
  | _ -> false

let assoc_upsert key value = function
  | `Assoc fields ->
    `Assoc ((key, value) :: List.filter (fun (k, _) -> not (String.equal k key)) fields)
  | other -> other

let shell_quote_for_policy token =
  let safe_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '.' | '/' | ':' | '=' | ',' ->
      true
    | _ -> false
  in
  if String.length token > 0 && String.for_all safe_char token
  then token
  else
    let parts = String.split_on_char '\'' token in
    "'" ^ String.concat "'\\''" parts ^ "'"

let typed_stage_command_text ~executable ~argv =
  executable :: argv
  |> List.map shell_quote_for_policy
  |> String.concat " "

let typed_input_command_text = function
  | Keeper_tool_bash_input.Exec { executable; argv; _ } ->
    typed_stage_command_text ~executable ~argv
  | Keeper_tool_bash_input.Pipeline { stages; _ } ->
    stages
    |> List.map (fun (stage : Keeper_tool_bash_input.exec_stage) ->
      typed_stage_command_text ~executable:stage.executable ~argv:stage.argv)
    |> String.concat " | "

let typed_input_has_env = function
  | Keeper_tool_bash_input.Exec { env; _ }
  | Keeper_tool_bash_input.Pipeline { env; _ } ->
    env <> []

let typed_validation_error_text error =
  Format.asprintf "%a" Keeper_tool_bash_input.pp_validation_error error

let normalize_path_for_keeper_bash_containment path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let repo_top_relative_read_path raw =
  let rec strip_current_dir path =
    if String.starts_with ~prefix:"./" path
    then strip_current_dir (String.sub path 2 (String.length path - 2))
    else path
  in
  let path = raw |> String.trim |> strip_current_dir in
  if path = ""
     || not (Filename.is_relative path)
     || String.equal path "."
     || String.equal path ".."
     || String.starts_with ~prefix:"../" path
     || String.starts_with ~prefix:"repos/" path
     || is_playground_lane_relative_path path
  then None
  else
    let first_segment =
      match String.split_on_char '/' path with
      | segment :: _ -> segment
      | [] -> path
    in
    if
      List.mem
        first_segment
        [ "bench"
        ; "bin"
        ; "docs"
        ; "examples"
        ; "lib"
        ; "ops"
        ; "scripts"
        ; "src"
        ; "test"
        ; "tests"
        ]
    then Some path
    else None

let single_repo_cwd_for_top_relative_read
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~(cmd : string)
  =
  let sandbox_root =
    keeper_playground_root ~config ~meta
    |> normalize_path_for_keeper_bash_containment
  in
  let cwd_norm = normalize_path_for_keeper_bash_containment cwd in
  if not (String.equal cwd_norm sandbox_root)
  then None
  else if Worker_dev_tools.is_write_operation cmd
  then None
  else
    match
      Worker_dev_tools.validate_command_coding_with_allowlist
        ~caller:Shell_command_gate.Keeper_shell_bash
        ~allow_pipes:false
        ~allowed_commands:Worker_dev_tools.dev_allowed_commands
        cmd
    with
    | Error _ -> None
    | Ok () ->
      (match keeper_sandbox_repo_names ~config ~meta with
       | [ repo_name ] ->
         let repo_root = Filename.concat (Filename.concat sandbox_root "repos") repo_name in
         let wants_repo_root =
           Worker_dev_tools.existing_dir_path_values cmd
           |> List.exists (fun raw_path ->
             match repo_top_relative_read_path raw_path with
             | None -> false
             | Some rel ->
               (not (safe_file_exists (Filename.concat sandbox_root rel)))
               && safe_file_exists (Filename.concat repo_root rel))
         in
         if wants_repo_root then Some repo_root else None
       | [] | _ :: _ :: _ -> None)

let typed_docker_image (meta : keeper_meta) =
  match meta.sandbox_image with
  | Some img when String.trim img <> "" -> img
  | _ -> Env_config_keeper.KeeperSandbox.docker_image ()

let typed_docker_sandbox_target ~turn_sandbox_factory ~meta ~cwd =
  match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
  | None ->
    Error
      "typed keeper_bash Docker Shell IR dispatch requires a turn sandbox factory"
  | Some runtime ->
    let image = typed_docker_image meta in
    let runner ~stdin_content ~argv ~env:_ ~cwd:stage_cwd ~timeout_sec =
      let cwd = Option.value stage_cwd ~default:cwd in
      match
        Keeper_turn_sandbox_runtime.run_exec_with_status
          ?stdin_content
          runtime
          ~timeout_sec
          ~cwd
          ~command_argv:argv
      with
      | Ok (status, output) -> status, output, ""
      | Error err -> Unix.WEXITED 1, "", err
    in
    Ok (Masc_exec.Sandbox_target.docker ~image ~runner)

let handle_keeper_bash_typed
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~timeout_sec
      ~run_in_background
      ~write_enabled
      ()
  =
  let root = Keeper_alerting_path.project_root_of_config config in
  if run_in_background
  then
    error_json
      ~fields:[ "typed", `Bool true ]
      "typed keeper_bash does not support run_in_background yet; use legacy cmd or foreground typed exec"
  else
    match Keeper_shell_shared.resolve_keeper_shell_write_cwd ~config ~meta ~args with
    | Error e -> error_json e
    | Ok cwd ->
      let typed_args = assoc_upsert "cwd" (`String cwd) args in
      match Keeper_tool_bash_input.of_json typed_args with
      | Error e ->
        error_json
          ~fields:[ "typed", `Bool true; "cwd", `String cwd ]
          e
      | Ok input ->
        let cmd = typed_input_command_text input in
        let cmd_for_log =
          cmd
          |> Worker_dev_tools.sanitize_command_for_log
          |> Worker_dev_tools.truncate_for_log
        in
        let mode =
          if write_enabled
          then Keeper_tool_bash_input.Dev_full
          else Keeper_tool_bash_input.Readonly
        in
        let in_playground =
          let cwd_canonical = normalize_path_for_keeper_bash_containment cwd in
          let playground_rel = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
          let playground_abs =
            normalize_path_for_keeper_bash_containment
              (Filename.concat root playground_rel)
          in
          String.starts_with ~prefix:(playground_abs ^ "/") (cwd_canonical ^ "/")
          || String.equal playground_abs cwd_canonical
        in
        let sandbox_profile, _sandbox_network_mode =
          Keeper_shell_shared.effective_sandbox_profile ~meta ~in_playground
        in
        let dispatch_sandbox =
          match sandbox_profile with
          | Local -> Ok (Masc_exec.Sandbox_target.host ())
          | Docker ->
            if typed_input_has_env input
            then Error "typed keeper_bash Docker Shell IR dispatch does not support env yet"
            else typed_docker_sandbox_target ~turn_sandbox_factory ~meta ~cwd
        in
        (match dispatch_sandbox with
         | Error e ->
           error_json
             ~fields:[ "typed", `Bool true; "cmd", `String cmd_for_log; "cwd", `String cwd ]
             e
         | Ok dispatch_sandbox ->
        if Worker_dev_tools.is_destructive_bash_operation cmd
        then
          Yojson.Safe.to_string
            (Exec_core.blocked_result_json
               ~cmd
               ~error:"destructive_operation_blocked"
               ~reason:
                 "This typed command is destructive and is blocked for all presets."
               ~alternatives:[ "Use a non-destructive command or a dedicated structured tool." ]
               ~retryability:Exec_core.Operator_required
               ~extra:[ "cmd", `String cmd_for_log; "typed", `Bool true; "execution_time_ms", `Int 0 ]
               ())
        else if (not write_enabled) && Worker_dev_tools.is_write_operation cmd
        then
          Yojson.Safe.to_string
            (Exec_core.blocked_result_json
               ~cmd
               ~error:"write_operation_gated"
               ~reason:
                 "This typed command modifies state. A write-enabled preset is required."
               ~alternatives:
                 [ "Use read-only commands such as rg, cat, ls, git status, or git log."
                 ; "Ask the operator for a write-enabled preset."
                 ]
               ~retryability:Exec_core.Operator_required
               ~extra:[ "cmd", `String cmd_for_log; "typed", `Bool true; "execution_time_ms", `Int 0 ]
               ())
        else
          match Keeper_tool_bash_input.to_shell_ir ~mode ~sandbox:dispatch_sandbox input with
          | Error e ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String cmd_for_log; "cwd", `String cwd ]
              (typed_validation_error_text e)
          | Ok ir ->
            let path_validation =
              match
                Keeper_task_worktree_lazy.ensure_command_existing_dirs
                  ~config ~meta ~cwd ~cmd
              with
              | Error e -> Error e
              | Ok () ->
                Worker_dev_tools.validate_command_paths
                  ~keeper_id:meta.name
                  ~base_path:root
                  ~workdir:cwd
                  cmd
            in
            (match path_validation with
             | Error e -> error_json ~fields:[ "blocked_cmd", `String cmd_for_log ] e
             | Ok () ->
               let env_snap =
                 Cancel_safe.protect
                   ~on_exn:(fun _ -> None)
                   (fun () -> Some (Exec_core.snapshot_env ~cwd))
               in
               let t0 = Unix.gettimeofday () in
               let result = Masc_exec.Exec_dispatch.dispatch ir in
               let elapsed_ms =
                 elapsed_duration_ms
                   ~start_time:t0
                   ~end_time:(Unix.gettimeofday ())
               in
               let output =
                 if String.equal result.stderr ""
                 then result.stdout
                 else result.stdout ^ result.stderr
               in
               Yojson.Safe.to_string
                 (Exec_core.process_result_json
                    ~base_path:root
                    ~keeper_name:meta.name
                    ~cmd
                    ~extra:
                      [ "cwd", `String cwd
                      ; "typed", `Bool true
                      ; "execution_time_ms", `Int elapsed_ms
                      ; "timeout_sec", `Float timeout_sec
                      ]
                    ~status:result.status
                    ~output
                    ~env_snapshot:env_snap
                    ())))

let handle_keeper_bash
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(turn_sandbox_factory_git : Keeper_sandbox_factory.t option)
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ()
  =
  let original_cmd =
    Safe_ops.json_string ~default:"" "cmd" args |> String.trim
  in
  let cmd, stripped_stderr_dev_null =
    strip_stderr_dev_null_redirects original_cmd
  in
  let root = Keeper_alerting_path.project_root_of_config config in
  let cmd_for_log =
    cmd
    |> Worker_dev_tools.sanitize_command_for_log
    |> Worker_dev_tools.truncate_for_log
  in
  let timeout_sec =
    Keeper_shell_shared.clamp_shell_timeout
      ~min_sec:Keeper_shell_shared.keeper_bash_min_timeout_sec
      ~default:Keeper_shell_shared.io_timeout_sec
      args
  in
  let run_in_background =
    Safe_ops.json_bool ~default:false "run_in_background" args
  in
  (* Keep read-only shell broadly visible; mutating shell is limited to
     privileged tool presets. *)
  let write_enabled =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some preset -> Keeper_tool_policy.allows_shell_write_for_preset preset
    | None -> false
  in
  let gh_pr_create_block () =
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_shell_bash_failures
      ~labels:[("keeper", meta.name); ("site", "gh_pr_create")]
      ();
    Log.Keeper.warn
      "keeper_bash gh pr create blocked: keeper=%s cmd=%s"
      meta.name cmd_for_log;
    Yojson.Safe.to_string
      (`Assoc
         [ "ok", `Bool false
         ; "error", `String "gh_pr_create_requires_keeper_pr_create"
         ; workflow_rejection_field
         ; "reason", `String
             "keeper_bash cannot bypass the PR creation approval and audit policy"
         ; "hint", `String
             "Use keeper_pr_create with draft=true so governance approval and PR lifecycle markers are enforced."
         ; "cmd", `String cmd_for_log
         ])
  in
  let native_pr_command_block hint =
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_shell_bash_failures
      ~labels:[("keeper", meta.name); ("site", "gh_pr_native_tool")]
      ();
    Log.Keeper.warn
      "keeper_bash gh pr command routed to native tool: keeper=%s rule=%s cmd=%s"
      meta.name hint.rule_id cmd_for_log;
    Yojson.Safe.to_string
      (Exec_core.blocked_result_json
         ~cmd
         ~error:"command_blocked"
         ~reason:"Raw GitHub PR commands must use the native PR tool surface."
         ~hint:hint.hint
         ~alternatives:hint.alternatives
         ~diag:(Some (native_tool_diagnosis hint))
         ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
         ())
  in
  let direct_tool_command_block ~tool_policy_visible tool_name =
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_shell_bash_failures
      ~labels:[("keeper", meta.name); ("site", "tool_invoked_as_shell")]
      ();
    Log.Keeper.warn
      "keeper_bash direct tool command blocked: keeper=%s tool=%s cmd=%s"
      meta.name tool_name cmd_for_log;
    Yojson.Safe.to_string
      (`Assoc
         [ "ok", `Bool false
         ; "error", `String "tool_invoked_as_shell_command"
         ; workflow_rejection_field
         ; "tool", `String tool_name
         ; "cmd", `String cmd_for_log
         ; "hint",
           `String
             (if tool_policy_visible
              then
                Printf.sprintf
                  "%s is a MASC tool, not a shell command. Call the %s \
                   tool directly with JSON arguments instead of using Bash."
                  tool_name tool_name
              else
                Printf.sprintf
                  "%s looks like a MASC tool, not a shell command, but it \
                   is not visible in this keeper's tool policy. Do not run \
                   it through Bash; pick a visible tool or update the keeper \
                   tool policy."
                  tool_name)
         ; "suggested_tool", `String tool_name
         ; "tool_policy_visible", `Bool tool_policy_visible
         ; "retryable", `Bool true
         ])
  in
  let task_state_http_probe_block () =
    Yojson.Safe.to_string
      (Exec_core.blocked_result_json
         ~cmd
         ~error:"task_state_http_probe_blocked"
         ~reason:
           "Task state is not exposed through guessed localhost HTTP APIs from \
            keeper_bash."
         ~hint:Task_probe.hint
         ~alternatives:Task_probe.alternatives
         ~retryability:Exec_core.Self_correct
         ~diag:
           (Some
              { Exec_core.rule_id = "task_state_http_probe_blocked"
              ; explanation =
                  "Keepers must use task-state tools instead of probing \
                   localhost task APIs from shell."
              ; rewrite = Some Task_probe.hint
              ; tool_suggestion = Some "keeper_tasks_list"
              })
         ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
         ())
  in
  let task_state_file_probe_block () =
    Yojson.Safe.to_string
      (Exec_core.blocked_result_json
         ~cmd
         ~error:"task_state_file_probe_blocked"
         ~reason:
           "Task state is owned by the MASC task tools, not by guessed \
            backlog/current-task files in keeper sandboxes."
         ~hint:Task_probe.hint
         ~alternatives:Task_probe.alternatives
         ~retryability:Exec_core.Self_correct
         ~diag:
           (Some
              { Exec_core.rule_id = "task_state_file_probe_blocked"
              ; explanation =
                  "Keepers must use task-state tools instead of cat/find/rg \
                   against .masc backlog files or worktree .task.json files."
              ; rewrite = Some Task_probe.hint
              ; tool_suggestion = Some "keeper_tasks_list"
              })
         ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
         ())
  in
  if Env_config_keeper.KeeperSandbox.hard_mode ()
     && meta.sandbox_profile <> Docker
  then
    error_json
      "MASC_KEEPER_SANDBOX_HARD_MODE requires sandbox_profile=docker"
  else if cmd = "" && has_typed_bash_input_key args
  then
    handle_keeper_bash_typed
      ~turn_sandbox_factory
      ~config
      ~meta
      ~args
      ~timeout_sec
      ~run_in_background
      ~write_enabled
      ()
  else if cmd = ""
  then error_json "cmd is required. Good: cmd='ls -la lib/'. Bad: cmd=''."
  else (
    match direct_tool_command_name ~meta cmd with
    | Some (tool_name, tool_policy_visible) ->
      direct_tool_command_block ~tool_policy_visible tool_name
    | None when cmd_contains_gh_pr_create cmd -> gh_pr_create_block ()
    | None when Option.is_some (gh_pr_native_tool_hint cmd) ->
      (match gh_pr_native_tool_hint cmd with
       | Some hint -> native_pr_command_block hint
       | None -> error_json "internal native PR command hint mismatch")
    | None when Task_probe.mentions_task_state_file cmd ->
      task_state_file_probe_block ()
    | None when Task_probe.looks_like_http_probe cmd ->
      task_state_http_probe_block ()
    | None -> begin
    (if stripped_stderr_dev_null then
       Log.Keeper.info
         "keeper_bash normalized stderr /dev/null redirect: keeper=%s cmd=%s"
         meta.name cmd_for_log);
    (* Tick 22: dark-launch shadow logger.  Runs
       [Worker_dev_tools.diff_command] side-by-side with the
       live gate and emits a structured line for every non-[Agree]
       outcome so operators can collect flip-blocker evidence
       (Legacy_deny_shadow_allow) and inverted-gap cases
       (Legacy_allow_shadow_deny) from real traffic without
       changing any behavior.  Flag-gated by
       [MASC_BASH_AST_SHADOW_LOG]; default off. *)
    (if Worker_dev_tools.shadow_diff_log_enabled () then begin
       let diff, legacy, shadow = Worker_dev_tools.diff_command cmd in
       Legendary_counters.incr_gate_diff diff;
       (* Histogram refinement of the Shadow_cannot_parse bucket —
          per-reason counters let operators prioritise A1-PR-N
          grammar expansion by construct frequency.  Typed dispatch
          over the [parse_outcome_kind] payload of
          [Shadow_parse_unsupported]; [classify_shadow] guarantees the
          only kinds wrapped here are [Parse_error] / [Parse_aborted _]
          / [Too_complex _].  A future divergence (e.g. wrapping
          [Parsed_simple]) is a compile error rather than a silent
          "other"-bucket landing. *)
       (match shadow with
        | Worker_dev_tools.Shadow_parse_unsupported { kind = Too_complex r } ->
          Legendary_counters.incr_too_complex r
        | Worker_dev_tools.Shadow_parse_unsupported { kind = Parse_error } ->
          Legendary_counters.incr_too_complex_parse_error ()
        | Worker_dev_tools.Shadow_parse_unsupported { kind = Parse_aborted r } ->
          Legendary_counters.incr_too_complex_parse_aborted r
        | Worker_dev_tools.Shadow_parse_unsupported { kind = Parsed_simple } ->
          (* Unreachable by construction: [classify_shadow] yields
             [Shadow_allow] for [Parsed_simple], not
             [Shadow_parse_unsupported].  The arm exists so any future
             change to [classify_shadow] forces a re-review here. *)
          ()
        | Shadow_allow | Shadow_deny_destructive _ -> ());
       (match diff with
        | Worker_dev_tools.Agree -> ()
        | _ ->
          Log.Keeper.info
            "gate_diff_shadow keeper=%s cmd_hash=%s diff=%s legacy=%s shadow=%s"
            meta.name
            (Worker_dev_tools.cmd_hash_for_log cmd)
            (Worker_dev_tools.gate_diff_to_string diff)
            (Worker_dev_tools.legacy_verdict_to_tag legacy)
            (Worker_dev_tools.shadow_verdict_to_tag shadow))
     end);
    (* RFC-0092 Phase A — typed-validation advisor (behavior-neutral).
       Flag-gated; emits a structured log line + per-bucket counter so
       operators can measure parity vs the legacy substring gate
       before the Phase C authority flip.  No allow/deny decision is
       driven from the typed path at this stage. *)
    (if Worker_dev_tools.typed_advisor_log_enabled () then begin
       let advisory =
         Shell_ir_validator.advise
           ~cmd
           ~allowlist:Worker_dev_tools.dev_allowed_commands
       in
       Legendary_counters.incr_typed_advisor advisory;
       Log.Keeper.info
         "typed_advisor keeper=%s cmd_hash=%s outcome=%s"
         meta.name
         (Worker_dev_tools.cmd_hash_for_log cmd)
         (Shell_ir_validator.advisory_tag advisory)
     end);
    (* Resolve cwd early — needed for playground detection before validation. *)
    match Keeper_shell_shared.resolve_keeper_shell_write_cwd ~config ~meta ~args with
    | Error e -> error_json e
    | Ok requested_cwd ->
    let command_cacheable () =
      Masc_exec.Risk_classifier.(is_cacheable (classify cmd))
    in
    let safe_read_fallback =
      safe_read_fallback_of_command ~write_enabled
        ~stderr_dev_null_stripped:stripped_stderr_dev_null cmd
    in
    let validation_cmd =
      match safe_read_fallback with
      | Some rewrite -> rewrite.primary_cmd
      | None -> cmd
    in
    let cwd =
      match safe_read_fallback with
      | Some { cwd_override = Some _; _ } -> requested_cwd
      | Some { cwd_override = None; _ } | None ->
        (match
           single_repo_cwd_for_top_relative_read
             ~config
             ~meta
             ~cwd:requested_cwd
             ~cmd:validation_cmd
         with
         | Some repo_cwd ->
           Log.Keeper.info
             "keeper_bash auto-selected single sandbox repo cwd: keeper=%s cwd=%s cmd=%s"
             meta.name repo_cwd cmd_for_log;
           repo_cwd
         | None -> requested_cwd)
    in
    let validation_cwd =
      match safe_read_fallback with
      | Some { cwd_override = Some rel; _ } -> Filename.concat requested_cwd rel
      | Some { cwd_override = None; _ } | None -> cwd
    in
    let env_snap =
      (* RFC-0106 P1: route Cancelled re-raise through Cancel_safe.protect.
         Silent [_ -> None] preserved verbatim — env snapshot is optional. *)
      Cancel_safe.protect
        ~on_exn:(fun _ -> None)
        (fun () -> Some (Exec_core.snapshot_env ~cwd))
    in
    let cached_result_json
          (entry : Masc_exec.Exec_cache.cache_entry) =
      let st = Unix.WEXITED entry.exit_code in
      Yojson.Safe.to_string
        (Exec_core.process_result_json
           ~base_path:root
           ~keeper_name:meta.name
           ~cmd
           ~extra:[
             "cwd", `String cwd;
             "execution_time_ms", `Int entry.duration_ms;
             "cached", `Bool true;
             "cache_age_ms",
               `Int
                 (int_of_float
                    ((Unix.time () -. entry.cached_at) *. 1000.));
           ]
           ~status:st
           ~output:entry.output
           ~env_snapshot:env_snap
           ())
    in
    let cached_raw_result_json
          (entry : Masc_exec.Exec_cache.cache_entry) =
      match
        Safe_ops.parse_json_safe
          ~context:"Keeper_shell_bash.cached_raw_result_json"
          entry.output
      with
      | Ok (`Assoc fields) ->
        let fields =
          fields
          |> List.remove_assoc "cached"
          |> List.remove_assoc "cache_age_ms"
          |> List.remove_assoc "execution_time_ms"
        in
        Yojson.Safe.to_string
          (`Assoc
            (fields @ [
               "cached", `Bool true;
               "cache_age_ms",
                 `Int
                   (int_of_float
                      ((Unix.time () -. entry.cached_at) *. 1000.));
               "execution_time_ms", `Int entry.duration_ms;
             ]))
      | Ok _ | Error _ -> cached_result_json entry
    in
    let with_raw_json_exec_cache run =
      let cacheable = command_cacheable () in
      if not cacheable then run ()
      else
        match exec_cache with
        | None -> run ()
        | Some cache ->
          (match Masc_exec.Exec_cache.lookup cache cmd with
           | Some entry -> cached_raw_result_json entry
           | None ->
             let t0 = Unix.gettimeofday () in
             let raw = run () in
             let elapsed_ms =
               elapsed_duration_ms
                 ~start_time:t0 ~end_time:(Unix.gettimeofday ())
             in
             (match
                Safe_ops.parse_json_safe
                  ~context:"Keeper_shell_bash.with_raw_json_exec_cache"
                  raw
              with
              | Ok json when Safe_ops.json_bool ~default:false "ok" json ->
                Masc_exec.Exec_cache.store cache
                  ~cmd ~exit_code:0 ~output:raw ~duration_ms:elapsed_ms
              | Ok _ | Error _ -> ());
             raw)
    in
    let normalize_path_for_containment path =
      Keeper_alerting_path.normalize_path_for_check path
      |> Keeper_alerting_path.strip_trailing_slashes
    in
    let cwd_canonical =
      normalize_path_for_containment cwd
    in
    let playground_rel =
      Keeper_sandbox.allowed_root_rel_of_meta ~meta
    in
    let playground_abs =
      normalize_path_for_containment (Filename.concat root playground_rel)
    in
    let in_playground =
      String.starts_with ~prefix:(playground_abs ^ "/") (cwd_canonical ^ "/")
      || String.equal playground_abs cwd_canonical
    in
    let base_profile, base_network_mode =
      Keeper_shell_shared.effective_sandbox_profile ~meta ~in_playground
    in
    (* Docker git-credential dispatch. When base profile is Docker and the
       command's leading token is git/gh, allow network egress and mount
       the selected root/keeper GitHub identity bundle read-only for the
       duration of this command. Disabled when
       MASC_KEEPER_SANDBOX_GIT_DISPATCH=false.
       [git_creds_enabled] replaces the former Docker_with_git variant:
       the external profile stays Docker; the dispatcher reads this flag
       to choose between Keeper_shell_shared.run_docker_with_git_bash and Keeper_shell_shared.run_docker_hardened_bash. *)
    let sandbox_profile, sandbox_network_mode, git_creds_enabled =
      if base_profile = Docker
         && Env_config_keeper.KeeperSandbox.with_git_dispatch_enabled ()
         && Keeper_shell_shared.cmd_targets_git_or_gh cmd
      then (Docker, Network_inherit, true)
      else (base_profile, base_network_mode, false)
    in
    let sandbox_root = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
    match keeper_bash_shape_block cmd with
    | Some block when
      Option.is_none safe_read_fallback
      && not (shape_block_allowed_by_active_validator ~write_enabled cmd block) ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_shell_bash_failures
        ~labels:
          [ ("keeper", meta.name)
          ; ("site", "command_shape")
          ; ("shape_block", bash_shape_block_tag block)
          ]
        ();
      Log.Keeper.warn
        "keeper_bash command-shape blocked: keeper=%s block=%s cmd=%s"
        meta.name (bash_shape_block_tag block) cmd_for_log;
      bash_shape_block_result ~cmd ~cmd_for_log ~env_snapshot:env_snap block
    | Some _ | None ->
      (* Destructive guard: always active regardless of Docker or preset *)
      if Worker_dev_tools.is_destructive_bash_operation cmd
    then (
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_shell_bash_failures
        ~labels:[("keeper", meta.name); ("site", "destructive")]
        ();
      Log.Keeper.warn "keeper_bash DESTRUCTIVE blocked: %s (keeper=%s)" cmd_for_log meta.name;
      Yojson.Safe.to_string
        (Exec_core.blocked_result_json
           ~cmd
           ~error:"destructive_operation_blocked"
           ~reason:
             "This command is destructive (force push, push to main, rm -rf, \
              etc.) and is blocked for all presets."
           ~alternatives:
             [ "Use `git push` without --force for normal pushes."
             ; "For cleanup, target specific files instead of rm -rf."
             ; "Ask a human operator to perform this destructive action."
             ]
           ~retryability:Exec_core.Operator_required
           ~diag:
             (Some { Exec_core.rule_id = "destructive_operation_blocked"
                    ; explanation =
                        "force push, rm -rf, and similar destructive \
                         commands are blocked for all presets to protect \
                         shared state."
                    ; rewrite =
                        Some "For git: use 'git push' without --force. \
                              For cleanup: target specific files (rm file) \
                              instead of rm -rf."
                    ; tool_suggestion = None })
           ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
           ~env_snapshot:env_snap
           ()))
    else if cmd_contains_gh_pr_create cmd
    then gh_pr_create_block ()
    else if base_profile = Docker
            && Env_config_keeper.KeeperSandbox.hard_mode ()
            && Keeper_shell_shared.cmd_targets_gh cmd
    then (
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_shell_bash_failures
        ~labels:[("keeper", meta.name); ("site", "hard_mode")]
        ();
      Log.Keeper.warn
        "keeper_bash gh blocked by hard mode: keeper=%s cmd=%s"
        meta.name cmd_for_log;
      Yojson.Safe.to_string
        (`Assoc
           [ "ok", `Bool false
           ; "error", `String "gh_requires_brokered_structured_tool"
           ; "reason", `String
               "MASC_KEEPER_SANDBOX_HARD_MODE keeps Docker containers on network=none and forbids host credential mounts"
           ; "hint", `String
               "Use keeper_shell op=gh cmd=\"...\"; hard mode runs validated gh commands through the host broker with keeper-scoped GH_CONFIG_DIR."
           ; "cmd", `String cmd_for_log
           ]))
    else if Worker_dev_tools.is_git_branch_switch cmd
            && not (write_enabled && in_playground)
    then (
      Log.Keeper.info
        "keeper_bash branch-switch blocked: %s (keeper=%s, write_enabled=%b, playground=%b)"
        cmd_for_log meta.name write_enabled in_playground;
      Yojson.Safe.to_string
        (Exec_core.blocked_result_json
           ~cmd
           ~error:"branch_switch_blocked"
           ~reason:
             "git checkout/switch/branch mutations require a write-enabled preset \
              (Coding/Delivery/Full) and a keeper-owned sandbox repo or \
              worktree. Clone into your sandbox first \
              (keeper_shell op=git_clone), then create or enter a worktree \
              under repos/<repo>/.worktrees/<task>."
           ~hint:(Printf.sprintf
                    "Use cwd=%srepos/REPO/.worktrees/TASK"
                    sandbox_root)
           ~alternatives:
             [ Printf.sprintf
                 "Clone the repo first: keeper_shell op=git_clone, then use cwd=%srepos/REPO/.worktrees/TASK."
                 sandbox_root
             ; "Use keeper_shell op=git op_cmd='branch -a' to list available branches."
             ]
           ~retryability:Exec_core.Operator_required
           ~diag:
             (Some { Exec_core.rule_id = "branch_switch_blocked"
                    ; explanation =
                        "git checkout/switch/branch mutations need a write-enabled preset and a sandbox clone."
                    ; rewrite =
                        Some (Printf.sprintf
                          "First: keeper_shell op=git_clone. Then: set cwd=%srepos/REPO/.worktrees/TASK"
                          sandbox_root)
                    ; tool_suggestion = None })
           ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
           ()))
    else if (not write_enabled) && Worker_dev_tools.is_write_operation cmd
    then (
      Log.Keeper.info "keeper_bash write-gate: %s (keeper=%s, playground=%b)"
        cmd_for_log meta.name in_playground;
      Yojson.Safe.to_string
        (Exec_core.blocked_result_json
           ~cmd
           ~error:"write_operation_gated"
           ~reason:
             "This command modifies state (git push/commit, make deploy, etc.). \
              A write-enabled preset (Coding/Delivery/Full) is required."
           ~alternatives:
             [ "Read-only alternatives: use keeper_bash for git log, git diff, git status."
             ; "If you need write access, ask the operator to assign a Coding/Delivery/Full preset."
             ]
           ~retryability:Exec_core.Operator_required
           ~diag:
             (Some { Exec_core.rule_id = "write_operation_gated"
                    ; explanation =
                        "This command modifies state but the current preset is read-only. Write operations require Coding, Delivery, or Full preset."
                    ; rewrite = None
                    ; tool_suggestion =
                        Some "Ask the operator for a write-enabled preset" })
           ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
           ~env_snapshot:env_snap
           ()))
    else if write_enabled
            && Worker_dev_tools.is_write_operation cmd
            && not in_playground
    then (
      Log.Keeper.info
        "keeper_bash write-containment blocked: %s (keeper=%s, cwd=%s, playground=%b)"
        cmd_for_log meta.name cwd in_playground;
      Yojson.Safe.to_string
        (Exec_core.blocked_result_json
           ~cmd
           ~error:"write_outside_playground_blocked"
           ~reason:
             (Printf.sprintf
                "Write operations (git push/commit, make deploy, etc.) \
                 must run with cwd inside your keeper-owned sandbox clone \
                 or one of its worktrees under %srepos/<repo>/.worktrees/. \
                 Open a sandbox clone first with keeper_shell op=git_clone \
                 if needed, then use masc_worktree_create and set cwd to \
                 the returned worktree path."
                sandbox_root)
           ~hint:(Printf.sprintf
                    "cwd must start with %s and usually looks like %srepos/REPO/.worktrees/TASK"
                    sandbox_root
                    sandbox_root)
           ~alternatives:
             [ Printf.sprintf
                 "Clone into your sandbox: keeper_shell op=git_clone, then cd to %srepos/REPO/."
                 sandbox_root
             ; "Create a worktree inside your sandbox with masc_worktree_create."
             ; "Use keeper_bash with a cwd pointing to your sandbox worktree."
             ]
           ~retryability:Exec_core.Operator_required
           ~diag:
             (Some { Exec_core.rule_id = "write_outside_playground_blocked"
                    ; explanation =
                        "Write operations must run inside the keeper sandbox. The current cwd is outside the sandbox root."
                    ; rewrite =
                        Some (Printf.sprintf
                          "Clone into sandbox: keeper_shell op=git_clone, then set cwd=%srepos/REPO/.worktrees/TASK"
                          sandbox_root)
                    ; tool_suggestion = None })
           ~extra:[ "cmd", `String cmd_for_log; "cwd", `String cwd; "execution_time_ms", `Int 0 ]
           ()))
    else if sandbox_profile = Docker && git_creds_enabled then (
      let detected_tool = if Keeper_shell_shared.cmd_targets_gh cmd then "gh" else "git" in
      Log.Keeper.info
        "DOCKER_GIT_EXEC: keeper=%s cwd=%s cmd=%s detected_tool=%s \
         base_network=%s upgraded_to=inherit"
        meta.name cwd cmd_for_log detected_tool
        (network_mode_to_string base_network_mode);
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_bash_network_upgrade
        ~labels:[ ("keeper", meta.name); ("detected_tool", detected_tool) ]
        ();
      Keeper_shell_shared.run_docker_with_git_bash
        ~turn_sandbox_runtime:
          (Keeper_sandbox_factory.resolve_opt
             turn_sandbox_factory_git ~cwd)
        ~config ~meta ~cwd ~timeout_sec ~cmd ())
    else if sandbox_profile = Docker then (
      Log.Keeper.info
        "DOCKER_EXEC: keeper=%s cwd=%s cmd=%s network=%s"
        meta.name cwd cmd_for_log (network_mode_to_string sandbox_network_mode);
      with_raw_json_exec_cache (fun () ->
        Keeper_shell_shared.run_docker_hardened_bash
          ~turn_sandbox_runtime:
            (Keeper_sandbox_factory.resolve_opt
               turn_sandbox_factory ~cwd)
          ~config ~meta ~cwd ~timeout_sec ~cmd
          ~network_mode:sandbox_network_mode))
    else
      let local_reason =
        if Env_config_keeper.KeeperSandbox.hard_mode () then "hard_mode_local"
        else if meta.sandbox_profile = Local then "declared_local_profile"
        else if not (Env_config_keeper.DockerPlayground.enabled) then
          "playground_disabled"
        else "outside_playground"
      in
      Log.Keeper.info
        "LOCAL_EXEC: keeper=%s cwd=%s reason=%s sandbox_profile=%s \
         playground=%b hard_mode=%b"
        meta.name cwd local_reason
        (sandbox_profile_to_string meta.sandbox_profile)
        in_playground
        (Env_config_keeper.KeeperSandbox.hard_mode ());
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_bash_local_execution
        ~labels:[ ("keeper", meta.name); ("reason", local_reason) ]
        ();
      (* Local execution path: full validation applies *)
      let validate =
        if write_enabled
        then
          Worker_dev_tools.validate_command_coding
            ~caller:Shell_command_gate.Keeper_shell_bash
        else if Option.is_some safe_read_fallback
        then
          Worker_dev_tools.validate_command_coding_with_allowlist
            ~caller:Shell_command_gate.Keeper_shell_bash
            ~allow_pipes:false
            ~allowed_commands:Worker_dev_tools.dev_allowed_commands
        else
          Worker_dev_tools.validate_command
            ~caller:Shell_command_gate.Keeper_shell_bash
      in
      match validate validation_cmd with
      | Error reason ->
        let reason_str = Worker_dev_tools.block_reason_to_string reason in
        let native_tool_hint =
          match reason with
          | Worker_dev_tools.Command_not_allowed name
            when String_util.equals_ci name "gh" ->
            gh_pr_native_tool_hint cmd
          | _ -> None
        in
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_shell_bash_failures
          ~labels:[("site", "generic_blocked")]
          ();
        Log.Keeper.warn "keeper_bash blocked: %s (cmd=%s)" reason_str cmd_for_log;
        let default_hint =
          match reason with
          | Worker_dev_tools.Command_not_allowed name
            when String_util.equals_ci name "gh" ->
            "`gh` is not allowed via keeper_bash. Use keeper_shell with \
             op=\"gh\" (e.g. keeper_shell op=gh cmd=\"pr list --state open\")."
          | Chain_or_redirect | Pipes_not_allowed | Unsafe_redirect ->
            "Use separate tool calls instead of chaining. Call keeper_bash once per command."
          | Direct_dune_invocation ->
            "Use scripts/dune-local.sh instead of bare dune so local builds share the machine-wide lock."
          | Injection | Process_substitution ->
            "Avoid shell metacharacters. Use keeper_shell with a specific op (rg, find, ls) instead."
          | Command_not_allowed _ ->
            "Check the command for blocked patterns. Use keeper_shell for structured ops (rg, ls, find)."
          | Empty_command -> "Provide a non-empty command string."
        in
        let hint =
          match native_tool_hint with
          | Some hint -> hint.hint
          | None -> default_hint
        in
        let default_alternatives =
          match reason with
          | Worker_dev_tools.Command_not_allowed name
            when String_util.equals_ci name "gh" ->
            [ "Use keeper_shell with op=\"gh\" for GitHub CLI operations."
            ; "Example: keeper_shell op=gh cmd=\"pr list --state open\"."
            ]
          | Chain_or_redirect | Pipes_not_allowed | Unsafe_redirect ->
            [ "Break the pipeline into separate keeper_bash calls."
            ; "Save intermediate output to a file, then process it in the next call."
            ]
          | Direct_dune_invocation ->
            [ "Run scripts/dune-local.sh build <target> from the repo root."
            ; "Do not run bare dune build/test/exec in local agent shells."
            ]
          | Injection | Process_substitution ->
            [ "Use keeper_shell with a specific op (rg, find, ls) for structured queries."
            ; "Avoid $(...) and backtick substitution in commands."
            ]
          | Command_not_allowed _ ->
            [ "Use keeper_shell for structured ops (rg, ls, find)."
            ; "Check if the command is available under a different name or op."
            ]
          | Empty_command ->
            [ "Provide a non-empty command string."
            ; "Example: keeper_bash cmd='ls -la lib/'."
            ]
        in
        let alternatives =
          match native_tool_hint with
          | Some hint -> hint.alternatives
          | None -> default_alternatives
        in
        let diag =
          match native_tool_hint with
          | Some hint -> Some (native_tool_diagnosis hint)
          | None -> Keeper_shell_shared.diagnosis_of_block_reason reason
        in
        Yojson.Safe.to_string
          (Exec_core.blocked_result_json
             ~cmd
             ~error:"command_blocked"
             ~reason:reason_str
             ~hint
             ~alternatives
             ~diag
             ~extra:[ "execution_time_ms", `Int 0 ]
             ~env_snapshot:env_snap
             ())
      | Ok () ->
        begin
          let path_validation =
           match
             Keeper_task_worktree_lazy.ensure_command_existing_dirs
               ~config ~meta ~cwd:validation_cwd ~cmd:validation_cmd
           with
           | Error e -> Error e
           | Ok () ->
             Worker_dev_tools.validate_command_paths
               ~keeper_id:meta.name
               ~base_path:root
               ~workdir:validation_cwd
               validation_cmd
          in
          match path_validation with
          | Error e -> error_json ~fields:["blocked_cmd", `String cmd_for_log] e
          | Ok () ->
               if write_enabled
                  && Worker_dev_tools.is_write_operation validation_cmd then
                 Log.Keeper.info "WRITE_AUDIT: keeper=%s cwd=%s cmd=%s playground=%b"
                   meta.name cwd cmd_for_log in_playground;
               (* Tick 7: background mode keeps stdout/stderr separate
                  so [keeper_bash_output] can report them distinctly.
                  Foreground mode merges via [2>&1] for backward
                  compatibility with the single [output] JSON field. *)
               if run_in_background then begin
                 let argv = [ host_bash; "-lc"; cmd ] in
                 match
                   Bg_task.spawn
                     ~base_path:root
                     ~keeper:meta.name
                     ~argv
                     ~cwd
                     ~envp:(Unix.environment ())
                     ~timeout_sec
                     ()
                 with
                 | Ok tid ->
                     Log.Keeper.info
                       "BG_SPAWN: keeper=%s task_id=%s cmd=%s"
                       meta.name (Bg_task.task_id_to_string tid) cmd_for_log;
                     Yojson.Safe.to_string
                       (`Assoc
                         [
                           ("ok", `Bool true);
                           ( "background_task_id",
                             `String (Bg_task.task_id_to_string tid) );
                           ("cmd", `String cmd);
                           ("cwd", `String cwd);
                           ( "hint",
                             `String
                               "Task running in background. Poll with \
                                keeper_bash_output or stop with \
                                keeper_bash_kill." );
                         ])
                 | Error (Bg_task.Spawn_failed e) ->
                     error_json
                       (Printf.sprintf "background spawn failed: %s" e)
                 | Error (Bg_task.Too_many_tasks { keeper = k; limit }) ->
                     error_json
                       (Printf.sprintf
                          "keeper %s exceeded background task limit (%d)"
                          k limit)
                 | Error (Bg_task.Invalid_cwd msg) ->
                     error_json (Printf.sprintf "invalid cwd: %s" msg)
               end
               else begin
                 (* Tick 11: Foreground path with optional auto-background
                    race.  When [MASC_BASH_AUTO_BG] is enabled and an Eio
                    clock is available, route through
                    [Masc_exec.Exec_run.run_with_auto_bg]: the command
                    spawns as a Bg_task, races its exit against
                    [MASC_BLOCKING_BUDGET_MS] (default 15000), and on
                    budget expiry returns a [Promoted] handle the LLM
                    can poll via [keeper_bash_output].  Without the
                    flag, fall back to the legacy blocking call so
                    existing consumers see no shape change. *)
                 let auto_bg_enabled =
                   match Sys.getenv_opt "MASC_BASH_AUTO_BG" with
                   | Some ("1" | "true" | "yes" | "on") -> true
                   | _ -> false
                 in
                 let argv_merged =
                   [ host_bash; "-lc"; cmd ^ " 2>&1" ]
                 in
                 (* Tick 23: AUTO_BG dark-launch observer.  When
                    [MASC_BASH_AUTO_BG_OBSERVE] is set, time the
                    foreground run and emit a structured log line
                    if the elapsed duration would have tripped the
                    blocking budget had [MASC_BASH_AUTO_BG] been
                    on.  No behavior change; cheap measurement
                    feeds future default-flip decisions. *)
                 let auto_bg_observe_enabled =
                   match Sys.getenv_opt "MASC_BASH_AUTO_BG_OBSERVE" with
                   | Some ("1" | "true" | "TRUE" | "yes" | "on" | "log") -> true
                   | _ -> false
                 in
                 match
                   if auto_bg_enabled
                   then Eio_context.get_clock_opt ()
                   else None
                 with
                 | None ->
                   (* P21: exec cache for foreground path *)
                   (match (if command_cacheable () then exec_cache else None) with
                    | Some cache ->
                      (match Masc_exec.Exec_cache.lookup cache cmd with
                       | Some entry ->
                         cached_result_json entry
                       | None ->
                         let t0 = Unix.gettimeofday () in
                         let st, out =
                           Masc_exec.Exec_gate.run_argv_with_status ~actor:`Keeper_shell
                             ~raw_source:(String.concat " " argv_merged)
                             ~summary:"keeper bash command"
                             ~cwd ~timeout_sec argv_merged
                         in
                         let elapsed_ms =
                           elapsed_duration_ms
                             ~start_time:t0 ~end_time:(Unix.gettimeofday ())
                         in
                         if not (Keeper_shell_shared.process_status_is_timeout st) then begin
                           let exit_code = match st with
                             | Unix.WEXITED n -> n
                             | Unix.WSIGNALED n -> 128 + n
                             | Unix.WSTOPPED n -> 256 + n
                           in
                           Masc_exec.Exec_cache.store cache
                             ~cmd ~exit_code ~output:out ~duration_ms:elapsed_ms
                         end;
                         (if auto_bg_observe_enabled then begin
                            let budget_ms =
                              Masc_exec.Exec_run.default_budget_ms ()
                            in
                            let promoted_candidate = elapsed_ms >= budget_ms in
                            Legendary_counters.incr_auto_bg_observed
                              ~promoted_candidate;
                            if promoted_candidate then
                              Log.Keeper.info
                                "auto_bg_would_have_promoted keeper=%s \
                                 cmd_hash=%s duration_ms=%d budget_ms=%d"
                                meta.name
                                (Worker_dev_tools.cmd_hash_for_log cmd)
                                elapsed_ms
                                budget_ms
                          end);
                         Yojson.Safe.to_string
                           (Exec_core.process_result_json
                              ~base_path:root
                              ~keeper_name:meta.name
                              ~cmd
                              ~extra:[
                                "cwd", `String cwd;
                                "execution_time_ms", `Int elapsed_ms;
                              ]
                              ~status:st
                              ~output:out
                              ~env_snapshot:env_snap
                              ()))
                    | None ->
                   let t0 = Unix.gettimeofday () in
                   let st, out =
                     Masc_exec.Exec_gate.run_argv_with_status ~actor:`Keeper_shell
                       ~raw_source:(String.concat " " argv_merged)
                       ~summary:"keeper bash command"
                       ~cwd ~timeout_sec argv_merged
                   in
                   let elapsed_ms =
                     elapsed_duration_ms
                       ~start_time:t0 ~end_time:(Unix.gettimeofday ())
                   in
                   (if auto_bg_observe_enabled then begin
                      let budget_ms =
                        Masc_exec.Exec_run.default_budget_ms ()
                      in
                      let promoted_candidate = elapsed_ms >= budget_ms in
                      Legendary_counters.incr_auto_bg_observed
                        ~promoted_candidate;
                      if promoted_candidate then
                        Log.Keeper.info
                          "auto_bg_would_have_promoted keeper=%s \
                           cmd_hash=%s duration_ms=%d budget_ms=%d"
                          meta.name
                          (Worker_dev_tools.cmd_hash_for_log cmd)
                          elapsed_ms
                          budget_ms
                    end);
                   Yojson.Safe.to_string
                     (Exec_core.process_result_json
                        ~base_path:root
                        ~keeper_name:meta.name
                        ~cmd
                        ~extra:[
                          "cwd", `String cwd;
                          "execution_time_ms", `Int elapsed_ms;
                        ]
                        ~status:st
                        ~output:out
                        ~env_snapshot:env_snap
                        ()))
                 | Some clock ->
                   let run_uncached () =
                     let budget_ms = Masc_exec.Exec_run.default_budget_ms () in
                     let t0_bg = Unix.gettimeofday () in
                     let outcome =
                       Masc_exec.Exec_run.run_with_auto_bg
                         ~clock
                         ~base_path:root
                         ~budget_ms
                         ~keeper:meta.name
                         ~argv:argv_merged
                         ~cwd
                         ~envp:(Unix.environment ())
                         ~timeout_sec
                         ()
                     in
                     (match outcome with
                      | Masc_exec.Exec_run.Completed r ->
                        let elapsed_ms =
                          elapsed_duration_ms
                            ~start_time:t0_bg ~end_time:(Unix.gettimeofday ())
                        in
                        (* P21: store in exec cache if not a timeout.  Only
                           cache commands classified as read-only; write,
                           network, and destructive commands must execute
                           every time. *)
                        if
                          command_cacheable ()
                          && not
                               (Keeper_shell_shared.process_status_is_timeout
                                  r.status)
                        then
                          (match exec_cache with
                           | Some cache ->
                             let exit_code = match r.status with
                               | Unix.WEXITED n -> n
                               | Unix.WSIGNALED n -> 128 + n
                               | Unix.WSTOPPED n -> 256 + n
                             in
                             Masc_exec.Exec_cache.store cache
                               ~cmd ~exit_code ~output:r.stdout ~duration_ms:elapsed_ms
                           | None -> ());
                        Yojson.Safe.to_string
                          (Exec_core.process_result_json
                             ~base_path:root
                             ~keeper_name:meta.name
                             ~cmd
                             ~extra:[
                               "cwd", `String cwd;
                               "execution_time_ms", `Int elapsed_ms;
                             ]
                             ~status:r.status
                             ~output:r.stdout
                             ~env_snapshot:env_snap
                             ())
                      | Masc_exec.Exec_run.Promoted p ->
                        let elapsed_ms =
                          elapsed_duration_ms
                            ~start_time:t0_bg ~end_time:(Unix.gettimeofday ())
                        in
                        Log.Keeper.info
                          "BG_PROMOTE: keeper=%s task_id=%s budget_ms=%d cmd=%s"
                          meta.name
                          (Bg_task.task_id_to_string p.task_id)
                          budget_ms
                          cmd_for_log;
                        Yojson.Safe.to_string
                          (`Assoc
                            [
                              ("ok", `Bool false);
                              ("promoted", `Bool true);
                              ( "background_task_id",
                                `String
                                  (Bg_task.task_id_to_string p.task_id) );
                              ("cmd", `String cmd);
                              ("cwd", `String cwd);
                              ("partial_output", `String p.partial_stdout);
                              ( "bytes_dropped",
                                `Int p.bytes_dropped_stdout );
                              ("budget_ms", `Int budget_ms);
                              ("execution_time_ms", `Int elapsed_ms);
                              ( "hint",
                                `String
                                  (Printf.sprintf
                                     "Command exceeded \
                                      MASC_BLOCKING_BUDGET_MS=%d. Still \
                                      running in background; poll with \
                                      keeper_bash_output or stop with \
                                      keeper_bash_kill."
                                     budget_ms) );
                            ])
                      | Masc_exec.Exec_run.Spawn_error
                          (Bg_task.Spawn_failed e) ->
                        error_json
                          (Printf.sprintf
                             "auto-bg spawn failed: %s" e)
                      | Masc_exec.Exec_run.Spawn_error
                          (Bg_task.Too_many_tasks { keeper = k; limit }) ->
                        error_json
                          (Printf.sprintf
                             "keeper %s exceeded background task limit (%d)"
                             k limit)
                      | Masc_exec.Exec_run.Spawn_error
                          (Bg_task.Invalid_cwd msg) ->
                        error_json (Printf.sprintf "invalid cwd: %s" msg))
                   in
                   (match (if command_cacheable () then exec_cache else None) with
                    | Some cache ->
                      (match Masc_exec.Exec_cache.lookup cache cmd with
                       | Some entry -> cached_result_json entry
                       | None -> run_uncached ())
                    | None -> run_uncached ())
               end
        end
  end)
;;
