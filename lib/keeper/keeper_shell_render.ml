open Keeper_types
open Keeper_exec_shared

let cmd_prefix_of_cmd cmd =
  match Keeper_shell_command_semantics.effective_stages_of_cmd cmd with
  | stage :: _ -> stage.bin
  | [] -> String.trim cmd
;;

let bash_history_entry ~cmd ~cmd_prefix ~op ~duration_ms ~success =
  Masc_exec.Bash_history.
    { ts = Unix.time ()
    ; cmd_hash = Masc_exec.Bash_history.cmd_hash cmd
    ; cmd_prefix
    ; semantic_kind = op
    ; duration_ms
    ; success
    }
;;

let failure_insight_extra ~base_path ~keeper_name =
  let patterns =
    Masc_exec.Bash_history.failure_insight ~base_path ~keeper_name
  in
  if patterns = []
  then []
  else
    [ "failure_insight"
    , `List (List.map Masc_exec.Bash_history.failure_pattern_to_json patterns)
    ]
;;

let record_history ~root ~keeper_name ~op ~cmd ~success ~duration_ms =
  let cmd_prefix = cmd_prefix_of_cmd cmd in
  let entry = bash_history_entry ~cmd ~cmd_prefix ~op ~duration_ms ~success in
  match Masc_exec.Bash_history.append ~base_path:root ~keeper_name entry with
  | Ok () -> ()
  | Error exn ->
    Log.KeeperExec.warn
      "bash_history.append failed: keeper=%s base=%s exn=%s"
      keeper_name root (Printexc.to_string exn)
;;

let render_process_json ~root ~keeper_name ~cmd ~extra ~status ~output =
  Exec_core.process_result_json
    ~artifact_policy:Exec_core.Inline_only
    ~base_path:root
    ~keeper_name
    ~cmd
    ~ir:(Keeper_shell_ir.of_cmd cmd)
    ~extra
    ~status
    ~output
    ()
;;

let render_process_result ~root ~keeper_name ~op ?cwd ~cmd argv =
  let st, out =
    Keeper_shell_shared.run_argv_with_status_retry_eintr ?cwd
      ~timeout_sec:Keeper_shell_timeout.io_timeout_sec argv
  in
  render_completed_process_result ~root ~keeper_name ~op ?cwd ~cmd st out
;;

let render_completed_process_result ~root ~keeper_name ~op ?cwd ~cmd
    ?(extra = []) st out
  =
  let success = st = Unix.WEXITED 0 in
  let elapsed_ms =
    List.find_map
      (fun (k, v) ->
        if k = "execution_time_ms"
        then (
          match v with
          | `Int n -> Some n
          | _ -> None)
        else None)
      extra
    |> Option.value ~default:0
  in
  record_history ~root ~keeper_name ~op ~cmd ~success ~duration_ms:elapsed_ms;
  let insight_extra = failure_insight_extra ~base_path:root ~keeper_name in
  let extra_with_via =
    if List.exists (fun (k, _) -> k = "via") extra
    then extra
    else ("via", `String "host") :: extra
  in
  Yojson.Safe.to_string
    (render_process_json
       ~root ~keeper_name ~cmd
       ~extra:
         ([ "op", `String op
          ; "cmd", `String cmd
          ; ( "cwd"
            , match cwd with
              | Some dir -> `String dir
              | None -> `Null )
          ]
          @ extra_with_via
          @ insight_extra)
       ~status:st
       ~output:out)
;;

let render_docker_process_result ~root ~keeper_name ~op ~config ~meta ~cwd
    ~cmd ~docker_cmd ~timeout_sec
  =
  match
    Keeper_shell_docker.run_docker_shell_command_with_status ~config ~meta ~cwd
      ~timeout_sec ~cmd:docker_cmd ~git_creds_enabled:false
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
    Yojson.Safe.to_string
      (render_process_json
         ~root ~keeper_name ~cmd
         ~extra:
           [ "op", `String op
           ; "cmd", `String cmd
           ; "cwd", Keeper_cwd_response.to_yojson_response cwd_response
           ; "via", `String "docker"
           ]
         ~status:result.status
         ~output:result.output)
;;
