(** Playground repository readiness.

    This module owns repository clone/worktree readiness for playground repo
    lanes. Keeper callers may ask whether a cwd-backed repo/worktree is usable,
    but clone/fetch/worktree provisioning policy lives here instead of in
    keeper execution code. *)

open Keeper_types
open Keeper_meta_contract

type command_result =
  { ok : bool
  ; output : string
  ; status : Unix.process_status
  }

(* Read-only git probe timeout. Large monorepos (~/me, kidsnote-backend)
   repeatedly trip a 5 s budget on first probe after filesystem cache
   eviction; 15 s matches [server_dashboard_http_runtime_info]'s sibling
   probe that was bumped for the same reason in #9765/#9775. *)
let read_only_probe_timeout_sec = 15.0

let run_git ~timeout_sec ~clone_path args =
  let argv = [ "git"; "-C"; clone_path; "--no-optional-locks" ] @ args in
  let status, output =
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:`Workspace_git
      ~raw_source:(String.concat " " argv)
      ~summary:"playground repo readiness git probe"
      ~timeout_sec argv
  in
  { ok = status = Unix.WEXITED 0; output = String.trim output; status }

let deleted_tracked_path_of_porcelain_line line =
  let line = String.trim line in
  let len = String.length line in
  if len = 0 then None
  else if String.starts_with ~prefix:"D  " line && len > 3
  then Some (String.sub line 3 (len - 3))
  else if String.starts_with ~prefix:"D " line && len > 2
  then Some (String.sub line 2 (len - 2))
  else None

let shell_quote_path path =
  let safe_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '/' | '.' | '_' | '-' -> true
    | _ -> false
  in
  if path <> "" && String.for_all safe_char path
  then path
  else
    "'"
    ^ (path
       |> String.split_on_char '\''
       |> String.concat "'\\''")
    ^ "'"

let deleted_tracked_files_restore_hint ~clone_path =
  let status =
    run_git
      ~timeout_sec:read_only_probe_timeout_sec
      ~clone_path
      [ "status"; "--porcelain"; "-z" ]
  in
  if not status.ok then None
  else
    let changes =
      status.output
      |> String.split_on_char '\x00'
      |> List.map String.trim
      |> List.filter (fun record -> record <> "")
    in
    match changes with
    | [] -> None
    | changes ->
      let deleted_paths =
        List.filter_map deleted_tracked_path_of_porcelain_line changes
      in
      if List.length deleted_paths = List.length changes
      then
        let status_summary =
          deleted_paths
          |> List.map (fun path -> "D " ^ path)
          |> String.concat "; "
        in
        let restore_args =
          deleted_paths |> List.map shell_quote_path |> String.concat " "
        in
        Some
          (Printf.sprintf
             "Dirty status only contains deleted tracked files: %s. Restore \
              them with: git checkout HEAD -- %s"
             status_summary
             restore_args)
      else None

let safe_is_dir path =
  try Sys.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false

let safe_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false

let normalize_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let same_path a b = String.equal (normalize_path a) (normalize_path b)

let git_toplevel path =
  let probe =
    run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path:path
      [ "rev-parse"; "--show-toplevel" ]
  in
  if probe.ok then Some probe.output else None

let safe_repo_component s =
  s <> "" && s <> "." && s <> ".."
  && not (String.starts_with ~prefix:"." s)
  && not (String.contains s '/')
  && not (String.contains s '\\')
  && not (String.contains s '\x00')
  && String.for_all
       (fun c ->
         (c >= 'A' && c <= 'Z')
         || (c >= 'a' && c <= 'z')
         || (c >= '0' && c <= '9')
         || c = '-'
         || c = '_'
         || c = '.')
       s

let repo_name_of_repo_arg ~project_root repo =
  let trimmed = String.trim repo in
  if trimmed = "" then Filename.basename project_root
  else
    let base = Filename.basename trimmed in
    if Filename.check_suffix base ".git" then
      String.sub base 0 (String.length base - 4)
    else base

let clone_path ~(config : Workspace.config) ~(meta : keeper_meta) ~repo_name =
  Filename.concat
    (Keeper_sandbox.host_root_abs_of_meta ~config meta)
    (Filename.concat "repos" repo_name)

let first_line_opt s =
  match
    String.split_on_char '\n' s
    |> List.map String.trim
    |> List.filter (fun line -> line <> "")
  with
  | [] -> None
  | line :: _ -> Some line

let parse_ahead_behind output =
  match String.split_on_char '\t' (String.trim output) with
  | [ behind; ahead ] -> (
      match int_of_string_opt behind, int_of_string_opt ahead with
      | Some behind, Some ahead -> Some (ahead, behind)
      | _ -> None)
  | _ -> None

let string_opt_field name = function
  | None -> [ name, `Null ]
  | Some value -> [ name, `String value ]

let int_opt_field name = function
  | None -> [ name, `Null ]
  | Some value -> [ name, `Int value ]

let inspect
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ?repo_name
    ?(repo = "")
    ?(default_branch = "main")
    ()
  =
  let project_root = Keeper_alerting_path.project_root_of_config config in
  let derived_repo_name =
    match repo_name with
    | Some name ->
        let trimmed = String.trim name in
        if trimmed <> "" then trimmed else repo_name_of_repo_arg ~project_root repo
    | None -> repo_name_of_repo_arg ~project_root repo
  in
  let clone_path = clone_path ~config ~meta ~repo_name:derived_repo_name in
  let common_fields state ok next_action extra =
    `Assoc
      ([
         "ok", `Bool ok;
         "state", `String state;
         "keeper", `String meta.name;
         "repo", `String repo;
         "repo_name", `String derived_repo_name;
         "clone_path", `String clone_path;
         "sandbox_repos",
         `String
           (Keeper_alerting_path.strip_trailing_slashes
              (Keeper_sandbox.allowed_root_rel_of_meta ~meta)
            ^ "/repos/");
         "default_branch", `String default_branch;
         "next_action", `String next_action;
       ]
      @ extra)
  in
  if not (safe_repo_component derived_repo_name) then
    common_fields "invalid_repo_name" false
      "Pass repo_name as a single directory name under repos/; no slashes or path traversal."
      [
        "exists", `Bool false;
        "is_git_repo", `Bool false;
        "has_origin", `Bool false;
      ]
  else if not (safe_is_dir clone_path) then
    common_fields "missing_clone" false
      "Create or clone the repo under sandbox repos/ before starting code work."
      [
        "exists", `Bool false;
        "is_git_repo", `Bool false;
        "has_origin", `Bool false;
      ]
  else
    let inside =
      run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path [ "rev-parse"; "--is-inside-work-tree" ]
    in
    let top =
      if inside.ok then
        run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path
          [ "rev-parse"; "--show-toplevel" ]
      else { inside with ok = false; output = "" }
    in
    if (not inside.ok) || (not top.ok) || not (same_path clone_path top.output)
    then
      common_fields "not_git_repo" false
        "This sandbox repo directory is not a git clone; reclone it under repos/."
        [
          "exists", `Bool true;
          "is_git_repo", `Bool false;
          "has_origin", `Bool false;
          "git_error", `String inside.output;
          "git_toplevel", (if top.ok then `String top.output else `Null);
        ]
    else
      let status =
        run_git
          ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Repo_readiness ())
          ~clone_path [ "status"; "--porcelain" ]
      in
      let dirty = status.ok && String.trim status.output <> "" in
      let branch =
        run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path [ "branch"; "--show-current" ]
        |> fun r -> if r.ok then first_line_opt r.output else None
      in
      let head =
        run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path [ "rev-parse"; "--short"; "HEAD" ]
        |> fun r -> if r.ok then first_line_opt r.output else None
      in
      let upstream =
        run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path
          [ "rev-parse"; "--abbrev-ref"; "--symbolic-full-name"; "@{upstream}" ]
      in
      let upstream_name = if upstream.ok then first_line_opt upstream.output else None in
      let ahead, behind =
        match upstream_name with
        | None -> None, None
        | Some _ -> (
            let counts =
              run_git
                ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Repo_readiness ())
                ~clone_path
                [ "rev-list"; "--left-right"; "--count"; "@{upstream}...HEAD" ]
            in
            if counts.ok then
              match parse_ahead_behind counts.output with
              | Some (ahead, behind) -> Some ahead, Some behind
              | None -> None, None
            else None, None)
      in
      let origin =
        run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path [ "remote"; "get-url"; "origin" ]
      in
      let has_origin = origin.ok && String.trim origin.output <> "" in
      (* Currency against [origin/<default_branch>] explicitly, independent of
         [@{upstream}]. The FETCH_HEAD-provisioned playground repos set no
         upstream, so an upstream-only check reports [behind=None] and the state
         falls through to "ready" even when the clone is hundreds of commits
         behind main. This is read-only -- it reflects the last fetch, not a
         fresh one; the fetch + fast-forward happens in [ensure_current]. *)
      let behind_default =
        let counts =
          run_git
            ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Repo_readiness ())
            ~clone_path
            [ "rev-list"; "--count"; "HEAD..origin/" ^ default_branch ]
        in
        if counts.ok then int_of_string_opt (String.trim counts.output) else None
      in
      let current = behind_default = Some 0 in
      let state, ok, next_action =
        if not status.ok then
          "status_failed", false,
          "Run Execute executable='git' argv=['status','--short'] in this repo; repair git status before starting work."
        else if not has_origin then
          "missing_origin", false,
          "Set or reclone origin before worktree creation; latest cannot be verified without origin."
        else if dirty then
          "dirty", false,
          "Commit, stash, or move existing changes before creating a fresh task worktree."
        else
          match behind with
          | Some n when n > 0 ->
              "behind_upstream", false,
              "Fetch/rebase the sandbox clone or create a new worktree from the fetched origin branch."
          | _ -> (
              match behind_default with
              | Some n when n > 0 ->
                  "behind_upstream", false,
                  Printf.sprintf
                    "Local branch is %d commit(s) behind origin/%s; fast-forward \
                     or recut your task worktree from it before editing."
                    n default_branch
              | _ -> "ready", true, "Create a task worktree from the fetched origin branch before editing.")
      in
      common_fields state ok next_action
        ([
           "exists", `Bool true;
           "is_git_repo", `Bool true;
           "dirty", `Bool dirty;
           "has_origin", `Bool has_origin;
           "origin_url",
           (if has_origin then `String origin.output else `Null);
           "status_ok", `Bool status.ok;
         ]
        @ string_opt_field "branch" branch
        @ string_opt_field "head" head
        @ string_opt_field "upstream" upstream_name
        @ int_opt_field "ahead" ahead
        @ int_opt_field "behind" behind
        @ int_opt_field "behind_default" behind_default
        @ [ "current", `Bool current ])

(* ── Sandbox repo auto-repair ─────────────────────────────────── *)

(** Look up the repository URL from [repositories.toml] by repo name. *)
let find_repo_url ~(config : Workspace.config) ~repo_name =
  Repo_store.find_url_by_id ~base_path:config.Workspace.base_path repo_name

(** Clone a sandbox repo using non-interactive repo-manager git.
    Constructs a minimal [repository] record and delegates to [Repo_git.clone]. *)
let clone_sandbox_repo ~(meta : keeper_meta) ~repo_name ~url ~clone_path =
  let open Repo_manager_types in
  let repo = {
    id = repo_name;
    name = repo_name;
    url;
    local_path = clone_path;
    aliases = [];
    default_branch = "main";
    keepers = [ meta.name ];
    status = Active;
    auto_sync = false;
    sync_interval = 0;
    created_at = 0L;
    updated_at = 0L;
  }
  in
  Repo_git.clone ~repository:repo

(** [ensure_ready ~config ~meta ~repo_name ()] probes the sandbox repo
    via [inspect]. If the repo is [missing_clone] or [not_git_repo],
    attempts to clone it from the configured repository URL. Returns [Ok ()] when the repo is ready,
    or [Error msg] if repair failed or was not possible. *)
let ensure_ready ~(config : Workspace.config) ~(meta : keeper_meta) ~repo_name () :
    (unit, string) result =
  if not (safe_repo_component repo_name) then
    Error (Printf.sprintf "invalid repo_name: %s" repo_name)
  else
    let probe =
      inspect ~config ~meta ~repo_name ()
    in
    let state =
      match Json_util.assoc_member_opt "state" probe with
      | Some (`String s) -> s
      | _ -> "unknown"
    in
    match state with
    | "ready" -> Ok ()
    | "missing_clone" | "not_git_repo" -> (
        let path = clone_path ~config ~meta ~repo_name in
        (* Remove corrupt directory if present *)
        if state = "not_git_repo" && safe_is_dir path then (
          (* Quarantine (move) instead of [rm -rf]. The [not_git_repo]
             classifier only checks the git toplevel, not whether the directory
             holds work -- a dirty clone with a corrupt/.git or worktree
             confusion can trip it while still carrying uncommitted or unpushed
             keeper work. Moving it aside preserves any salvageable work for
             recovery and lets the reclone proceed into a clean path; [rm -rf]
             would destroy it irreversibly with no commit/stash first. *)
          let quarantine =
            Printf.sprintf "%s.corrupt-%d-%d" path (Unix.getpid ())
              (int_of_float (Unix.gettimeofday () *. 1000.))
          in
          let _ =
            Masc_exec.Exec_gate.run_argv_with_status
              ~actor:`Workspace_git
              ~raw_source:
                (Printf.sprintf "mv %s %s" (Filename.quote path)
                   (Filename.quote quarantine))
              ~summary:"quarantine corrupt sandbox repo before reclone"
              ~timeout_sec:read_only_probe_timeout_sec
              [ "mv"; path; quarantine ]
          in
          ());
        match find_repo_url ~config ~repo_name with
        | None ->
          Error
            (Printf.sprintf
               "repo %s not found in repositories.toml; cannot auto-clone"
               repo_name)
        | Some url -> (
            match clone_sandbox_repo ~meta ~repo_name ~url ~clone_path:path with
            | Error msg ->
              Error (Printf.sprintf "auto-clone failed for %s: %s" repo_name msg)
            | Ok () ->
              (* Verify post-clone state *)
              let post = inspect ~config ~meta ~repo_name () in
              let post_state =
                match Json_util.assoc_member_opt "state" post with
                | Some (`String s) -> s
                | _ -> "unknown"
              in
              if post_state = "ready" then Ok ()
              else
                Error
                  (Printf.sprintf
                     "auto-clone succeeded but post-clone state is %s"
                     post_state)))
    | other ->
      Error
        (Printf.sprintf
           "repo %s is in state %s; auto-repair not applicable"
           repo_name other)

let ensure_parent_clone_for_worktree ~(config : Workspace.config) ~(meta : keeper_meta)
    ~repo_name =
  let repo_path = clone_path ~config ~meta ~repo_name in
  if safe_is_dir repo_path then (
    let inside =
      run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path:repo_path
        [ "rev-parse"; "--is-inside-work-tree" ]
    in
    let top =
      if inside.ok then
        run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path:repo_path
          [ "rev-parse"; "--show-toplevel" ]
      else { inside with ok = false; output = "" }
    in
    if inside.ok && top.ok && same_path repo_path top.output then Ok repo_path
    else
      match ensure_ready ~config ~meta ~repo_name () with
      | Ok () -> Ok repo_path
      | Error msg -> Error msg)
  else
    match ensure_ready ~config ~meta ~repo_name () with
    | Ok () -> Ok repo_path
    | Error msg -> Error msg

let best_effort_fetch_origin repo_path =
  ignore
    (run_git
       ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Repo_readiness ())
       ~clone_path:repo_path
       [ "fetch"; "--quiet"; "origin" ])

let first_existing_ref ~repo_path refs =
  let rec loop = function
    | [] -> None
    | ref_name :: rest ->
      let probe =
        run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path:repo_path
          [ "rev-parse"; "--verify"; "--quiet"; ref_name ]
      in
      if probe.ok then Some ref_name else loop rest
  in
  loop refs

let worktree_base_ref ~repo_path =
  best_effort_fetch_origin repo_path;
  let remote_head =
    let probe =
      run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path:repo_path
        [ "symbolic-ref"; "--quiet"; "--short"; "refs/remotes/origin/HEAD" ]
    in
    if probe.ok then first_line_opt probe.output else None
  in
  let candidates =
    List.filter_map
      (fun x -> x)
      [ remote_head; Some "origin/main"; Some "origin/master"; Some "origin/develop" ]
  in
  first_existing_ref ~repo_path candidates

let is_standard_worktree_path ~repo_path ~task_name ~worktree_path =
  let expected_worktree_path =
    Filename.concat (Filename.concat repo_path ".worktrees") task_name
  in
  same_path worktree_path expected_worktree_path

let relative_gitdir_of_pointer ~repo_path pointer =
  let prefix = "gitdir:" in
  if not (String.starts_with ~prefix pointer) then
    Error "worktree .git file is not a gitdir pointer"
  else
    let gitdir =
      String.sub
        pointer
        (String.length prefix)
        (String.length pointer - String.length prefix)
      |> String.trim
    in
    if gitdir = "" then Error "worktree .git file has an empty gitdir pointer"
    else if Filename.is_relative gitdir then Ok None
    else
      let gitdir = normalize_path gitdir in
      let worktrees_dir =
        Filename.concat (Filename.concat repo_path ".git") "worktrees"
        |> normalize_path
      in
      if String.starts_with ~prefix:(worktrees_dir ^ "/") gitdir then
        let suffix =
          String.sub
            gitdir
            (String.length worktrees_dir + 1)
            (String.length gitdir - String.length worktrees_dir - 1)
        in
        Ok (Some (Printf.sprintf "../../.git/worktrees/%s" suffix))
      else
        Error
          (Printf.sprintf
             "worktree gitdir %s is not under %s"
             gitdir worktrees_dir)

let read_file_trim path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len |> String.trim)

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let worktree_git_marker_path worktree_path =
  Filename.concat worktree_path ".git"

let quarantine_candidate path =
  let rec loop n =
    let candidate =
      if n = 0 then path ^ ".broken"
      else Printf.sprintf "%s.broken-%d" path n
    in
    if safe_exists candidate then loop (n + 1) else candidate
  in
  loop 0

let quarantine_broken_worktree_slot ~worktree_path =
  let quarantine = quarantine_candidate worktree_path in
  try
    Sys.rename worktree_path quarantine;
    Ok quarantine
  with
  | Sys_error msg ->
    Error
      (Printf.sprintf
         "failed to quarantine broken worktree %s to %s: %s"
         worktree_path quarantine msg)

let prepare_worktree_path_for_add ~worktree_path =
  if not (safe_exists worktree_path) then Ok None
  else if safe_is_dir worktree_path
          && safe_exists (worktree_git_marker_path worktree_path)
  then
    quarantine_broken_worktree_slot ~worktree_path
    |> Result.map (fun path -> Some path)
  else
    Error
      (Printf.sprintf
         "worktree path %s already exists but is not a git checkout and has no \
          .git marker; refusing to overwrite"
         worktree_path)

let normalize_worktree_gitdir_file ~repo_path ~task_name ~worktree_path =
  if not (is_standard_worktree_path ~repo_path ~task_name ~worktree_path) then
    Ok ()
  else
    let git_file = worktree_git_marker_path worktree_path in
    if not (Sys.file_exists git_file) then
      Error (Printf.sprintf "worktree %s has no .git file" worktree_path)
    else if Sys.is_directory git_file then Ok ()
    else (
      try
        let current = read_file_trim git_file in
        match relative_gitdir_of_pointer ~repo_path current with
        | Error msg ->
          Error (Printf.sprintf "worktree %s %s" worktree_path msg)
        | Ok None -> Ok ()
        | Ok (Some relative_gitdir) ->
          write_file git_file ("gitdir: " ^ relative_gitdir ^ "\n");
          Ok ()
      with
      | Sys_error msg ->
        Error
          (Printf.sprintf
             "failed to normalize worktree gitdir for %s: %s"
             worktree_path msg))

(** [ensure_worktree_ready ~config ~meta ~repo_name ~task_name ~worktree_path ()]
    ensures a git worktree exists at [worktree_path] inside the sandbox clone for
    [repo_name].  If the worktree is missing, first ensures the parent repo is a
    valid git clone (reclone if needed), then creates the worktree from the
    fetched default origin branch.  Parent clone dirtiness is preserved and does
    not block creating a separate task worktree.  Returns [Ok ()] when the
    worktree is a valid git checkout, or [Error msg] if creation failed.

    Root fixes for the Docker sandbox Git/CWD boundary:
    - when the keeper cwd targets a worktree path that doesn't exist in the
      sandbox clone, recreate it instead of failing with
      [sandbox_repo_not_ready];
    - when the worktree exists, normalize its [.git] gitdir pointer to a
      relative path so Git can resolve the metadata from both the host and the
      container mount. *)
let ensure_worktree_ready
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(repo_name : string)
      ~(task_name : string)
      ~(worktree_path : string)
      () : (unit, string) result =
  if not (safe_repo_component repo_name) then
    Error (Printf.sprintf "invalid repo_name: %s" repo_name)
  else if not (safe_repo_component task_name) then
    Error (Printf.sprintf "invalid task_name: %s" task_name)
  else
    (* Fast path: worktree already exists and is a valid git checkout.
       Skip parent repo validation — the parent may be "dirty" from worktree
       metadata (.git/worktrees/), which is normal and expected. *)
    match git_toplevel worktree_path with
    | Some top when same_path worktree_path top ->
      let repo_path = clone_path ~config ~meta ~repo_name in
      normalize_worktree_gitdir_file ~repo_path ~task_name ~worktree_path
    | Some top ->
      Error
        (Printf.sprintf
           "worktree path %s is not an independent git checkout (git_toplevel=%s)"
           worktree_path top)
    | None ->
      (* Worktree missing or corrupt — ensure parent repo exists, then create *)
      match ensure_parent_clone_for_worktree ~config ~meta ~repo_name with
      | Error msg ->
        Error (Printf.sprintf "parent repo %s not usable for worktree: %s" repo_name msg)
      | Ok repo_path -> (
        match prepare_worktree_path_for_add ~worktree_path with
        | Error msg -> Error msg
        | Ok _quarantined -> (
          match worktree_base_ref ~repo_path with
        | None ->
          Error
            (Printf.sprintf
               "worktree add failed for %s/%s at %s: no base ref found"
               repo_name task_name worktree_path)
        | Some base_ref ->
          (* [git worktree add --detach <path> <ref>] avoids inheriting a dirty
             parent task branch as the new task's base. *)
          let add_result =
            run_git ~timeout_sec:(read_only_probe_timeout_sec *. 2.0)
              ~clone_path:repo_path
              [ "worktree"; "add"; "--detach"; worktree_path; base_ref ]
          in
          if add_result.ok then (
            match
              normalize_worktree_gitdir_file ~repo_path ~task_name ~worktree_path
            with
            | Error msg -> Error msg
            | Ok () ->
              (* Create a task branch in the new worktree *)
              let branch_name = Printf.sprintf "task/%s" task_name in
              let checkout =
                run_git ~timeout_sec:read_only_probe_timeout_sec
                  ~clone_path:worktree_path
                  [ "checkout"; "-b"; branch_name ]
              in
              if checkout.ok then Ok ()
              else
                (* worktree created but branch checkout failed — still usable *)
                Ok ())
          else
            Error
              (Printf.sprintf
                 "worktree add failed for %s/%s at %s from %s: %s"
                 repo_name task_name worktree_path base_ref add_result.output)))

(** [provision_worktrees_for_task ~config ~agent_name ~task_id ()] scans all
    repos in the keeper's docker playground and creates a worktree for [task_id]
    in each repo that is ready.  Called best-effort at task claim time so that
    worktrees exist before the LLM tries to use them.

    Only operates for Docker-sandboxed keepers (local keepers use the project
    root directly and don't need worktree provisioning).

    Computes paths directly from [config.base_path] and [agent_name] to avoid
    constructing a full [keeper_meta] record.  Uses [run_git] directly for
    worktree operations.

    Failures in individual repos are logged but do not propagate — the
    validation-time [ensure_worktree_ready] safety net handles any misses. *)
let provision_worktrees_for_task
      ~(config : Workspace.config)
      ~(agent_name : string)
      ~(task_id : string)
      () =
  if not (safe_repo_component task_id) then
    Log.Workspace.info "provision_worktrees: invalid task_id %S, skipping" task_id
  else
    let safe_name = Playground_paths.sanitize_keeper_name agent_name in
    let playground =
      Filename.concat config.Workspace.base_path
        (Printf.sprintf ".masc/playground/docker/%s" safe_name)
    in
    let repos_dir = Filename.concat playground "repos" in
    if not (safe_is_dir repos_dir) then ()
    else
      let entries =
        try Sys.readdir repos_dir with Sys_error _ -> [||]
      in
      Array.iter
        (fun repo_name ->
           if not (safe_repo_component repo_name) then ()
           else
             let repo_path = Filename.concat repos_dir repo_name in
             if not (safe_is_dir repo_path) then ()
             else
               let worktree_path =
                 Filename.concat
                   (Filename.concat repo_path ".worktrees")
                   task_id
               in
               match git_toplevel worktree_path with
               | Some top when same_path worktree_path top -> ()
               | Some top ->
                 Log.Workspace.debug
                   "provision_worktrees: skipped %s/%s: %s is not an independent \
                    git checkout (git_toplevel=%s)"
                   repo_name task_id worktree_path top
               | None -> (
                   match prepare_worktree_path_for_add ~worktree_path with
                   | Error msg ->
                     Log.Workspace.debug
                       "provision_worktrees: skipped %s/%s: %s"
                       repo_name task_id msg
                   | Ok _quarantined -> (
                     match worktree_base_ref ~repo_path with
                   | None ->
                     Log.Workspace.debug
                       "provision_worktrees: skipped %s/%s: no base ref found"
                       repo_name task_id
                   | Some base_ref ->
                     (* Create worktree in the sandbox clone from origin, not
                        from whatever task branch the parent clone is currently
                        on. *)
                     let add_result =
                       run_git
                         ~timeout_sec:(read_only_probe_timeout_sec *. 2.0)
                         ~clone_path:repo_path
                         [ "worktree"; "add"; "--detach"; worktree_path; base_ref ]
                     in
                     if add_result.ok then (
                       (match
                          normalize_worktree_gitdir_file
                            ~repo_path
                            ~task_name:task_id
                            ~worktree_path
                        with
                        | Ok () -> ()
                        | Error msg ->
                          Log.Workspace.debug
                            "provision_worktrees: gitdir normalization failed for %s/%s: %s"
                            repo_name task_id msg);
                       let branch_name =
                         Printf.sprintf "task/%s" task_id
                       in
                       let _checkout =
                         run_git ~timeout_sec:read_only_probe_timeout_sec
                           ~clone_path:worktree_path
                           [ "checkout"; "-b"; branch_name ]
                       in
                       Log.Workspace.info
                         "provision_worktrees: worktree created for %s/%s"
                         repo_name task_id
                     )
                     else
                       Log.Workspace.debug
                         "provision_worktrees: skipped %s/%s from %s: %s"
                         repo_name task_id base_ref add_result.output)))
        entries

(* ── Sandbox repo currency (fetch + work-preserving fast-forward) ──── *)

(** Build a minimal [repository] record for the sandbox clone lane.
    [auto_sync]/[sync_interval] are 0/false because the playground lane is
    advanced explicitly by [ensure_current], not by the [.masc/repos] periodic
    [repo_sync] fiber. *)
let make_repo_record ~repo_name ~url ~clone_path ~default_branch ~keeper_name
    : Repo_manager_types.repository =
  let open Repo_manager_types in
  {
    id = repo_name;
    name = repo_name;
    url;
    local_path = clone_path;
    aliases = [];
    default_branch;
    keepers = [ keeper_name ];
    status = Active;
    auto_sync = false;
    sync_interval = 0;
    created_at = 0L;
    updated_at = 0L;
  }

(** Outcome of a currency pass. Every non-[Advanced] case leaves the working
    tree byte-for-byte untouched. *)
type currency_outcome =
  | Up_to_date
  | Advanced of int
      (** fast-forwarded; payload is the number of commits gained *)
  | Preserved of string
      (** not advanced (dirty / detached / task branch / diverged); the
          working tree is left untouched. payload is the reason *)
  | Skipped of string
      (** not applicable (not a ready clone / no repository URL / fetch failed);
          payload is the reason *)

let count_behind ~clone_path ~target_ref =
  let r =
    run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path
      [ "rev-list"; "--count"; "HEAD.." ^ target_ref ]
  in
  if r.ok then int_of_string_opt (String.trim r.output) else None

(** [Some true] iff [ancestor] is an ancestor of [descendant] (a fast-forward
    from [ancestor] to [descendant] is possible); [Some false] iff not; [None]
    on probe error. [git merge-base --is-ancestor] exits 0 = yes, 1 = no. *)
let is_ancestor ~clone_path ~ancestor ~descendant =
  let r =
    run_git ~timeout_sec:read_only_probe_timeout_sec ~clone_path
      [ "merge-base"; "--is-ancestor"; ancestor; descendant ]
  in
  match r.status with
  | Unix.WEXITED 0 -> Some true
  | Unix.WEXITED 1 -> Some false
  | _ -> None

(** [ensure_current ~config ~meta ~repo_name ()] fetches [origin] and, when the
    sandbox clone is clean, on [default_branch], and a pure fast-forward behind
    [origin/<default_branch>], advances it with [Repo_git.fast_forward]. Any
    other state (dirty / detached / on a task branch / diverged) is left
    untouched and reported as [Preserved] -- uncommitted and unpushed work is
    never overwritten. Missing/corrupt clones are out of scope here (that is
    [ensure_ready]'s repair path) and return [Skipped]. *)
let ensure_current ~(config : Workspace.config) ~(meta : keeper_meta) ~repo_name
    ?(default_branch = "main") () : currency_outcome =
  if not (safe_repo_component repo_name) then
    Skipped (Printf.sprintf "invalid repo_name: %s" repo_name)
  else
    let cpath = clone_path ~config ~meta ~repo_name in
    let probe = inspect ~config ~meta ~repo_name ~default_branch () in
    let state =
      match Json_util.assoc_member_opt "state" probe with
      | Some (`String s) -> s
      | _ -> "unknown"
    in
    match state with
    | "invalid_repo_name" | "missing_clone" | "not_git_repo" | "missing_origin"
    | "status_failed" ->
        Skipped (Printf.sprintf "repo not a ready clone (state=%s)" state)
    | _ -> (
        match find_repo_url ~config ~repo_name with
        | None -> Skipped "repo not in repositories.toml"
        | Some url -> (
            let repo =
              make_repo_record ~repo_name ~url ~clone_path:cpath ~default_branch
                ~keeper_name:meta.name
            in
            match Repo_git.fetch ~repository:repo with
            | Error msg -> Skipped (Printf.sprintf "fetch failed: %s" msg)
            | Ok _ -> (
                let target_ref = "origin/" ^ default_branch in
                let behind = count_behind ~clone_path:cpath ~target_ref in
                let dirty =
                  let s =
                    run_git ~timeout_sec:read_only_probe_timeout_sec
                      ~clone_path:cpath [ "status"; "--porcelain" ]
                  in
                  s.ok && String.trim s.output <> ""
                in
                let branch =
                  run_git ~timeout_sec:read_only_probe_timeout_sec
                    ~clone_path:cpath [ "branch"; "--show-current" ]
                  |> fun r -> if r.ok then first_line_opt r.output else None
                in
                match behind with
                | Some 0 -> Up_to_date
                | _ when dirty ->
                    Preserved "uncommitted changes in the working tree"
                | _ -> (
                    match branch with
                    | None -> Preserved "detached HEAD"
                    | Some b when not (String.equal b default_branch) ->
                        Preserved
                          (Printf.sprintf "on task branch %s (not %s)" b
                             default_branch)
                    | Some _ -> (
                        match
                          is_ancestor ~clone_path:cpath ~ancestor:"HEAD"
                            ~descendant:target_ref
                        with
                        | Some true -> (
                            match
                              Repo_git.fast_forward ~repository:repo ~target_ref
                            with
                            | Ok () -> Advanced (Option.value ~default:0 behind)
                            | Error msg ->
                                Preserved
                                  (Printf.sprintf "fast-forward refused: %s" msg))
                        | Some false ->
                            Preserved
                              "local branch has commits not on origin (diverged)"
                        | None ->
                            Preserved
                              "could not determine fast-forward eligibility")))))
