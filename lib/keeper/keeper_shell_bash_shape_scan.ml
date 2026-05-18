open Keeper_shell_bash_redirects
open Keeper_shell_bash_shape_ir
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
  | Masc_exec.Parsed.Parsed ir -> parsed_keeper_bash_shape_block ir
  | Masc_exec.Parsed.Parse_error _
  | Masc_exec.Parsed.Parse_aborted _
  | Masc_exec.Parsed.Too_complex _ ->
    raw_keeper_bash_shape_block cmd
