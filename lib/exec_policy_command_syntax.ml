(** Shell word helpers for execution policy path and transparent-wrapper checks.

    Command-shape validation is owned by
    [Masc_exec_command_gate.Shell_command_gate]. This module keeps only
    path-token normalization helpers plus explicit argv/word helpers for
    transparent wrappers such as [env] and [opam exec]. *)

let rec shell_ir_literal_text = function
  | Masc_exec.Shell_ir.Lit (text, _) -> Some text
  | Masc_exec.Shell_ir.Concat parts ->
    let rec loop acc = function
      | [] -> Some (String.concat "" (List.rev acc))
      | part :: rest ->
        (match shell_ir_literal_text part with
         | Some text -> loop (text :: acc) rest
         | None -> None)
    in
    loop [] parts
  | Masc_exec.Shell_ir.Var (_, _) -> None
;;

let argv_words_of_simple (simple : Masc_exec.Shell_ir.simple) =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | arg :: rest ->
      (match shell_ir_literal_text arg with
       | Some text -> loop (text :: acc) rest
       | None -> None)
  in
  Option.map
    (fun args -> Masc_exec.Bin.to_string simple.bin :: args)
    (loop [] simple.Masc_exec.Shell_ir.args)
;;

let argv_words_of_split_string text =
  let words =
    String.split_on_char ' ' text
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  match words with
  | [] -> None
  | _ -> Some words
;;

let basename_token token = Filename.basename token

let is_env_assignment token =
  match String.index_opt token '=' with
  | Some idx ->
    idx > 0
    && not (String.contains (String.sub token 0 idx) '/')
    && not (String.starts_with ~prefix:"-" token)
  | None -> false
;;

let rec skip_env_assignments_tokens = function
  | [] -> None
  | token :: rest ->
    if is_env_assignment token then skip_env_assignments_tokens rest else Some (token :: rest)
;;

let rec command_after_env_prefix_tokens = function
  | [] -> None
  | token :: rest ->
    if is_env_assignment token || token = "-" || token = "-i"
       || token = "--ignore-environment" || token = "-0" || token = "--null"
    then command_after_env_prefix_tokens rest
    else if token = "--"
    then skip_env_assignments_tokens rest
    else if token = "-S" || token = "--split-string"
    then (
      match rest with
      | arg :: rest -> (
        match argv_words_of_split_string arg with
        | Some split_tokens -> (
          match command_after_env_prefix_tokens split_tokens with
          | Some _ as command -> command
          | None -> command_after_env_prefix_tokens rest)
        | None -> command_after_env_prefix_tokens rest)
      | [] -> None)
    else if String.starts_with ~prefix:"--split-string=" token
    then
      let prefix = "--split-string=" in
      let arg =
        String.sub token (String.length prefix) (String.length token - String.length prefix)
      in
      Option.bind
        (argv_words_of_split_string arg)
        command_after_env_prefix_tokens
    else if token = "-u" || token = "--unset" || token = "-C" || token = "--chdir"
    then (
      match rest with
      | _ :: rest -> command_after_env_prefix_tokens rest
      | [] -> None)
    else if String.starts_with ~prefix:"-u" token
            || String.starts_with ~prefix:"--unset=" token
            || String.starts_with ~prefix:"--chdir=" token
    then command_after_env_prefix_tokens rest
    else Some (token :: rest)
;;

let opam_exec_command_tokens rest =
  match rest with
  | sub :: rest when String.equal (basename_token sub) "exec" ->
    let rec find_sentinel = function
      | [] -> None
      | "--" :: rest -> skip_env_assignments_tokens rest
      | _ :: rest -> find_sentinel rest
    in
    let rec find_command_without_sentinel = function
      | [] -> None
      | token :: rest ->
        if is_env_assignment token
        then find_command_without_sentinel rest
        else if token = "--switch" || token = "--color" || token = "--root" || token = "--cli"
        then (
          match rest with
          | _ :: rest -> find_command_without_sentinel rest
          | [] -> None)
        else if String.starts_with ~prefix:"--switch=" token
                || String.starts_with ~prefix:"--color=" token
                || String.starts_with ~prefix:"--root=" token
                || String.starts_with ~prefix:"--cli=" token
                || String.starts_with ~prefix:"-" token
        then find_command_without_sentinel rest
        else Some (token :: rest)
    in
    (match find_sentinel rest with
     | Some _ as command -> command
     | None -> find_command_without_sentinel rest)
  | [] -> Some [ "opam" ]
  | _non_exec_subcommand :: _rest -> Some [ "opam" ]
;;

let rec effective_command_name_from_tokens = function
  | [] -> None
  | token :: rest -> (
    match basename_token token with
    | "env" ->
      Option.bind (command_after_env_prefix_tokens rest) effective_command_name_from_tokens
    | "opam" ->
      (match opam_exec_command_tokens rest with
       | Some [ "opam" ] -> Some "opam"
       | Some tokens -> effective_command_name_from_tokens tokens
       | None -> None)
    | name -> Some name)
;;

let command_after_env_prefix tokens =
  Option.bind (command_after_env_prefix_tokens tokens) effective_command_name_from_tokens
;;

let opam_exec_command_name tokens =
  Option.bind (opam_exec_command_tokens tokens) effective_command_name_from_tokens
;;
