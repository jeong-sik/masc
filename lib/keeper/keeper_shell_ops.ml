open Keeper_types
open Keeper_exec_shared

let handle_keeper_shell
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~exec_cache:(_exec_cache : Masc_exec.Exec_cache.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let op_str =
    Safe_ops.json_string ~default:"" "op" args |> String.trim |> String.lowercase_ascii
  in
  let root = Keeper_alerting_path.project_root_of_config config in
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  (* RFC-0006 Phase B-1.5: pin host-FS read guard for Docker keeper
     shell read ops. Local keepers remain on the host path. *)
  (* Actionable error: Samchon/Claude Code validateInput pattern.
     Returns structured JSON with tried path, playground root, and concrete next action. *)
  match Keeper_shell_shared.shell_op_of_string op_str with
  | None ->
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool false
          ; "error", `String "unsupported_op"
          ; "op", `String op_str
          ; ( "supported_ops"
              (* Issue #8524: derive from Variant SSOT instead of a
                 hand-rolled duplicate. *)
            , `List
                (List.map
                   (fun name -> `String name)
                   Keeper_shell_shared.valid_shell_op_strings) )
          ])
  | Some shell_op ->
    let op = Keeper_shell_shared.shell_op_to_string shell_op in
    match shell_op with
    | Pwd ->
      Keeper_shell_runtime.with_cwd_target ~config ~meta ~args ~root ~op ~raw_path
        (fun cwd ->
          Keeper_shell_runtime.run_cwd_op ~root ~keeper_name:meta.name ~op ~config ~meta
            ?turn_sandbox_factory ~cwd ~cmd:"pwd" ~docker_cmd:"pwd"
            ~command_argv:[ Keeper_shell_runtime.coreutils.pwd ]
            ~map_output:(Keeper_shell_runtime.hostify_turn_runtime_output ~config ~meta)
            ~max_bytes:4096 ~timeout_sec:Keeper_shell_shared.io_timeout_sec ())
    | Git_status ->
      Keeper_shell_runtime.with_cwd_target ~config ~meta ~args ~root ~op ~raw_path
        (fun cwd ->
          Keeper_shell_runtime.run_cwd_op ~root ~keeper_name:meta.name ~op ~config ~meta
            ?turn_sandbox_factory ~cwd
            ~cmd:"git -C <cwd> --no-optional-locks status --short --branch"
            ~docker_cmd:"git --no-optional-locks status --short --branch"
            ~command_argv:[ "git"; "--no-optional-locks"; "status"; "--short"; "--branch" ]
            ~max_bytes:1_000_000
            ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
    | Ls ->
      Keeper_shell_runtime.with_read_target ~config ~meta ~args ~root ~op ~raw_path
        (fun target ->
          let limit = shell_readonly_limit args in
          Keeper_shell_runtime.run_ls_op ~config ~meta ?turn_sandbox_factory
            ~op ~target ~limit ~timeout_sec:Keeper_shell_shared.io_timeout_sec ())
    | Cat ->
      Keeper_shell_runtime.with_read_target ~config ~meta ~args ~root ~op ~raw_path
        (fun target ->
          let max_bytes = shell_readonly_cat_max_bytes args in
          Keeper_shell_runtime.run_cat_op ~config ~meta ?turn_sandbox_factory
            ~op ~target ~max_bytes ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
    | Rg ->
      Keeper_shell_rg.handle ~op ~meta ~config ~args ?turn_sandbox_factory ~root ~raw_path
    | Git_log ->
      Keeper_shell_git_log.handle ~op ~meta ~config ~args ?turn_sandbox_factory ~root
    | Find ->
      Keeper_shell_find.handle ~op ~meta ~config ~args ?turn_sandbox_factory ~root ~raw_path
    | Head | Tail ->
      Keeper_shell_runtime.with_read_target ~config ~meta ~args ~root ~op ~raw_path
        (fun target ->
          let n = max 1 (min 200 (Safe_ops.json_int ~default:20 "lines" args)) in
          Keeper_shell_runtime.run_head_tail_op ~config ~meta ?turn_sandbox_factory
            ~op ~target ~n ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
    | Wc ->
      Keeper_shell_runtime.with_read_target ~config ~meta ~args ~root ~op ~raw_path
        (fun target ->
          Keeper_shell_runtime.run_wc_op ~root ~keeper_name:meta.name ~config ~meta
            ?turn_sandbox_factory ~op ~target
            ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
    | Tree ->
      Keeper_shell_runtime.with_read_target ~config ~meta ~args ~root ~op ~raw_path
        (fun target ->
          let limit = shell_readonly_limit args in
          Keeper_shell_runtime.run_tree_op ~config ~meta ?turn_sandbox_factory
            ~op ~target ~limit ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
    | Git_diff ->
      Keeper_shell_runtime.with_cwd_target ~config ~meta ~args ~root ~op ~raw_path
        (fun cwd ->
          Keeper_shell_runtime.run_cwd_op ~root ~keeper_name:meta.name ~op ~config ~meta
            ?turn_sandbox_factory ~cwd ~cmd:"git diff --stat"
            ~docker_cmd:"git --no-optional-locks diff --stat"
            ~command_argv:[ "git"; "--no-optional-locks"; "diff"; "--stat" ]
            ~max_bytes:1_000_000 ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
    | Git_worktree ->
      Keeper_shell_git_worktree.handle ~op ~meta ~config ~args ?turn_sandbox_factory
        ~root ~raw_path
    | Git_clone ->
      Keeper_shell_clone.handle ~op ~meta ~config ~args
    | Gh ->
      Keeper_shell_gh.handle ~op ~meta ~config ~args
;;
