(* SearchFiles operation handlers.

   Read/list/search operations live in Keeper_workspace_read_ops. This facade keeps
   alias parsing, remaining git mutation-ish helpers, and unsupported-op
   reporting in one place. *)

open Keeper_types
open Agent_tool_shared_runtime

include Keeper_workspace_ops_setup

(* TEL-OK: handler rename only; [render_completed_process_result] records
   command history and failure telemetry through Keeper_workspace_ops_setup. *)
let handle_tool_search_files
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
    | "read" | "file" | "type" -> "cat"
    | "search" -> "rg"
    | "dir" | "list" -> "ls"
    | _ -> raw_op
  in
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  match
    Keeper_workspace_read_ops.try_handle ~turn_sandbox_factory ~config ~meta ~args
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
      match Agent_tool_execute_path.resolve_tool_read_cwd ~config ~meta ~args with
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
    (* TEL-OK: adapter delegates to Agent_tool_execute_shell_ir/Exec_dispatch; execution
       telemetry stays with the delegated runtime path. *)
    let dispatch_host_shell_ir
          ?(allowed_commands = Dev_exec_allowlist.readonly)
          ?timeout_sec
          ~workdir
          ir
      =
      Agent_tool_execute_shell_ir.dispatch ~allowed_commands ~keeper_id:meta.name
        ~base_path:root ~workdir ~sandbox:(Masc_exec.Sandbox_target.host ())
        ?timeout_sec ir
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
            Agent_tool_execute_shell_ir.simple ~cwd_raw:cwd ~cwd_base:root
              Masc_exec.Exec_program.Git
              [ "--no-optional-locks"; "diff"; "--stat" ]
          in
          run_in_turn_runtime ~cwd ~cmd:"git diff --stat"
            ~command_argv:[ "git"; "--no-optional-locks"; "diff"; "--stat" ]
            ~host_ir ~host_allowed_commands:Dev_exec_allowlist.dev
            ~max_bytes:1_000_000
            ~timeout_sec:Agent_tool_execute_timeout.read_timeout_sec ())
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
                      Keeper_workspace_op.valid_strings) )
             ]))
;;
