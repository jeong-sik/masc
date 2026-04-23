(** Keeper repository readiness.

    This is a read-only probe for the single keeper sandbox repo clone under
    the keeper's backend-scoped sandbox repo lane. It gives preflight callers a
    concrete answer about whether code work can safely start from that clone. *)

open Keeper_types

type command_result =
  { ok : bool
  ; output : string
  ; status : Unix.process_status
  }

let run_git ~timeout_sec ~clone_path args =
  let argv = [ "git"; "-C"; clone_path; "--no-optional-locks" ] @ args in
  let status, output =
    Process_eio.run_argv_with_status ~timeout_sec argv
  in
  { ok = status = Unix.WEXITED 0; output = String.trim output; status }

let safe_is_dir path =
  try Sys.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false

let safe_repo_component s =
  s <> "" && s <> "." && s <> ".."
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

let clone_path ~(config : Coord.config) ~(meta : keeper_meta) ~repo_name =
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
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ?repo_name
    ?(repo = "")
    ?(default_branch = "main")
    ()
  =
  let project_root = Keeper_alerting_path.project_root_of_config config in
  let derived_repo_name =
    match repo_name with
    | Some name when String.trim name <> "" -> String.trim name
    | _ -> repo_name_of_repo_arg ~project_root repo
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
    let workspace_matches =
      Coord_worktree.workspace_repo_matches ~search_root:project_root
        ~repo_name:derived_repo_name
    in
    (match workspace_matches with
     | [ source_root ] ->
         (match Coord_worktree.git_origin_url source_root with
          | Some origin_url -> (
              match
                Tool_code_write.validate_clone_url
                  ~base_path:config.base_path origin_url
              with
              | Ok () ->
                  common_fields "auto_provisionable" true
                    (Printf.sprintf
                       "Call masc_worktree_create with repo_name=%S; the sandbox clone \
                        will be auto-provisioned from origin %s discovered via workspace repo %s."
                       derived_repo_name origin_url source_root)
                    [
                      "exists", `Bool false;
                      "is_git_repo", `Bool false;
                      "has_origin", `Bool false;
                      "workspace_repo_match", `String source_root;
                      "workspace_repo_origin", `String origin_url;
                      "auto_provision_on_worktree_create", `Bool true;
                    ]
              | Error err ->
                  common_fields "workspace_origin_not_allowed" false
                    (Printf.sprintf
                       "Workspace repo %s points at origin %s, but clone policy rejected it: %s. \
                        Update allowlist or use an approved repo."
                       source_root origin_url err)
                    [
                      "exists", `Bool false;
                      "is_git_repo", `Bool false;
                      "has_origin", `Bool true;
                      "workspace_repo_match", `String source_root;
                      "workspace_repo_origin", `String origin_url;
                      "auto_provision_on_worktree_create", `Bool false;
                    ])
          | None ->
              common_fields "workspace_origin_unavailable" false
                (Printf.sprintf
                   "Workspace repo %s has no origin remote. Sandbox auto-provision requires cloning from origin."
                   source_root)
                [
                  "exists", `Bool false;
                  "is_git_repo", `Bool false;
                  "has_origin", `Bool false;
                  "workspace_repo_match", `String source_root;
                  "auto_provision_on_worktree_create", `Bool false;
                ])
     | _ :: _ as matches ->
         common_fields "ambiguous_workspace_repo" false
           (Printf.sprintf
              "Multiple workspace repos named %s exist under %s. Use \
               keeper_shell op=git_clone explicitly or disambiguate repo_name."
              derived_repo_name project_root)
           [
             "exists", `Bool false;
             "is_git_repo", `Bool false;
             "has_origin", `Bool false;
             ( "workspace_repo_matches",
               `List (List.map (fun path -> `String path) matches) );
           ]
     | [] ->
         common_fields "missing_clone" false
           "Clone the repo into sandbox repos/ first with keeper_shell op=git_clone, then create a worktree."
           [
             "exists", `Bool false;
             "is_git_repo", `Bool false;
             "has_origin", `Bool false;
           ])
  else
    let inside =
      run_git ~timeout_sec:5.0 ~clone_path [ "rev-parse"; "--is-inside-work-tree" ]
    in
    if not inside.ok then
      common_fields "not_git_repo" false
        "This sandbox repo directory is not a git clone; reclone it under repos/."
        [
          "exists", `Bool true;
          "is_git_repo", `Bool false;
          "has_origin", `Bool false;
          "git_error", `String inside.output;
        ]
    else
      let status =
        run_git ~timeout_sec:10.0 ~clone_path [ "status"; "--porcelain" ]
      in
      let dirty = status.ok && String.trim status.output <> "" in
      let branch =
        run_git ~timeout_sec:5.0 ~clone_path [ "branch"; "--show-current" ]
        |> fun r -> if r.ok then first_line_opt r.output else None
      in
      let head =
        run_git ~timeout_sec:5.0 ~clone_path [ "rev-parse"; "--short"; "HEAD" ]
        |> fun r -> if r.ok then first_line_opt r.output else None
      in
      let upstream =
        run_git ~timeout_sec:5.0 ~clone_path
          [ "rev-parse"; "--abbrev-ref"; "--symbolic-full-name"; "@{upstream}" ]
      in
      let upstream_name = if upstream.ok then first_line_opt upstream.output else None in
      let ahead, behind =
        match upstream_name with
        | None -> None, None
        | Some _ -> (
            let counts =
              run_git ~timeout_sec:10.0 ~clone_path
                [ "rev-list"; "--left-right"; "--count"; "@{upstream}...HEAD" ]
            in
            if counts.ok then
              match parse_ahead_behind counts.output with
              | Some (ahead, behind) -> Some ahead, Some behind
              | None -> None, None
            else None, None)
      in
      let origin =
        run_git ~timeout_sec:5.0 ~clone_path [ "remote"; "get-url"; "origin" ]
      in
      let has_origin = origin.ok && String.trim origin.output <> "" in
      let state, ok, next_action =
        if not status.ok then
          "status_failed", false,
          "Run keeper_shell op=git_status in this repo; repair git status before starting work."
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
          | _ -> "ready", true, "Create a task worktree from the fetched origin branch before editing."
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
        @ int_opt_field "behind" behind)
