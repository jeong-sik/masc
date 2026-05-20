(** Repo-wide shell scan detection for the keeper bash safety policy.

    Extracted from [keeper_shell_bash.ml] (lines 104-263) as part of the
    godfile decomp campaign. Pure-function helpers, no Eio/state — given a
    parsed shell command, decide whether it walks the entire repo (which
    the keeper bash policy then blocks or rewrites).

    Boundaries:
    - Input: [shell_word list] from [Keeper_shell_bash_words.shell_words_with_boundaries].
    - Output: [bool] predicates; no side effects.
    - Callers (after extraction) live in [keeper_shell_bash.ml] only. *)

open Keeper_shell_bash_words

let has_malformed_dev_null_redirect_token scan_text =
  scan_text
  |> String.split_on_char ' '
  |> List.exists (fun token ->
    match String.trim (String.lowercase_ascii token) with
    | "0/dev/null" | "1/dev/null" | "2/dev/null" -> true
    | _ -> false)
;;

let strip_trailing_slashes text =
  let rec loop i =
    if i > 0 && Char.equal text.[i - 1] '/' then loop (i - 1) else i
  in
  let len = loop (String.length text) in
  if len = String.length text then text else String.sub text 0 len
;;

let is_repo_wide_root text =
  let text = String.trim text |> strip_trailing_slashes in
  String.equal text "."
  || String.equal text "./"
  || String.equal text "repos"
  || String.equal text "./repos"
;;

let is_scoped_read_root text =
  let text = String.trim text |> strip_trailing_slashes in
  String.starts_with ~prefix:"lib" text
  || String.starts_with ~prefix:"test" text
  || String.starts_with ~prefix:"bin" text
  || String.starts_with ~prefix:"docs" text
  || String.starts_with ~prefix:"src" text
  || String.starts_with ~prefix:"repos/" text
  || String.contains text '/'
;;

let option_consumes_next_arg text =
  match text with
  | "-e" | "-f" | "-g" | "-m" | "-t" | "--after-context" | "--before-context"
  | "--context" | "--exclude" | "--exclude-dir" | "--glob" | "--include"
  | "--max-count" | "--regexp" | "--type" | "--type-add" -> true
  | _ -> false
;;

let rec non_option_args = function
  | [] -> []
  | arg :: _ :: rest when option_consumes_next_arg arg.text -> non_option_args rest
  | arg :: rest when String.starts_with ~prefix:"--" arg.text ->
    non_option_args rest
  | arg :: rest
    when String.length arg.text > 1 && Char.equal arg.text.[0] '-' ->
    non_option_args rest
  | arg :: rest -> arg.text :: non_option_args rest
;;

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
;;

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
;;

let find_is_repo_wide args =
  match non_option_args args with
  | root :: _ -> is_repo_wide_root root
  | [] -> true
;;

let rg_has_files_mode args =
  List.exists (fun arg -> String.equal arg.text "--files") args
;;

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
;;

let git_log_all_is_repo_wide args =
  match args with
  | subcmd :: rest when String.equal subcmd.text "log" ->
    let has_all = List.exists (fun arg -> String.equal arg.text "--all") rest in
    if not has_all then false
    else
      let has_output_limit arg =
        let t = arg.text in
        (* -N (bare number flag like -30).  See the matching
           [int_of_string_opt] below for the rationale: option-typed
           parse replaces exception-as-control-flow. *)
        (t <> "" && t.[0] = '-' && t <> "-" && t <> "--"
         && let digits = String.sub t 1 (String.length t - 1) in
            Option.is_some (int_of_string_opt digits))
        (* -n N handled below: "-n" followed by a number *)
        || String.equal t "-n"
        || String.starts_with ~prefix:"--max-count" t
      in
      let rec check_limit = function
        | [] -> false
        | arg :: rest ->
          if String.equal arg.text "-n" then
            match rest with
            | n :: _ ->
              (* [int_of_string_opt] removes the exception-as-control-flow
                 pattern that previously masked the parse-failure branch.
                 The old [try ... with _ -> _] form would have silently
                 swallowed any exception raised by future refactors of the
                 [int_of_string] call (and violated RFC-0106 if it ever
                 became cancellable).  Option-typed parse is total. *)
              (match int_of_string_opt n.text with
               | Some _ -> true
               | None -> check_limit rest)
            | [] -> false
          else if has_output_limit arg then true
          else check_limit rest
      in
      not (check_limit rest)
  | _ -> false
;;

let simple_command_is_repo_wide_scan words =
  match strip_command_wrappers words with
  | bin :: args ->
    let args =
      let rec take = function
        | [] -> []
        | w :: _ when w.starts_command -> []
        | w :: rest -> w :: take rest
      in
      take args
    in
    (match command_name bin.text with
     | "grep" | "egrep" | "fgrep" -> grep_is_repo_wide args
     | "find" -> find_is_repo_wide args
     | "rg" -> rg_is_repo_wide args
     | "git" -> git_log_all_is_repo_wide args
     | _ -> false)
  | [] -> false
;;

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
;;
