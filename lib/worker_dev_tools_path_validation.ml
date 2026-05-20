module Paths = Worker_dev_tools_paths
module Command_syntax = Worker_dev_tools_command_syntax
module Path_words = Worker_dev_tools_path_words

open Paths
open Command_syntax

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
  let resolved = resolve_path ?base_dir:workdir path in
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
  let resolved = resolve_path ?base_dir:workdir token in
  not (Sys.file_exists resolved)
;;

type path_token = Path_words.t

let token_has_unsafe_rewrite_syntax = Path_words.has_unsafe_rewrite_syntax
;;

let command_allows_safe_globbed_path = function
  | "ls" -> true
  | _ -> false
;;

let token_glob_is_limited_to_basename token =
  let value = token.Path_words.value in
  let start =
    match String.rindex_opt value '/' with
    | None -> 0
    | Some idx -> idx + 1
  in
  let rec loop i =
    if i >= String.length value
    then true
    else (
      match value.[i] with
      | '*' | '?' | '[' | ']' -> i >= start && loop (i + 1)
      | _ -> loop (i + 1))
  in
  loop 0
;;

let path_token_error_hint token =
  let suggestions =
    [ ( token.Path_words.globbed
      , "Glob expansion ('*' / '?' / '[]') — use masc_code_search with file_pattern \
         (e.g. file_pattern='*.ml') or rg with --glob instead of letting the shell \
         expand." )
    ; ( token.Path_words.braced
      , "Brace expansion ('{a,b}') — run one command per target, or use masc_code_search \
         / rg which accept multiple patterns natively." )
    ; ( token.Path_words.escaped
      , "Backslash escaping — the keeper shell does not interpret escapes. Use \
         masc_code_search with is_regex=true for pattern work that would need \\. / \\w \
         / etc." )
    ; ( token.Path_words.quoted
      , "Quoting — path args must be unquoted plain strings. Move any pattern into \
         masc_code_search.query with is_regex appropriately set." )
    ]
  in
  suggestions
  |> List.filter_map (fun (cond, msg) -> if cond then Some msg else None)
  |> String.concat " "
;;

let path_syntax_blocked_message token =
  let raw_hint = path_token_error_hint token in
  let hint = if raw_hint = "" then None else Some raw_hint in
  Keeper_path_check_error.(
    to_message (Path_syntax_blocked { token = token.Path_words.value; hint }))
;;

let path_word_stages_of_command = Path_words.stages
;;

let token_value_is_redirect_to_dev_null token =
  let value = token.Path_words.value in
  String.equal value ">/dev/null"
  || String.equal value "2>/dev/null"
  || String.equal value "1>/dev/null"
  || String.equal value ">>/dev/null"
  || String.equal value "2>>/dev/null"
  || String.equal value "1>>/dev/null"
  || String.equal value "0</dev/null"
;;

let token_value_is_redirect_op token =
  match token.Path_words.value with
  | ">" | ">>" | "<" | "2>" | "2>>" | "1>" | "1>>" | "0<" -> true
  | _ -> false
;;

let command_pattern_arg_flags cmd =
  match cmd with
  | "find" ->
    [ "-name", false
    ; "-iname", false
    ; "-path", false
    ; "-ipath", false
    ; "-wholename", false
    ; "-iwholename", false
    ; "-regex", false
    ; "-iregex", false
    ]
  | "rg" ->
    [ "-e", true
    ; "--regexp", true
    ; "-f", true
    ; "--file", true
    ; "-g", false
    ; "--glob", false
    ; "--iglob", false
    ; "--type", false
    ; "-t", false
    ; "--type-not", false
    ; "-T", false
    ]
  | "grep" ->
    [ "-e", true
    ; "--regexp", true
    ; "-f", true
    ; "--file", true
    ; "--include", false
    ; "--exclude", false
    ]
  | "sed" -> [ "-e", true; "--expression", true ]
  | "gh" ->
    [ "-R", false
    ; "--repo", false
    ; "--json", false
    ; "--jq", false
    ; "--template", false
    ; "--search", false
    ; "--state", false
    ; "--author", false
    ; "--assignee", false
    ; "--label", false
    ; "--base", false
    ; "--head", false
    ]
  | "git" ->
    [ "--branches", false
    ; "--remotes", false
    ; "--glob", false
    ; "--exclude", false
    ; "--format", false
    ; "--pretty", false
    ; "--author", false
    ; "--grep", false
    ]
  | _ -> []
;;

let token_is_inline_pattern_flag cmd token =
  let value = token.Path_words.value in
  command_pattern_arg_flags cmd
  |> List.find_map (fun (flag, consumes_primary_pattern) ->
    if String.starts_with ~prefix:(flag ^ "=") value
    then Some consumes_primary_pattern
    else None)
;;

let command_flag_pattern_arity cmd value =
  command_pattern_arg_flags cmd
  |> List.find_map (fun (flag, consumes_primary_pattern) ->
    if String.equal flag value then Some consumes_primary_pattern else None)
;;

let rg_token_is_option_value token =
  let value = token.Path_words.value in
  String.starts_with ~prefix:"-" value && String.length value > 1
;;

let command_treats_plain_args_as_content = function
  | "echo" | "printf" -> true
  | _ -> false
;;

let path_argument_tokens tokens =
  match tokens with
  | [] -> []
  | command :: args ->
    let command_name = command.Path_words.value in
    let rg_files_mode =
      String.equal command_name "rg"
      && List.exists (fun token -> String.equal token.Path_words.value "--files") args
    in
    let rec loop ~skip_next_pattern ~redirect_target ~seen_primary_pattern acc =
      function
      | [] -> List.rev acc
      | token :: rest ->
        if redirect_target
        then
          let acc =
            if String.equal token.Path_words.value "/dev/null" then acc else token :: acc
          in
          loop ~skip_next_pattern:None ~redirect_target:false ~seen_primary_pattern acc rest
        else if token_value_is_redirect_to_dev_null token
        then loop ~skip_next_pattern:None ~redirect_target:false ~seen_primary_pattern acc rest
        else (
          match skip_next_pattern with
          | Some consumes_primary_pattern ->
            loop
              ~skip_next_pattern:None
              ~redirect_target:false
              ~seen_primary_pattern:
                (seen_primary_pattern || consumes_primary_pattern)
              acc
              rest
          | None ->
            if token_value_is_redirect_op token
            then loop ~skip_next_pattern:None ~redirect_target:true ~seen_primary_pattern acc rest
            else
              (match command_flag_pattern_arity command_name token.Path_words.value with
               | Some consumes_primary_pattern ->
                 loop
                   ~skip_next_pattern:(Some consumes_primary_pattern)
                   ~redirect_target:false
                   ~seen_primary_pattern
                   acc
                   rest
               | None ->
                 (match token_is_inline_pattern_flag command_name token with
                  | Some consumes_primary_pattern ->
                    loop
                      ~skip_next_pattern:None
                      ~redirect_target:false
                      ~seen_primary_pattern:
                        (seen_primary_pattern || consumes_primary_pattern)
                      acc
                      rest
                  | None when command_treats_plain_args_as_content command_name ->
                    loop
                      ~skip_next_pattern:None
                      ~redirect_target:false
                      ~seen_primary_pattern
                      acc
                      rest
                  | None when command_name = "sed"
                              && (not seen_primary_pattern)
                              && not (rg_token_is_option_value token) ->
                    loop
                      ~skip_next_pattern:None
                      ~redirect_target:false
                      ~seen_primary_pattern:true
                      acc
                      rest
                  | None when command_name = "rg"
                              && (not rg_files_mode)
                              && (not seen_primary_pattern)
                              && not (rg_token_is_option_value token) ->
                    loop
                      ~skip_next_pattern:None
                      ~redirect_target:false
                      ~seen_primary_pattern:true
                      acc
                      rest
                  | None when command_name = "grep"
                              && (not seen_primary_pattern)
                              && not (rg_token_is_option_value token) ->
                    loop
                      ~skip_next_pattern:None
                      ~redirect_target:false
                      ~seen_primary_pattern:true
                      acc
                      rest
                  | None ->
                    loop
                      ~skip_next_pattern:None
                      ~redirect_target:false
                      ~seen_primary_pattern
                      (token :: acc)
                      rest)))
    in
    loop
      ~skip_next_pattern:None
      ~redirect_target:false
      ~seen_primary_pattern:false
      []
      args
;;

let existing_dir_path_values cmd =
  let rec loop ~command_name expect_existing_dir acc = function
    | [] -> List.rev acc
    | token :: rest ->
      if token.Path_words.value = ""
      then loop ~command_name expect_existing_dir acc rest
      else if expect_existing_dir
      then loop ~command_name false (token.Path_words.value :: acc) rest
      else (
        match path_value_of_flagged_token token.Path_words.value with
        | Some value when inline_path_flag_requires_existing_dir token.Path_words.value ->
          loop ~command_name false (value :: acc) rest
        | Some _ -> loop ~command_name false acc rest
        | None when is_path_flag token.Path_words.value ->
          loop
            ~command_name
            (path_flag_requires_existing_dir token.Path_words.value)
            acc
            rest
        | None
          when command_materializes_path_arg command_name
               && looks_like_path_token token.Path_words.value
               && not (token_has_unsafe_rewrite_syntax token)
               && not token.Path_words.globbed ->
          loop ~command_name false (token.Path_words.value :: acc) rest
        | None -> loop ~command_name false acc rest)
  in
  let values_for_stage tokens =
    let command_name =
      match tokens with
      | command :: _ -> Filename.basename command.Path_words.value
      | [] -> ""
    in
    tokens |> path_argument_tokens |> loop ~command_name false []
  in
  match path_word_stages_of_command cmd with
  | Ok stages -> List.concat_map values_for_stage stages
  | Error _ -> []
;;

let validate_command_paths ?keeper_id ?base_path ?workdir cmd =
  match workdir with
  | None -> Ok ()
  | Some _ ->
      let validate_path_value ~requires_existing_dir token =
        if String.equal (strip_wrapping_quotes token.Path_words.value) "/dev/null"
        then Ok ()
        else if not (validate_path ?keeper_id ?base_path ?workdir token.Path_words.value)
        then
          Error
            (Keeper_path_check_error.(
               to_message
                 (Path_outside_whitelist
                    { path = token.Path_words.value; for_keeper_command = true })))
        else if requires_existing_dir && not (path_is_existing_dir ?workdir token.Path_words.value)
        then
          Error
            (Keeper_path_check_error.(
               to_message (Cwd_not_directory { path = token.Path_words.value; hint = None })))
        else Ok ()
      in
      let rec validate_path_tokens ~command_name expect_existing_dir = function
        | [] -> Ok ()
        | token :: rest ->
          if token.Path_words.value = ""
          then validate_path_tokens ~command_name expect_existing_dir rest
          else if expect_existing_dir
          then
            (match validate_path_value ~requires_existing_dir:true token with
             | Ok () -> validate_path_tokens ~command_name false rest
             | Error _ as err -> err)
          else (
            match path_value_of_flagged_token token.Path_words.value with
            | Some value ->
              let token = { token with Path_words.value = value } in
              (match
                 validate_path_value
                   ~requires_existing_dir:(inline_path_flag_requires_existing_dir token.Path_words.value)
                   token
               with
               | Ok () -> validate_path_tokens ~command_name false rest
               | Error _ as err -> err)
            | None when is_path_flag token.Path_words.value ->
              validate_path_tokens
                ~command_name
                (path_flag_requires_existing_dir token.Path_words.value)
                rest
            | None
              when String.equal command_name "git"
                   && git_revisionish_token ?workdir token.Path_words.value ->
              validate_path_tokens ~command_name false rest
            | None when looks_like_path_token token.Path_words.value ->
              if token_has_unsafe_rewrite_syntax token
              then Error (path_syntax_blocked_message token)
              else if token.Path_words.globbed
              then
                if command_allows_safe_globbed_path command_name
                   && token_glob_is_limited_to_basename token
                then (
                  match validate_path_value ~requires_existing_dir:false token with
                  | Ok () -> validate_path_tokens ~command_name false rest
                  | Error _ as err -> err)
                else Error (path_syntax_blocked_message token)
              else (
                match validate_path_value ~requires_existing_dir:false token with
                | Ok () -> validate_path_tokens ~command_name false rest
                | Error _ as err -> err)
            | None -> validate_path_tokens ~command_name false rest)
      in
      let validate_path_argument_tokens tokens path_tokens =
        let command_name =
          match tokens with
          | command :: _ -> Filename.basename command.Path_words.value
          | [] -> ""
        in
        validate_path_tokens ~command_name false path_tokens
      in
      let validate_token_stream tokens =
        validate_path_argument_tokens tokens (path_argument_tokens tokens)
      in

      let rec validate_redirects = function
        | [] -> Ok ()
        | Masc_exec.Redirect_scope.File { target; _ } :: rest ->
          let token = Masc_exec.Path_scope.raw target |> Path_words.of_literal in
          (match validate_path_value ~requires_existing_dir:false token with
           | Ok () -> validate_redirects rest
           | Error _ as err -> err)
        | Masc_exec.Redirect_scope.Fd_to_fd _ :: rest -> validate_redirects rest
      in
      let tokens_of_simple (simple : Masc_exec.Shell_ir.simple) =
        let command = Masc_exec.Bin.to_string simple.bin |> Path_words.of_literal in
        let rec args acc = function
          | [] -> Some (command :: List.rev acc)
          | Masc_exec.Shell_ir.Lit value :: rest ->
            args (Path_words.of_literal value :: acc) rest
          | Masc_exec.Shell_ir.Concat _ :: _ | Masc_exec.Shell_ir.Var _ :: _ -> None
        in
        args [] simple.args
      in
      let validate_parsed_shell_ir = function
        | Masc_exec.Shell_ir.Simple simple ->
          (match tokens_of_simple simple with
           | Some tokens ->
             Some
               (match validate_token_stream tokens with
                | Ok () -> validate_redirects simple.redirects
                | Error _ as err -> err)
           | None -> None)
        | Masc_exec.Shell_ir.Pipeline stages ->
          let rec loop = function
            | [] -> Some (Ok ())
            | Masc_exec.Shell_ir.Simple simple :: rest ->
              (match tokens_of_simple simple with
               | None -> None
               | Some tokens ->
                 (match validate_token_stream tokens with
                  | Ok () ->
                    (match validate_redirects simple.redirects with
                     | Ok () -> loop rest
                     | Error _ as err -> Some err)
                  | Error _ as err -> Some err))
            | Masc_exec.Shell_ir.Pipeline _ :: _ -> None
          in
          loop stages
      in
      let validate_path_word_stages stages =
        let rec loop = function
          | [] -> Ok ()
          | tokens :: rest ->
            (match validate_token_stream tokens with
             | Ok () -> loop rest
             | Error _ as err -> err)
        in
        loop stages
      in
      match path_word_stages_of_command cmd with
      | Error _ ->
        Error
          (Keeper_path_check_error.(
             to_message
               (Path_syntax_blocked
                  { token = cmd
                  ; hint =
                      Some
                        "Unsupported shell quoting or escaping in path validation. \
                         Use plain path arguments or structured tools."
                  })))
      | Ok command_word_stages ->
        let command_needs_syntax_sensitive_gate =
          List.exists
            (fun words ->
               words
               |> path_argument_tokens
               |> List.exists (fun token ->
                 token_has_unsafe_rewrite_syntax token || token.Path_words.globbed))
            command_word_stages
        in
        if command_needs_syntax_sensitive_gate
        then validate_path_word_stages command_word_stages
        else (
          match Masc_exec_bash_parser.Bash.parse_string cmd with
          | Masc_exec.Parsed.Parsed shell_ir ->
            (match validate_parsed_shell_ir shell_ir with
             | Some result -> result
             | None -> validate_path_word_stages command_word_stages)
          | Masc_exec.Parsed.Parse_error _
          | Masc_exec.Parsed.Parse_aborted _
          | Masc_exec.Parsed.Too_complex _ ->
            validate_path_word_stages command_word_stages)
;;
