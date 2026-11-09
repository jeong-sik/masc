open Keeper_turn_sandbox_runtime_record

(* The cwd of every exec comes from a resolver that already confined it to
   this keeper's playground: Execute and spawn through
   [Keeper_tool_execute_path.resolve_tool_execute_cwd_typed], Read through the
   playground root itself. A path outside it has no container spelling, so the
   answer is the error, never a directory the caller did not name. *)
let container_path_of_host (t : t) ~host_path =
  let host_norm = normalize_path host_path in
  if host_norm = t.host_root
  then Ok t.container_root
  else if String.starts_with ~prefix:(t.host_root ^ "/") host_norm
  then (
    let suffix =
      String.sub
        host_norm
        (String.length t.host_root + 1)
        (String.length host_norm - String.length t.host_root - 1)
    in
    Ok (Filename.concat t.container_root suffix))
  else
    Error
      (Printf.sprintf
         "container_path_of_host: %s is not inside playground %s"
         host_norm
         t.host_root)
;;

let format_docker_exec_error ~head_program ~st ~out =
  match st with
  | Unix.WEXITED code ->
    Printf.sprintf
      "docker_%s_failed: exit=%d output=%s"
      head_program
      code
      (Keeper_sandbox_runtime.docker_failure_output_for_log out)
  | Unix.WSIGNALED n -> Printf.sprintf "docker_%s_signaled: signal=%d" head_program n
  | Unix.WSTOPPED n -> Printf.sprintf "docker_%s_stopped: signal=%d" head_program n
;;

let sandbox_environment () =
  Env_keeper_scrub.filter_environment (Unix.environment ())
;;

let run_argv_with_status ?timeout_sec argv =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    Process_eio.run_argv_with_status
      ?timeout_sec
      ~env:(sandbox_environment ())
      ~cwd:(Config_dir_resolver.current_working_dir ())
      argv)
;;

(* The policy lane attaches a guest to a host-only network, and [container
   run] fails rather than falling back when that network is absent. Creating
   it here rather than at server boot keeps the failure next to the keeper
   that needed it, and keeps a server with no policy keeper from creating a
   network nothing uses.

   Idempotent by listing first: a create against an existing name is an
   error on this CLI, and swallowing that error would also swallow the real
   ones. *)
(* Named because a bare 30. and 60. in a boot path is the kind of number a
   later edit rounds without knowing which call it bounds. Listing is a local
   read; creating brings up a vmnet interface. *)
let policy_network_list_timeout_s = 30.0
let policy_network_create_timeout_s = 60.0

(* Returns the gateway a guest on the policy network reaches the host at, so
   the boot can point the guest's clients at the proxy behind it. [None] for
   every other mode, which needs no gateway. *)
let ensure_policy_network backend ~keeper_name (mode : Keeper_types_profile_sandbox.network_mode) =
  let gateway_of_network () =
    match Keeper_sandbox_microvm.policy_network_inspect_argv_for backend ~keeper_name with
    | Error _ as error -> error
    | Ok inspect_argv ->
      (match run_argv_with_status ~timeout_sec:policy_network_list_timeout_s inspect_argv with
       | Unix.WEXITED 0, inspect ->
         (match Keeper_sandbox_microvm.policy_network_gateway ~inspect with
          | Ok gateway -> Ok (Some gateway)
          | Error detail -> Error ("microvm_policy_network_unreadable: " ^ detail))
       | (Unix.WEXITED _, output) | (Unix.WSIGNALED _, output) | (Unix.WSTOPPED _, output) ->
         Error
           (Printf.sprintf
              "microvm_policy_network_unreadable: %s: %s"
              (String.concat " " inspect_argv)
              (String.trim output)))
  in
  match mode with
  | Keeper_types_profile_sandbox.Network_none | Keeper_types_profile_sandbox.Network_inherit
    -> Ok None
  | Keeper_types_profile_sandbox.Network_policy ->
    (match Keeper_sandbox_microvm.policy_network_list_argv_for backend with
     | Error _ as error -> error
     | Ok list_argv ->
       let create_network () =
         match Keeper_sandbox_microvm.policy_network_create_argv_for backend ~keeper_name with
         | Error _ as error -> error
         | Ok create_argv ->
           (match run_argv_with_status ~timeout_sec:policy_network_create_timeout_s create_argv with
            | Unix.WEXITED 0, _ -> Ok ()
            | (Unix.WEXITED _, output) | (Unix.WSIGNALED _, output) | (Unix.WSTOPPED _, output) ->
              Error
                (Printf.sprintf
                   "microvm_policy_network_uncreatable: %s: %s"
                   (String.concat " " create_argv)
                   (String.trim output)))
       in
       (match run_argv_with_status ~timeout_sec:policy_network_list_timeout_s list_argv with
        | Unix.WEXITED 0, listing ->
          (match Keeper_sandbox_microvm.policy_network_present ~keeper_name ~listing with
           | Ok true -> gateway_of_network ()
           | Ok false ->
             (match create_network () with
              | Error _ as error -> error
              | Ok () -> gateway_of_network ())
           | Error detail ->
             Error ("microvm_policy_network_unreadable: " ^ detail))
        | (Unix.WEXITED _, listing) | (Unix.WSIGNALED _, listing) | (Unix.WSTOPPED _, listing) ->
          Error
            (Printf.sprintf
               "microvm_policy_network_unreadable: %s: %s"
               (String.concat " " list_argv)
               (String.trim listing))))
;;

let output_for_status ~(stdout : string) ~(stderr : string) =
  match stdout, stderr with
  | "", err -> err
  | out, "" -> out
  | out, err -> out ^ "\n" ^ err
;;

let run_argv_with_status_split
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?output_capture
      argv
  =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    let env = sandbox_environment () in
    let cwd = Config_dir_resolver.current_working_dir () in
    match on_stdout_chunk, on_stderr_chunk, output_capture with
    | None, None, None ->
      Process_eio.run_argv_with_status_split
        ?timeout_sec
        ~env
        ~cwd
        argv
    | _ ->
      (* DET-OK: absent stream callbacks mean the caller requested capture only. *)
      let on_stdout_chunk = Option.value on_stdout_chunk ~default:(fun _ -> ()) in
      (* DET-OK: stderr callback absence has the same capture-only meaning. *)
      let on_stderr_chunk = Option.value on_stderr_chunk ~default:(fun _ -> ()) in
      Process_eio.run_argv_with_status_split_streaming
        ?timeout_sec
        ?output_capture
        ~env
        ~cwd
        ~on_stdout_chunk
        ~on_stderr_chunk
        argv)
;;

(* A failed transport can leave a guest effect running. Do not start another
   process in response to an Eio bind error for these requests. The requests
   carry their paths in argv and attach no stdin. *)
let run_build_link_effect ?timeout_sec argv =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    let status, _, _ =
      Process_eio.run_argv_with_stdin_and_status_split
        ?timeout_sec ~fallback_policy:Process_eio.Eio_only
        ~env:(sandbox_environment ())
        ~cwd:(Config_dir_resolver.current_working_dir ())
        ~stdin_content:"" argv in
    status)
;;

(* Every request runs, as one helper keeps going past a path that fails, and
   the first failure is the status. A raised failure stops the rest. *)
let run_build_link_effects ?timeout_sec argvs =
  List.fold_left
    (fun status argv ->
      let next = run_build_link_effect ?timeout_sec argv in
      match status with
      | Unix.WEXITED 0 -> next
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> status)
    (Unix.WEXITED 0)
    argvs
;;

let run_argv_with_stdin_and_status_split
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?output_capture
      ~stdin_content
      argv
  =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    Process_eio.run_argv_with_stdin_and_status_split
      ?timeout_sec
      ?output_capture
      ~env:(sandbox_environment ())
      ~cwd:(Config_dir_resolver.current_working_dir ())
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~stdin_content
      argv)
;;

let run_argv_pipeline_with_status_split
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      stages
  =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    Process_eio.run_argv_pipeline_with_status_split
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      stages)
;;
