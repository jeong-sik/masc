open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_run_argv
open Keeper_turn_sandbox_runtime_container
open Keeper_turn_sandbox_runtime_start

(* The argv [run_exec_with_status_split_once] runs: the turn-scoped
   container, the same uid, the rewritten paths. *)
let exec_argv ?stdin ?timeout_sec ~validate_cached_container (t : t) ~cwd ~command_argv =
  let open Result.Syntax in
  let* () = docker_exec_only t in
  let* container_cwd = container_path_of_host t ~host_path:cwd in
  let* container_name =
    ensure_started ~validate_running:validate_cached_container ?timeout_sec t
  in
  let command_argv =
    List.map
      (fun arg ->
         let rewritten =
           Keeper_sandbox_runtime.rewrite_host_root_to_container_root
             ~host_root:t.host_root
             ~container_root:t.container_root
             arg
         in
         if String.equal t.raw_host_root t.host_root
         then rewritten
         else
           Keeper_sandbox_runtime.rewrite_host_root_to_container_root
             ~host_root:t.raw_host_root
             ~container_root:t.container_root
             rewritten)
      command_argv
  in
  Ok
    (exec_prefix t ~container_cwd ~stdin:(Option.value stdin ~default:false)
     @ (container_name :: command_argv))
;;

let run_exec_with_status_split_once
      ?(validate_cached_container = false)
      ?(stdin_content : string option)
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  match
    exec_argv
      ~stdin:(Option.is_some stdin_content)
      ?timeout_sec
      ~validate_cached_container
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok argv ->
    let run ?output_capture () =
      match stdin_content with
      | Some content ->
        run_argv_with_stdin_and_status_split
          ?timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          ?output_capture
          ~stdin_content:content
          argv
      | None ->
        run_argv_with_status_split
          ?timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          ?output_capture
          argv
    in
    let (st, stdout, stderr), files =
      match capture_dir with
      | None -> run (), None
      | Some capture_dir ->
        let result, files =
          Process_output_capture.with_capture ~capture_dir (fun output_capture ->
            run ~output_capture ())
        in
        result, Some files
    in
    Ok (st, stdout, stderr, files)
;;

let run_exec_with_optional_output_files
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  let has_output_callback =
    Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
  in
  match
    run_exec_with_status_split_once
      ~validate_cached_container:has_output_callback
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok (((Unix.WEXITED 126 | Unix.WEXITED 127) as status), stdout, stderr, _) as failed ->
    (match failed_exec_recovery ?timeout_sec t with
     | Preserve_failed_exec -> failed
     | Restart_failed_exec ->
       set_state t Not_started;
       (match
          run_exec_with_status_split_once
            ?stdin_content
            ?on_stdout_chunk
            ?on_stderr_chunk
            ?timeout_sec
            ?capture_dir
            t
            ~cwd
            ~command_argv
        with
        | Ok _ as ok -> ok
        | Error _ as err -> err)
     | Failed_exec_state_probe_error detail ->
       Error
         (failed_exec_state_probe_error
            ~status
            ~output:(output_for_status ~stdout ~stderr)
            detail))
  | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _, _) as other) ->
    Ok other
;;

let run_exec_with_status_split
      ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
      t ~cwd ~command_argv
  =
  run_exec_with_optional_output_files
    ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    t ~cwd ~command_argv
  |> Result.map (fun (status, stdout, stderr, _) -> status, stdout, stderr)
;;

let run_exec_with_output_files
      ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
      ~capture_dir t ~cwd ~command_argv
  =
  run_exec_with_optional_output_files
    ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    ~capture_dir t ~cwd ~command_argv
;;

let run_exec_with_status
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  match
    run_exec_with_status_split
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok (status, stdout, stderr) ->
    Ok (status, output_for_status ~stdout ~stderr)
;;

type exec_pipeline_stage = {
  command_argv : string list;
  cwd : string option;
}

let rewrite_command_argv (t : t) command_argv =
  List.map
    (fun arg ->
      let rewritten =
        Keeper_sandbox_runtime.rewrite_host_root_to_container_root
          ~host_root:t.host_root
          ~container_root:t.container_root
          arg
      in
      if String.equal t.raw_host_root t.host_root
      then rewritten
      else
        Keeper_sandbox_runtime.rewrite_host_root_to_container_root
          ~host_root:t.raw_host_root
          ~container_root:t.container_root
          rewritten)
    command_argv
;;

let docker_exec_pipeline_argv (t : t) ~container_name ~container_cwd command_argv =
  exec_prefix t ~container_cwd ~stdin:true
  @ (container_name :: rewrite_command_argv t command_argv)
;;

let run_exec_pipeline_with_status_once
      ?(validate_cached_container = false)
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      (t : t)
      ~(cwd : string)
      ~(stages : exec_pipeline_stage list)
  =
  let open Result.Syntax in
  let* () = docker_exec_only t in
  let rec project_stages projected = function
    | [] -> Ok (List.rev projected)
    | ({ command_argv; cwd = stage_cwd } : exec_pipeline_stage) :: rest ->
      let* container_cwd =
        container_path_of_host t ~host_path:(Option.value stage_cwd ~default:cwd)
      in
      project_stages ((command_argv, container_cwd) :: projected) rest
  in
  let* projected_stages = project_stages [] stages in
  let* container_name =
    ensure_started ~validate_running:validate_cached_container ?timeout_sec t
  in
  let process_stages =
    List.map
      (fun (command_argv, container_cwd) ->
        let argv = docker_exec_pipeline_argv t ~container_name ~container_cwd command_argv in
        Process_eio.plumbed_stage
          ~argv
          ~env:(Some (sandbox_environment ()))
          ~cwd:(Some (Config_dir_resolver.current_working_dir ())))
      projected_stages
  in
  (* These stages carry no file redirect, so the runner's redirect error is
     out of reach here; it is passed on rather than folded into a status. *)
  run_argv_pipeline_with_status_split
    ?timeout_sec
    ?on_stdout_chunk
    ?on_stderr_chunk
    process_stages
;;

let run_exec_pipeline_with_status ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    t ~cwd ~stages =
  let has_output_callback =
    Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
  in
  match
    run_exec_pipeline_with_status_once
      ~validate_cached_container:has_output_callback
      ?timeout_sec
      t
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~cwd
      ~stages
  with
  | Error _ as err -> err
  | Ok (((Unix.WEXITED 126 | Unix.WEXITED 127) as status), stdout, stderr) as failed ->
    (match failed_exec_recovery ?timeout_sec t with
     | Preserve_failed_exec -> failed
     | Restart_failed_exec ->
       set_state t Not_started;
       (match
          run_exec_pipeline_with_status_once
            ?timeout_sec
            t
            ?on_stdout_chunk
            ?on_stderr_chunk
            ~cwd
            ~stages
        with
        | Ok _ as ok -> ok
        | Error _ as err -> err)
     | Failed_exec_state_probe_error detail ->
       Error
         (failed_exec_state_probe_error
            ~status
            ~output:(output_for_status ~stdout ~stderr)
            detail))
  | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) as other) ->
    Ok other
;;

let run_command_with_status
      ?(ok_exit_codes = [ 0 ])
      ~timeout_sec
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
      ~(max_bytes : int)
      ()
  =
  match command_argv with
  | [] -> Error "run_command_with_status: command_argv is empty"
  | head_program :: _ ->
    (match run_exec_with_status t ~timeout_sec ~cwd ~command_argv with
     | Error _ as err -> err
     | Ok (st, out) ->
       (match st with
        | Unix.WEXITED code when List.exists (fun ok_code -> ok_code = code) ok_exit_codes
          ->
          let body =
            if String.length out > max_bytes then String.sub out 0 max_bytes else out
          in
          Ok (st, body)
        | Unix.WSIGNALED _ | Unix.WSTOPPED _ | WEXITED _ -> Error (format_docker_exec_error ~head_program ~st ~out)))
;;
