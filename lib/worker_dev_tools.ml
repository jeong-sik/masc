(** Development tools for autonomous agent coding.

    Provides file_read, file_write, shell_exec so Fleet agents
    can perform local development tasks (code generation, test runs,
    file modifications).

    file_read/file_write use OCaml stdlib (no Eio filesystem capability needed).
    shell_exec uses Eio.Process with fiber-based timeout. *)

(* --- Safety validation --- *)

(** Resolve '.' and '..' segments in a path without filesystem access.
    This prevents path traversal attacks like /tmp/../../etc/passwd. *)
let normalize_path ?base_dir path =
  let abs =
    if Filename.is_relative path then
      Filename.concat
        (Option.value ~default:(Sys.getcwd ()) base_dir)
        path
    else path
  in
  let parts = String.split_on_char '/' abs in
  let resolved = List.fold_left (fun acc part ->
    match part with
    | "" | "." -> acc
    | ".." -> (match acc with [] -> [] | _ :: rest -> rest)
    | s -> s :: acc
  ) [] parts in
  "/" ^ String.concat "/" (List.rev resolved)

(** Split a target path into the deepest existing ancestor and the missing
    segments below it. This lets us resolve symlinks in the existing prefix
    while still validating paths that don't exist yet. *)
let rec split_existing_path path missing =
  if Sys.file_exists path then (path, missing)
  else
    let parent = Filename.dirname path in
    if parent = path then (path, missing)
    else split_existing_path parent (Filename.basename path :: missing)

(** Resolve symlinks in the existing prefix of a path and then append the
    remaining missing path segments lexically. *)
let resolve_path ?base_dir path =
  let abs = normalize_path ?base_dir path in
  let existing_prefix, missing_segments = split_existing_path abs [] in
  let resolved_prefix =
    try Unix.realpath existing_prefix |> normalize_path
    with Unix.Unix_error _ -> normalize_path existing_prefix
  in
  List.fold_left Filename.concat resolved_prefix missing_segments
  |> normalize_path

(** Check whether [path] is exactly [dir] or a descendant of [dir]. *)
let is_within_dir ~dir path =
  path = dir
  || String.starts_with ~prefix:(dir ^ "/") path

(** Path allowlist. When workdir is set, restrict to workdir + /tmp only.
    When unset, allow /tmp, cwd subtree, and ~/me subtree (backward compat). *)
let validate_path ?workdir path =
  let resolved = resolve_path ?base_dir:workdir path in
  match workdir with
  | Some wd ->
    let resolved_wd = resolve_path wd in
    is_within_dir ~dir:(resolve_path "/tmp") resolved
    || is_within_dir ~dir:resolved_wd resolved
  | None ->
    is_within_dir ~dir:(resolve_path "/tmp") resolved
    || is_within_dir ~dir:(resolve_path (Sys.getcwd ())) resolved
    || (match Sys.getenv_opt "HOME" with
        | Some home -> is_within_dir ~dir:(resolve_path (Filename.concat home "me")) resolved
        | None -> false)

(** shell_exec intentionally supports only a narrow allowlist of dev/test
    commands and rejects shell control syntax to keep execution predictable. *)
let dev_allowed_commands =
  [
    "cat"; "cargo"; "cmake"; "cut"; "dune"; "echo"; "env"; "file"; "find";
    "git"; "go"; "gofmt"; "gradle"; "grep"; "head"; "java"; "javac"; "ls";
    "make"; "mvn"; "node"; "npm"; "ninja"; "npx"; "opam"; "pip"; "pnpm";
    "printf"; "pwd"; "pyright"; "pytest"; "python"; "python3"; "rg"; "ruff";
    "rustc"; "sed"; "sort"; "stat"; "tail"; "tr"; "uniq"; "uv"; "wc";
    "which"; "yarn";
  ]

let readonly_allowed_commands =
  [
    "cat"; "cut"; "echo"; "env"; "file"; "find"; "grep"; "head"; "ls";
    "printf"; "pwd"; "rg"; "sed"; "sort"; "stat"; "tail"; "tr"; "uniq";
    "wc"; "which";
  ]

let forbidden_shell_chars =
  [ ';'; '|'; '&'; '>'; '<'; '`'; '$'; '\n'; '\r' ]

let contains_forbidden_shell_chars cmd =
  String.exists (fun ch -> List.mem ch forbidden_shell_chars) cmd

(** Relaxed metacharacter set for Coding/Full preset keepers.
    Allows [|] (pipes) and fd-to-fd redirects like [2>&1].
    Still blocks [;] [`] [$] and control chars.
    [&] is checked at pattern level: [>&] (redirect) is allowed,
    [&&] (chaining) and standalone [&] (background) are blocked. *)
let forbidden_shell_chars_coding_base =
  [ ';'; '`'; '$'; '\n'; '\r' ]

(** Returns [true] if [cmd] contains a dangerous [&] usage.
    [>&] in redirect context (e.g. [2>&1]) is safe; [&&] and standalone [&]
    are command chaining/background operators. *)
let has_dangerous_ampersand cmd =
  let len = String.length cmd in
  let rec check i =
    if i >= len then false
    else if cmd.[i] <> '&' then check (i + 1)
    else if i > 0 && cmd.[i - 1] = '>' then
      (* Part of >& redirect syntax — safe *)
      check (i + 1)
    else
      true
  in
  check 0

let contains_forbidden_shell_chars_coding cmd =
  String.exists (fun ch -> List.mem ch forbidden_shell_chars_coding_base) cmd
  || has_dangerous_ampersand cmd

let contains_substring s needle =
  let s_len = String.length s in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > s_len then false
    else if String.sub s i needle_len = needle then true
    else loop (i + 1)
  in
  if needle_len = 0 then true else loop 0

let has_process_substitution cmd =
  contains_substring cmd "<(" || contains_substring cmd ">("

let split_pipeline_segments cmd =
  let segments =
    String.split_on_char '|' cmd |> List.map String.trim
  in
  if List.exists (fun segment -> segment = "") segments then
    Error "Pipes must separate complete allowed commands."
  else Ok segments

let split_shell_tokens cmd =
  String.split_on_char ' ' cmd
  |> List.map String.trim
  |> List.filter (fun token -> token <> "")

let is_digits_only s start stop =
  let rec loop i =
    if i >= stop then true
    else if Char.code s.[i] >= Char.code '0' && Char.code s.[i] <= Char.code '9'
    then loop (i + 1)
    else false
  in
  loop start

let is_safe_fd_redirect_token token =
  let len = String.length token in
  let check op_char =
    let rec find i =
      if i + 1 >= len then None
      else if token.[i] = op_char && token.[i + 1] = '&' then Some i
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

let has_unsafe_redirection cmd =
  split_shell_tokens cmd
  |> List.exists (fun token ->
         (contains_substring token ">" || contains_substring token "<")
         && not (is_safe_fd_redirect_token token))

let extract_command_name cmd =
  let trimmed = String.trim cmd in
  if trimmed = "" then None
  else
    let len = String.length trimmed in
    let rec find_sep i =
      if i >= len then len
      else
        match trimmed.[i] with
        | ' ' | '\t' -> i
        | _ -> find_sep (i + 1)
    in
    let token = String.sub trimmed 0 (find_sep 0) in
    Some (Filename.basename token)

(** Error hint for a blocked command.

    A terse "'foo' is not allowed, allowed: dune, git..." drives the LLM
    to retry variants of foo, including OCaml/Python syntax fragments
    ('let', 'sort', 'Keeper_agent_run.build_ctx_composition', etc.) —
    live log 2026-04-16 shows 12+ retries per ~3MB.

    Give the LLM an actionable nudge based on what it probably tried:
      - OCaml/Python identifier → redirect to code tools
      - common shell command we don't allow (sort, awk) → name the
        supported alternative (rg/jq)
      - everything else → plain allowlist

    The helper is a pure function of the tried command name. *)
let command_blocked_hint name =
  let looks_like_source_code s =
    (* Contains '.' at a non-boundary position (A.B), or starts with a
       reserved OCaml keyword that no shell command uses. *)
    (String.contains s '.'
     && (String.index s '.' > 0)
     && (String.index s '.' < String.length s - 1))
    || List.mem s
         [ "let"; "match"; "if"; "then"; "else"; "fun"; "rec"; "in";
           "module"; "open"; "type"; "def"; "class"; "import"; "from" ]
  in
  let alt =
    match name with
    | "sort" | "uniq" -> " Use rg or jq for filtering."
    | "sed" | "awk" -> " Use keeper_fs_edit for in-place edits."
    | "find" -> " Use rg --files or masc_code_search."
    | "curl" | "wget" -> " Use masc_web_search for content fetching."
    | "gh" ->
      " 'gh' is NOT available in the keeper sandbox. For pull-request \
       work use keeper_pr_list / keeper_pr_view / keeper_pr_comment / \
       keeper_pr_review_read. For issues use masc_board_list / \
       masc_board_post / masc_board_comment. For commits or branches \
       just use 'git' directly — it is on the allowlist."
    | "docker" | "podman" | "kubectl" | "systemctl" | "brew" | "apt"
    | "apt-get" | "yum" | "dnf" ->
      Printf.sprintf
        " '%s' operates on host / cluster state and is deliberately \
         excluded from the keeper sandbox. If you need this operation, \
         escalate to an operator via masc_board_post instead of retrying."
        name
    | "ssh" | "scp" | "rsync" | "ftp" | "sftp" | "nc" ->
      Printf.sprintf
        " '%s' is a network primitive and is not permitted. Keeper \
         network access goes through masc_web_search or \
         masc_autoresearch_* tools."
        name
    | _ when looks_like_source_code name ->
      " This looks like source code, not a shell command — use \
       masc_code_edit / masc_code_write / masc_code_read instead."
    | _ -> ""
  in
  (* The "Allowed: ..." list below is a hand-curated prefix of
     [dev_allowed_commands] — kept short so the hint fits in one line of
     LLM context, but truthful (no stale entries). Keep in sync when
     dev_allowed_commands changes; the pointer to keeper_tools_list
     covers anything not in the printed prefix. *)
  Printf.sprintf
    "Command blocked: '%s' is not allowed. Common allowed commands: \
     dune, git, rg, ls, cat, head, tail, grep, find, make, node, npm, \
     python3, pytest, cargo, go.%s See keeper_tools_list for the \
     exhaustive tool surface, and keeper_fs_read / keeper_fs_edit for \
     file operations."
    name alt

type block_reason =
  | Empty_command
  | Chain_or_redirect
  | Injection
  | Process_substitution
  | Unsafe_redirect
  | Pipes_not_allowed
  | Command_not_allowed of string

let block_reason_to_string = function
  | Empty_command -> "command must not be empty"
  | Chain_or_redirect ->
    "Blocked: chaining (&&/||/;) and redirects (|/>) are not allowed. \
     Run ONE command per call. \
     To change directory, use the `cwd` argument instead of `cd` — \
     Good: cwd='repos/masc-mcp', cmd='dune build'. \
     Bad:  cmd='cd repos/masc-mcp && dune build'. \
     For pipelines like `rg foo | wc -l`, run the primary command and \
     process output at the LLM layer. To write files, use keeper_fs_edit."
  | Injection ->
    "Shell injection syntax (;, &&, standalone &, `, $) not allowed. \
     Run ONE command per call. \
     To change directory, use the `cwd` argument — \
     Good: cwd='repos/masc-mcp', cmd='dune build'. \
     Bad:  cmd='cd repos/masc-mcp && dune build' or cmd='cmd1 ; cmd2'. \
     Relative paths resolve from `cwd` (defaults to playground root). \
     For file writes, use keeper_fs_edit."
  | Process_substitution ->
    "Process substitution (<(...) or >(...)) is not allowed."
  | Unsafe_redirect ->
    "File redirects are not allowed. Only fd redirects like 2>&1 are permitted."
  | Pipes_not_allowed ->
    "Pipes are not allowed. Run one command per call."
  | Command_not_allowed name -> command_blocked_hint name

let validate_command_with_allowlist ~allowed_commands cmd =
  let trimmed = String.trim cmd in
  if trimmed = "" then Error Empty_command
  else if contains_forbidden_shell_chars trimmed then
    Error Chain_or_redirect
  else
    match extract_command_name trimmed with
    | None -> Error Empty_command
    | Some name when List.mem name allowed_commands -> Ok ()
    | Some name -> Error (Command_not_allowed name)

let validate_command cmd =
  validate_command_with_allowlist ~allowed_commands:dev_allowed_commands cmd

let validate_command_coding_with_allowlist
    ?(allow_pipes = true)
    ~(allowed_commands : string list)
    cmd =
  let trimmed = String.trim cmd in
  if trimmed = "" then Error Empty_command
  else if contains_forbidden_shell_chars_coding trimmed then
    Error Injection
  else if has_process_substitution trimmed then
    Error Process_substitution
  else if has_unsafe_redirection trimmed then
    Error Unsafe_redirect
  else
    match split_pipeline_segments trimmed with
    | Error msg -> Error (Command_not_allowed msg)
    | Ok segments ->
      if (not allow_pipes) && List.length segments > 1 then
        Error Pipes_not_allowed
      else
      let rec validate_segments = function
        | [] -> Ok ()
        | segment :: rest -> (
            match extract_command_name segment with
            | None -> Error Empty_command
            | Some name when List.mem name allowed_commands ->
              validate_segments rest
            | Some name -> Error (Command_not_allowed name))
      in
      validate_segments segments

(** Relaxed command validation for Coding/Full preset keepers.
    Allows pipes and redirects; validates every command in the pipeline
    against [dev_allowed_commands]. *)
let validate_command_coding cmd =
  validate_command_coding_with_allowlist
    ~allow_pipes:true
    ~allowed_commands:dev_allowed_commands
    cmd

let strip_wrapping_quotes token =
  let len = String.length token in
  if len >= 2 then
    let first = token.[0] and last = token.[len - 1] in
    if (first = '"' && last = '"') || (first = '\'' && last = '\'')
    then String.sub token 1 (len - 2)
    else token
  else token

let looks_like_url token =
  let token = strip_wrapping_quotes token in
  match String.index_opt token ':' with
  | Some idx when idx + 2 < String.length token ->
    token.[idx + 1] = '/' && token.[idx + 2] = '/'
  | _ -> false

let is_path_flag token =
  match strip_wrapping_quotes token with
  | "-C" | "--git-dir" | "--work-tree" | "--exec-path" -> true
  | _ -> false

let path_value_of_flagged_token token =
  let token = strip_wrapping_quotes token in
  let prefixes =
    [ "--git-dir="; "--work-tree="; "--exec-path=" ]
  in
  List.find_map
    (fun prefix ->
       if String.starts_with ~prefix token then
         Some
           (String.sub token (String.length prefix)
              (String.length token - String.length prefix))
       else None)
    prefixes

let looks_like_path_token token =
  let token = strip_wrapping_quotes token in
  token <> ""
  && not (looks_like_url token)
  &&
  (token = "." || token = ".."
   || String.starts_with ~prefix:"/" token
   || String.starts_with ~prefix:"./" token
   || String.starts_with ~prefix:"../" token
   || String.starts_with ~prefix:"~/" token
   || String.contains token '/')

let has_path_rewrite_syntax cmd =
  String.exists
    (function
      | '\'' | '"' | '\\' | '*' | '?' | '[' | ']' | '{' | '}' -> true
      | _ -> false)
    cmd

(* When a path-bearing keeper command carries path-rewrite syntax, tell the
   keeper which specific character tripped the block and what the supported
   alternative is. Otherwise small-LLM keepers retry the same glob/quote
   pattern (observed 62x on 2026-04-17/18). *)
let path_rewrite_redirect_hint cmd =
  let has ch = String.contains cmd ch in
  let suggestions = [
    (has '*' || has '?' || has '[' || has ']'),
      "Glob expansion ('*' / '?' / '[]') — use masc_code_search with \
       file_pattern (e.g. file_pattern='*.ml') or rg with --glob instead \
       of letting the shell expand.";
    (has '{' || has '}'),
      "Brace expansion ('{a,b}') — run one command per target, or use \
       masc_code_search / rg which accept multiple patterns natively.";
    (has '\\'),
      "Backslash escaping — the keeper shell does not interpret escapes. \
       Use masc_code_search with is_regex=true for pattern work that \
       would need \\. / \\w / etc.";
    (has '\'' || has '"'),
      "Quoting — path args must be unquoted plain strings. Move any \
       pattern into masc_code_search.query with is_regex appropriately set.";
  ] in
  let active =
    List.filter_map (fun (cond, msg) -> if cond then Some msg else None)
      suggestions
  in
  match active with
  | [] -> ""
  | msgs -> " " ^ String.concat " " msgs

let validate_command_paths ?workdir cmd =
  match workdir with
  | None -> Ok ()
  | Some _ ->
    if String.contains cmd '/' && has_path_rewrite_syntax cmd then
      Error
        ("Path syntax blocked: shell quoting, globbing, brace expansion, \
          and backslash escapes are not allowed for path-bearing keeper \
          commands. Use plain unquoted paths and explicit cwd."
         ^ path_rewrite_redirect_hint cmd)
    else
    let rec loop expect_path_value = function
      | [] -> Ok ()
      | token :: rest ->
        let token = strip_wrapping_quotes token in
        if token = "" then loop expect_path_value rest
        else if expect_path_value then
          if validate_path ?workdir token then loop false rest
          else
            Error
              (Printf.sprintf
                 "Path blocked: %s (outside allowed directories for this keeper command)"
                 token)
        else
          match path_value_of_flagged_token token with
          | Some value ->
            if validate_path ?workdir value then loop false rest
            else
              Error
                (Printf.sprintf
                   "Path blocked: %s (outside allowed directories for this keeper command)"
                   value)
          | None when is_path_flag token -> loop true rest
          | None when looks_like_path_token token ->
            if validate_path ?workdir token then loop false rest
            else
              Error
                (Printf.sprintf
                   "Path blocked: %s (outside allowed directories for this keeper command)"
                   token)
          | None -> loop false rest
    in
    cmd |> split_shell_tokens |> loop false

(** Check if a command performs write/mutating operations.
    Returns [true] for commands like [git push], [git commit],
    [make deploy], [npm publish], [mv], [cp], etc.
    Read-only commands (git status, dune build, rg) return [false]. *)
let is_write_operation cmd =
  let parts = String.split_on_char ' ' (String.trim cmd) in
  match parts with
  | "git" :: sub :: _ ->
    List.mem sub ["push"; "commit"; "merge"; "rebase"; "reset";
                  "checkout"; "branch"; "tag"; "stash"; "clone"; "init"]
  | "dune" :: sub :: _ ->
    List.mem sub ["clean"; "promote"]
  | "make" :: sub :: _ ->
    List.mem sub ["clean"; "deploy"; "install"; "publish"]
  | ("npm" | "pnpm" | "yarn") :: sub :: _ ->
    List.mem sub ["add"; "install"; "link"; "prune"; "publish"; "remove"; "unlink"; "update"; "up"]
  | cmd_name :: _ ->
    List.mem cmd_name ["mv"; "cp"; "mkdir"; "touch"; "chmod"]
  | [] -> false

(** Skip git global options (e.g. [-C dir], [--work-tree=...]) to find the
    actual subcommand. Handles both [-C dir] (two-token) and [--work-tree=x]
    (single-token) forms. *)
let rec skip_git_global_options = function
  | [] -> []
  | "--" :: rest -> rest
  | ("-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace"
    | "--super-prefix" | "--config-env" | "--exec-path") :: _ :: rest ->
    skip_git_global_options rest
  | opt :: rest when String.length opt > 1 && opt.[0] = '-' &&
      (String.starts_with ~prefix:"--git-dir=" opt
       || String.starts_with ~prefix:"--work-tree=" opt
       || String.starts_with ~prefix:"--namespace=" opt
       || String.starts_with ~prefix:"--exec-path=" opt
       || String.starts_with ~prefix:"-c" opt) ->
    skip_git_global_options rest
  | parts -> parts

(** Detect git branch-switch commands that would mutate the repo state outside
    the default keeper playground sandbox. keeper_bash/keeper_shell resolve to
    a sandboxed cwd by default, but explicit cwd overrides still need this
    guard. Redirect checkout/switch/branch mutations to an explicit worktree
    flow: create the worktree first, then use keeper_bash for git add/commit/
    push and keeper_shell op=gh for the draft PR.

    Handles tab-separated tokens, global git options like [-C dir], and real
    branch mutation forms (create, rename, copy). Allows read-only listing. *)
let is_git_branch_switch cmd =
  (* Tokenize on both space and tab *)
  let parts =
    let buf = Buffer.create 64 in
    let tokens = ref [] in
    String.iter (fun c ->
      match c with
      | ' ' | '\t' ->
        if Buffer.length buf > 0 then begin
          tokens := Buffer.contents buf :: !tokens;
          Buffer.clear buf
        end
      | _ -> Buffer.add_char buf c
    ) (String.trim cmd);
    if Buffer.length buf > 0 then
      tokens := Buffer.contents buf :: !tokens;
    List.rev !tokens
  in
  let is_option arg = String.length arg > 0 && arg.[0] = '-' in
  let has_any_flag flags args = List.exists (fun a -> List.mem a flags) args in
  let rec first_non_option = function
    | [] -> None
    | a :: _ when not (is_option a) -> Some a
    | _ :: rest -> first_non_option rest
  in
  match parts with
  | "git" :: rest ->
    (match skip_git_global_options rest with
     | "checkout" :: _ -> true
     | "switch" :: _ -> true
     | "branch" :: branch_args ->
       (* Block branch mutations:
          - git branch <newname> [<start-point>]
          - git branch -c/-C/--copy ...
          - git branch -m/-M/--move ...
          Allow: listing (-l/--list/-a/--all/-r/--remotes/-v/-vv/--show-current)
                 and deletion (-d/-D/--delete). *)
       if branch_args = [] then false
       else if has_any_flag ["-d"; "-D"; "--delete"] branch_args then false
       else if has_any_flag
         ["-l"; "--list"; "-a"; "--all"; "-r"; "--remotes";
          "--show-current"; "-v"; "-vv"] branch_args
       then false
       else if has_any_flag ["-c"; "-C"; "--copy"; "-m"; "-M"; "--move"] branch_args
       then true
       else Option.is_some (first_non_option branch_args)
     | _ -> false)
  | _ -> false

(** Detect truly destructive commands that must be blocked even for
    Coding/Full preset keepers. Delegates to [Eval_gate.detect_destructive]
    for the full 19-pattern check as a fallback. *)
let is_destructive_bash_operation cmd =
  let parts =
    String.split_on_char ' ' (String.trim cmd)
    |> List.filter (fun s -> s <> "")
  in
  let is_short_option arg =
    String.length arg > 1 && arg.[0] = '-' && arg.[1] <> '-'
  in
  let has_short_flag flag arg =
    is_short_option arg && String.contains arg flag
  in
  let is_protected_branch_target arg =
    let target = String.lowercase_ascii arg in
    List.mem target
      [ "main"; "master"; "origin/main"; "origin/master";
        "refs/heads/main"; "refs/heads/master" ]
    || List.exists
         (fun suffix -> String.ends_with ~suffix target)
         [ ":main"; ":master"; ":origin/main"; ":origin/master";
           ":refs/heads/main"; ":refs/heads/master" ]
  in
  match parts with
  | "git" :: "push" :: rest ->
    List.exists
      (fun arg ->
        arg = "--force" || arg = "-f"
        || String.starts_with ~prefix:"--force-with-lease" arg)
      rest
    || List.exists is_protected_branch_target rest
  | "git" :: "reset" :: rest ->
    List.mem "--hard" rest
  | "rm" :: rest ->
    let option_args =
      List.filter
        (fun arg -> String.length arg > 0 && arg.[0] = '-')
        rest
    in
    let has_recursive =
      List.exists
        (fun arg ->
          arg = "--recursive"
          || has_short_flag 'r' arg
          || has_short_flag 'R' arg)
        option_args
    in
    let has_force =
      List.exists
        (fun arg -> arg = "--force" || has_short_flag 'f' arg)
        option_args
    in
    has_recursive && has_force
  | _ ->
    (match Eval_gate.detect_destructive cmd with
     | Some _ -> true
     | None -> false)

let redact_url_credentials token =
  let redact_after_scheme token scheme =
    if String.starts_with ~prefix:scheme token then
      let scheme_len = String.length scheme in
      match String.index_from_opt token scheme_len '@' with
      | Some at_idx ->
        let slash_idx =
          match String.index_from_opt token scheme_len '/' with
          | Some idx -> idx
          | None -> String.length token
        in
        if at_idx < slash_idx then
          String.sub token 0 scheme_len ^ "[REDACTED]"
          ^ String.sub token at_idx (String.length token - at_idx)
        else token
      | None -> token
    else token
  in
  token |> fun t -> redact_after_scheme t "https://"
  |> fun t -> redact_after_scheme t "http://"

let redact_inline_secret_assignment token =
  let redact_after token marker =
    if contains_substring token marker then
      let marker_len = String.length marker in
      let rec find i =
        if i + marker_len > String.length token then None
        else if String.sub token i marker_len = marker then Some i
        else find (i + 1)
      in
      match find 0 with
      | Some idx ->
        String.sub token 0 (idx + marker_len) ^ "[REDACTED]"
      | None -> token
    else token
  in
  token |> fun t -> redact_after t ":_authToken="
  |> fun t -> redact_after t "_authToken="
  |> fun t -> redact_after t "token="
  |> fun t -> redact_after t "password="
  |> fun t -> redact_after t "passwd="
  |> fun t -> redact_after t "api-key="

let sanitize_command_for_log cmd =
  let sensitive_flags =
    [ "--token"; "--password"; "--passwd"; "--auth-token"; "--api-key" ]
  in
  let parts =
    String.split_on_char ' ' cmd
  in
  let rec redact prev_sensitive acc = function
    | [] -> String.concat " " (List.rev acc)
    | part :: rest ->
      let part =
        if prev_sensitive && part <> "" then "[REDACTED]"
        else
          part
          |> redact_url_credentials
          |> redact_inline_secret_assignment
      in
      let next_sensitive =
        List.mem (String.lowercase_ascii part) sensitive_flags
      in
      redact next_sensitive (part :: acc) rest
  in
  redact false [] parts

let truncate_for_log ?(max_len = 240) s =
  String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." s |> String_util.to_string

(* --- gh CLI validation for keeper_shell op=gh / PR workflow helpers --- *)

(** Top-level gh CLI commands allowed. Commands not in this list are
    rejected at the allowlist gate. *)
let gh_allowed_commands =
  [
    "api"; "cache"; "gist"; "issue"; "label"; "pr"; "project";
    "release"; "repo"; "ruleset"; "run"; "search"; "status";
    "workflow";
  ]

(** Reversibility classification for gh commands.
    Based on Thariq (Anthropic) Agent SDK workshop principle:
    "Tools for atomic/irreversible actions; bash for reversible work."
    + Anthropic Claude Code auto mode pattern:
    "Safe-tool allowlist = tools that cannot modify state; everything
    else goes to classifier; irreversible requires approval."

    - [R0_Read]: no state mutation. gh view/list, api GET, status,
      search. Free to run; only org allowlist gate.
    - [R1_Reversible]: mutates state but recoverable via inverse op.
      pr create/close/reopen/merge/ready/comment/edit, issue
      create/close/reopen, label create/delete, run cancel. Allowed
      + caller is expected to emit an audit event.
    - [R2_Irreversible]: cannot be undone via a gh inverse op.
      repo delete/archive/transfer/rename, release delete, secret
      delete, auth logout/token, ssh-key delete, workflow disable,
      api --method DELETE, graphql mutation delete*/remove*/transfer*.
      Must route through a structured keeper tool that carries
      operator-approval semantics. *)
type gh_reversibility =
  | R0_Read
  | R1_Reversible
  | R2_Irreversible

let string_of_gh_reversibility = function
  | R0_Read -> "R0" | R1_Reversible -> "R1" | R2_Irreversible -> "R2"

(** (command, subcommand) pairs classified as R2 irreversible.
    Conservative: when an operation *could* leak/destroy state that
    gh itself cannot restore, we mark it R2 even if a manual recovery
    path exists. Examples: repo archive is technically reversible via
    unarchive but disrupts downstream PRs; ssh-key delete is
    re-registrable but signing/deploy keys mid-CI break. *)
let gh_irreversible_ops =
  [
    ("repo",     ["delete"; "archive"; "transfer"; "rename"]);
    ("release",  ["delete"]);
    ("secret",   ["delete"; "remove"]);
    ("ssh-key",  ["delete"]);
    ("workflow", ["disable"]);
    ("auth",     ["logout"; "token"]);
    ("gist",     ["delete"]);
    ("ruleset",  ["delete"]);
  ]

(** (command, subcommand) pairs classified as R1 reversible mutation.
    The inverse operation is also a gh subcommand (pr close ↔ reopen,
    label create ↔ delete, run cancel is always followed by rerun).
    Allowed via op=gh but callers should audit. *)
let gh_reversible_mutations =
  [
    ("pr",      ["create"; "close"; "reopen"; "merge"; "ready";
                 "edit"; "comment"; "review"; "lock"; "unlock"]);
    ("issue",   ["create"; "close"; "reopen"; "edit"; "comment";
                 "lock"; "unlock"; "develop"; "pin"; "unpin"]);
    ("label",   ["create"; "edit"; "delete"; "clone"]);
    ("release", ["create"; "edit"; "upload"; "download"]);
    ("run",     ["cancel"; "rerun"; "watch"]);
    ("cache",   ["delete"]);
    ("gist",    ["create"; "edit"; "clone"; "rename"]);
    ("repo",    ["create"; "clone"; "fork"; "edit"; "sync"; "set-default"]);
    ("project", ["create"; "edit"; "close"; "copy"; "link"; "unlink";
                 "field-create"; "field-delete"; "item-add";
                 "item-archive"; "item-delete"; "item-edit"]);
    ("workflow", ["enable"; "run"]);
    ("ruleset", ["create"; "edit"]);
  ]

(** SSOT: GraphQL mutation names classified as R2 irreversible.
    Used by both [gh_api_graphql_is_destructive] (R0/R1/R2 classifier)
    and [is_gh_dangerous_operation] (legacy workflow guard).
    All names are lowercase for substring matching. *)
let gh_graphql_r2_mutations =
  [ "deletepullrequest"; "deleteissue"; "deletebranch"; "deleteref";
    "deleteproject"; "deletebranchprotectionrule";
    "removeouterfromorganization"; "transferrepository";
    "archiverepository" ]

let extract_gh_api_method cmd =
  let tokens =
    String.split_on_char ' ' (String.trim cmd)
    |> List.filter (fun s -> s <> "")
  in
  let rec find = function
    | [] -> "GET"
    | "-X" :: m :: _ | "--method" :: m :: _ -> String.uppercase_ascii m
    | tok :: _ when String.length tok > 9
                    && String.sub tok 0 9 = "--method=" ->
      String.uppercase_ascii (String.sub tok 9 (String.length tok - 9))
    | tok :: _ when String.length tok > 3
                    && String.sub tok 0 3 = "-X=" ->
      String.uppercase_ascii (String.sub tok 3 (String.length tok - 3))
    | _ :: rest -> find rest
  in
  find tokens

(** Detect [gh api graphql] invocations that carry a destructive
    mutation name. Uses substring match on the query body (passed via
    -f query=... or --raw-field query=...). Conservative: unknown
    mutation names default to R1 because GraphQL mutation semantics
    are wide; only the destructive-verb-prefix set is R2. *)
let gh_api_graphql_is_destructive cmd =
  let lower = String.lowercase_ascii cmd in
  let has s = contains_substring lower s in
  has "graphql"
  && List.exists has gh_graphql_r2_mutations

(** Classify a gh command string by state reversibility.
    The command is the portion after "gh " — a normalized form
    without the leading "gh" literal.

    Precedence (first match wins):
      1. top command + subcommand in [gh_irreversible_ops] → R2
      2. [api] with [--method DELETE] or a destructive graphql
         mutation → R2
      3. top command + subcommand in [gh_reversible_mutations] → R1
      4. [api] with --method POST/PUT/PATCH (or -f field flags that
         imply non-GET) → R1
      5. anything else → R0 (read-only default) *)
(* [classify_gh_reversibility] is defined after [has_mutating_http_method]
   below so we can reuse its -f/-F/--field → implicit-POST detection.
   The forward declaration pattern keeps this section free of an
   [let rec] cluster that would pull unrelated functions into the same
   recursive binding. *)

(** Legacy alias: kept so pre-classifier call sites still compile.
    Equivalent to [classify_gh_reversibility cmd = R2_Irreversible]
    for the pairs we used to block. *)
let gh_blocked_operations =
  List.concat_map
    (fun (c, subs) -> List.map (fun s -> (c, s)) subs)
    gh_irreversible_ops

(* [structured_tool_hint_for_r2] is defined after [extract_gh_command_pair]
   below (see the classifier block near the bottom of this file). *)

(** Extract owner from a [--repo OWNER/NAME], [--repo=OWNER/NAME], or
    [-R OWNER/NAME] flag in a gh command string. Returns [None] if no
    such flag is present — in that case gh defaults to the cwd's git
    origin, which is already org-gated at clone time.

    Only the owner segment is returned; repo/branch names are outside
    the allowlist scope. *)
let extract_gh_repo_owner cmd =
  let tokens =
    String.split_on_char ' ' (String.trim cmd)
    |> List.filter (fun s -> s <> "")
  in
  let owner_of_slug s =
    match String.split_on_char '/' s with
    | owner :: _ :: _ when owner <> "" -> Some owner
    | _ -> None
  in
  let rec find = function
    | [] -> None
    | "--repo" :: slug :: _ | "-R" :: slug :: _ -> owner_of_slug slug
    | tok :: rest when String.length tok > 7 && String.sub tok 0 7 = "--repo=" ->
      let slug = String.sub tok 7 (String.length tok - 7) in
      (match owner_of_slug slug with
       | Some _ as o -> o
       | None -> find rest)
    | _ :: rest -> find rest
  in
  find tokens

(** Extract the top-level command and its first subcommand from a gh
    command string (the portion after "gh ").
    Flags (starting with '-') and their values are skipped when scanning
    for the subcommand, preventing bypass via flag insertion.
    Example: "pr view 123" -> (Some "pr", Some "view")
    Example: "workflow --repo o/r disable" -> (Some "workflow", Some "disable") *)
let extract_gh_command_pair cmd =
  let parts =
    String.split_on_char ' ' (String.trim cmd)
    |> List.filter (fun s -> s <> "")
  in
  match parts with
  | [] -> (None, None)
  | [ x ] -> (Some x, None)
  | x :: rest ->
    let rec find_subcmd = function
      | [] -> None
      | tok :: tl ->
        if String.length tok > 0 && tok.[0] = '-' then
          if String.contains tok '=' then find_subcmd tl
          else (match tl with _ :: rest' -> find_subcmd rest' | [] -> None)
        else Some tok
    in
    (Some x, find_subcmd rest)

(** Validate a gh CLI command string for safety.
    Checks in order:
      (1) shell metacharacters,
      (2) top-level command allowlist,
      (3) blocked (command, subcommand) operation pairs,
      (4) [--repo OWNER/NAME] owner against [allowed_orgs] (if non-empty).

    Check 4 is skipped when [allowed_orgs] is [] (policy not configured)
    or when the command carries no [--repo] flag (gh falls back to
    cwd's origin, which is already gated at clone time).

    [cmd] is the portion after "gh ", e.g. "pr view 123". *)
let validate_gh_command ?(allowed_orgs = []) cmd =
  let trimmed = String.trim cmd in
  if trimmed = "" then Error "gh command must not be empty"
  else if contains_forbidden_shell_chars trimmed then
    Error
      "Blocked: chaining/redirect in gh command. Use a single subcommand. \
       Good: cmd='pr list --state open'. Bad: cmd='pr list && echo done'."
  else
    match extract_gh_command_pair trimmed with
    | (None, _) -> Error "gh command must not be empty"
    | (Some command, subcmd) ->
      let command = String.lowercase_ascii command in
      if not (List.mem command gh_allowed_commands) then
        Error
          (Printf.sprintf
             "gh command blocked: '%s' is not in the approved command list"
             command)
      else
        let sub =
          Option.value ~default:"" subcmd |> String.lowercase_ascii
        in
        if List.exists (fun (c, s) -> c = command && s = sub)
             gh_blocked_operations
        then
          Error
            (Printf.sprintf "gh %s %s is blocked for safety" command sub)
        else
          match allowed_orgs, extract_gh_repo_owner trimmed with
          | [], _ | _, None -> Ok ()
          | orgs, Some owner when List.mem owner orgs -> Ok ()
          | orgs, Some owner ->
            Error
              (Printf.sprintf
                 "gh --repo owner '%s' not in allowed_orgs [%s]. \
                  Drop --repo to use the current repo, or use an allowed org."
                 owner
                 (String.concat ", " orgs))

(** Known destructive API endpoint patterns.
    Each pattern is checked as a substring of the full command.
    Covers merge, state-closing, and branch-merge endpoints. *)
let gh_api_destructive_patterns =
  [ "/merge"; "/merges";
    "state=closed"; "state=\"closed\""; "state='closed'" ]

(** Legacy alias. Callers that need the R1 workflow-mutation names
    (mergepullrequest, closepullrequest, closeissue) add them locally;
    the R2 set is [gh_graphql_r2_mutations]. *)
let gh_graphql_destructive_mutations =
  gh_graphql_r2_mutations
  @ [ "mergepullrequest"; "closepullrequest"; "closeissue" ]

(** Check if a gh API command uses or implies a non-GET HTTP method.
    Returns [true] for explicit mutating methods (-X POST, --method PATCH,
    etc.) and for implicit POST via field flags (-f, -F, --field,
    --raw-field), matching gh CLI behavior where field flags cause an
    automatic POST. Handles both "--method POST" and "--method=POST". *)
let has_implicit_post_flags parts =
  let rec check = function
    | [] -> false
    | tok :: rest ->
      let tok_lower = String.lowercase_ascii tok in
      if tok = "-f" || tok = "-F" || tok = "--field" || tok = "--raw-field"
         || String.length tok_lower > 3 && String.sub tok_lower 0 3 = "-f="
         || String.length tok_lower > 8 && String.sub tok_lower 0 8 = "--field="
         || String.length tok_lower > 12 && String.sub tok_lower 0 12 = "--raw-field="
      then true
      else check rest
  in
  check parts

let has_mutating_http_method parts =
  let cmd = String.concat " " parts in
  let m = String.lowercase_ascii (extract_gh_api_method cmd) in
  (m = "post" || m = "put" || m = "patch" || m = "delete")
  || has_implicit_post_flags parts

(** Classify a gh command string by state reversibility.
    The command is the portion after "gh " — a normalized form
    without the leading "gh" literal.

    Precedence (first match wins):
      1. top command + subcommand in [gh_irreversible_ops] → R2
      2. [api] with [--method DELETE] or a destructive graphql
         mutation → R2
      3. [api] with --method POST/PUT/PATCH, or implicit POST via
         [-f]/[-F]/[--field]/[--raw-field] (gh auto-converts field
         flags to POST) → R1
      4. top command + subcommand in [gh_reversible_mutations] → R1
      5. anything else → R0 (read-only default) *)
let classify_gh_reversibility cmd =
  match extract_gh_command_pair cmd with
  | (None, _) -> R0_Read
  | (Some command, subcmd_opt) ->
    let command = String.lowercase_ascii command in
    let sub =
      Option.value ~default:"" subcmd_opt |> String.lowercase_ascii
    in
    let in_table table =
      List.exists
        (fun (c, subs) -> c = command && List.mem sub subs)
        table
    in
    if in_table gh_irreversible_ops then R2_Irreversible
    else if command = "api" then begin
      let method_ = extract_gh_api_method cmd in
      let parts =
        String.split_on_char ' ' (String.trim cmd)
        |> List.filter (fun s -> s <> "")
      in
      if method_ = "DELETE" then R2_Irreversible
      else if gh_api_graphql_is_destructive cmd then R2_Irreversible
      else if List.mem method_ ["POST"; "PUT"; "PATCH"] then R1_Reversible
      else if has_mutating_http_method parts then R1_Reversible
      else R0_Read
    end
    else if in_table gh_reversible_mutations then R1_Reversible
    else R0_Read

(** Suggested next-action hint for a rejected R2 command.
    Returned in the gate response so small LLMs can self-recover
    without a second operator turn. Conservative: only returns a hint
    when the mapping is obvious; otherwise None → caller falls back
    to a generic message. *)
let structured_tool_hint_for_r2 cmd =
  match extract_gh_command_pair cmd with
  | (Some "repo", Some ("delete" | "archive" | "transfer" | "rename")) ->
    Some "Use an operator-approved path: open a board post describing \
          the intent and wait for operator action. No keeper tool \
          performs repo-level destructive ops."
  | (Some "release", Some "delete") ->
    Some "Open a board post with release tag + reason. Release deletion \
          requires operator approval."
  | (Some "secret", _) | (Some "ssh-key", _) | (Some "auth", _) ->
    Some "Credential operations are operator-only. Do not attempt via \
          any keeper tool."
  | (Some "api", _) ->
    Some "Destructive gh api calls (DELETE or graphql mutation \
          delete*/remove*/transfer*) are blocked. Use pr/issue \
          subcommands for R1 mutations, or open a board post."
  | _ ->
    None

(** Filter out flag-like tokens, keeping only positional args.
    Handles boolean flag bypass (e.g. "workflow -q delete"). *)
let positional_tokens parts =
  List.filter (fun s -> String.length s = 0 || s.[0] <> '-') parts

(** Shared tokenizer for destructive-operation checks. *)
let gh_op_parts cmd =
  String.split_on_char ' ' (String.trim cmd)
  |> List.filter (fun s -> s <> "")
  |> List.map String.lowercase_ascii

let has_positional_subcmd subcmds rest =
  let positionals = positional_tokens rest in
  List.exists (fun s -> List.mem s subcmds) positionals

(** Check if a gh command is a normal workflow mutation (merge, close).
    These are legitimate for coding-preset keepers but should still be
    gated for lower-privilege presets. *)
let is_gh_workflow_operation cmd =
  let parts = gh_op_parts cmd in
  match parts with
  | "pr" :: rest -> has_positional_subcmd [ "merge"; "close" ] rest
  | "issue" :: rest -> has_positional_subcmd [ "close" ] rest
  | "project" :: rest -> has_positional_subcmd [ "close" ] rest
  | "api" :: _ ->
    let joined = String.concat " " parts in
    has_mutating_http_method parts
    && List.exists (fun pat -> contains_substring joined pat)
         [ "/merge"; "/merges"; "state=closed"; "state=\"closed\""; "state='closed'" ]
  | _ -> false

(** Check if a gh command is specifically [gh pr merge]. *)
let is_gh_pr_merge cmd =
  let parts = gh_op_parts cmd in
  match parts with
  | "pr" :: rest -> has_positional_subcmd [ "merge" ] rest
  | _ -> false

let gh_raw_parts cmd =
  String.split_on_char ' ' (String.trim cmd)
  |> List.filter (fun s -> s <> "")

let gh_option_takes_value tok =
  let tok = String.lowercase_ascii tok in
  not (contains_substring tok "=")
  && List.mem tok
       [ "-r"; "--repo";
         "-b"; "--body";
         "-f"; "--body-file";
         "-t"; "--subject";
         "--match-head-commit";
         "--author-email" ]

(** Return the explicit target passed to [gh pr merge], if any.
    Supports numeric PR ids, branch names, and PR URLs. Returns [None]
    when the merge command targets the current branch's PR. *)
let gh_pr_merge_target cmd =
  let raw_parts = gh_raw_parts cmd in
  let lower_parts = List.map String.lowercase_ascii raw_parts in
  let rec drop_until_merge raw lower =
    match raw, lower with
    | _raw_hd :: raw_tl, lower_hd :: lower_tl ->
        if lower_hd = "merge" then Some (raw_tl, lower_tl)
        else drop_until_merge raw_tl lower_tl
    | _ -> None
  in
  let rec find_target raw lower =
    match raw, lower with
    | [], [] -> None
    | raw_hd :: raw_tl, lower_hd :: lower_tl ->
        if String.length lower_hd > 0 && lower_hd.[0] = '-' then
          if gh_option_takes_value lower_hd then
            (match raw_tl, lower_tl with
             | _value :: raw_rest, _value_lower :: lower_rest ->
                 find_target raw_rest lower_rest
             | _ -> None)
          else
            find_target raw_tl lower_tl
        else
          Some raw_hd
    | _ -> None
  in
  match lower_parts with
  | "pr" :: _ -> (
      match drop_until_merge raw_parts lower_parts with
      | Some (raw_after_merge, lower_after_merge) ->
          find_target raw_after_merge lower_after_merge
      | None -> None)
  | _ -> None

(** Check if a gh command is a dangerous irreversible operation (delete,
    archive, transfer). Always gated regardless of preset. *)
let is_gh_dangerous_operation cmd =
  let parts = gh_op_parts cmd in
  match parts with
  | "issue" :: rest -> has_positional_subcmd [ "delete"; "transfer" ] rest
  | "release" :: rest -> has_positional_subcmd [ "delete" ] rest
  | "repo" :: rest -> has_positional_subcmd [ "archive"; "rename" ] rest
  | "label" :: rest -> has_positional_subcmd [ "delete" ] rest
  | "cache" :: rest -> has_positional_subcmd [ "delete" ] rest
  | "project" :: rest -> has_positional_subcmd [ "delete" ] rest
  | "workflow" :: rest -> has_positional_subcmd [ "delete" ] rest
  | "ruleset" :: _ -> false
  | "api" :: _ ->
    let joined = String.concat " " parts in
    List.mem "delete" parts
    || (List.mem "graphql" parts
        && List.exists (fun m -> contains_substring joined m)
             gh_graphql_destructive_mutations)
  | _ -> false

(** Combined check: returns [true] for any destructive mutation.
    Use [is_gh_dangerous_operation] for always-gated ops, or
    [is_gh_workflow_operation] for preset-dependent gating. *)
let is_gh_destructive_operation cmd =
  is_gh_workflow_operation cmd || is_gh_dangerous_operation cmd

(* --- Recursive mkdir --- *)

let mkdir_p path _perm =
  Fs_compat.mkdir_p path

type tool_exec_observer =
  tool_name:string -> success:bool -> duration_ms:int -> unit

(* --- Tool implementations --- *)

(** [file_read] byte cap. Reads longer than this are truncated to prevent
    context overflow. SSOT for the limit, its display label, and the
    tool description shown to agents. *)
let file_read_max_bytes = 100_000
let file_read_max_label = "100KB"

let file_read_description =
  Printf.sprintf
    "Read file contents by absolute path. Returns file text. \
     Use shell_exec with 'ls' instead if you need directory listing. \
     Maximum %s per read to prevent context overflow."
    file_read_max_label

let make_file_read ?workdir ?on_exec () =
  Agent_sdk.Tool.create
    ~name:"file_read"
    ~description:file_read_description
    ~parameters:[
      { name = "path";
        description = "Absolute file path to read";
        param_type = Agent_sdk.Types.String; required = true };
    ]
    (fun input ->
       match Worker_tool_input.extract_string "path" input with
       | Error e ->
         Error { Agent_sdk.Types.message = e; recoverable = false }
       | Ok path ->
         let started = Time_compat.now () in
         let resolved_path = resolve_path ?base_dir:workdir path in
         if not (validate_path ?workdir path) then
           let err =
             Printf.sprintf "Path blocked: %s (outside allowed directories)" path
           in
           let duration_ms =
             int_of_float ((Time_compat.now () -. started) *. 1000.0)
           in
           Option.iter
             (fun f -> f ~tool_name:"file_read" ~success:false ~duration_ms)
             on_exec;
           Error { Agent_sdk.Types.message = err; recoverable = false }
         else
           try
             let content = In_channel.with_open_text resolved_path In_channel.input_all in
             let duration_ms =
               int_of_float ((Time_compat.now () -. started) *. 1000.0)
             in
             Option.iter
               (fun f -> f ~tool_name:"file_read" ~success:true ~duration_ms)
               on_exec;
             if String.length content > file_read_max_bytes then
               Ok { Agent_sdk.Types.content =
                 String.sub content 0 file_read_max_bytes
                 ^ Printf.sprintf "\n[TRUNCATED at %s]" file_read_max_label }
             else Ok { Agent_sdk.Types.content = content }
           with Sys_error msg ->
             let duration_ms =
               int_of_float ((Time_compat.now () -. started) *. 1000.0)
             in
             Option.iter
               (fun f -> f ~tool_name:"file_read" ~success:false ~duration_ms)
               on_exec;
             Error { Agent_sdk.Types.message =
               Printf.sprintf "Cannot read: %s" msg; recoverable = false })

let make_file_write ?workdir ?on_exec () =
  Agent_sdk.Tool.create
    ~name:"file_write"
    ~description:"Write content to a file by absolute path. Creates the file \
      if it doesn't exist, overwrites if it does. Creates parent directories. \
      Use file_read first to check existing content before overwriting."
    ~parameters:[
      { name = "path";
        description = "Absolute file path to write";
        param_type = Agent_sdk.Types.String; required = true };
      { name = "content";
        description = "Content to write to the file";
        param_type = Agent_sdk.Types.String; required = true };
    ]
    (fun input ->
       match Worker_tool_input.extract_string "path" input,
             Worker_tool_input.extract_string "content" input with
       | Error e, _ | _, Error e ->
         Error { Agent_sdk.Types.message = e; recoverable = false }
       | Ok path, Ok content ->
         let started = Time_compat.now () in
         let resolved_path = resolve_path ?base_dir:workdir path in
         if not (validate_path ?workdir path) then
           let err =
             Printf.sprintf "Path blocked: %s (outside allowed directories)" path
           in
           let duration_ms =
             int_of_float ((Time_compat.now () -. started) *. 1000.0)
           in
           Option.iter
             (fun f -> f ~tool_name:"file_write" ~success:false ~duration_ms)
             on_exec;
           Error { Agent_sdk.Types.message = err; recoverable = false }
         else
           try
             mkdir_p (Filename.dirname resolved_path) 0o755;
             Out_channel.with_open_text resolved_path
               (fun oc -> Out_channel.output_string oc content);
             let duration_ms =
               int_of_float ((Time_compat.now () -. started) *. 1000.0)
             in
             Option.iter
               (fun f -> f ~tool_name:"file_write" ~success:true ~duration_ms)
               on_exec;
             Ok { Agent_sdk.Types.content =
               Printf.sprintf "Written %d bytes to %s"
                 (String.length content) resolved_path }
           with Sys_error msg ->
             let duration_ms =
               int_of_float ((Time_compat.now () -. started) *. 1000.0)
             in
             Option.iter
               (fun f -> f ~tool_name:"file_write" ~success:false ~duration_ms)
               on_exec;
             Error { Agent_sdk.Types.message =
               Printf.sprintf "Cannot write: %s" msg; recoverable = false })

(* --- Attribution envelope conversion (Layer 1) ---
   Shell command validation is a Det policy gate. The 7 block_reason
   variants map uniformly to Policy_failed (no transition involved —
   this is a pre-execution allow/deny check).

   Defined before [make_shell_exec_with_allowlist] so the tool's
   validation callsite can record the attribution without forward
   referencing. *)

let block_reason_tag = function
  | Empty_command -> "empty_command"
  | Chain_or_redirect -> "chain_or_redirect"
  | Injection -> "injection"
  | Process_substitution -> "process_substitution"
  | Unsafe_redirect -> "unsafe_redirect"
  | Pipes_not_allowed -> "pipes_not_allowed"
  | Command_not_allowed _ -> "command_not_allowed"

let attribution_of_validation ~cmd
    (result : (unit, block_reason) result) : Attribution.t =
  match result with
  | Ok () ->
    let evidence : Yojson.Safe.t =
      `Assoc [ ("cmd", `String cmd) ]
    in
    Attribution.passed ~origin:Det ~gate:"worker_dev_tools" ~evidence
  | Error br ->
    let command_name =
      match br with
      | Command_not_allowed name -> Some name
      | _ -> None
    in
    let evidence : Yojson.Safe.t =
      `Assoc
        ([
           ("cmd", `String cmd);
           ("block_reason", `String (block_reason_tag br));
         ]
         @
         match command_name with
         | Some n -> [ ("command_name", `String n) ]
         | None -> [])
    in
    Attribution.policy_failed ~origin:Det ~gate:"worker_dev_tools"
      ~evidence ~reason:(block_reason_to_string br)

let make_shell_exec_with_allowlist ~workdir ~on_exec ~proc_mgr ~clock ~allowed_commands
    ~description () =
  Agent_sdk.Tool.create
    ~name:"shell_exec"
    ~description
    ~parameters:[
      { name = "command";
        description = "Shell command to execute";
        param_type = Agent_sdk.Types.String; required = true };
      { name = "timeout_s";
        description = "Timeout in seconds (default 30, max 120)";
        param_type = Agent_sdk.Types.Number; required = false };
    ]
    (fun input ->
       match Worker_tool_input.extract_string "command" input with
       | Error e ->
         Error { Agent_sdk.Types.message = e; recoverable = false }
       | Ok command ->
         let validation =
           validate_command_with_allowlist ~allowed_commands command
         in
         Dashboard_attribution.record
           (attribution_of_validation ~cmd:command validation);
         (match validation with
          | Error reason ->
            Error { Agent_sdk.Types.message = block_reason_to_string reason; recoverable = false }
          | Ok () ->
           let timeout =
             Worker_tool_input.extract_float "timeout_s" input
             |> Option.value ~default:30.0
             |> Float.min 120.0
          in
           try
             let started = Time_compat.now () in
             let buf = Buffer.create 1024 in
             let wrapped_command =
               match workdir with
               | Some dir when String.trim dir <> "" ->
                   Printf.sprintf "cd %s && %s" (Filename.quote dir) command
               | _ -> command
             in
             let result =
               try
                 let status, output =
                   Eio.Time.with_timeout_exn clock timeout (fun () ->
                     Eio.Switch.run @@ fun sw ->
                     let stdout_r, stdout_w = Eio.Process.pipe ~sw proc_mgr in
                     let proc = Eio.Process.spawn ~sw proc_mgr
                       ~stdout:stdout_w
                       ["sh"; "-c"; wrapped_command ^ " 2>&1"] in
                     Eio.Flow.close stdout_w;
                     (try
                        Eio.Flow.copy stdout_r (Eio.Flow.buffer_sink buf);
                        Eio.Flow.close stdout_r
                      with Eio.Cancel.Cancelled _ as e ->
                        (try Eio.Flow.close stdout_r with _ -> ());
                        raise e);
                     let status = Eio.Process.await proc in
                     (status, Buffer.contents buf))
                 in
                 match status with
                 | `Exited 0 ->
                   Ok { Agent_sdk.Types.content = output }
                 | `Exited code ->
                   Error { Agent_sdk.Types.message =
                     Printf.sprintf "Exit code %d:\n%s" code output;
                     recoverable = false }
                 | `Signaled sig_num ->
                   Error { Agent_sdk.Types.message =
                     Printf.sprintf "Killed by signal %d:\n%s" sig_num output;
                     recoverable = sig_num = Sys.sigterm }
               with
               | Eio.Time.Timeout ->
                 let output = Buffer.contents buf in
                 Error { Agent_sdk.Types.message =
                   Printf.sprintf "Timeout after %.0fs: %s\n%s" timeout command
                     output;
                   recoverable = true }
             in
             let duration_ms =
               int_of_float ((Time_compat.now () -. started) *. 1000.0)
             in
             Option.iter
               (fun f ->
                 f ~tool_name:"shell_exec"
                   ~success:(Result.is_ok result) ~duration_ms)
               on_exec;
             result
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             let duration_ms = 0 in
             Option.iter
               (fun f -> f ~tool_name:"shell_exec" ~success:false ~duration_ms)
               on_exec;
             Error { Agent_sdk.Types.message =
               Printf.sprintf "Command failed: %s" (Printexc.to_string exn);
               recoverable = false }))

let make_shell_exec ~workdir ~on_exec ~proc_mgr ~clock =
  make_shell_exec_with_allowlist ~workdir ~on_exec ~proc_mgr ~clock
    ~allowed_commands:dev_allowed_commands
    ~description:
      "Execute a shell command and return stdout+stderr. \
       Timeout: 30s default, max 120s. \
       Use for: running tests, git commands, build tools, directory listing. \
       Unlike file_read (single file), this handles approved CLI operations. \
       Commands run in /bin/sh but shell control syntax is rejected."
    ()

let make_shell_exec_readonly ~workdir ~on_exec ~proc_mgr ~clock =
  make_shell_exec_with_allowlist ~workdir ~on_exec ~proc_mgr ~clock
    ~allowed_commands:readonly_allowed_commands
    ~description:
      "Execute a read-only shell command and return stdout+stderr. \
       Timeout: 30s default, max 120s. \
       Use for search, inspection, and verification only. \
       Write-oriented commands are intentionally excluded."
    ()

(** Create dev tools that close over Eio capabilities.
    Returns [file_read; file_write; shell_exec]. *)
let make_tools ~proc_mgr ~clock ?workdir ?on_exec () : Agent_sdk.Tool.t list =
  [ make_file_read ?workdir ?on_exec ();
    make_file_write ?workdir ?on_exec ();
    make_shell_exec ~workdir ~on_exec ~proc_mgr ~clock ]

let make_readonly_tools ~proc_mgr ~clock ?workdir ?on_exec () : Agent_sdk.Tool.t list =
  [ make_file_read ?workdir ?on_exec ();
    make_shell_exec_readonly ~workdir ~on_exec ~proc_mgr ~clock ]

