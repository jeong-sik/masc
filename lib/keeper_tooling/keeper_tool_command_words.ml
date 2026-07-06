type guard_token =
  | Guard_word of string * bool
  | Guard_separator

module Shell_words = Masc_exec_shell_words.Shell_words

type command_word_parse_error =
  | Shell_ir_parse_error of Exec_policy.block_reason
  | Shell_words_parse_error of
      { segment : string
      ; error : Shell_words.error
      }

type guard_tokens_with_errors =
  { guard_tokens : guard_token list
  ; guard_token_parse_errors : command_word_parse_error list
  }

let shell_words_error_to_string = function
  | Shell_words.Unclosed_quote -> "unclosed_quote"
  | Shell_words.Trailing_escape -> "trailing_escape"
;;

let command_word_parse_error_to_string = function
  | Shell_ir_parse_error reason ->
    Printf.sprintf "shell_ir_parse_error:%s" (Exec_policy.block_reason_tag reason)
  | Shell_words_parse_error { segment; error } ->
    Printf.sprintf
      "shell_words_parse_error:%s segment=%S"
      (shell_words_error_to_string error)
      segment
;;

let warn_command_word_parse_error ~site error =
  Log.Misc.warn
    "keeper_tool_command_words %s: %s"
    site
    (command_word_parse_error_to_string error)
;;

let first_token_of_cmd_result cmd =
  if String.equal (String.trim cmd) ""
  then Ok None
  else
    match Exec_policy.parse_string_to_ir ~mode:Tool_execute cmd with
    | Error reason -> Error (Shell_ir_parse_error reason)
  | Ok ir ->
    (match Exec_policy.flat_stage_words ir with
     | token :: _ -> Ok (Some token)
     | [] -> Ok None)
;;

let strip_simple_shell_quotes token =
  let len = String.length token in
  if
    len >= 2
    && ((token.[0] = '\'' && token.[len - 1] = '\'')
        || (token.[0] = '"' && token.[len - 1] = '"'))
  then String.sub token 1 (len - 2)
  else token
;;

let fallback_cmd_prefix cmd =
  let trimmed = String.trim cmd in
  match String.split_on_char ' ' trimmed with
  | [] | [ "" ] -> trimmed
  | first :: _ -> strip_simple_shell_quotes first
;;

let first_token_of_cmd cmd =
  match first_token_of_cmd_result cmd with
  | Ok token -> token
  | Error error ->
    warn_command_word_parse_error ~site:"first_token_of_cmd" error;
    None
;;

let cmd_prefix_result cmd =
  match first_token_of_cmd_result cmd with
  | Ok (Some token) -> Ok token
  | Ok None -> Ok (fallback_cmd_prefix cmd)
  | Error error -> Error error
;;

let cmd_prefix cmd =
  match cmd_prefix_result cmd with
  | Ok prefix -> prefix
  | Error error ->
    warn_command_word_parse_error ~site:"cmd_prefix" error;
    fallback_cmd_prefix cmd
;;

let guard_word_of_shell_word (word : Shell_words.word) =
  Guard_word (String.lowercase_ascii word.value, word.quoted)
;;

let guard_tokens_of_segment_result segment =
  match Shell_words.stages segment with
  | Error error -> Error (Shell_words_parse_error { segment; error })
  | Ok stages ->
    Ok
      (List.concat_map
         (fun words -> List.map guard_word_of_shell_word words @ [ Guard_separator ])
         stages)
;;

let guard_tokens_of_cmd_with_errors cmd =
  let rec loop tokens errors = function
    | [] ->
      { guard_tokens = List.rev tokens; guard_token_parse_errors = List.rev errors }
    | (_unconditional, segment) :: rest ->
      (match guard_tokens_of_segment_result segment with
       | Ok segment_tokens -> loop (List.rev_append segment_tokens tokens) errors rest
       | Error error -> loop tokens (error :: errors) rest)
  in
  loop [] [] (Shell_words.top_level_command_segments cmd)
;;

let guard_tokens_of_cmd cmd =
  let result = guard_tokens_of_cmd_with_errors cmd in
  List.iter
    (warn_command_word_parse_error ~site:"guard_tokens_of_cmd")
    result.guard_token_parse_errors;
  result.guard_tokens
;;
