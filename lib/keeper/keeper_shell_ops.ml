(* keeper_shell_ops — public structured shell op dispatcher for keeper tools.

   Read/list/search operations live in Keeper_shell_read_ops. This facade keeps
   alias parsing, remaining git mutation-ish helpers, and unsupported-op
   reporting in one place. *)

open Keeper_types
open Keeper_exec_shared

include Keeper_shell_ops_setup

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
  let op =
    match raw_op with
    | "git status" | "status" -> "git_status"
    | "git log" -> "git_log"
    | "git diff" -> "git_diff"
    | "git worktree" | "worktree" -> "git_worktree"
    | "read" | "file" | "type" -> "cat"
    | "search" -> "rg"
    | "dir" | "list" -> "ls"
    | _ -> raw_op
  in
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  match
    Keeper_shell_read_ops.try_handle ~turn_sandbox_factory ~config ~meta ~args
      ~op ~raw_path
  with
  | Some response -> response
  | None ->
    let root = Keeper_alerting_path.project_root_of_config config in
    let containment_check target =
      Keeper_sandbox_containment.check_read_target ~config ~meta ~target
    in
    let repo_check target =
      Keeper_repo_mapping.validate_path_access ~keeper_id:meta.name
        ~base_path:root ~path:target
    in
    let cwd_target () =
      match Keeper_shell_path.resolve_keeper_shell_read_cwd ~config ~meta ~args with
      | Error _ as e -> e
      | Ok cwd ->
        (match containment_check cwd with
         | Error msg -> Error msg
         | Ok () ->
           match repo_check cwd with
           | Error msg -> Error msg
           | Ok () -> Ok cwd)
    in
    let path_error e =
      actionable_path_error ~op ~meta ~raw_path ~error:e
    in
    (* TEL-OK: adapter delegates to Keeper_shell_ir/Exec_dispatch; execution
       telemetry stays with the delegated runtime path. *)
    let dispatch_host_shell_ir
          ?(allowed_commands = Dev_exec_allowlist.readonly)
          ?timeout_sec
          ~workdir
          ir
      =
      Keeper_shell_ir.dispatch ~allowed_commands ~keeper_id:meta.name
        ~base_path:root ~workdir ~sandbox:(Masc_exec.Sandbox_target.host ())
        ?timeout_sec ir
    in
    let dispatch_error_message = function
      | Keeper_shell_ir.Gate_reject diagnostic -> diagnostic
      | Keeper_shell_ir.Cannot_parse -> "Cannot parse command"
      | Keeper_shell_ir.Too_complex -> "Command too complex"
      | Keeper_shell_ir.Path_reject e -> e
    in
    let run_host_shell_ir
          ?(allowed_commands = Dev_exec_allowlist.readonly)
          ?timeout_sec
          ?path
          ~workdir
          ~cmd
          ir
          ~on_ok
      =
      let fields =
        [ "typed", `Bool true; "cmd", `String cmd ]
        @
        match path with
        | None -> []
        | Some path -> [ "path", `String path ]
      in
      match dispatch_host_shell_ir ~allowed_commands ?timeout_sec ~workdir ir with
      | Error (Gate_reject diagnostic) -> error_json ~fields diagnostic
      | Error Cannot_parse -> error_json ~fields "Cannot parse command"
      | Error Too_complex -> error_json ~fields "Command too complex"
      | Error (Path_reject e) -> error_json ~fields:[ "blocked_cmd", `String cmd ] e
      | Ok result -> on_ok result
    in
    let dispatch_result_output (result : Masc_exec.Exec_dispatch.dispatch_result) =
      if String.equal result.stderr "" then result.stdout else result.stdout ^ result.stderr
    in
    let hostify_turn_runtime_output out =
      Keeper_shell_runtime_paths.rewrite_turn_runtime_paths_to_host ~config ~meta out
    in
    let run_in_turn_runtime ?(ok_exit_codes = [ 0 ]) ~cwd ~cmd ~command_argv
        ?host_ir ?(host_allowed_commands = Dev_exec_allowlist.readonly)
        ~max_bytes ~timeout_sec ?(map_output = fun out -> out) ?(extra = []) () =
      match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
      | Some runtime ->
        (match
           Keeper_turn_sandbox_runtime.run_command_with_status
             ~ok_exit_codes runtime ~cwd ~command_argv ~max_bytes ~timeout_sec ()
         with
         | Error msg ->
           error_json
             ~fields:([ "op", `String op; "cwd", `String cwd ] @ extra) msg
         | Ok (st, out) ->
           render_completed_process_result ~root ~keeper_name:meta.name ~op ~cwd
             ~cmd ~extra st (map_output out))
      | None ->
        (match host_ir with
         | None ->
           error_json
             ~fields:[ "op", `String op; "cwd", `String cwd ]
             "missing host Shell IR fallback"
         | Some ir ->
           run_host_shell_ir ~allowed_commands:host_allowed_commands ~timeout_sec
             ~workdir:cwd ~cmd ~path:cwd ir
             ~on_ok:(fun result ->
               render_completed_process_result ~root ~keeper_name:meta.name ~op
                 ~cwd ~cmd ~extra result.status
                 (map_output (dispatch_result_output result))))
    in
    (match op with
     | "git_diff" ->
       (match cwd_target () with
        | Error e -> path_error e
        | Ok cwd ->
          let host_ir =
            Keeper_shell_ir.simple ~cwd_raw:cwd ~cwd_base:root
              Masc_exec.Exec_program.Git
              [ "--no-optional-locks"; "diff"; "--stat" ]
          in
          run_in_turn_runtime ~cwd ~cmd:"git diff --stat"
            ~command_argv:[ "git"; "--no-optional-locks"; "diff"; "--stat" ]
            ~host_ir ~host_allowed_commands:Dev_exec_allowlist.dev
            ~max_bytes:1_000_000
            ~timeout_sec:Keeper_shell_timeout.read_timeout_sec ())
     | "git_worktree" ->
       let action =
         Safe_ops.json_string ~default:"list" "action" args
         |> String.trim |> String.lowercase_ascii
       in
       (match action with
        | "list" ->
          (match cwd_target () with
           | Error e -> path_error e
           | Ok cwd ->
             let host_ir =
               Keeper_shell_ir.simple ~cwd_raw:cwd ~cwd_base:root
                 Masc_exec.Exec_program.Git
                 [ "worktree"; "list" ]
             in
             run_in_turn_runtime ~cwd ~cmd:"git worktree list"
               ~map_output:hostify_turn_runtime_output
               ~command_argv:[ "git"; "worktree"; "list" ] ~host_ir
               ~host_allowed_commands:Dev_exec_allowlist.dev
               ~max_bytes:1_000_000
               ~timeout_sec:Keeper_shell_timeout.read_timeout_sec ())
        | "add" ->
          let branch = Safe_ops.json_string ~default:"" "branch" args |> String.trim in
          let base = Safe_ops.json_string ~default:"origin/main" "base" args |> String.trim in
          if branch = "" then
            error_json ~fields:[ "op", `String op ]
              "branch is required. Good: action='add', branch='feature/my-task'. Bad: branch=''."
          else (
            match cwd_target () with
            | Error e -> path_error e
            | Ok cwd ->
              let wt_out_result =
                let ir =
                  Keeper_shell_ir.simple ~cwd_raw:cwd ~cwd_base:root
                    Masc_exec.Exec_program.Git
                    [ "worktree"; "list"; "--porcelain" ]
                in
                match
                  dispatch_host_shell_ir ~allowed_commands:Dev_exec_allowlist.dev
                    ~timeout_sec:Keeper_shell_timeout.git_meta_timeout_sec ~workdir:cwd ir
                with
                | Ok result -> Ok (dispatch_result_output result)
                | Error err -> Error (dispatch_error_message err)
              in
              match wt_out_result with
              | Error msg ->
                error_json ~fields:[ "op", `String op; "cwd", `String cwd ] msg
              | Ok wt_out ->
                let existing_path =
                  let branch_ref = "branch refs/heads/" ^ branch in
                  let rec loop current_worktree = function
                    | [] -> None
                    | line :: rest ->
                      let line = String.trim line in
                      if String.starts_with ~prefix:"worktree " line then
                        let prefix_len = String.length "worktree " in
                        let path =
                          String.sub line prefix_len (String.length line - prefix_len)
                          |> String.trim
                        in
                        loop (Some path) rest
                      else if String.equal line branch_ref then current_worktree
                      else loop current_worktree rest
                  in
                  loop None (String.split_on_char '\n' wt_out)
                in
                (match existing_path with
                 | Some existing_path ->
                  Yojson.Safe.to_string
                    (`Assoc
                        [ "ok", `Bool false
                        ; "op", `String op
                        ; "error", `String "branch_already_in_worktree"
                        ; "branch", `String branch
                        ; "existing_worktree", `String existing_path
                        ; "hint", `String "Branch is already in a worktree. Use 'cd' to the existing path, or choose a different branch name."
                        ])
                 | None ->
                  let wt_path =
                    Printf.sprintf ".worktrees/%s"
                      (String.map (fun c -> if c = '/' then '-' else c) branch)
                  in
                  let ir =
                    Keeper_shell_ir.simple ~cwd_raw:cwd ~cwd_base:root
                      Masc_exec.Exec_program.Git
                      [ "worktree"; "add"; wt_path; "-b"; branch; base ]
                  in
                  run_host_shell_ir ~allowed_commands:Dev_exec_allowlist.dev
                    ~timeout_sec:Keeper_shell_timeout.io_timeout_sec ~workdir:cwd
                    ~cmd:(Printf.sprintf "git worktree add %s -b %s %s" wt_path branch base)
                    ~path:cwd ir
                    ~on_ok:(fun result ->
                      render_completed_process_result ~root ~keeper_name:meta.name ~op
                        ~cwd
                        ~cmd:(Printf.sprintf "git worktree add %s -b %s %s" wt_path branch base)
                        result.status
                        (dispatch_result_output result))))
        | other ->
          error_json ~fields:[ "op", `String op ]
            (Printf.sprintf "Unknown git_worktree action '%s'. Use: list, add." other))
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
                      Keeper_shell_op.valid_strings) )
             ]))
;;
