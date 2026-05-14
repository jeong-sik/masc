(** Coord Worktree - Git Worktree Integration for Agent Isolation

    MASC v2 feature: Each agent works in isolated git worktrees
    to prevent file conflicts during parallel work.

    Extracted from room.ml for modularity.
*)

open Masc_domain
open Coord_utils

let exec_gate_raw_source argv =
  String.concat " " (List.map Filename.quote argv)

(** Run argv and get lines (Eio-native, no shell) *)
let run_argv_lines argv =
  Masc_exec.Exec_gate.run_argv
    ~actor:(Masc_exec.Agent_id.of_string "coord/worktree")
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"coord_worktree argv"
    ~timeout_sec:Env_config_runtime.Coord_git.local_op_timeout_sec
    argv
  |> String.split_on_char '\n'
  |> List.filter (fun s -> s <> "")

(** Run argv and get process status + combined output.
    [timeout_sec] defaults to
    {!Env_config_runtime.Coord_git.local_op_timeout_sec}, the short
    window appropriate for local-only git operations (status, branch,
    rev-parse).  Network-bound operations like [git fetch origin]
    should pass an explicit longer budget — see
    {!Env_config_core.git_fetch_timeout_sec}. *)
let run_argv_with_status
    ?(timeout_sec = Env_config_runtime.Coord_git.local_op_timeout_sec)
    argv =
  Masc_exec.Exec_gate.run_argv_with_status
    ~actor:(Masc_exec.Agent_id.of_string "coord/worktree")
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"coord_worktree argv"
    ~timeout_sec
    argv

(** Run argv and get exit code (Eio-native, no shell) *)
let run_argv_exit ?timeout_sec argv =
  match run_argv_with_status ?timeout_sec argv with
  | Unix.WEXITED n, _ -> n
  | Unix.WSIGNALED _, _ -> 128
  | Unix.WSTOPPED _, _ -> 128

let first_nonempty_line output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.find_opt (fun s -> s <> "")

let policy_string_array_of_line ~key line =
  let trimmed = String.trim line in
  let prefix = key ^ " =" in
  if not (String.starts_with ~prefix trimmed) then
    None
  else
    let raw =
      String.sub trimmed (String.length prefix)
        (String.length trimmed - String.length prefix)
      |> String.trim
    in
    if String.length raw < 2 || raw.[0] <> '[' || raw.[String.length raw - 1] <> ']'
    then
      Some []
    else
      let body = String.sub raw 1 (String.length raw - 2) in
      let items =
        body
        |> String.split_on_char ','
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
        |> List.filter_map (fun token ->
             let len = String.length token in
             if len >= 2 && token.[0] = '"' && token.[len - 1] = '"' then
               Some (String.sub token 1 (len - 2) |> String.lowercase_ascii)
             else
               None)
      in
      Some items

let git_clone_policy_paths ~base_path =
  let canonical =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path |> fun d -> Filename.concat d "config")
      "tool_policy.toml"
  in
  let legacy = Filename.concat (Filename.concat base_path "config") "tool_policy.toml" in
  canonical, legacy

let parse_git_clone_policy_content content =
  let rec loop in_git_clone allowed denied = function
    | [] -> allowed, denied
    | raw_line :: rest ->
        let line = String.trim raw_line in
        if line = "" || String.starts_with ~prefix:"#" line then
          loop in_git_clone allowed denied rest
        else if String.length line >= 2 && line.[0] = '[' && line.[String.length line - 1] = ']'
        then
          loop (String.equal line "[git_clone]") allowed denied rest
        else if not in_git_clone then
          loop in_git_clone allowed denied rest
        else
          let allowed =
            match policy_string_array_of_line ~key:"allowed_orgs" line with
            | Some items -> items
            | None -> allowed
          in
          let denied =
            match policy_string_array_of_line ~key:"denied_repos" line with
            | Some items -> items
            | None -> denied
          in
          loop in_git_clone allowed denied rest
  in
  loop false [] [] (String.split_on_char '\n' content)

let load_git_clone_policy_result ~base_path =
  let canonical, legacy = git_clone_policy_paths ~base_path in
  let read_or_empty p =
    match Safe_ops.read_file_safe p with
    | Error _ -> None
    | Ok content -> Some content
  in
  let content_opt =
    match read_or_empty canonical with
    | Some c -> Some c
    | None -> read_or_empty legacy
  in
  match content_opt with
  | None ->
      Error
        (Printf.sprintf
           "tool policy config not found at %s or %s"
           canonical legacy)
  | Some content -> Ok (parse_git_clone_policy_content content)

(* SSOT path resolution: canonical config root is [<base_path>/.masc/config/]
   (same primitive Config_dir_resolver.path_from_local_masc uses via
   Common.masc_dir_from_base_path). The legacy [<base_path>/config/] form is
   retained as a secondary lookup for older deployments. Reading order:
   canonical first, legacy fallback only when canonical is absent. *)
let load_git_clone_policy ~base_path =
  match load_git_clone_policy_result ~base_path with
  | Ok policy -> policy
  | Error msg ->
      Log.Coord.routine "git_clone_policy: using defaults (%s)" msg;
      [], []

let valid_github_org_slug org =
  let valid_org_char c =
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-'
  in
  org <> "" && Seq.for_all valid_org_char (String.to_seq org)

let extract_github_org_repo url =
  let lc = String.lowercase_ascii (String.trim url) in
  let prefixes =
    [
      "https://github.com/";
      "git@github.com:";
      "ssh://git@github.com/";
    ]
  in
  let after_prefix =
    List.find_map
      (fun prefix ->
         if String.starts_with ~prefix lc then
           Some
             (String.sub lc (String.length prefix)
                (String.length lc - String.length prefix))
         else None)
      prefixes
  in
  match after_prefix with
  | None -> None
  | Some rest ->
      let rest =
        if String.ends_with ~suffix:"/" rest then
          String.sub rest 0 (String.length rest - 1)
        else rest
      in
      let stripped =
        if String.ends_with ~suffix:".git" rest then
          String.sub rest 0 (String.length rest - 4)
        else rest
      in
      match String.split_on_char '/' stripped with
      | [ org; repo ] when valid_github_org_slug org && repo <> "" ->
          Some (org ^ "/" ^ repo)
      | _ -> None

let extract_github_org url =
  match extract_github_org_repo url with
  | Some org_repo -> (
      match String.split_on_char '/' org_repo with
      | org :: _ -> Some org
      | [] -> None)
  | None -> None

let normalize_github_clone_url url =
  match extract_github_org_repo url with
  | Some org_repo -> "https://github.com/" ^ org_repo ^ ".git"
  | None -> url

let local_clone_origin_path url =
  let trimmed = String.trim url in
  let file_prefix = "file://" in
  let path =
    if String.starts_with ~prefix:file_prefix trimmed then
      Some
        (String.sub trimmed (String.length file_prefix)
           (String.length trimmed - String.length file_prefix))
    else if trimmed <> "" && not (Filename.is_relative trimmed) then
      Some trimmed
    else
      None
  in
  match path with
  | Some p when p <> "" -> Some p
  | _ -> None

let realpath_opt path =
  try Some (Unix.realpath path) with
  | Unix.Unix_error _ | Sys_error _ -> None

let path_is_under ~root path =
  match realpath_opt root, realpath_opt path with
  | Some root_real, Some path_real ->
      let root_prefix =
        if String.ends_with ~suffix:"/" root_real then root_real
        else root_real ^ "/"
      in
      String.equal root_real path_real
      || String.starts_with ~prefix:root_prefix path_real
  | _ -> false

let validate_local_clone_origin ~base_path url =
  match local_clone_origin_path url with
  | None -> None
  | Some path ->
      Some
        (if path_is_under ~root:base_path path then
           Ok ()
         else
           Error
             (Printf.sprintf
                "Local clone origin is outside base_path: origin=%s base_path=%s"
                path base_path))

let validate_clone_origin_url ~base_path url =
  match load_git_clone_policy_result ~base_path with
  | Error msg ->
      Error (Printf.sprintf "Git clone policy unavailable: %s" msg)
  | Ok (allowed_orgs, denied_repos) ->
      let allowed_lc = List.map String.lowercase_ascii allowed_orgs in
      let denied_lc = List.map String.lowercase_ascii denied_repos in
      match validate_local_clone_origin ~base_path url with
      | Some result -> result
      | None -> match extract_github_org_repo url with
      | None ->
          Error (Printf.sprintf "Cannot parse GitHub org/repo from URL: %s" url)
      | Some org_repo ->
          if List.mem org_repo denied_lc then
            Error (Printf.sprintf "Repository '%s' is in the denied list" org_repo)
          else
            match String.split_on_char '/' org_repo with
            | _org :: _ when allowed_lc = [] ->
                (* Explicit empty allowed_orgs means "any supported GitHub org",
                   still bounded by URL parsing and denied_repos. *)
                Ok ()
            | org :: _ when List.mem org allowed_lc -> Ok ()
            | org :: _ ->
                Error
                  (Printf.sprintf
                     "GitHub org '%s' not in allowed list: %s. Use the actual GitHub owner from the clone URL; do not infer an org from local workspace path segments."
                     org (String.concat ", " allowed_orgs))
            | [] ->
                Error (Printf.sprintf "Cannot parse GitHub org/repo from URL: %s" url)

(** Check if directory is a git repository - delegates to Coord_git *)
let is_git_repo config =
  Coord_git.is_git_repo ~base_path:config.base_path

(** Resolve the project root from config.base_path.
    If base_path ends with ".masc", use its parent; otherwise use base_path.
    Then walk parent directories until we find the owning repository root
    (.git directory). This keeps config.base_path as the anchor while still
    handling nested subdirectories and worktree roots (.git file).
    Inlined from Keeper_alerting_path to avoid room→keeper dependency. *)
let git_marker_kind path =
  match (try Some (Sys.is_directory path) with Sys_error _ -> None) with
  | Some true -> `Directory
  | Some false -> `File
  | None -> `Missing

let project_root config =
  let base = config.base_path in
  let candidate =
    if Filename.basename base = Common.masc_dirname then Filename.dirname base else base
  in
  let rec find_repo_root dir =
    let git_marker = Filename.concat dir ".git" in
    match git_marker_kind git_marker with
    | `Directory -> Some dir
    | `File | `Missing ->
        let parent = Filename.dirname dir in
        if String.equal parent dir then None else find_repo_root parent
  in
  match find_repo_root candidate with
  | Some root -> root
  | None -> candidate

let require_repository_root_with_git config =
  let root = project_root config in
  let git_marker = Filename.concat root ".git" in
  match git_marker_kind git_marker with
  | `Directory | `File ->
    Ok root
  | `Missing ->
    Error
      (System (System_error.IoError
         (Printf.sprintf
            "Worktree isolation requires repository root with .git: %s (current base path: %s)"
            root config.base_path)))

let ensure_worktree_path root worktree_name =
  let worktrees_dir = Filename.concat root ".worktrees" in
  let worktree_path = Filename.concat worktrees_dir worktree_name in
  if Filename.dirname worktree_path = worktrees_dir then
    Ok (worktree_path, worktrees_dir)
  else
    Error (System (System_error.IoError "Invalid worktree path: must be created under .worktrees/"))

let safe_file_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false

let safe_is_dir path =
  try Sys.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false

let safe_repo_name name =
  name <> "" && name <> "." && name <> ".."
  && not (String.contains name '/')
  && not (String.contains name '\\')
  && not (String.contains name '\x00')
  && String.for_all
       (fun c ->
         (c >= 'A' && c <= 'Z')
         || (c >= 'a' && c <= 'z')
         || (c >= '0' && c <= '9')
         || c = '-'
         || c = '_'
         || c = '.')
       name

(* Git worktree mutations include Eio subprocess calls; use Eio.Mutex so
   same-domain fibers serialize without blocking the scheduler. *)
let worktree_mutation_mutex = Eio.Mutex.create ()

let with_worktree_mutation_lock f =
  Eio.Mutex.use_rw ~protect:true worktree_mutation_mutex f

let is_git_clone candidate =
  safe_is_dir candidate
  &&
  match git_marker_kind (Filename.concat candidate ".git") with
  | `Directory | `File -> true
  | `Missing -> false

let same_realpath a b =
  try String.equal (Unix.realpath a) (Unix.realpath b) with
  | Unix.Unix_error _ -> String.equal a b

let is_usable_git_worktree path =
  safe_is_dir path
  &&
  match run_argv_with_status
          [ "git"; "-C"; path; "rev-parse"; "--show-toplevel" ]
  with
  | Unix.WEXITED 0, output -> (
      match first_nonempty_line output with
      | Some top -> same_realpath top path
      | None -> false)
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> false

let run_git_in_clone clone_path args =
  run_argv_with_status ([ "git"; "-C"; clone_path; "--no-optional-locks" ] @ args)

let trim_output_detail output =
  let detail = String.trim output in
  if detail = "" then "(no output)" else detail

let first_nul_field output =
  match String.index_opt output '\x00' with
  | Some idx when idx > 0 -> Some (String.sub output 0 idx)
  | Some _ -> None
  | None ->
      let trimmed = String.trim output in
      if trimmed = "" then None else Some trimmed

type sandbox_clone_state =
  | Ready
  | Needs_checkout of string
  | Broken_git of string

let inspect_sandbox_clone candidate =
  let inside_status, inside_output =
    run_git_in_clone candidate [ "rev-parse"; "--is-inside-work-tree" ]
  in
  if inside_status <> Unix.WEXITED 0 then
    Broken_git
      (Printf.sprintf "git rev-parse failed: %s"
         (trim_output_detail inside_output))
  else
    let top_status, top_output =
      run_git_in_clone candidate [ "rev-parse"; "--show-toplevel" ]
    in
    if top_status <> Unix.WEXITED 0 then
      Broken_git
        (Printf.sprintf "git rev-parse --show-toplevel failed: %s"
           (trim_output_detail top_output))
    else
      match first_nonempty_line top_output with
      | Some top ->
          if not (same_realpath top candidate) then
            Broken_git
              (Printf.sprintf
                 "git top-level mismatch: expected sandbox clone root %s but \
                  git resolved %s"
                 candidate top)
          else
            let tracked_status, tracked_output =
              run_git_in_clone candidate [ "ls-files"; "-z" ]
            in
            if tracked_status <> Unix.WEXITED 0 then
              Broken_git
                (Printf.sprintf "git ls-files failed: %s"
                   (trim_output_detail tracked_output))
            else
              (match first_nul_field tracked_output with
              | None -> Ready
              | Some relpath ->
                  if safe_file_exists (Filename.concat candidate relpath) then
                    Ready
                  else Needs_checkout relpath)
      | None ->
          Broken_git "git rev-parse --show-toplevel returned no path"

let restore_sandbox_clone_checkout candidate =
  let checkout_status, checkout_output =
    run_git_in_clone candidate [ "checkout"; "-f"; "HEAD"; "--"; "." ]
  in
  if checkout_status <> Unix.WEXITED 0 then
    Error
      (System (System_error.IoError
         (Printf.sprintf
            "sandbox_clone_checkout_restore_failed: could not restore tracked \
             files in %s: %s"
            candidate (trim_output_detail checkout_output))))
  else
    match inspect_sandbox_clone candidate with
    | Ready ->
        Ok
          (Some
             "Existing sandbox clone checkout was restored from HEAD before \
              worktree creation.")
    | Needs_checkout relpath ->
        Error
          (System (System_error.IoError
             (Printf.sprintf
                "sandbox_clone_checkout_restore_failed: %s is still missing \
                 tracked path %s after checkout."
                candidate relpath)))
    | Broken_git detail ->
        Error
          (System (System_error.IoError
             (Printf.sprintf
                "sandbox_clone_checkout_restore_failed: %s is still not a \
                 usable git clone after checkout: %s"
                candidate detail)))

let ensure_sandbox_clone_ready candidate =
  match inspect_sandbox_clone candidate with
  | Ready -> Ok None
  | Needs_checkout _ -> restore_sandbox_clone_checkout candidate
  | Broken_git detail ->
      Error
        (System (System_error.IoError
           (Printf.sprintf
              "sandbox_clone_invalid: %s has a .git marker but is not a usable git clone: %s"
              candidate detail)))

let keeper_toml_path ~config ~agent_name =
  let keeper_name = Playground_paths.sanitize_keeper_name agent_name in
  Filename.concat
    (Filename.concat
       (Filename.concat
          (masc_dir_from_base_path ~base_path:config.base_path)
          "config")
       "keepers")
    (keeper_name ^ ".toml")

let strip_inline_comment line =
  match String.index_opt line '#' with
  | Some idx -> String.sub line 0 idx
  | None -> line

let unquote value =
  let len = String.length value in
  if len >= 2 && value.[0] = '"' && value.[len - 1] = '"'
  then String.sub value 1 (len - 2)
  else value

let keeper_uses_docker_sandbox ~config ~agent_name =
  let path = keeper_toml_path ~config ~agent_name in
  if not (safe_file_exists path) then false
  else
    try
      let lines =
        Fs_compat.load_file path |> String.split_on_char '\n'
      in
      let rec loop in_keeper = function
        | [] -> false
        | raw_line :: rest ->
            let line =
              raw_line |> strip_inline_comment |> String.trim
            in
            if line = "" then loop in_keeper rest
            else if String.length line > 0 && line.[0] = '[' then
              loop (String.equal line "[keeper]") rest
            else if
              in_keeper
              && String.starts_with ~prefix:"sandbox_profile" line
            then
              let value =
                match String.index_opt line '=' with
                | None -> ""
                | Some idx ->
                    String.sub line (idx + 1) (String.length line - idx - 1)
                    |> String.trim
                    |> unquote
                    |> String.lowercase_ascii
              in
              String.equal value "docker"
            else
              loop in_keeper rest
      in
      loop false lines
    with Sys_error _ -> false

let repos_dir_of_keeper config agent_name =
  let safe_name = Playground_paths.sanitize_keeper_name agent_name in
  let repos_rel =
    if keeper_uses_docker_sandbox ~config ~agent_name then
      Printf.sprintf "%s/docker/%s/repos/"
        Playground_paths.all_playgrounds_prefix safe_name
    else
      Playground_paths.repos_path agent_name
  in
  Filename.concat config.base_path repos_rel

let strip_trailing_slashes path =
  let rec loop i =
    if i > 0 && path.[i - 1] = '/' then loop (i - 1) else i
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len

let suffix_under ~prefix path =
  let prefix = strip_trailing_slashes prefix in
  let path = strip_trailing_slashes path in
  if String.equal path prefix then Some ""
  else
    let prefix_with_sep = prefix ^ "/" in
    if String.starts_with ~prefix:prefix_with_sep path then
      Some
        (String.sub path (String.length prefix_with_sep)
           (String.length path - String.length prefix_with_sep))
    else None

let keeper_visible_worktree_path ~config ~agent_name ~host_path =
  if not (keeper_uses_docker_sandbox ~config ~agent_name) then host_path
  else
    let safe_name = Playground_paths.sanitize_keeper_name agent_name in
    let container_repos_dir =
      Filename.concat
        (Filename.concat
           Env_config_keeper.DockerPlayground.container_playground_root
           safe_name)
        "repos"
    in
    match suffix_under ~prefix:(repos_dir_of_keeper config agent_name) host_path with
    | Some "" -> container_repos_dir
    | Some suffix -> Filename.concat container_repos_dir suffix
    | None -> host_path

let worktree_next_step keeper_path =
  Printf.sprintf
    "Next: keeper_bash cwd=%S cmd=\"git status -sb\"; after edits, git \
     add/commit/push, then use keeper_pr_create draft=true."
    keeper_path

type repo_candidate = {
  name : string;
  path : string;
}

let trim_repo_token token =
  let is_edge = function
    | '`' | '\'' | '"' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>'
    | ',' | ';' | ':' | '!' | '?' | '.' -> true
    | _ -> false
  in
  let len = String.length token in
  let rec left i =
    if i >= len then len
    else if is_edge token.[i] then left (i + 1)
    else i
  in
  let rec right i =
    if i < 0 then -1
    else if is_edge token.[i] then right (i - 1)
    else i
  in
  let l = left 0 in
  let r = right (len - 1) in
  if r < l then "" else String.sub token l (r - l + 1)

let tokenize_repo_evidence text =
  let mapped =
    String.map
      (function
        | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '.'
          | '/') as c -> c
        | _ -> ' ')
      text
  in
  mapped
  |> String.split_on_char ' '
  |> List.map trim_repo_token
  |> List.filter (fun token -> token <> "")

(* Route to the SSOT helper rather than allocating String.sub on every
   step.  Keeps semantics aligned across modules (empty needle returns
   true). *)
let contains_substring = String_util.contains_substring

let task_repo_text (task : task) =
  let handoff_texts =
    match task.handoff_context with
    | None -> []
    | Some handoff ->
        [ Some handoff.summary
        ; handoff.reason
        ; handoff.next_step
        ; handoff.failure_mode
        ]
        |> List.filter_map Fun.id
  in
  String.concat "\n" (task.title :: task.description :: handoff_texts)

(* Reject any path-hint candidate whose components include a literal
   ".." segment.  Substring matching falsely flagged legitimate names
   like "..config.ts.bak" (filename containing ".."), and missed
   embedded segments such as "src/foo/../bar" only by accident.
   Splitting on '/' and checking segments is both more precise and
   the same definition the OS uses for parent-traversal. *)
let has_parent_segment token =
  String.split_on_char '/' token
  |> List.exists (fun seg -> String.equal seg "..")

let task_path_hints (task : task) =
  let text_paths =
    task_repo_text task
    |> tokenize_repo_evidence
    |> List.filter (fun token ->
           contains_substring token "/"
           && Filename.is_relative token
           && not (has_parent_segment token))
  in
  (task.files @ text_paths)
  |> List.map trim_repo_token
  |> List.filter (fun token ->
         token <> ""
         && Filename.is_relative token
         && not (has_parent_segment token))
  |> List.sort_uniq String.compare

let repo_candidates_in_dir repos_dir =
  if not (safe_is_dir repos_dir) then []
  else
    let entries =
      try Sys.readdir repos_dir |> Array.to_list with Sys_error _ -> []
    in
    entries
    |> List.filter safe_repo_name
    |> List.filter_map (fun name ->
           let path = Filename.concat repos_dir name in
           if is_git_clone path then Some { name; path } else None)
    |> List.sort (fun a b -> String.compare a.name b.name)

let repo_name_mentioned ~tokens repo_name =
  List.exists
    (fun token ->
       String.equal token repo_name
       || String.equal (Filename.basename token) repo_name)
    tokens

let task_by_id config task_id =
  let backlog = Coord_backlog.read_backlog config in
  List.find_opt (fun (task : task) -> String.equal task.id task_id)
    backlog.tasks

let max_path_hints = 20
let mention_score_value = 100
let file_score_weight = 25

let score_repo_candidate ~(task : task) ~tokens ~path_hints candidate =
  let mention_score =
    if repo_name_mentioned ~tokens candidate.name then mention_score_value
    else 0
  in
  let file_score =
    if mention_score >= mention_score_value then 0
    else
      path_hints
      |> List.filteri (fun i _ -> i < max_path_hints)
      |> List.filter (fun rel_path ->
             safe_file_exists (Filename.concat candidate.path rel_path))
      |> List.length
      |> ( * ) file_score_weight
  in
  let worktree_score =
    match task.worktree with
    | Some wt when String.equal wt.repo_name candidate.name -> 5
    | _ -> 0
  in
  mention_score + file_score + worktree_score

(* Hoisted above [infer_task_repo_name] so the candidates=[] path can
   validate task-evidence mentions against the workspace before
   returning. The companion error helpers
   ([workspace_repo_not_found_error] / [workspace_repo_ambiguous_error]
   / [partial_clone_error]) stay near [auto_provision_sandbox_clone]
   since [infer_task_repo_name] does not produce them. *)
let workspace_repo_matches ~search_root ~repo_name =
  let max_dirs = 4000 in
  let max_matches = 8 in
  let preferred_dir_name = function
    | "workspace" | "workspaces" | "repos" | "projects" | "src" -> true
    | _ -> false
  in
  let entry_priority entry =
    if entry = repo_name then 0
    else if preferred_dir_name entry then 1
    else if String.length entry > 0 && entry.[0] = '.' then 3
    else 2
  in
  let skip_dir_name name =
    name = ".git" || name = ".hg" || name = ".svn"
    || name = Common.masc_dirname || name = ".worktrees"
    || name = "_build" || name = "node_modules"
  in
  let matches =
    if Filename.basename search_root = repo_name && is_git_clone search_root
    then ref [ search_root ]
    else ref []
  in
  let queue = Queue.create () in
  Queue.add search_root queue;
  let dirs_seen = ref 0 in
  while
    !dirs_seen < max_dirs
    && Queue.length queue > 0
    && List.length !matches < max_matches
  do
    let dir = Queue.take queue in
    incr dirs_seen;
    let entries =
      try Sys.readdir dir with Sys_error _ -> [||]
    in
    Array.sort
      (fun a b ->
         match compare (entry_priority a) (entry_priority b) with
         | 0 -> compare a b
         | n -> n)
      entries;
    Array.iter
      (fun entry ->
         if List.length !matches < max_matches then
           let path = Filename.concat dir entry in
           if entry = repo_name && is_git_clone path then
             matches := path :: !matches;
           if safe_is_dir path && not (skip_dir_name entry) then
             Queue.add path queue)
      entries
  done;
  List.sort_uniq String.compare !matches

let infer_task_repo_name config ~agent_name ~task_id =
  let repos_dir = repos_dir_of_keeper config agent_name in
  let candidates = repo_candidates_in_dir repos_dir in
  match task_by_id config task_id with
  | None -> (
      match candidates with
      | [] -> Ok None
      | [ candidate ] -> Ok (Some candidate.name)
      | _ ->
          Error
            (System (System_error.IoError
               (Printf.sprintf
                  "ambiguous_task_repo: task %s is not in backlog and sandbox has multiple repos [%s]"
                  task_id
                  (String.concat ", " (List.map (fun c -> c.name) candidates))))))
  | Some task -> (
      match candidates with
      | [] -> (
          (* Sandbox is empty.  Prefer a previously-linked
             [task.worktree.repo_name]; otherwise scan task evidence
             for a unique safe_repo_name mention that resolves to
             exactly one workspace repo via [workspace_repo_matches]
             — [worktree_create_r] will then [auto_provision_sandbox_clone]
             on demand.  Returning [Ok None] here would be a silent
             stranding of the task (caller falls to
             [missing_sandbox_clone] with no actionable repo hint),
             which contradicts the PR's "infer from task evidence"
             contract.  Multiple workspace matches escalate to
             [ambiguous_task_repo] for the same reason as the
             multi-candidate path. *)
          match task.worktree with
          | Some wt when safe_repo_name wt.repo_name -> Ok (Some wt.repo_name)
          | _ ->
              let tokens = tokenize_repo_evidence (task_repo_text task) in
              let mention_candidates =
                tokens
                (* Allow URL-path mentions like "github.com/org/masc-mcp"
                   to surface "masc-mcp" via Filename.basename. *)
                |> List.concat_map (fun t -> [ t; Filename.basename t ])
                |> List.filter safe_repo_name
                |> List.sort_uniq String.compare
              in
              let search_root = project_root config in
              let workspace_unique =
                mention_candidates
                |> List.filter_map (fun name ->
                       match
                         workspace_repo_matches ~search_root ~repo_name:name
                       with
                       | [ _ ] -> Some name
                       | _ -> None)
                |> List.sort_uniq String.compare
              in
              (match workspace_unique with
               | [] -> Ok None
               | [ name ] -> Ok (Some name)
               | many ->
                   Error
                     (System (System_error.IoError
                        (Printf.sprintf
                           "ambiguous_task_repo: task %s has no sandbox \
                            clone, and task evidence mentions multiple \
                            workspace repos [%s]"
                           task_id (String.concat ", " many))))))
      | [ candidate ] -> Ok (Some candidate.name)
      | _ ->
          let tokens = tokenize_repo_evidence (task_repo_text task) in
          let path_hints = task_path_hints task in
          let ranked =
            candidates
            |> List.map (fun candidate ->
                   ( score_repo_candidate ~task ~tokens ~path_hints candidate
                   , candidate ))
            |> List.sort (fun (sa, a) (sb, b) ->
                   match compare sb sa with
                   | 0 -> String.compare a.name b.name
                   | n -> n)
          in
          match ranked with
          | (top_score, top_candidate) :: (second_score, _) :: _
            when top_score > 0 && top_score > second_score ->
              Ok (Some top_candidate.name)
          | (top_score, top_candidate) :: [] when top_score > 0 ->
              Ok (Some top_candidate.name)
          | (top_score, _) :: _ when top_score > 0 ->
              let tied =
                ranked
                |> List.filter (fun (score, _) -> score = top_score)
                |> List.map (fun (_, candidate) -> candidate.name)
              in
              Error
                (System (System_error.IoError
                   (Printf.sprintf
                      "ambiguous_task_repo: task %s matches multiple repos with equal score [%s]"
                      task_id (String.concat ", " tied))))
          | _ ->
              Error
                (System (System_error.IoError
                   (Printf.sprintf
                      "ambiguous_task_repo: task %s has no repo evidence; sandbox repos=[%s]"
                      task_id
                      (String.concat ", "
                         (List.map (fun c -> c.name) candidates))))))

let rec rm_rf path =
  if safe_file_exists path then
    if safe_is_dir path then begin
      (try Sys.readdir path with Sys_error _ -> [||])
      |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
    end else
      try Unix.unlink path with Unix.Unix_error _ -> ()

let missing_sandbox_clone_error ~agent_name ~repos_dir ~repo_name =
  let rel_target, clone_hint =
    match repo_name with
    | Some name when String.trim name <> "" ->
      let rel = Printf.sprintf "repos/%s" name in
      ( rel,
        Printf.sprintf
          "keeper_shell op=git_clone url=\"https://github.com/<org>/%s.git\" path=\"%s\""
          name rel )
    | _ ->
      ( "repos/<repo>",
        "keeper_shell op=git_clone url=\"https://github.com/<org>/<repo>.git\" \
         path=\"repos/<repo>\"" )
  in
  System (System_error.IoError
    (Printf.sprintf
       "missing_sandbox_clone: no sandbox git clone found for agent %s under %s \
        (expected %s). Recovery: %s"
       agent_name repos_dir rel_target clone_hint))

let workspace_repo_not_found_error ~agent_name ~repos_dir ~repo_name
    ~search_root =
  System (System_error.IoError
    (Printf.sprintf
       "missing_sandbox_clone: no sandbox git clone found for agent %s under %s \
        and no workspace git repo named %s was found under %s. Recovery: \
        keeper_shell op=git_clone url=\"https://github.com/<org>/%s.git\" \
        path=\"repos/%s\""
       agent_name repos_dir repo_name search_root repo_name repo_name))

let workspace_repo_ambiguous_error ~repo_name ~search_root ~matches =
  System (System_error.IoError
    (Printf.sprintf
       "ambiguous_workspace_repo: found multiple git repos named %s under %s: \
        [%s]. Auto-provision is blocked until the repo is disambiguated; use \
        keeper_shell op=git_clone explicitly."
       repo_name search_root (String.concat ", " matches)))

let partial_clone_error ~clone_path ~msg =
  rm_rf clone_path;
  System (System_error.IoError msg)

let git_origin_url root =
  match run_argv_with_status [ "git"; "-C"; root; "remote"; "get-url"; "origin" ] with
  | Unix.WEXITED 0, output -> first_nonempty_line output
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> None

let normalize_origin_remote_to_https root =
  match git_origin_url root with
  | None -> None
  | Some origin_url ->
      let normalized = normalize_github_clone_url origin_url in
      if String.equal origin_url normalized then None
      else
        match
          run_argv_with_status
            [ "git"; "-C"; root; "remote"; "set-url"; "origin"; normalized ]
        with
        | Unix.WEXITED 0, _ -> Some normalized
        | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> None

let auto_provision_sandbox_clone ~config ~agent_name ~repos_dir ~repo_name =
  let search_root = project_root config in
  match workspace_repo_matches ~search_root ~repo_name with
  | [] ->
      Error
        (workspace_repo_not_found_error ~agent_name ~repos_dir ~repo_name
           ~search_root)
  | [ source_root ] ->
      Fs_compat.mkdir_p repos_dir;
      let clone_path = Filename.concat repos_dir repo_name in
      if safe_file_exists clone_path then
        if is_git_clone clone_path then
          ensure_sandbox_clone_ready clone_path
          |> Result.map (fun repair_note -> (clone_path, repair_note))
        else
          Error
            (System (System_error.IoError
               (Printf.sprintf
                  "sandbox_clone_conflict: %s already exists under %s but is not \
                   a git clone. Remove or repair it, or use keeper_shell \
                   op=git_clone explicitly."
                  repo_name repos_dir)))
      else
        (match git_origin_url source_root with
         | None ->
             Error
               (System (System_error.IoError
                  (Printf.sprintf
                     "auto_provision_clone_failed: workspace repo %s has no origin remote. \
                      Sandbox auto-provision requires cloning from origin, not from the local checkout."
                     source_root)))
         | Some origin_url -> (
             match validate_clone_origin_url ~base_path:config.base_path origin_url with
             | Error err ->
                 Error
                   (System (System_error.IoError
                      (Printf.sprintf
                         "auto_provision_clone_failed: origin %s rejected by clone policy: %s"
                         origin_url err)))
             | Ok () ->
                 let origin_url = normalize_github_clone_url origin_url in
                 let status, output =
                   run_argv_with_status [ "git"; "clone"; origin_url; clone_path ]
                 in
                 if status <> Unix.WEXITED 0 then
                   Error
                     (partial_clone_error ~clone_path
                        ~msg:
                          (Printf.sprintf
                             "auto_provision_clone_failed: git clone from origin %s \
                              into %s failed: %s"
                             origin_url clone_path
                             (let detail = String.trim output in
                              if detail = "" then "(no output)" else detail)))
                 else
                   Ok
                     ( clone_path,
                       Some
                         (Printf.sprintf
                            "Sandbox clone auto-provisioned from %s."
                            (match extract_github_org_repo origin_url with
                             | Some org_repo ->
                                 "https://github.com/" ^ org_repo ^ ".git"
                             | None -> "a validated local workspace origin")) )))
  | matches ->
      Error
        (workspace_repo_ambiguous_error ~repo_name ~search_root ~matches)

(** Link worktree info to a task in backlog.
    Uses read_json/write_json to handle Backend ZSTD compression transparently. *)
let link_worktree_to_task config ~task_id ~worktree_info =
  let backlog_file = Filename.concat (tasks_dir config) "backlog.json" in
  let json = read_json config backlog_file in
  match backlog_of_yojson json with
  | Error e -> Error (System (System_error.IoError e))
  | Ok backlog ->
      if backlog.tasks = [] then
        Error (System (System_error.IoError "Backlog not found"))
      else
        let found = ref false in
        let new_tasks = List.map (fun (task : task) ->
          if task.id = task_id then begin
            found := true;
            { task with worktree = Some worktree_info }
          end else task
        ) backlog.tasks in
        if not !found then
          Error (Task (Task_error.NotFound task_id))
        else begin
          let new_backlog = { backlog with tasks = new_tasks; last_updated = now_iso () } in
          write_json config backlog_file (backlog_to_yojson new_backlog);
          Ok ()
        end

(** Create worktree for agent - Result version
    @param link_task If true, links worktree info to the task in backlog (default: true)
    @param repo_name If set, target the keeper's sandbox repo clone at
           [.masc/playground/<agent>/repos/<repo_name>/] directly. If
           unset, infer the repo from the task's repo/path evidence; only
           fall back to the sole clone when exactly one clone exists. A
           sandbox repo clone is required. *)
let worktree_create_r ?(link_task=true) ?repo_name config ~agent_name ~task_id ~base_branch : string masc_result =
  if not (is_initialized config) then
    Error (System System_error.NotInitialized)
  else if not (is_git_repo config) then
    Error (System (System_error.IoError "Not a git repository. MASC v2 requires .git directory for worktree isolation."))
  else match validate_agent_name_r agent_name, validate_task_id_r task_id with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok _, Ok _ ->
    with_worktree_mutation_lock @@ fun () ->
    let repo_name =
      match repo_name with
      | Some name when String.trim name <> "" && not (safe_repo_name name) ->
          Error
            (System (System_error.IoError
               (Printf.sprintf
                  "invalid_repo_name: %S must be a single repo directory name under repos/"
                  name)))
      | Some name when String.trim name <> "" -> Ok (Some name)
      | _ -> infer_task_repo_name config ~agent_name ~task_id
    in
    match repo_name with
    | Error e -> Error e
    | Ok repo_name ->
        (* Prefer a keeper's sandbox repo clone under the keeper's
           backend-specific sandbox repo lane. If [repo_name] is supplied,
           target that clone directly; otherwise use the repo inferred above.
           Keepers may work on any repo their [tool_policy.toml] allows, but
           the worktree root must come from a sandbox repo clone. *)
        let resolve_keeper_repo_root () =
          let repos_dir = repos_dir_of_keeper config agent_name in
          let explicit_repo =
            match repo_name with
            | None | Some "" -> None
            | Some name when not (safe_repo_name name) -> None
            | Some name ->
                let candidate = Filename.concat repos_dir name in
                if is_git_clone candidate
                then
                  Some
                    (ensure_sandbox_clone_ready candidate
                     |> Result.map (fun note -> (candidate, note)))
                else None
          in
          match repo_name with
          | Some name when String.trim name <> "" && safe_repo_name name -> (
              match explicit_repo with
              | Some result -> result
              | None ->
                  auto_provision_sandbox_clone ~config ~agent_name ~repos_dir
                    ~repo_name:name)
          | _ ->
              Error (missing_sandbox_clone_error ~agent_name ~repos_dir ~repo_name)
        in
        match resolve_keeper_repo_root () with
        | Error e -> Error e
        | Ok (root, provision_note) -> begin
        let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
        match ensure_worktree_path root worktree_name with
        | Error e -> Error e
        | Ok (worktree_path, worktrees_dir) ->
          let branch_name = Playground_paths.worktree_branch_name agent_name task_id in
          let repo_name = Filename.basename root in

          (* Build worktree_info for task linking *)
          let wt_info : worktree_info = {
            branch = branch_name;
            path = Printf.sprintf ".worktrees/%s" worktree_name;
            git_root = root;
            repo_name = repo_name;
          } in

          let update_agent_current_task () =
            let agent_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
            let json = read_json config agent_file in
            match agent_of_yojson json with
            | Ok agent ->
                let updated_agent = { agent with current_task = Some worktree_name } in
                write_json config agent_file (agent_to_yojson updated_agent)
            | Error msg -> Log.Misc.info "agent state read: %s" msg
          in

          (* Link worktree to task in backlog *)
          (* WORKAROUND: Masc_error.t has 7 ctors with nested per-domain
             variants (Task_error has its own ctors). 정확한 enumeration은
             도메인 신규 ctor마다 무관한 caller가 churn 대상이 됨.
             근본 해결: per-domain error-to-string helper로 분류 일원화 (RFC 후보). *)
          let[@warning "-4"] maybe_link_task () =
            if link_task then begin
              match link_worktree_to_task config ~task_id ~worktree_info:wt_info with
              | Ok () -> ""
              | Error (Task (Task_error.NotFound _)) -> "\n  Note: Task not found in backlog, worktree not linked"
              | Error _ -> "\n  Note: Could not link worktree to task"
            end else ""
          in

          let existing_worktree_ok ?(created_concurrently=false) () =
            update_agent_current_task ();
            let keeper_path =
              keeper_visible_worktree_path ~config ~agent_name
                ~host_path:worktree_path
            in
            let race_note =
              if created_concurrently then
                "\n  Note: Worktree was created concurrently by another worker."
              else ""
            in
            let link_note = maybe_link_task () in
            Ok
              (Printf.sprintf
                 "Worktree already exists:\n  Path: %s\n  Branch: %s\n  \
                  Repo: %s%s%s\n\n%s"
                 keeper_path branch_name repo_name race_note link_note
                 (worktree_next_step keeper_path))
          in

          (* Create .worktrees directory if not exists *)
          Fs_compat.mkdir_p worktrees_dir;

          (* Check if worktree already exists *)
          if safe_file_exists worktree_path then begin
            if is_usable_git_worktree worktree_path then
              existing_worktree_ok ()
            else
              Error
                (System (System_error.IoError
                   (Printf.sprintf
                      "worktree_path_conflict: %s already exists but is not a \
                       usable git worktree. Remove or repair it before retrying."
                      worktree_path)))
          end else begin
            (* Fetch origin first; stale remotes must be explicit, not hidden.
               Use the longer git_fetch_timeout_sec budget — the default
               30s rejected legitimately slow Docker-bridge fetches and
               cold fetches on large remotes (#9587). *)
            ignore (normalize_origin_remote_to_https root : string option);
            let fetch_exit =
              run_argv_exit
                ~timeout_sec:(Env_config_core.git_fetch_timeout_sec ())
                ["git"; "-C"; root; "fetch"; "origin"]
            in
            if fetch_exit <> 0 then
              Error
                (System (System_error.IoError
                   "Failed to fetch origin before worktree creation. Verify network/auth and retry so the task starts from the latest remote ref."))
            else begin
              let playground_dir =
                repos_dir_of_keeper config agent_name
                |> strip_trailing_slashes
                |> Filename.dirname
              in
              Playground_repo_cache.update ~playground_dir ~repo_name
                ~repo_path:root ~action:"fetch"
                ~shallow:(Playground_repo_cache.is_shallow_repo root);
              match Coord_git.resolve_base_branch root base_branch with
            | Error e -> Error e
            | Ok (resolved_base, fallback_from) ->
                let note = match fallback_from with
                  | None -> ""
                  | Some missing ->
                      Printf.sprintf "\n  Note: origin/%s not found; used origin/%s" missing resolved_base
                in
                let provision_note =
                  match provision_note with
                  | None -> ""
                  | Some detail -> "\n  Note: " ^ detail
                in
                (* Create worktree with force-branch (-B) from base.
                   -B resets the branch if it already exists (stale from a
                   previous session), avoiding the TOCTOU race of
                   check-delete-create and the permanent failure when keeper
                   branches are not cleaned up after worktree removal. *)
                let exit_code, git_output =
                  let argv =
                    [
                      "git";
                      "-C";
                      root;
                      "worktree";
                      "add";
                      worktree_path;
                      "-B";
                      branch_name;
                      Printf.sprintf "origin/%s" resolved_base;
                    ]
                  in
                  Masc_exec.Exec_gate.run_argv_with_status
                    ~actor:(Masc_exec.Agent_id.of_string "coord/worktree")
                    ~raw_source:(exec_gate_raw_source argv)
                    ~summary:"coord_worktree worktree add"
                    ~timeout_sec:Env_config_runtime.Coord_git.local_op_timeout_sec
                    argv
                in

                if exit_code = Unix.WEXITED 0 then begin
                  (* Update agent's current_worktree in state *)
                  update_agent_current_task ();
                  let keeper_path =
                    keeper_visible_worktree_path ~config ~agent_name
                      ~host_path:worktree_path
                  in

                  (* Link to task *)
                  let link_note = maybe_link_task () in

                  (* Log event with worktree info *)
                  let event = Printf.sprintf
                    "{\"type\":\"worktree_create\",\"agent\":\"%s\",\"branch\":\"%s\",\"path\":\"%s\",\"repo\":\"%s\",\"task_id\":\"%s\",\"ts\":\"%s\"}"
                    agent_name branch_name worktree_path repo_name task_id (now_iso ()) in
                  log_event config (Yojson.Safe.from_string event);

                  Ok (Printf.sprintf "Worktree created:\n  Path: %s\n  Branch: %s\n  Repo: %s%s%s\n\n%s"
                      keeper_path branch_name repo_name note
                      (provision_note ^ link_note)
                      (worktree_next_step keeper_path))
                end
                else if is_usable_git_worktree worktree_path then
                  existing_worktree_ok ~created_concurrently:true ()
                else begin
                  rm_rf worktree_path;
                  let detail = String.trim git_output in
                  Error (System (System_error.IoError (Printf.sprintf "Failed to create worktree from origin/%s: %s"
                    resolved_base (if detail = "" then "(no output)" else detail))))
                end
            end
          end
  end

(** Remove worktree - Result version *)
let worktree_remove_r config ~agent_name ~task_id : string masc_result =
  if not (is_initialized config) then
    Error (System System_error.NotInitialized)
  else match validate_agent_name_r agent_name, validate_task_id_r task_id with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok _, Ok _ ->
    let resolve_existing_worktree_root () =
      let repos_dir = repos_dir_of_keeper config agent_name in
      let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
      let safe_is_dir path =
        try Sys.file_exists path && Sys.is_directory path
        with Sys_error _ -> false
      in
      let is_git_clone candidate =
        safe_is_dir candidate
        && (try Sys.file_exists (Filename.concat candidate ".git")
            with Sys_error _ -> false)
      in
      let find_matching_clone dir =
        if not (safe_is_dir dir) then None
        else
          let entries =
            try Sys.readdir dir with Sys_error _ -> [||]
          in
          Array.sort compare entries;
          let rec find i =
            if i >= Array.length entries then None
            else
              let candidate = Filename.concat dir entries.(i) in
              let worktree_path =
                Filename.concat candidate (Filename.concat ".worktrees" worktree_name)
              in
              if is_git_clone candidate && Sys.file_exists worktree_path
              then Some candidate
              else find (i + 1)
          in
          find 0
      in
      match find_matching_clone repos_dir with
      | Some root -> Ok root
      | None ->
        (* #13302 P2-1 follow-up: typed variant replaces the previous
           [IoError "Worktree ... not found under ..."] string-formatted
           error.  #13304 demoted the WARN by matching that prefix in
           [coord_task.cleanup_worktree_for_transition]; the typed
           variant here lets the caller pattern-match safely so a future
           message-format change does not silently regress the demotion. *)
        Error
          (System (System_error.WorktreeNotFound
             { worktree = worktree_name; searched_in = repos_dir }))
    in
    match resolve_existing_worktree_root () with
    | Error e -> Error e
    | Ok root ->
        let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
        match ensure_worktree_path root worktree_name with
        | Error e -> Error e
        | Ok (worktree_path, _) -> begin
            let branch_name = Playground_paths.worktree_branch_name agent_name task_id in

            if not (Sys.file_exists worktree_path) then
              Error (System (System_error.IoError (Printf.sprintf "Worktree not found: %s" worktree_path)))
            else begin
              (* Remove worktree *)
              let exit_code = run_argv_exit ["git"; "-C"; root; "worktree"; "remove"; worktree_path] in

              if exit_code = 0 then begin
                (* Delete the branch — use -D to force-delete unmerged branches *)
                let branch_exit = run_argv_exit ["git"; "-C"; root; "branch"; "-D"; branch_name] in

                (* Prune stale worktrees *)
                let prune_exit = run_argv_exit ["git"; "-C"; root; "worktree"; "prune"] in

                (* Log event with post-processing status *)
                let branch_status = if branch_exit = 0 then "ok" else "warn:branch_delete_failed" in
                let prune_status = if prune_exit = 0 then "ok" else "warn:prune_failed" in
                let event = Printf.sprintf
                  "{\"type\":\"worktree_remove\",\"agent\":\"%s\",\"branch\":\"%s\",\"branch_delete\":\"%s\",\"prune\":\"%s\",\"ts\":\"%s\"}"
                  agent_name branch_name branch_status prune_status (now_iso ()) in
                log_event config (Yojson.Safe.from_string event);

                (* Return result with post-processing status *)
                let msg = Printf.sprintf "Worktree removed: %s\n   Branch: %s (delete: %s)\n   Prune: %s"
                  worktree_path branch_name branch_status prune_status in
                if branch_exit <> 0 || prune_exit <> 0 then
                  Error (System (System_error.IoError (msg ^ "\n   ⚠️ Post-processing had failures")))
                else
                  Ok msg
              end
              else
                Error (System (System_error.IoError "Failed to remove worktree. It may have uncommitted changes."))
	    end
    end

(** List all worktrees *)
let worktree_list config =
  if not (is_initialized config) then
    `Assoc [("error", `String "MASC not initialized")]
  else
    Coord_git.list ~base_path:config.base_path
