type guard_token =
  | Guard_word of string * bool
  | Guard_separator

let first_token_of_cmd cmd =
  match Agent_tool_execute_command_parse.parse_cmd_to_ir_opt cmd with
  | None -> None
  | Some ir ->
    (match Exec_policy_mutation_classifier.flat_stage_words ir with
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

let push_guard_word acc ~quoted value =
  if String.equal value ""
  then acc
  else Guard_word (String.lowercase_ascii value, quoted) :: acc
;;

let split_unquoted_guard_word acc value =
  let len = String.length value in
  let rec loop start i acc =
    if i >= len
    then push_guard_word acc ~quoted:false (String.sub value start (len - start))
    else (
      match value.[i] with
      | ';' ->
        let acc = push_guard_word acc ~quoted:false (String.sub value start (i - start)) in
        loop (i + 1) (i + 1) (Guard_separator :: acc)
      | '&' when i + 1 < len && value.[i + 1] = '&' ->
        let acc = push_guard_word acc ~quoted:false (String.sub value start (i - start)) in
        loop (i + 2) (i + 2) (Guard_separator :: acc)
      | '|' when i + 1 < len && value.[i + 1] = '|' ->
        let acc = push_guard_word acc ~quoted:false (String.sub value start (i - start)) in
        loop (i + 2) (i + 2) (Guard_separator :: acc)
      | _ch -> loop start (i + 1) acc)
  in
  loop 0 0 acc
;;

let guard_tokens_of_word acc (word : Exec_policy_mutation_classifier.quoted_word) =
  if word.quoted
  then push_guard_word acc ~quoted:true word.value
  else if String.equal word.value "&&"
          || String.equal word.value "||"
          || String.equal word.value ";"
  then Guard_separator :: acc
  else split_unquoted_guard_word acc word.value
;;

let guard_tokens_of_cmd cmd =
  match Agent_tool_execute_command_parse.parse_cmd_to_ir_opt cmd with
  | None -> []
  | Some ir ->
    Exec_policy_mutation_classifier.stages_quoted_words_of_ir ir
    |> List.fold_left
         (fun acc stage ->
            let acc = List.fold_left guard_tokens_of_word acc stage in
            Guard_separator :: acc)
         []
    |> List.rev
;;
