(** Command-shape classifier for {!Keeper_shell_bash}. *)

open Keeper_shell_bash_redirects
open Keeper_shell_bash_shape_ir
open Keeper_shell_bash_shape_messages
open Keeper_shell_bash_words

module Repo_wide_scan = Keeper_shell_bash_repo_wide_scan

let string_contains_char s ch = String.exists (Char.equal ch) s
let string_contains_substring s needle = String_util.contains_substring s needle

let shell_ir_shape_scan_text cmd =
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

let shell_ir_parse_failure_shape_block cmd =
  let cmd, _ = strip_stderr_dev_null_redirects cmd in
  let scan_text = shell_ir_shape_scan_text cmd in
  let lower = String.lowercase_ascii scan_text in
  if string_contains_substring lower "gh pr checks"
  then Some Gh_pr_checks
  else if Repo_wide_scan.command_has_repo_wide_scan cmd
  then Some Repo_wide_scan
  else if Repo_wide_scan.has_malformed_dev_null_redirect_token scan_text
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
  let scan_text = shell_ir_shape_scan_text cmd in
  if Repo_wide_scan.command_has_repo_wide_scan cmd
  then Some Repo_wide_scan
  else if Repo_wide_scan.has_malformed_dev_null_redirect_token scan_text
  then Some Pipe_or_redirect
  else
    match Masc_exec_bash_parser.Bash.parse_string cmd with
    | Masc_exec.Parsed.Parsed ir -> parsed_keeper_bash_shape_block ir
    | Masc_exec.Parsed.Parse_error _
    | Masc_exec.Parsed.Parse_aborted _
    | Masc_exec.Parsed.Too_complex _ ->
      shell_ir_parse_failure_shape_block cmd
