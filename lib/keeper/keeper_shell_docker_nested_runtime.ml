(* Nested-container runtime detection for keeper_bash sandboxing.

   When the sandbox profile forbids spawning Docker/Podman/nerdctl/
   buildah from inside a sandboxed keeper, this module statically
   detects whether a given shell command would trigger such a spawn.

   Detection covers:
   - direct command word (incl. `sudo`/`command`/`time`/`env` chains
     and inline `VAR=value` env assignments)
   - command substitution `$(...)` / backticks
   - bare references to container daemon sockets (docker/podman/
     containerd/buildkit)
   - `sh -c '...'` payloads (recursive)

   Extracted from [Keeper_shell_docker] (godfile decomp). Pure shell
   tokenizer + classifier - no I/O, no shared state. *)

let nested_container_runtime_tokens = [ "docker"; "podman"; "nerdctl"; "buildah" ]

let sandbox_socket_markers =
  [ "/var/run/docker.sock"
  ; "/run/docker.sock"
  ; "/run/podman/podman.sock"
  ; "podman.sock"
  ; "containerd.sock"
  ; "buildkitd.sock"
  ]
;;

type shell_guard_token =
  | Guard_word of string * bool
  | Guard_separator

let shell_guard_tokens cmd =
  let flush_word acc buf quoted =
    if Buffer.length buf = 0
    then acc
    else (
      let word = Buffer.contents buf |> String.lowercase_ascii in
      Buffer.clear buf;
      Guard_word (word, quoted) :: acc)
  in
  let len = String.length cmd in
  let rec loop i quote quoted acc buf =
    if i >= len
    then List.rev (flush_word acc buf quoted)
    else (
      match quote, cmd.[i] with
      | Some q, c when c = q -> loop (i + 1) None true acc buf
      | Some _, c ->
        Buffer.add_char buf c;
        loop (i + 1) quote quoted acc buf
      | None, (('\'' | '"') as q) -> loop (i + 1) (Some q) true acc buf
      | None, (' ' | '\t' | '\r' | '\n') ->
        let acc = flush_word acc buf quoted in
        loop (i + 1) None false acc buf
      | None, (';' | '|') ->
        let acc = Guard_separator :: flush_word acc buf quoted in
        loop (i + 1) None false acc buf
      | None, '&' ->
        let acc =
          if i + 1 < len && cmd.[i + 1] = '&'
          then Guard_separator :: flush_word acc buf quoted
          else flush_word acc buf quoted
        in
        loop
          (if i + 1 < len && cmd.[i + 1] = '&' then i + 2 else i + 1)
          None
          false
          acc
          buf
      | None, c ->
        Buffer.add_char buf c;
        loop (i + 1) None quoted acc buf)
  in
  loop 0 None false [] (Buffer.create 32)
;;

let shell_assignment_like word =
  match String.index_opt word '=' with
  | None | Some 0 -> false
  | Some idx ->
    let ok_char = function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
      | _ -> false
    in
    String.for_all ok_char (String.sub word 0 idx)
;;

let env_option_takes_arg = function
  | "-u" | "--unset" | "-c" | "--chdir" -> true
  | _ -> false
;;

let env_option_like word = String.length word > 0 && word.[0] = '-'

let env_split_string_inline_value word =
  let prefix = "--split-string=" in
  if String.starts_with ~prefix word
  then
    Some
      (String.sub word (String.length prefix) (String.length word - String.length prefix))
  else None
;;

let shell_interpreter_names = [ "bash"; "sh"; "zsh" ]
let is_shell_interpreter word = List.mem (Filename.basename word) shell_interpreter_names

let word_contains_runtime_token text token =
  String.equal (Filename.basename text) token
  || String.starts_with ~prefix:("$(" ^ token) text
  || String.starts_with ~prefix:("`" ^ token) text
;;

let shell_c_payload = function
  | Guard_word (shell, false) :: rest when is_shell_interpreter shell ->
    let rec loop = function
      | [] -> None
      | Guard_word (flag, false) :: Guard_word (payload, _) :: _
        when String.length flag > 1 && flag.[0] = '-' && String.contains flag 'c' ->
        Some payload
      | Guard_word (flag, false) :: rest when String.length flag > 0 && flag.[0] = '-' ->
        loop rest
      | _ -> None
    in
    loop rest
  | _ -> None
;;

let command_word_mentions_nested_runtime tokens =
  let rec scan expect_command in_env skip_env_arg = function
    | [] -> false
    | Guard_separator :: rest -> scan true false false rest
    | Guard_word (word, _) :: rest ->
      if not expect_command
      then scan false false false rest
      else if in_env
      then scan_env_word word skip_env_arg rest
      else scan_command_word word rest
  and scan_command_word word rest =
    if List.exists (word_contains_runtime_token word) nested_container_runtime_tokens
    then true
    else if word = "sudo" || word = "command" || word = "time"
    then scan true false false rest
    else if word = "env"
    then scan true true false rest
    else if shell_assignment_like word
    then scan true false false rest
    else scan false false false rest
  and scan_env_word word skip_env_arg rest =
    if skip_env_arg
    then scan true true false rest
    else if word = "--"
    then scan true false false rest
    else if word = "-s" || word = "--split-string"
    then (
      match rest with
      | Guard_word (split_arg, _) :: tail ->
        nested_in_split_arg split_arg || scan true true false tail
      | _ -> false)
    else (
      match env_split_string_inline_value word with
      | Some split_arg -> nested_in_split_arg split_arg || scan true true false rest
      | None ->
        if shell_assignment_like word
        then scan true true false rest
        else if env_option_takes_arg word
        then scan true true true rest
        else if env_option_like word
        then scan true true false rest
        else scan_command_word word rest)
  and nested_in_split_arg split_arg =
    scan true false false (shell_guard_tokens split_arg)
  in
  scan true false false tokens
;;

let command_substitution_mentions_nested_runtime tokens =
  List.exists
    (function
      | Guard_word (word, false)
        when String.starts_with ~prefix:"$(" word || String.starts_with ~prefix:"`" word
        -> List.exists (word_contains_runtime_token word) nested_container_runtime_tokens
      | _ -> false)
    tokens
;;

let unquoted_word_mentions_socket_marker tokens =
  List.exists
    (function
      | Guard_word (word, false) ->
        List.exists
          (fun marker -> String_util.contains_substring word marker)
          sandbox_socket_markers
      | _ -> false)
    tokens
;;

let rec command_uses_nested_container_runtime cmd =
  let tokens = shell_guard_tokens cmd in
  command_word_mentions_nested_runtime tokens
  || command_substitution_mentions_nested_runtime tokens
  || unquoted_word_mentions_socket_marker tokens
  ||
  match shell_c_payload tokens with
  | None -> false
  | Some payload -> command_uses_nested_container_runtime payload
;;
