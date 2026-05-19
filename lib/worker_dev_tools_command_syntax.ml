(** Legacy shell syntax helpers for Worker_dev_tools.

    The authoritative Coding/Full gate is typed through Shell_command_gate,
    but worker_dev_tools still keeps a small legacy lexer for strict mode,
    fallback parsing, and path-token extraction. *)

(* Mirror of [Gh_command_validation.forbidden_shell_chars].  Kept as a
   list for docs/tests; the scan uses a closed pattern match below so the
   per-byte check compiles to a jump table instead of an O(M) list walk
   over [cmd]. *)
let forbidden_shell_chars = [ ';'; '|'; '&'; '>'; '<'; '`'; '$'; '\n'; '\r' ]

let contains_forbidden_shell_chars cmd =
  String.exists
    (function
      | ';' | '|' | '&' | '>' | '<' | '`' | '$' | '\n' | '\r' -> true
      | _ -> false)
    cmd
;;

(** Relaxed metacharacter set for Coding/Full preset keepers.
    Allows [|] (pipes) and fd-to-fd redirects like [2>&1].
    Still blocks [;] [`] [$] and control chars.
    [&] is checked at pattern level: [>&] (redirect) is allowed,
    [&&] (chaining) and standalone [&] (background) are blocked. *)
let forbidden_shell_chars_coding_base = [ ';'; '`'; '$'; '\n'; '\r' ]

(** Returns [true] if [cmd] contains a dangerous [&] usage.
    [>&] in redirect context (e.g. [2>&1]) is safe; [&&] and standalone [&]
    are command chaining/background operators. *)
let has_dangerous_ampersand cmd =
  let len = String.length cmd in
  let rec check i =
    if i >= len
    then false
    else if cmd.[i] <> '&'
    then check (i + 1)
    else if i > 0 && cmd.[i - 1] = '>'
    then
      (* Part of >& redirect syntax — safe *)
      check (i + 1)
    else true
  in
  check 0
;;

let contains_forbidden_shell_chars_coding cmd =
  String.exists
    (function
      | ';' | '`' | '$' | '\n' | '\r' -> true
      | _ -> false)
    cmd
  || has_dangerous_ampersand cmd
;;

let contains_substring s needle = String_util.contains_substring s needle

let has_process_substitution cmd =
  contains_substring cmd "<(" || contains_substring cmd ">("
;;

type pipeline_quote_state = Pipeline_no_quote | Pipeline_single | Pipeline_double

let split_pipeline_segments cmd =
  let len = String.length cmd in
  let buf = Buffer.create len in
  let push_segment segments =
    let segment = Buffer.contents buf |> String.trim in
    Buffer.clear buf;
    segment :: segments
  in
  let rec loop quote escaped i segments =
    if i >= len
    then List.rev (push_segment segments)
    else if escaped
    then (
      Buffer.add_char buf cmd.[i];
      loop quote false (i + 1) segments)
    else
      match quote, cmd.[i] with
      | Pipeline_single, '\'' ->
        Buffer.add_char buf cmd.[i];
        loop Pipeline_no_quote false (i + 1) segments
      | Pipeline_single, _ ->
        Buffer.add_char buf cmd.[i];
        loop quote false (i + 1) segments
      | Pipeline_double, '"' ->
        Buffer.add_char buf cmd.[i];
        loop Pipeline_no_quote false (i + 1) segments
      | Pipeline_double, '\\' ->
        Buffer.add_char buf cmd.[i];
        loop quote true (i + 1) segments
      | Pipeline_double, _ ->
        Buffer.add_char buf cmd.[i];
        loop quote false (i + 1) segments
      | Pipeline_no_quote, '\'' ->
        Buffer.add_char buf cmd.[i];
        loop Pipeline_single false (i + 1) segments
      | Pipeline_no_quote, '"' ->
        Buffer.add_char buf cmd.[i];
        loop Pipeline_double false (i + 1) segments
      | Pipeline_no_quote, '\\' ->
        Buffer.add_char buf cmd.[i];
        loop quote true (i + 1) segments
      | Pipeline_no_quote, '|' ->
        loop Pipeline_no_quote false (i + 1) (push_segment segments)
      | Pipeline_no_quote, _ ->
        Buffer.add_char buf cmd.[i];
        loop quote false (i + 1) segments
  in
  let segments = loop Pipeline_no_quote false 0 [] in
  if List.exists (fun segment -> segment = "") segments
  then Error "Pipes must separate complete allowed commands."
  else Ok segments
;;

let split_shell_tokens cmd =
  String.split_on_char ' ' cmd
  |> List.map String.trim
  |> List.filter (fun token -> token <> "")
;;

let strip_wrapping_quotes token =
  let len = String.length token in
  if len >= 2
  then (
    let first = token.[0]
    and last = token.[len - 1] in
    if (first = '"' && last = '"') || (first = '\'' && last = '\'')
    then String.sub token 1 (len - 2)
    else token)
  else token
;;

let basename_token token = Filename.basename (strip_wrapping_quotes token)

let is_env_assignment token =
  let token = strip_wrapping_quotes token in
  match String.index_opt token '=' with
  | Some idx ->
    idx > 0
    && not (String.contains (String.sub token 0 idx) '/')
    && not (String.starts_with ~prefix:"-" token)
  | None -> false
;;

let rec skip_env_assignments = function
  | [] -> None
  | token :: rest ->
    let token = strip_wrapping_quotes token in
    if is_env_assignment token then skip_env_assignments rest
    else Some (basename_token token)
;;

let rec command_after_env_prefix = function
  | [] -> None
  | token :: rest ->
    let token = strip_wrapping_quotes token in
    if is_env_assignment token || token = "-" || token = "-i"
       || token = "--ignore-environment" || token = "-0" || token = "--null"
    then command_after_env_prefix rest
    else if token = "--" then skip_env_assignments rest
    else if token = "-S" || token = "--split-string"
    then (
      match rest with
      | arg :: rest -> (
        match command_after_env_prefix (split_shell_tokens (strip_wrapping_quotes arg)) with
        | Some _ as command -> command
        | None -> command_after_env_prefix rest)
      | [] -> None)
    else if String.starts_with ~prefix:"--split-string=" token
    then
      let prefix = "--split-string=" in
      let arg =
        String.sub token (String.length prefix)
          (String.length token - String.length prefix)
      in
      command_after_env_prefix (split_shell_tokens (strip_wrapping_quotes arg))
    else if token = "-u" || token = "--unset" || token = "-C"
            || token = "--chdir"
    then (
      match rest with
      | _ :: rest -> command_after_env_prefix rest
      | [] -> None)
    else if String.starts_with ~prefix:"-u" token
            || String.starts_with ~prefix:"--unset=" token
            || String.starts_with ~prefix:"--chdir=" token
    then command_after_env_prefix rest
    else Some (basename_token token)
;;

let opam_exec_command_name rest =
  match rest with
  | sub :: rest when String.equal (basename_token sub) "exec" ->
    let rec find_sentinel = function
      | [] -> None
      | "--" :: token :: _ -> Some (basename_token token)
      | "--" :: [] -> None
      | _ :: rest -> find_sentinel rest
    in
    let rec find_command_without_sentinel = function
      | [] -> None
      | token :: rest ->
        let token = strip_wrapping_quotes token in
        if is_env_assignment token then find_command_without_sentinel rest
        else if token = "--switch" || token = "--color" || token = "--root"
                || token = "--cli"
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
        else Some (basename_token token)
    in
    (match find_sentinel rest with
     | Some _ as command -> command
     | None -> find_command_without_sentinel rest)
  | [] -> Some "opam"
  | _non_exec_subcommand :: _rest -> Some "opam"
;;

let segment_command_name segment =
  match split_shell_tokens segment with
  | [] -> None
  | token :: rest -> (
    match basename_token token with
    | "env" -> command_after_env_prefix rest
    | "opam" -> opam_exec_command_name rest
    | name -> Some name)
;;

let invokes_direct_dune segment =
  match segment_command_name segment with
  | Some "dune" -> true
  | _ -> false
;;

let is_digits_only s start stop =
  let rec loop i =
    if i >= stop
    then true
    else if Char.code s.[i] >= Char.code '0' && Char.code s.[i] <= Char.code '9'
    then loop (i + 1)
    else false
  in
  loop start
;;

let is_safe_fd_redirect_token token =
  let lower = String.lowercase_ascii token in
  if
    List.mem
      lower
      [ ">/dev/null"
      ; "1>/dev/null"
      ; "2>/dev/null"
      ; ">>/dev/null"
      ; "1>>/dev/null"
      ; "2>>/dev/null"
      ; "</dev/null"
      ; "0</dev/null"
      ]
  then true
  else
  let len = String.length token in
  let check op_char =
    let rec find i =
      if i + 1 >= len
      then None
      else if token.[i] = op_char && token.[i + 1] = '&'
      then Some i
      else find (i + 1)
    in
    match find 0 with
    | None -> false
    | Some op_idx ->
      let rhs_start = op_idx + 2 in
      (op_idx = 0 || is_digits_only token 0 op_idx)
      && rhs_start < len
      && is_digits_only token rhs_start len
  in
  check '>' || check '<'
;;

let has_unsafe_redirection cmd =
  split_shell_tokens cmd
  |> List.exists (fun token ->
    (contains_substring token ">" || contains_substring token "<")
    && not (is_safe_fd_redirect_token token))
;;

let extract_command_name cmd =
  let trimmed = String.trim cmd in
  if trimmed = ""
  then None
  else (
    let len = String.length trimmed in
    let rec find_sep i =
      if i >= len
      then len
      else (
        match trimmed.[i] with
        | ' ' | '\t' -> i
        | _ -> find_sep (i + 1))
    in
    let token = String.sub trimmed 0 (find_sep 0) in
    Some (Filename.basename token))
;;
