(** Token / path classifier helpers for the dev-tools worker.

    Pure functions on argv tokens — URL/path/redirect predicates plus
    a few [Sys.file_exists]-style existence checks. Verbatim extract
    from [Worker_dev_tools]. All callers are internal to the parent
    (verified via grep across lib/ + test/).

    Dependencies:
    - [Worker_dev_tools_command_syntax.strip_wrapping_quotes] —
      brought in via [open] so the helper bodies remain byte-for-byte
      identical to the pre-extraction code.
    - [Worker_dev_tools_paths.resolve_path] — fully-qualified at the
      two use sites (path_is_existing_dir, git_revisionish_token). *)

open Worker_dev_tools_command_syntax

let looks_like_url token =
  let token = strip_wrapping_quotes token in
  match String.index_opt token ':' with
  | Some idx when idx + 2 < String.length token ->
    token.[idx + 1] = '/' && token.[idx + 2] = '/'
  | _ -> false
;;

let is_path_flag token =
  match strip_wrapping_quotes token with
  | "-C" | "--git-dir" | "--work-tree" | "--exec-path" -> true
  | _ -> false
;;

let path_flag_requires_existing_dir token =
  match strip_wrapping_quotes token with
  | "-C" | "--work-tree" -> true
  | _ -> false
;;

let path_value_of_flagged_token token =
  let token = strip_wrapping_quotes token in
  let prefixes = [ "--git-dir="; "--work-tree="; "--exec-path=" ] in
  List.find_map
    (fun prefix ->
       if String.starts_with ~prefix token
       then
         Some
           (String.sub
              token
              (String.length prefix)
              (String.length token - String.length prefix))
       else None)
    prefixes
;;

let inline_path_flag_requires_existing_dir token =
  let token = strip_wrapping_quotes token in
  String.starts_with ~prefix:"--work-tree=" token
;;

let command_materializes_path_arg = function
  | "cat" | "find" | "grep" | "head" | "ls" | "nl" | "rg" | "sed" | "stat"
  | "tail" | "wc" -> true
  | _ -> false
;;

let path_is_existing_dir ?workdir path =
  let resolved = Worker_dev_tools_paths.resolve_path ?base_dir:workdir path in
  try Sys.file_exists resolved && Sys.is_directory resolved with
  | Sys_error _ -> false
;;

let looks_like_path_token token =
  let token = strip_wrapping_quotes token in
  token <> ""
  && (not (looks_like_url token))
  && (token = "."
      || token = ".."
      || String.starts_with ~prefix:"/" token
      || String.starts_with ~prefix:"./" token
      || String.starts_with ~prefix:"../" token
      || String.starts_with ~prefix:"~/" token
      || String.contains token '/')
;;

let token_value_is_explicit_path token =
  let token = strip_wrapping_quotes token in
  token = "."
  || token = ".."
  || String.starts_with ~prefix:"/" token
  || String.starts_with ~prefix:"./" token
  || String.starts_with ~prefix:"../" token
  || String.starts_with ~prefix:"~/" token
;;

let token_has_parent_dir_segment token =
  token
  |> strip_wrapping_quotes
  |> String.split_on_char '/'
  |> List.exists (String.equal "..")
;;

let git_revisionish_token ?workdir token =
  let token = strip_wrapping_quotes token |> String.trim in
  token <> ""
  && String.contains token '/'
  && (not (token_value_is_explicit_path token))
  && not (token_has_parent_dir_segment token)
  &&
  let resolved = Worker_dev_tools_paths.resolve_path ?base_dir:workdir token in
  not (Sys.file_exists resolved)
;;

let token_value_is_redirect_to_dev_null value =
  String.equal value ">/dev/null"
  || String.equal value "2>/dev/null"
  || String.equal value "1>/dev/null"
  || String.equal value ">>/dev/null"
  || String.equal value "2>>/dev/null"
  || String.equal value "1>>/dev/null"
;;

let token_value_is_redirect_op value =
  match value with
  | ">" | ">>" | "<" | "2>" | "2>>" | "1>" | "1>>" -> true
  | _ -> false
;;
