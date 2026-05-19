type shell_quote_state = No_quote | Single_quote | Double_quote

type shell_word = {
  text : string;
  starts_command : bool;
}

let shell_words_with_boundaries cmd =
  let len = String.length cmd in
  let buf = Buffer.create len in
  let quote_state = ref No_quote in
  let escaped = ref false in
  let at_command_start = ref true in
  let word_started_at_command_start = ref true in
  let push_word acc =
    if Buffer.length buf = 0 then acc
    else
      let text =
        Buffer.contents buf
        |> String.trim
        |> String.lowercase_ascii
      in
      Buffer.clear buf;
      at_command_start := false;
      { text; starts_command = !word_started_at_command_start } :: acc
  in
  let start_word_if_needed () =
    if Buffer.length buf = 0 then
      word_started_at_command_start := !at_command_start
  in
  let rec loop i acc =
    if i >= len then List.rev (push_word acc)
    else if !escaped then (
      start_word_if_needed ();
      Buffer.add_char buf cmd.[i];
      escaped := false;
      loop (i + 1) acc)
    else
      match !quote_state, cmd.[i] with
      | Single_quote, '\'' ->
        quote_state := No_quote;
        loop (i + 1) acc
      | Single_quote, ch ->
        start_word_if_needed ();
        Buffer.add_char buf ch;
        loop (i + 1) acc
      | Double_quote, '"' ->
        quote_state := No_quote;
        loop (i + 1) acc
      | Double_quote, '\\' ->
        escaped := true;
        loop (i + 1) acc
      | Double_quote, ch ->
        start_word_if_needed ();
        Buffer.add_char buf ch;
        loop (i + 1) acc
      | No_quote, '\\' ->
        escaped := true;
        loop (i + 1) acc
      | No_quote, '\'' ->
        start_word_if_needed ();
        quote_state := Single_quote;
        loop (i + 1) acc
      | No_quote, '"' ->
        start_word_if_needed ();
        quote_state := Double_quote;
        loop (i + 1) acc
      | No_quote, (' ' | '\t') ->
        loop (i + 1) (push_word acc)
      | No_quote, ('\n' | '\r' | ';' | '&' | '|') ->
        let acc = push_word acc in
        at_command_start := true;
        loop (i + 1) acc
      | No_quote, ch ->
        start_word_if_needed ();
        Buffer.add_char buf ch;
        loop (i + 1) acc
  in
  loop 0 []

let shell_interpreter_names = [ "bash"; "sh"; "zsh" ]

let command_name text = Filename.basename text

let is_direct_masc_tool_command_name name =
  String.starts_with ~prefix:"keeper_" name
  || String.starts_with ~prefix:"masc_" name
  || String.equal name "extend_turns"

let shell_c_payload words =
  match words with
  | shell :: rest when
    shell.starts_command
    && List.mem (command_name shell.text) shell_interpreter_names ->
    let rec loop = function
      | [] -> None
      | flag :: payload :: _ when
        String.length flag.text > 1
        && flag.text.[0] = '-'
        && String.contains flag.text 'c' ->
        Some payload.text
      | flag :: rest when String.length flag.text > 0 && flag.text.[0] = '-' ->
        loop rest
      | _ -> None
    in
    loop rest
  | _ -> None

let is_env_assignment text =
  match String.index_opt text '=' with
  | Some i when i > 0 ->
    let lhs = String.sub text 0 i in
    not (String.contains lhs '/')
  | _ -> false

let rec strip_command_wrappers = function
  | [] -> []
  | word :: rest when is_env_assignment word.text ->
    strip_command_wrappers rest
  | word :: rest when
    let name = command_name word.text in
    String.equal name "command" || String.equal name "exec" ->
    strip_command_wrappers rest
  | word :: rest when String.equal (command_name word.text) "env" ->
    strip_env_args rest
  | words -> words

and strip_env_args = function
  | word :: rest when String.starts_with ~prefix:"-" word.text ->
    strip_env_args rest
  | word :: rest when is_env_assignment word.text ->
    strip_env_args rest
  | words -> strip_command_wrappers words

let direct_tool_command_name ~meta cmd =
  let allowed =
    Keeper_tool_policy.keeper_universe_tool_names meta
    |> List.map String.lowercase_ascii
  in
  let rec first_command_name cmd =
    let words = shell_words_with_boundaries cmd in
    let first_from_words =
      let rec loop = function
        | word :: rest when word.starts_command ->
          (match strip_command_wrappers (word :: rest) with
           | first :: _ -> Some (command_name first.text)
           | [] -> None)
        | _ :: rest -> loop rest
        | [] -> None
      in
      loop words
    in
    match shell_c_payload words with
    | Some payload -> first_command_name payload
    | None -> first_from_words
  in
  match first_command_name cmd with
  | Some name when is_direct_masc_tool_command_name name ->
    let normalized = String.lowercase_ascii name in
    Some (name, List.mem normalized allowed)
  | _ -> None

let gh_pr_create_sequence = function
  | gh :: pr :: create :: _ ->
    String.equal (command_name gh.text) "gh"
    && String.equal pr.text "pr"
    && String.equal create.text "create"
  | _ -> false

type gh_pr_native_subcommand =
  | Gh_pr_list
  | Gh_pr_status
  | Gh_pr_diff
  | Gh_pr_review

let gh_pr_native_subcommand_sequence = function
  | gh :: pr :: subcommand :: _
    when String.equal (command_name gh.text) "gh"
         && String.equal pr.text "pr" ->
    (match subcommand.text with
     | "list" -> Some Gh_pr_list
     | "view" | "status" | "checks" -> Some Gh_pr_status
     | "diff" -> Some Gh_pr_diff
     | "review" | "comment" -> Some Gh_pr_review
     | _ -> None)
  | _ -> None

let rec cmd_gh_pr_native_subcommand cmd =
  let words = shell_words_with_boundaries cmd in
  let rec loop = function
    | word :: rest when word.starts_command ->
      (match gh_pr_native_subcommand_sequence (strip_command_wrappers (word :: rest)) with
       | Some _ as hit -> hit
       | None -> loop rest)
    | _ :: rest -> loop rest
    | [] -> None
  in
  match loop words with
  | Some _ as hit -> hit
  | None ->
    (match shell_c_payload words with
     | Some payload -> cmd_gh_pr_native_subcommand payload
     | None -> None)

let rec cmd_contains_gh_pr_create cmd =
  let words = shell_words_with_boundaries cmd in
  let rec loop = function
    | word :: rest when
      word.starts_command
      && gh_pr_create_sequence (strip_command_wrappers (word :: rest)) ->
      true
    | _ :: rest -> loop rest
    | [] -> false
  in
  loop words
  ||
  match shell_c_payload words with
  | Some payload -> cmd_contains_gh_pr_create payload
  | None -> false
