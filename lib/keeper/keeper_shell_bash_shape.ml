open Keeper_shell_bash_redirects
open Keeper_shell_bash_shape_messages
open Keeper_shell_bash_words

let string_contains_char s ch = String.exists (Char.equal ch) s
let string_contains_substring s needle = String_util.contains_substring s needle

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
    | Masc_exec.Parsed.Parsed ir ->
      Keeper_shell_bash_shape_ir.parsed_keeper_bash_shape_block ir
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
      | Some cwd_override, Some rewrite ->
        Some { rewrite with cwd_override = Some cwd_override }
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
    (match Worker_dev_tools.validate_command_coding cmd with
     | Ok () -> true
     | Error _ -> false)
  | Gh_pr_checks | Chaining | Substitution | Repo_wide_scan | Pipe_or_redirect ->
    false
