(** Path-token validation for worker dev tools. *)

module Syntax = Worker_dev_tools_command_syntax
module Paths = Worker_dev_tools_paths

open Syntax

let resolve_path = Paths.resolve_path
let validate_path = Paths.validate_path

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

type path_token =
  { value : string
  ; quoted : bool
  ; escaped : bool
  ; globbed : bool
  ; braced : bool
  }

let token_has_unsafe_rewrite_syntax token =
  token.quoted || token.escaped || token.braced
;;

let command_allows_safe_globbed_path = function
  | "ls" -> true
  | _ -> false
;;

let token_glob_is_limited_to_basename token =
  let value = token.value in
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
    [ ( token.globbed
      , "Glob expansion ('*' / '?' / '[]') — use masc_code_search with file_pattern \
         (e.g. file_pattern='*.ml') or rg with --glob instead of letting the shell \
         expand." )
    ; ( token.braced
      , "Brace expansion ('{a,b}') — run one command per target, or use masc_code_search \
         / rg which accept multiple patterns natively." )
    ; ( token.escaped
      , "Backslash escaping — the keeper shell does not interpret escapes. Use \
         masc_code_search with is_regex=true for pattern work that would need \\. / \\w \
         / etc." )
    ; ( token.quoted
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
    to_message (Path_syntax_blocked { token = token.value; hint }))
;;

let tokenize_path_args cmd =
  let len = String.length cmd in
  let tokens = ref [] in
  let buf = Buffer.create 32 in
  let quoted = ref false in
  let escaped = ref false in
  let globbed = ref false in
  let braced = ref false in
  let push () =
    if Buffer.length buf > 0
       || !quoted
       || !escaped
       || !globbed
       || !braced
    then (
      tokens :=
        { value = Buffer.contents buf
        ; quoted = !quoted
        ; escaped = !escaped
        ; globbed = !globbed
        ; braced = !braced
        }
        :: !tokens;
      Buffer.clear buf;
      quoted := false;
      escaped := false;
      globbed := false;
      braced := false)
  in
  let rec scan i quote =
    if i >= len
    then push ()
    else
      match quote, cmd.[i] with
      | None, (' ' | '\t' | '\n' | '\r') ->
        push ();
        scan (i + 1) None
      | None, ('\'' | '"') ->
        quoted := true;
        scan (i + 1) (Some cmd.[i])
      | Some q, ch when ch = q ->
        scan (i + 1) None
      | _, '\\' ->
        escaped := true;
        if i + 1 < len
        then (
          Buffer.add_char buf cmd.[i + 1];
          scan (i + 2) quote)
        else scan (i + 1) quote
      | _, ('*' | '?' | '[' | ']') ->
        globbed := true;
        Buffer.add_char buf cmd.[i];
        scan (i + 1) quote
      | _, ('{' | '}') ->
        braced := true;
        Buffer.add_char buf cmd.[i];
        scan (i + 1) quote
      | _, ch ->
        Buffer.add_char buf ch;
        scan (i + 1) quote
  in
  scan 0 None;
  List.rev !tokens
;;

let token_value_is_redirect_to_dev_null token =
  let value = token.value in
  String.equal value ">/dev/null"
  || String.equal value "2>/dev/null"
  || String.equal value "1>/dev/null"
  || String.equal value ">>/dev/null"
  || String.equal value "2>>/dev/null"
  || String.equal value "1>>/dev/null"
;;

let token_value_is_redirect_op token =
  match token.value with
  | ">" | ">>" | "<" | "2>" | "2>>" | "1>" | "1>>" -> true
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
  let value = token.value in
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
  let value = token.value in
  String.starts_with ~prefix:"-" value && String.length value > 1
;;

let command_treats_plain_args_as_content = function
  | "echo" | "printf" -> true
  | _ -> false
;;

let path_validation_tokens tokens =
  match tokens with
  | [] -> []
  | command :: args ->
    let command_name = command.value in
    let rg_files_mode =
      String.equal command_name "rg"
      && List.exists (fun token -> String.equal token.value "--files") args
    in
    let rec loop ~skip_next_pattern ~redirect_target ~seen_primary_pattern acc =
      function
      | [] -> List.rev acc
      | token :: rest ->
        if redirect_target
        then
          let acc =
            if String.equal token.value "/dev/null" then acc else token :: acc
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
              (match command_flag_pattern_arity command_name token.value with
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
  let command_name =
    match tokenize_path_args cmd with
    | command :: _ -> Filename.basename command.value
    | [] -> ""
  in
  let rec loop expect_existing_dir acc = function
    | [] -> List.rev acc
    | token :: rest ->
      if token.value = ""
      then loop expect_existing_dir acc rest
      else if expect_existing_dir
      then loop false (token.value :: acc) rest
      else (
        match path_value_of_flagged_token token.value with
        | Some value when inline_path_flag_requires_existing_dir token.value ->
          loop false (value :: acc) rest
        | Some _ -> loop false acc rest
        | None when is_path_flag token.value ->
          loop (path_flag_requires_existing_dir token.value) acc rest
        | None
          when command_materializes_path_arg command_name
               && looks_like_path_token token.value
               && not (token_has_unsafe_rewrite_syntax token)
               && not token.globbed ->
          loop false (token.value :: acc) rest
        | None -> loop false acc rest)
  in
  cmd |> tokenize_path_args |> path_validation_tokens |> loop false []
;;

let validate_command_paths ?keeper_id ?base_path ?workdir cmd =
  match workdir with
  | None -> Ok ()
  | Some _ ->
      let validate_path_value ~requires_existing_dir token =
        if not (validate_path ?keeper_id ?base_path ?workdir token.value)
        then
          Error
            (Keeper_path_check_error.(
               to_message
                 (Path_outside_whitelist
                    { path = token.value; for_keeper_command = true })))
        else if requires_existing_dir && not (path_is_existing_dir ?workdir token.value)
        then
          Error
            (Keeper_path_check_error.(
               to_message (Cwd_not_directory { path = token.value; hint = None })))
        else Ok ()
      in
      let rec validate_path_tokens ~command_name expect_existing_dir = function
        | [] -> Ok ()
        | token :: rest ->
          if token.value = ""
          then validate_path_tokens ~command_name expect_existing_dir rest
          else if expect_existing_dir
          then
            (match validate_path_value ~requires_existing_dir:true token with
             | Ok () -> validate_path_tokens ~command_name false rest
             | Error _ as err -> err)
          else (
            match path_value_of_flagged_token token.value with
            | Some value ->
              let token = { token with value } in
              (match
                 validate_path_value
                   ~requires_existing_dir:(inline_path_flag_requires_existing_dir token.value)
                   token
               with
               | Ok () -> validate_path_tokens ~command_name false rest
               | Error _ as err -> err)
            | None when is_path_flag token.value ->
              validate_path_tokens
                ~command_name
                (path_flag_requires_existing_dir token.value)
                rest
            | None
              when String.equal command_name "git"
                   && git_revisionish_token ?workdir token.value ->
              validate_path_tokens ~command_name false rest
            | None when looks_like_path_token token.value ->
              if token_has_unsafe_rewrite_syntax token
              then Error (path_syntax_blocked_message token)
              else if token.globbed
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
      let validate_token_stream tokens =
        let command_name =
          match tokens with
          | command :: _ -> Filename.basename command.value
          | [] -> ""
        in
        tokens
        |> path_validation_tokens
        |> validate_path_tokens ~command_name false
      in
      let path_token_of_literal value =
        { value; quoted = false; escaped = false; globbed = false; braced = false }
      in
      let rec validate_redirects = function
        | [] -> Ok ()
        | Masc_exec.Redirect_scope.File { target; _ } :: rest ->
          let token = Masc_exec.Path_scope.raw target |> path_token_of_literal in
          (match validate_path_value ~requires_existing_dir:false token with
           | Ok () -> validate_redirects rest
           | Error _ as err -> err)
        | Masc_exec.Redirect_scope.Fd_to_fd _ :: rest -> validate_redirects rest
      in
      let tokens_of_simple (simple : Masc_exec.Shell_ir.simple) =
        let command = Masc_exec.Bin.to_string simple.bin |> path_token_of_literal in
        let rec args acc = function
          | [] -> Some (command :: List.rev acc)
          | Masc_exec.Shell_ir.Lit value :: rest ->
            args (path_token_of_literal value :: acc) rest
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
      let legacy_tokens = tokenize_path_args cmd in
      let legacy_path_tokens = path_validation_tokens legacy_tokens in
      let legacy_needs_syntax_sensitive_gate =
        List.exists
          (fun token -> token_has_unsafe_rewrite_syntax token || token.globbed)
          legacy_path_tokens
      in
      if legacy_needs_syntax_sensitive_gate
      then validate_token_stream legacy_tokens
      else (
        match Masc_exec_bash_parser.Bash.parse_string cmd with
        | Masc_exec.Parsed.Parsed shell_ir ->
          (match validate_parsed_shell_ir shell_ir with
           | Some result -> result
           | None -> validate_token_stream legacy_tokens)
        | Masc_exec.Parsed.Parse_error _
        | Masc_exec.Parsed.Parse_aborted _
        | Masc_exec.Parsed.Too_complex _ ->
          validate_token_stream legacy_tokens)
;;
