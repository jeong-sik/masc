(** Playground repository readiness.

    This module owns repository clone readiness for playground repo lanes.
    Keeper callers may ask whether a cwd-backed repo is usable, but clone/fetch
    provisioning policy lives here instead of keeper execution code. *)

open Keeper_types
open Keeper_meta_contract

type command_result =
  { ok : bool
  ; output : string
  ; status : Unix.process_status
  }

(* Read-only git probe: hang protection is git's responsibility via
   `--no-optional-locks` (refuses to take a long-lived lock per command).
   NFS or corrupt-repo hang is the tool's domain, not the caller's;
   see PR #20479 spirit (caller-specific timeout closure). *)
let run_git ~clone_path args =
  let argv = [ "git"; "-C"; clone_path; "--no-optional-locks" ] @ args in
  let status, output =
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:`Workspace_git
      ~raw_source:(String.concat " " argv)
      ~summary:"playground repo readiness git probe"
      argv
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
    run_git ~clone_path:path
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
      run_git ~clone_path [ "rev-parse"; "--is-inside-work-tree" ]
    in
    let top =
      if inside.ok then
        run_git ~clone_path
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
          ~clone_path [ "status"; "--porcelain" ]
      in
      let dirty = status.ok && String.trim status.output <> "" in
      let branch =
        run_git ~clone_path [ "branch"; "--show-current" ]
        |> fun r -> if r.ok then first_line_opt r.output else None
      in
      let head =
        run_git ~clone_path [ "rev-parse"; "--short"; "HEAD" ]
        |> fun r -> if r.ok then first_line_opt r.output else None
      in
      let upstream =
        run_git ~clone_path
          [ "rev-parse"; "--abbrev-ref"; "--symbolic-full-name"; "@{upstream}" ]
      in
      let upstream_name = if upstream.ok then first_line_opt upstream.output else None in
      let ahead, behind =
        match upstream_name with
        | None -> None, None
        | Some _ -> (
            let counts =
              run_git
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
        run_git ~clone_path [ "remote"; "get-url"; "origin" ]
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

(** Look up the repository URL from [repositories.toml] by repo id/name/alias. *)
let find_repo_url ~(config : Workspace.config) ~repo_name =
  Repo_store.find_url_by_identity ~base_path:config.Workspace.base_path repo_name

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
    run_git ~clone_path
      [ "rev-list"; "--count"; "HEAD.." ^ target_ref ]
  in
  if r.ok then int_of_string_opt (String.trim r.output) else None

(** [Some true] iff [ancestor] is an ancestor of [descendant] (a fast-forward
    from [ancestor] to [descendant] is possible); [Some false] iff not; [None]
    on probe error. [git merge-base --is-ancestor] exits 0 = yes, 1 = no. *)
let is_ancestor ~clone_path ~ancestor ~descendant =
  let r =
    run_git ~clone_path
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
                    run_git ~clone_path:cpath [ "status"; "--porcelain" ]
                  in
                  s.ok && String.trim s.output <> ""
                in
                let branch =
                  run_git ~clone_path:cpath [ "branch"; "--show-current" ]
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
