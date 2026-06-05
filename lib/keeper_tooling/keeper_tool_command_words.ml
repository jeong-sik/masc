type guard_token =
  | Guard_word of string * bool
  | Guard_separator

let first_token_of_cmd cmd =
  match Exec_policy.parse_string_to_ir ~mode:Tool_execute cmd with
  | Error _ -> None
  | Ok ir ->
    (match Exec_policy.flat_stage_words ir with
     | token :: _ -> Some token
     | [] -> None)
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

let cmd_prefix cmd =
  match first_token_of_cmd cmd with
  | Some token -> token
  | None ->
    let trimmed = String.trim cmd in
    (match String.split_on_char ' ' trimmed with
     | [] | [ "" ] -> trimmed
     | first :: _ -> strip_simple_shell_quotes first)
;;

module Shell_words = Masc_exec_shell_words.Shell_words

let guard_word_of_shell_word (word : Shell_words.word) =
  Guard_word (String.lowercase_ascii word.value, word.quoted)
;;

let guard_tokens_of_segment segment =
  match Shell_words.stages segment with
  | Error _ -> []
  | Ok stages ->
    List.concat_map
      (fun words ->
         List.map guard_word_of_shell_word words @ [ Guard_separator ])
      stages
;;

let guard_tokens_of_cmd cmd =
  Shell_words.top_level_command_segments cmd
  |> List.concat_map (fun (_unconditional, segment) ->
    guard_tokens_of_segment segment)
;;
