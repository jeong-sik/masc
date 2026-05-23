open Keeper_types
open Keeper_exec_shared

let handle ~op ~(meta : keeper_meta) ~(config : Coord.config) ~(args : Yojson.Safe.t)
    ?turn_sandbox_factory ~root
  =
  Keeper_shell_runtime.with_cwd_target ~config ~meta ~args ~root ~op ~raw_path:""
    (fun cwd ->
    let count = max 1 (min 50 (Safe_ops.json_int ~default:10 "count" args)) in
    let format = Safe_ops.json_string ~default:"%h %s" "format" args in
    let file_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
    let grep = Safe_ops.json_string ~default:"" "grep" args |> String.trim in
    if Keeper_docker_read.should_route_read ~meta
    then
      (match Keeper_shell_runtime.docker_git_log_path ~config ~meta file_path with
       | Error err ->
         Keeper_exec_shared.error_json_for_op ~op
           ~extra_fields:[ "cwd", `String cwd; "path", `String file_path ]
           err
       | Ok docker_file_path ->
         let docker_cmd =
           let base =
             Printf.sprintf "git --no-optional-locks log --format=%s -%d%s"
               (Filename.quote format)
               count
               (if grep = "" then "" else " --grep=" ^ Filename.quote grep)
           in
           if docker_file_path = "" then base
           else Printf.sprintf "%s -- %s" base (Filename.quote docker_file_path)
         in
         (match
            Keeper_shell_docker.run_docker_shell_command_with_status
              ~config
              ~meta
              ~cwd
              ~timeout_sec:Keeper_shell_shared.read_timeout_sec
              ~cmd:docker_cmd
              ~git_creds_enabled:false
              ~network_mode:Network_none
          with
          | Error msg ->
            Keeper_exec_shared.error_json_for_op ~op
              ~extra_fields:[ "cwd", `String cwd ]
              msg
          | Ok result ->
            let cwd_response =
              Keeper_cwd_response.docker ~host_cwd:cwd
                ~container_cwd:
                  (Keeper_shell_docker.docker_private_workspace_cwd ~config ~meta cwd)
            in
            let json =
              Keeper_shell_runtime.git_log_response_json
                ~ok:true
                ~op
                ~cwd:(Keeper_cwd_response.to_yojson_response cwd_response)
                ~count
                ~grep
                ~via:"docker"
                ~status:result.status
                ~output:result.output
                ~limit:50
            in
            Yojson.Safe.to_string json))
    else
      let argv =
        [ "git"; "-C"; cwd ]
        @ Keeper_shell_runtime.git_log_argv_core ~format ~count ~grep ~file_path ()
      in
      (match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
       | Some runtime ->
         let runtime_path =
           if Filename.is_relative file_path
           then file_path
           else
             (match
                Keeper_turn_sandbox_runtime.container_path_of_host runtime
                  ~host_path:file_path
              with
              | Ok mapped -> mapped
              | Error _ -> file_path)
         in
         let argv =
           Keeper_shell_runtime.git_log_argv_core
             ~format
             ~count
             ~grep
             ~file_path:runtime_path
             ()
         in
         (match
            Keeper_turn_sandbox_runtime.run_command_with_status
              runtime
              ~cwd
              ~command_argv:argv
              ~ok_exit_codes:[ 0 ]
              ~max_bytes:1_000_000
              ~timeout_sec:Keeper_shell_shared.read_timeout_sec
              ()
          with
          | Error msg ->
            Keeper_exec_shared.error_json_for_op ~op
              ~extra_fields:[ "op", `String op; "cwd", `String cwd ]
              msg
          | Ok (st, out) ->
            let cwd_response =
              Keeper_cwd_response.docker ~host_cwd:cwd
                ~container_cwd:
                  (Keeper_turn_sandbox_runtime.container_cwd_of_host
                     runtime
                     ~host_cwd:cwd)
            in
            let json =
              Keeper_shell_runtime.git_log_response_json
                ~ok:true
                ~op
                ~cwd:(Keeper_cwd_response.to_yojson_response cwd_response)
                ~count
                ~grep
                ~via:"docker"
                ~status:st
                ~output:out
                ~limit:50
            in
            Yojson.Safe.to_string json)
       | None ->
         let st, out =
           Masc_exec.Exec_gate.run_argv_with_status
             ~actor:`Keeper_shell
             ~raw_source:(String.concat " " argv)
             ~summary:"keeper shell op"
             ~timeout_sec:Keeper_shell_shared.read_timeout_sec
             argv
         in
         let json =
           Keeper_shell_runtime.git_log_response_json
             ~ok:(st = Unix.WEXITED 0)
             ~op
             ~cwd:(`String cwd)
             ~count
             ~grep
             ~status:st
             ~output:out
             ~limit:50
         in
         Yojson.Safe.to_string json))
;;
