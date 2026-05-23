open Keeper_types
open Keeper_exec_shared

let handle
      ~op
      ~(meta : keeper_meta)
      ~(config : Coord.config)
      ~(args : Yojson.Safe.t)
      ?turn_sandbox_factory
      ~root
      ~raw_path
  =
  let action =
    Safe_ops.json_string ~default:"list" "action" args
    |> String.trim |> String.lowercase_ascii
  in
  begin match action with
  | "list" ->
    (match Keeper_shell_runtime.cwd_target ~config ~meta ~args ~base_path:root () with
     | Error e -> Keeper_shell_runtime.path_error ~op ~meta ~raw_path e
     | Ok cwd ->
       Keeper_shell_runtime.run_cwd_op ~root ~keeper_name:meta.name ~op ~config ~meta
         ?turn_sandbox_factory ~cwd
         ~cmd:"git worktree list"
         ~docker_cmd:"git worktree list"
         ~map_output:(Keeper_shell_runtime.hostify_turn_runtime_output ~config ~meta)
         ~command_argv:[ "git"; "worktree"; "list" ]
         ~max_bytes:1_000_000 ~timeout_sec:Keeper_shell_timeout.read_timeout_sec ())
  | "add" ->
    let branch = Safe_ops.json_string ~default:"" "branch" args |> String.trim in
    let base = Safe_ops.json_string ~default:"origin/main" "base" args |> String.trim in
    if branch = "" then
      error_json_for_op ~op
        "branch is required. Good: action='add', branch='feature/my-task'. Bad: branch=''."
    else (
      match Keeper_shell_runtime.cwd_target ~config ~meta ~args ~base_path:root () with
      | Error e -> Keeper_shell_runtime.path_error ~op ~meta ~raw_path e
      | Ok cwd ->
        let wt_out_result =
          let _st, wt_out =
            Keeper_shell_shared.run_argv_with_status_retry_eintr
              ~timeout_sec:Keeper_shell_timeout.git_meta_timeout_sec
              [ "git"; "-C"; cwd; "worktree"; "list"; "--porcelain" ]
          in
          Ok wt_out
        in
        match wt_out_result with
        | Error msg ->
          error_json ~fields:[ "op", `String op; "cwd", `String cwd ] msg
        | Ok wt_out ->
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
            Keeper_shell_runtime.render_process_result ~root ~keeper_name:meta.name ~op ~cwd
              ~cmd:(Printf.sprintf "git worktree add %s -b %s %s" wt_path branch base)
              [ "git"; "worktree"; "add"; wt_path; "-b"; branch; base ]
    )
  | other ->
    error_json_for_op ~op
      (Printf.sprintf "Unknown git_worktree action '%s'. Use: list, add." other)
  end
;;
