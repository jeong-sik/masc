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

let validate_command_with_allowlist ~allowed_commands cmd =
  let trimmed = String.trim cmd in
  if trimmed = "" then Error "command must not be empty"
  else if contains_forbidden_shell_chars trimmed then
    Error
      "Blocked: chaining (&&/||/;) and redirects (|/>) are not allowed. \
       Run ONE command per call. Example: cmd='dune build'. \
       Do NOT use: cmd='cd x && dune build' or cmd='rg foo | wc -l'. \
       To write files, use keeper_fs_edit."
  else
    match extract_command_name trimmed with
    | None -> Error "command must not be empty"
    | Some name when List.mem name allowed_commands -> Ok ()
    | Some name ->
      Error
        (Printf.sprintf
           "Command blocked: '%s' is not allowed. Allowed: dune, git, rg, ls, cat, make, node, npm, etc. \
            For file operations use keeper_fs_read or keeper_fs_edit."
           name)

let validate_command cmd =
  validate_command_with_allowlist ~allowed_commands:dev_allowed_commands cmd

(** Relaxed command validation for Coding/Full preset keepers.
    Allows pipes and redirects; validates every command in the pipeline
    against [dev_allowed_commands]. *)
let validate_command_coding cmd =
  let trimmed = String.trim cmd in
  if trimmed = "" then Error "command must not be empty"
  else if contains_forbidden_shell_chars_coding trimmed then
    Error "Shell injection syntax (;, &&, standalone &, `, $) not allowed."
  else if has_process_substitution trimmed then
    Error "Process substitution (<(...) or >(...)) is not allowed."
  else if has_unsafe_redirection trimmed then
    Error "File redirects are not allowed. Only fd redirects like 2>&1 are permitted."
  else
    match split_pipeline_segments trimmed with
    | Error _ as err -> err
    | Ok segments ->
      let rec validate_segments = function
        | [] -> Ok ()
        | segment :: rest -> (
            match extract_command_name segment with
            | None -> Error "command must not be empty"
            | Some name when List.mem name dev_allowed_commands ->
              validate_segments rest
            | Some name ->
              Error
                (Printf.sprintf
                   "Command blocked: '%s' is not allowed. Allowed: dune, git, rg, ls, cat, make, node, npm, etc."
                   name))
      in
      validate_segments segments

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

(** Detect git branch-switch commands that would mutate the main repo's HEAD.
    keeper_bash runs in the repo root, so checkout/switch/branch mutations must
    be redirected to keeper_pr_workflow (playground clone).

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
  if String.length s <= max_len then s
  else String.sub s 0 max_len ^ "..."

(* --- gh CLI validation for keeper_github --- *)

(** Top-level gh CLI commands allowed for keeper_github.
    Commands not in this list are rejected at the allowlist gate. *)
let gh_allowed_commands =
  [
    "api"; "cache"; "gist"; "issue"; "label"; "pr"; "project";
    "release"; "repo"; "ruleset"; "run"; "search"; "status";
    "workflow";
  ]

(** Specific (command, subcommand) pairs that are always blocked
    regardless of allowlist. These are irreversible or catastrophic. *)
let gh_blocked_operations =
  [
    ("repo", "delete");
    ("gist", "delete");
    ("workflow", "disable");
  ]

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
    Checks: (1) shell metacharacters, (2) top-level command allowlist,
    (3) blocked operation pairs.
    [cmd] is the portion after "gh ", e.g. "pr view 123". *)
let validate_gh_command cmd =
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
        else Ok ()

(** Known destructive API endpoint patterns.
    Each pattern is checked as a substring of the full command.
    Covers merge, state-closing, and branch-merge endpoints. *)
let gh_api_destructive_patterns =
  [ "/merge"; "/merges";
    "state=closed"; "state=\"closed\""; "state='closed'" ]

(** Known destructive GraphQL mutation names (lowercase).
    Used to detect bypass via "gh api graphql -f query='mutation ...'". *)
let gh_graphql_destructive_mutations =
  [ "mergepullrequest"; "closepullrequest"; "closeissue";
    "deleteissue"; "deleteref"; "deletebranch";
    "deletebranchprotectionrule"; "deleteproject" ]

(** Check if a gh API command uses or implies a non-GET HTTP method.
    Returns [true] for explicit mutating methods (-X POST, --method PATCH,
    etc.) and for implicit POST via field flags (-f, -F, --field,
    --raw-field), matching gh CLI behavior where field flags cause an
    automatic POST. Handles both "--method POST" and "--method=POST". *)
let has_mutating_http_method parts =
  let is_mutating m =
    let m = String.lowercase_ascii m in
    m = "post" || m = "put" || m = "patch" || m = "delete"
  in
  let rec check = function
    | [] -> false
    | tok :: rest when tok = "-x" || tok = "--method" ->
      (match rest with m :: _ -> is_mutating m | [] -> false)
    | tok :: rest ->
      if String.length tok >= 10
         && String.lowercase_ascii (String.sub tok 0 9) = "--method="
      then is_mutating (String.sub tok 9 (String.length tok - 9))
      else if String.length tok > 3
              && String.lowercase_ascii (String.sub tok 0 3) = "-x="
      then is_mutating (String.sub tok 3 (String.length tok - 3))
      else
        let tok_lower = String.lowercase_ascii tok in
        if tok = "-f" || tok = "-F" || tok = "--field" || tok = "--raw-field"
           || String.length tok_lower > 3 && String.sub tok_lower 0 3 = "-f="
           || String.length tok_lower > 8 && String.sub tok_lower 0 8 = "--field="
           || String.length tok_lower > 12 && String.sub tok_lower 0 12 = "--raw-field="
        then true
        else check rest
  in
  check parts

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

let make_file_read ?workdir ?on_exec () =
  Agent_sdk.Tool.create
    ~name:"file_read"
    ~description:"Read file contents by absolute path. Returns file text. \
      Use shell_exec with 'ls' instead if you need directory listing. \
      Maximum 100KB per read to prevent context overflow."
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
             if String.length content > 100_000 then
               Ok { Agent_sdk.Types.content =
                 String.sub content 0 100_000 ^ "\n[TRUNCATED at 100KB]" }
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
         (match validate_command_with_allowlist ~allowed_commands command with
          | Error e ->
            Error { Agent_sdk.Types.message = e; recoverable = false }
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
