open Keeper_types
open Keeper_exec_shared

let handle_keeper_shell
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~exec_cache:(_exec_cache : Masc_exec.Exec_cache.t option)
      ~(config : Coord.config)
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
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  (* RFC-0006 Phase B-1.5: pin host-FS read guard for Docker keeper
     shell read ops. Local keepers remain on the host path. *)
  (* Actionable error: Samchon/Claude Code validateInput pattern.
     Returns structured JSON with tried path, playground root, and concrete next action. *)
  let path_error e =
    actionable_path_error ~op ~meta ~raw_path ~error:e
  in
  match op with
  | "pwd" ->
    (match Keeper_shell_runtime.cwd_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok cwd ->
       Keeper_shell_runtime.run_cwd_op ~root ~keeper_name:meta.name ~op ~config ~meta
         ?turn_sandbox_factory ~cwd ~cmd:"pwd" ~docker_cmd:"pwd"
         ~command_argv:[ Keeper_shell_runtime.coreutils.pwd ]
         ~map_output:(Keeper_shell_runtime.hostify_turn_runtime_output ~config ~meta)
         ~max_bytes:4096 ~timeout_sec:Keeper_shell_shared.io_timeout_sec ())
  | "git_status" ->
    (match Keeper_shell_runtime.cwd_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok cwd ->
       Keeper_shell_runtime.run_cwd_op ~root ~keeper_name:meta.name ~op ~config ~meta
         ?turn_sandbox_factory ~cwd
         ~cmd:"git -C <cwd> --no-optional-locks status --short --branch"
         ~docker_cmd:"git --no-optional-locks status --short --branch"
         ~command_argv:[ "git"; "--no-optional-locks"; "status"; "--short"; "--branch" ]
         ~max_bytes:1_000_000
         ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
  | "ls" ->
    (match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok target ->
       let limit = shell_readonly_limit args in
       Keeper_shell_runtime.run_ls_op ~config ~meta ?turn_sandbox_factory
         ~op ~target ~limit ~timeout_sec:Keeper_shell_shared.io_timeout_sec ())
  | "cat" ->
    (match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok target ->
       let max_bytes = shell_readonly_cat_max_bytes args in
       Keeper_shell_runtime.run_cat_op ~config ~meta ?turn_sandbox_factory
         ~op ~target ~max_bytes ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
  | "rg" ->
    Keeper_shell_rg.handle ~op ~meta ~config ~args ?turn_sandbox_factory ~root ~raw_path
  | "git_log" ->
    Keeper_shell_git_log.handle ~op ~meta ~config ~args ?turn_sandbox_factory ~root
  | "find" ->
    Keeper_shell_find.handle ~op ~meta ~config ~args ?turn_sandbox_factory ~root ~raw_path
  | "head" | "tail" ->
    (match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok target ->
       let n = max 1 (min 200 (Safe_ops.json_int ~default:20 "lines" args)) in
       Keeper_shell_runtime.run_head_tail_op ~config ~meta ?turn_sandbox_factory
         ~op ~target ~n ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
  | "wc" ->
    (match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok target ->
       Keeper_shell_runtime.run_wc_op ~root ~keeper_name:meta.name ~config ~meta
         ?turn_sandbox_factory ~op ~target
         ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
  | "tree" ->
    (match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok target ->
       let limit = shell_readonly_limit args in
       Keeper_shell_runtime.run_tree_op ~config ~meta ?turn_sandbox_factory
         ~op ~target ~limit ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
  | "git_diff" ->
    (match Keeper_shell_runtime.cwd_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok cwd ->
       Keeper_shell_runtime.run_cwd_op ~root ~keeper_name:meta.name ~op ~config ~meta
         ?turn_sandbox_factory ~cwd ~cmd:"git diff --stat"
         ~docker_cmd:"git --no-optional-locks diff --stat"
         ~command_argv:[ "git"; "--no-optional-locks"; "diff"; "--stat" ]
         ~max_bytes:1_000_000 ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
  | "git_worktree" ->
    Keeper_shell_git_worktree.handle ~op ~meta ~config ~args ?turn_sandbox_factory
      ~root ~raw_path
  | "git_clone" ->
    Keeper_shell_clone.handle ~op ~meta ~config ~args
  | "gh" ->
    Keeper_shell_gh.handle ~op ~meta ~config ~args
  | _ ->
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool false
          ; "error", `String "unsupported_op"
          ; "op", `String op
          ; ( "supported_ops"
              (* Issue #8524: derive from Variant SSOT instead of a
                 hand-rolled duplicate. *)
            , `List
                (List.map
                   (fun name -> `String name)
                   Keeper_shell_shared.valid_shell_op_strings) )
          ])
;;
