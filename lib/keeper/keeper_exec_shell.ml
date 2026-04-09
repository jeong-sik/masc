open Keeper_types
open Keeper_exec_shared

(** Shell operation timeout constants.
    - [io_timeout_sec]: commands that may block on network/disk I/O
      (git status, ls with large dirs, custom bash).
    - [read_timeout_sec]: fast read-only commands on local files
      (cat, rg, head, tail, find, git_log, tree).
    - [user_timeout_max_sec]: upper bound for user-provided timeout_sec
      in keeper_bash (prevents indefinite blocking). *)
let io_timeout_sec = 30.0
let read_timeout_sec = 15.0
let user_timeout_max_sec = 180.0

(** Write playground repo state cache after successful clone/pull.
    Reads git metadata from [repo_path] and upserts into
    [playground_dir/.playground_state.json]. Best-effort: failures are logged
    but do not propagate. *)
let update_playground_repo_cache
      ~(playground_dir : string) ~(repo_name : string) ~(repo_path : string)
      ~(action : string) ~(shallow : bool) : unit =
  try
    let branch =
      let st, s = Process_eio.run_argv_with_status ~timeout_sec:5.0
        [ "git"; "-C"; repo_path; "rev-parse"; "--abbrev-ref"; "HEAD" ] in
      if st = Unix.WEXITED 0 then String.trim s else "unknown"
    in
    let commit =
      let st, s = Process_eio.run_argv_with_status ~timeout_sec:5.0
        [ "git"; "-C"; repo_path; "log"; "--oneline"; "-1" ] in
      if st = Unix.WEXITED 0 then String.trim s else ""
    in
    let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
    let entry = `Assoc [
      "name", `String repo_name;
      "branch", `String branch;
      "latest_commit", `String commit;
      "shallow", `Bool shallow;
      "last_action", `String action;
      "updated_at", `String ts;
    ] in
    let cache_path = Filename.concat playground_dir ".playground_state.json" in
    let existing =
      try
        let json = Yojson.Safe.from_file cache_path in
        (match Yojson.Safe.Util.member "repos" json with
         | `List repos -> repos
         | _ -> [])
      with Sys_error _ | Yojson.Json_error _ -> []
    in
    let updated =
      entry :: List.filter (fun r ->
        match Yojson.Safe.Util.member "name" r with
        | `String n -> n <> repo_name
        | _ -> true) existing
    in
    let json = `Assoc [
      "repos", `List updated;
      "last_updated", `String ts;
    ] in
    ignore (Fs_compat.save_file_atomic cache_path
      (Yojson.Safe.pretty_to_string json ^ "\n"))
  with exn ->
    Logs.warn (fun f -> f "playground cache update failed: %s"
      (Printexc.to_string exn))

let resolve_keeper_shell_read_cwd
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then Ok (keeper_default_read_root ~config ~meta)
    else resolve_keeper_read_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Sys.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd -> Error (Printf.sprintf "cwd_not_directory: %s" cwd)

let resolve_keeper_shell_write_cwd
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then Ok (keeper_default_read_root ~config ~meta)
    else resolve_keeper_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Sys.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd -> Error (Printf.sprintf "cwd_not_directory: %s" cwd)

let handle_keeper_bash
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
  let cmd_for_log =
    cmd
    |> Worker_dev_tools.sanitize_command_for_log
    |> Worker_dev_tools.truncate_for_log
  in
  let timeout_sec =
    Safe_ops.json_float ~default:io_timeout_sec "timeout_sec" args |> fun n -> max 1.0 (min user_timeout_max_sec n)
  in
  (* Write access is config-driven via permissions.shell_write_presets *)
  let write_enabled =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some preset -> Keeper_tool_policy.allows_shell_write_for_preset preset
    | None -> false
  in
  if cmd = ""
  then error_json "cmd is required. Good: cmd='ls -la lib/'. Bad: cmd=''."

  else
    let validate =
      if write_enabled then Worker_dev_tools.validate_command_coding
      else Worker_dev_tools.validate_command
    in
    match validate cmd with
    | Error reason ->
      Log.Keeper.warn "keeper_bash blocked: %s (cmd=%s)" reason cmd_for_log;
      let hint =
        if String.length reason > 0 &&
           (Re.execp (Re.Pcre.re "chain|redirect|pipe|semicolon" |> Re.compile) (String.lowercase_ascii reason))
        then "Use separate tool calls instead of chaining. Call keeper_bash once per command."
        else if Re.execp (Re.Pcre.re "inject|symbol" |> Re.compile) (String.lowercase_ascii reason)
        then "Avoid shell metacharacters. Use keeper_shell with a specific op (rg, find, ls) instead."
        else "Check the command for blocked patterns. Use keeper_shell for structured ops (rg, ls, find)."
      in
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool false
            ; "error", `String "command_blocked"
            ; "reason", `String reason
            ; "hint", `String hint
            ])
    | Ok () ->
      (* Destructive guard: always active regardless of preset *)
      if Worker_dev_tools.is_destructive_bash_operation cmd
      then (
        Log.Keeper.warn "keeper_bash DESTRUCTIVE blocked: %s (keeper=%s)" cmd_for_log meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "destructive_operation_blocked"
              ; ( "reason"
                , `String
                    "This command is destructive (force push, push to main, rm -rf, \
                     etc.) and is blocked for all presets." )
              ; "cmd", `String cmd_for_log
              ]))
      (* Branch-switch guard: keeper_bash must not mutate git branch state.
         Use keeper_pr_workflow to create changes in an isolated clone/worktree. *)
      else if Worker_dev_tools.is_git_branch_switch cmd
      then (
        Log.Keeper.info "keeper_bash branch-switch blocked: %s (keeper=%s)" cmd_for_log meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "branch_switch_blocked"
              ; ( "reason"
                , `String
                    "git checkout, git switch, and git branch mutations \
                     (create/rename/copy) are blocked in the main repo. \
                     Plain git branch listing is allowed. \
                     Use keeper_pr_workflow to create changes in an isolated clone." )
              ; "cmd", `String cmd_for_log
              ; "hint", `String "keeper_pr_workflow"
              ]))
      (* Write gate: only for non-coding presets *)
      else if (not write_enabled) && Worker_dev_tools.is_write_operation cmd
      then (
        Log.Keeper.info "keeper_bash write-gate: %s (keeper=%s)" cmd_for_log meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "write_operation_gated"
              ; ( "reason"
                , `String
                    "This command modifies state (git push/commit, make deploy, etc.). \
                     Use a Coding preset keeper for write access." )
              ; "cmd", `String cmd_for_log
              ]))
      else (
        match resolve_keeper_shell_write_cwd ~config ~meta ~args with
        | Error e -> error_json e
        | Ok cwd ->
          (match Worker_dev_tools.validate_command_paths ~workdir:cwd cmd with
           | Error e -> error_json e
           | Ok () ->
             if write_enabled && Worker_dev_tools.is_write_operation cmd then
               Log.Keeper.info "WRITE_AUDIT: keeper=%s cwd=%s cmd=%s"
                 meta.name cwd cmd_for_log;
             let st, out =
               Process_eio.run_argv_with_status ~cwd ~timeout_sec
                 [ "/bin/bash"; "-lc"; cmd ^ " 2>&1" ]
             in
             Yojson.Safe.to_string
               (`Assoc
                   [ "ok", `Bool (st = Unix.WEXITED 0)
                   ; "cwd", `String cwd
                   ; "status", Keeper_alerting_path.process_status_to_json st
                   ; "output", `String out
                   ])))
;;

let handle_keeper_shell
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_op =
    Safe_ops.json_string ~default:"" "op" args |> String.trim |> String.lowercase_ascii
  in
  (* Normalize common aliases so the model's naming variation doesn't cause
     unsupported_op failures. *)
  let op = match raw_op with
    | "git status" | "status" -> "git_status"
    | "git log" -> "git_log"
    | "git diff" -> "git_diff"
    | "git worktree" | "worktree" -> "git_worktree"
    | "read" | "file" | "type" -> "cat"
    | "grep" | "search" -> "rg"
    | "dir" | "list" -> "ls"
    | "git clone" | "clone" -> "git_clone"
    | _ -> raw_op
  in
  let root = Keeper_alerting_path.project_root_of_config config in
  let read_target () =
    let raw_path = Safe_ops.json_string ~default:"." "path" args in
    resolve_keeper_read_path ~config ~meta ~raw_path
  in
  let cwd_target () = resolve_keeper_shell_read_cwd ~config ~meta ~args in
  let render_process_result ?cwd ~cmd argv =
    let st, out =
      Process_eio.run_argv_with_status ?cwd ~timeout_sec:io_timeout_sec argv
    in
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool (st = Unix.WEXITED 0)
          ; "op", `String op
          ; "cmd", `String cmd
          ; ( "cwd"
            , match cwd with
              | Some dir -> `String dir
              | None -> `Null )
          ; "status", Keeper_alerting_path.process_status_to_json st
          ; "output", `String out
          ])
  in
  match op with
  | "pwd" ->
    (match cwd_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok cwd -> render_process_result ~cwd ~cmd:"pwd" [ "/bin/pwd" ])
  | "git_status" ->
    (match cwd_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok cwd ->
       render_process_result ~cwd
         ~cmd:"git -C <cwd> --no-optional-locks status --short --branch"
         [ "git"; "-C"; cwd; "--no-optional-locks"; "status"; "--short"; "--branch" ])
  | "ls" ->
    (match read_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok target ->
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:io_timeout_sec [ "/bin/ls"; "-la"; target ]
       in
       let limit = shell_readonly_limit args in
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool (st = Unix.WEXITED 0)
             ; "op", `String op
             ; "path", `String target
             ; "status", Keeper_alerting_path.process_status_to_json st
             ; "entries", lines_to_json ~limit out
             ]))
  | "cat" ->
    (match read_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok target ->
       let max_bytes = shell_readonly_cat_max_bytes args in
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec [ "/bin/cat"; target ]
       in
       let body =
         if String.length out > max_bytes then String.sub out 0 max_bytes else out
       in
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool (st = Unix.WEXITED 0)
             ; "op", `String op
             ; "path", `String target
             ; "status", Keeper_alerting_path.process_status_to_json st
             ; "truncated", `Bool (String.length out > max_bytes)
             ; "content", `String body
             ]))
  | "rg" ->
    let pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
    if pattern = ""
    then error_json ~fields:[ "op", `String op ] "pattern is required for rg. Good: pattern='handle_request'. Bad: pattern=''."
    else (
      match read_target () with
      | Error e -> error_json ~fields:[ "op", `String op ] e
      | Ok target ->
        let limit = shell_readonly_limit args in
        (* Optional file-type filter (e.g. "ml", "py") *)
        let file_type = Safe_ops.json_string ~default:"" "type" args |> String.trim in
        (* Optional glob filter (e.g. "*.ml", "lib/**/*.ml") *)
        let glob = Safe_ops.json_string ~default:"" "glob" args |> String.trim in
        let base_argv = [ "rg"; "-n"; "-m"; string_of_int limit ] in
        let type_argv = if file_type <> "" then [ "--type"; file_type ] else [] in
        let glob_argv = if glob <> "" then [ "--glob"; glob ] else [] in
        let argv = base_argv @ type_argv @ glob_argv @ [ pattern; target ] in
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec argv
        in
        (* rg exit codes: 0=matches found, 1=no matches (not an error), 2+=real error.
           Treat exit 1 as success with empty results — "no match" is a valid answer. *)
        let is_ok = st = Unix.WEXITED 0 || st = Unix.WEXITED 1 in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool is_ok
              ; "op", `String op
              ; "path", `String target
              ; "pattern", `String pattern
              ; "status", Keeper_alerting_path.process_status_to_json st
              ; "matches", lines_to_json ~limit out
              ]))
  | "git_log" ->
    (match cwd_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok cwd ->
       let count = max 1 (min 50 (Safe_ops.json_int ~default:10 "count" args)) in
       let format = Safe_ops.json_string ~default:"%h %s" "format" args in
       let file_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
       let base_argv =
         [ "git"; "-C"; cwd; "--no-optional-locks"; "log";
           Printf.sprintf "--format=%s" format;
           Printf.sprintf "-%d" count ]
       in
       let argv = if file_path <> "" then base_argv @ [ "--"; file_path ] else base_argv in
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec argv
       in
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool (st = Unix.WEXITED 0)
             ; "op", `String op
             ; "cwd", `String cwd
             ; "count", `Int count
             ; "status", Keeper_alerting_path.process_status_to_json st
             ; "entries", lines_to_json ~limit:50 out
             ]))
  | "find" ->
    let name_pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
    if name_pattern = ""
    then error_json ~fields:[ "op", `String op ] "pattern is required for find. Good: pattern='*.ml'. Bad: pattern=''."
    else (
      match read_target () with
      | Error e -> error_json ~fields:[ "op", `String op ] e
      | Ok target ->
        let limit = shell_readonly_limit args in
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec
            [ "find"; target; "-maxdepth"; "5"; "-name"; name_pattern;
              "-not"; "-path"; "*/.git/*";
              "-not"; "-path"; "*/_build/*";
              "-not"; "-path"; "*/.masc/*" ]
        in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool (st = Unix.WEXITED 0)
              ; "op", `String op
              ; "path", `String target
              ; "name", `String name_pattern
              ; "status", Keeper_alerting_path.process_status_to_json st
              ; "files", lines_to_json ~limit out
              ]))
  | "head" ->
    (match read_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok target ->
       let n = Safe_ops.json_int ~default:20 "lines" args |> fun v -> max 1 (min 200 v) in
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec
           [ "/usr/bin/head"; "-n"; string_of_int n; target ]
       in
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool (st = Unix.WEXITED 0)
             ; "op", `String op
             ; "path", `String target
             ; "lines", `Int n
             ; "status", Keeper_alerting_path.process_status_to_json st
             ; "content", `String out
             ]))
  | "tail" ->
    (match read_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok target ->
       let n = Safe_ops.json_int ~default:20 "lines" args |> fun v -> max 1 (min 200 v) in
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec
           [ "/usr/bin/tail"; "-n"; string_of_int n; target ]
       in
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool (st = Unix.WEXITED 0)
             ; "op", `String op
             ; "path", `String target
             ; "lines", `Int n
             ; "status", Keeper_alerting_path.process_status_to_json st
             ; "content", `String out
             ]))
  | "wc" ->
    (match read_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok target ->
       render_process_result ~cmd:"wc" [ "/usr/bin/wc"; "-l"; target ])
  | "tree" ->
    (match read_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok target ->
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec
           [ "find"; target; "-maxdepth"; "3"; "-print";
             "-not"; "-path"; "*/.git/*";
             "-not"; "-path"; "*/_build/*" ]
       in
       let limit = shell_readonly_limit args in
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool (st = Unix.WEXITED 0)
             ; "op", `String op
             ; "path", `String target
             ; "status", Keeper_alerting_path.process_status_to_json st
             ; "entries", lines_to_json ~limit out
             ]))
  | "git_diff" ->
    (match cwd_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok cwd ->
       render_process_result ~cwd
         ~cmd:"git diff --stat"
         [ "git"; "-C"; cwd; "--no-optional-locks"; "diff"; "--stat" ])
  | "git_worktree" ->
    let action =
      Safe_ops.json_string ~default:"list" "action" args
      |> String.trim |> String.lowercase_ascii
    in
    begin match action with
    | "list" ->
      (match cwd_target () with
       | Error e -> error_json ~fields:[ "op", `String op ] e
       | Ok cwd ->
         render_process_result ~cwd ~cmd:"git worktree list"
           [ "git"; "-C"; cwd; "worktree"; "list" ])
    | "add" ->
      let branch = Safe_ops.json_string ~default:"" "branch" args |> String.trim in
      let base = Safe_ops.json_string ~default:"origin/main" "base" args |> String.trim in
      if branch = "" then
        error_json ~fields:[ "op", `String op ]
          "branch is required. Good: action='add', branch='feature/my-task'. Bad: branch=''."
      else (
        match cwd_target () with
        | Error e -> error_json ~fields:[ "op", `String op ] e
        | Ok cwd ->
          let _st, wt_out =
            Process_eio.run_argv_with_status ~timeout_sec:5.0
              [ "git"; "-C"; cwd; "worktree"; "list"; "--porcelain" ]
          in
          if String_util.contains_substring_ci wt_out branch then
            let existing_path =
              String.split_on_char '\n' wt_out
              |> List.find_map (fun line ->
                if String_util.contains_substring_ci line "worktree"
                   && String_util.contains_substring_ci wt_out branch
                then Some (String.trim line) else None)
              |> Option.value ~default:"(unknown)"
            in
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool false
                  ; "op", `String op
                  ; "error", `String "branch_already_in_worktree"
                  ; "branch", `String branch
                  ; "existing_worktree", `String existing_path
                  ; "hint", `String "Branch is already in a worktree. Use 'cd' to the existing path, or choose a different branch name."
                  ])
          else
            let wt_path = Printf.sprintf ".worktrees/%s"
              (String.map (fun c -> if c = '/' then '-' else c) branch)
            in
            render_process_result ~cwd
              ~cmd:(Printf.sprintf "git worktree add %s -b %s %s" wt_path branch base)
              [ "git"; "-C"; cwd; "worktree"; "add"; wt_path; "-b"; branch; base ]
      )
    | other ->
      error_json ~fields:[ "op", `String op ]
        (Printf.sprintf "Unknown git_worktree action '%s'. Use: list, add." other)
    end
  | "bash" ->
    let cmd_str = Safe_ops.json_string ~default:"" "command" args |> String.trim in
    if cmd_str = "" then error_json ~fields:[ "op", `String op ] "command is required for bash op. Good: command='env'. Bad: command=''."

    else
      (* Non-overridable deny layer (runs after preset gate).
         First match wins — specific patterns before generic. *)
      let hint_of_category = function
        | "chaining"        -> "Call the tool multiple times instead of chaining commands."
        | "redirect"        -> "Redirects are not allowed. Use keeper_fs_edit to write files."
        | "git_write"       -> "Use keeper_bash with coding preset for git write operations."
        | "package_install" -> "Package installation requires keeper_bash with coding preset."
        | "destructive"     -> "Use keeper_bash for write operations, not readonly shell."
        | _                 -> "This operation is not allowed in readonly shell."
      in
      let deny_patterns =
        [ (* chaining *)
          "&&", "chaining"
        ; "||", "chaining"
        ; ";", "chaining"
        (* redirect *)
        ; "| tee ", "redirect"
        ; ">> ", "redirect"
        ; "> ", "redirect"
        (* git write *)
        ; "git push", "git_write"
        ; "git reset", "git_write"
        ; "git checkout", "git_write"
        ; "git rebase", "git_write"
        (* package install *)
        ; "pip install", "package_install"
        ; "npm install", "package_install"
        ; "opam install", "package_install"
        (* destructive / write *)
        ; "rm ", "destructive"
        ; "rm\t", "destructive"
        ; "rmdir", "destructive"
        ; "mv ", "destructive"
        ; "cp ", "destructive"
        ; "chmod", "destructive"
        ; "chown", "destructive"
        ; "kill", "destructive"
        ; "pkill", "destructive"
        ; "dd ", "destructive"
        ; "mkfs", "destructive"
        ; "wget ", "destructive"
        ; "curl -o", "destructive"
        ; "curl --output", "destructive"
        ]
      in
      let matched =
        List.find_opt (fun (pat, _cat) ->
          String_util.contains_substring_ci cmd_str pat
        ) deny_patterns
      in
      (match matched with
      | Some (pat, category) ->
        let hint = hint_of_category category in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "op", `String op
              ; "error", `String "command_blocked_readonly"
              ; "blocked_pattern", `String pat
              ; "category", `String category
              ; "hint", `String hint
              ])
      | None ->
        (match cwd_target () with
         | Error e -> error_json ~fields:[ "op", `String op ] e
         | Ok cwd ->
           (match Worker_dev_tools.validate_command_paths ~workdir:cwd cmd_str with
            | Error e -> error_json ~fields:[ "op", `String op ] e
            | Ok () ->
              let st, out =
                Process_eio.run_argv_with_status ~cwd ~timeout_sec:io_timeout_sec
                  [ "bash"; "-lc"; cmd_str ^ " 2>&1" ]
              in
              Yojson.Safe.to_string
                (`Assoc
                    [ "ok", `Bool (st = Unix.WEXITED 0)
                    ; "op", `String op
                    ; "cwd", `String cwd
                    ; "command", `String cmd_str
                    ; "status", Keeper_alerting_path.process_status_to_json st
                    ; "output", `String out
                    ]))))
  | "git_clone" ->
    (* Clone a repo into this keeper's playground repos directory.
       Sandboxed: always targets .masc/playground/<keeper_name>/repos/<repo_name>.
       Validates against tool_policy.toml git_clone.allowed_orgs. *)
    let url = Safe_ops.json_string ~default:"" "url" args |> String.trim in
    if url = "" then
      error_json ~fields:[ "op", `String op ]
        "url is required for git_clone. Good: url='https://github.com/org/repo'. Bad: url=''."
    else
      let base_path = config.base_path in
      (match Tool_code_write.validate_clone_url ~base_path url with
       | Error reason ->
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool false
               ; "op", `String op
               ; "error", `String "clone_blocked"
               ; "reason", `String reason
               ; "url", `String url
               ])
       | Ok () ->
         ignore (Keeper_alerting_path.ensure_playground_bundle ~config ~name:meta.name);
         let playground = Filename.concat root
           (Keeper_alerting_path.playground_path_of_keeper meta.name) in
         let repos_dir = Filename.concat root
           (Keeper_alerting_path.playground_repos_path meta.name) in
         (* Derive repo name from URL: strip trailing slash, .git, then basename.
            Guard against empty/traversal names (e.g. url ending with "/" or ".."). *)
         let repo_name =
           let stripped =
             let s = String.trim url in
             if String.ends_with ~suffix:"/" s
             then String.sub s 0 (String.length s - 1) else s
           in
           let base = Filename.basename stripped in
           let name =
             if String.ends_with ~suffix:".git" base
             then String.sub base 0 (String.length base - 4)
             else base
           in
           (* Sanitize: only allow alphanumeric, hyphen, underscore, dot.
              Reject empty, ".", ".." to prevent traversal. *)
           let safe = String.map (fun c ->
             if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
             then c else '_') name
           in
           if safe = "" || safe = "." || safe = ".." then "repo" else safe
         in
         let clone_path = Filename.concat repos_dir repo_name in
         if Sys.file_exists clone_path then
           (* Already cloned — pull latest instead *)
           let st, out =
             Process_eio.run_argv_with_status ~timeout_sec:60.0
               [ "git"; "-C"; clone_path; "pull"; "--ff-only" ]
           in
           if st = Unix.WEXITED 0 then
             update_playground_repo_cache
               ~playground_dir:playground ~repo_name ~repo_path:clone_path
               ~action:"pull" ~shallow:false;
           Yojson.Safe.to_string
             (`Assoc
                 [ "ok", `Bool (st = Unix.WEXITED 0)
                 ; "op", `String op
                 ; "action", `String "pull"
                 ; "path", `String clone_path
                 ; "status", Keeper_alerting_path.process_status_to_json st
                 ; "output", `String out
                 ])
         else
           let depth = Keeper_tool_policy.clone_depth () |> max 0 in
           let depth_args =
             if depth > 0 then ["--depth"; string_of_int depth] else []
           in
           let shallow = depth > 0 in
           let st, out =
             Process_eio.run_argv_with_status
               ~timeout_sec:(Keeper_tool_policy.clone_timeout_sec ())
               ("git" :: "clone" :: depth_args @ [ url; clone_path ])
           in
           if st = Unix.WEXITED 0 then
             update_playground_repo_cache
               ~playground_dir:playground ~repo_name ~repo_path:clone_path
               ~action:"clone" ~shallow;
           Yojson.Safe.to_string
             (`Assoc
                 [ "ok", `Bool (st = Unix.WEXITED 0)
                 ; "op", `String op
                 ; "action", `String "clone"
                 ; "path", `String clone_path
                 ; "status", Keeper_alerting_path.process_status_to_json st
                 ; "output", `String out
                 ]))
  | _ ->
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool false
          ; "error", `String "unsupported_op"
          ; "op", `String op
          ; ( "supported_ops"
            , `List
                (List.map
                   (fun name -> `String name)
                   [ "pwd"; "ls"; "cat"; "rg"; "git_status";
                     "find"; "head"; "tail"; "wc"; "tree";
                     "git_log"; "git_diff"; "git_worktree"; "bash";
                     "git_clone" ]) )
          ])
;;
