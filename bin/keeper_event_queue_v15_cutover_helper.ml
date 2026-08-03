open Cmdliner

let ( let* ) = Result.bind

let errorf format = Printf.ksprintf (fun message -> Error (`Msg message)) format

let cmdliner_result = function
  | Ok value -> `Ok value
  | Error (`Msg message) -> `Error (false, message)
;;

let validate_signal_file path =
  try
    In_channel.with_open_text path (fun input ->
      let rec loop line_number row_count =
        match In_channel.input_line input with
        | None -> Ok row_count
        | Some line ->
          let* json =
            try Ok (Yojson.Safe.from_string line) with
            | Yojson.Json_error detail ->
              errorf
                "schedule signal JSON is malformed path=%s line=%d: %s"
                path
                line_number
                detail
          in
          let* (_ : Schedule_runner.wake_signal) =
            Schedule_runner.wake_signal_of_yojson json
            |> Result.map_error (fun detail ->
              `Msg
                (Printf.sprintf
                   "schedule signal contract rejected path=%s line=%d: %s"
                   path
                   line_number
                   detail))
          in
          loop (line_number + 1) (row_count + 1)
      in
      loop 1 0)
  with
  | Sys_error detail ->
    errorf "schedule signal file is unreadable path=%s: %s" path detail
;;

let validate_signals paths =
  let* row_count =
    List.fold_left
      (fun result path ->
         let* count = result in
         let* file_count = validate_signal_file path in
         Ok (count + file_count))
      (Ok 0)
      paths
  in
  Printf.printf "%d\n%!" row_count;
  Ok ()
;;

let validate_current_queue path =
  try
    let json = Yojson.Safe.from_file path in
    let* (_ : Keeper_event_queue_state.t) =
      Keeper_event_queue_state.of_yojson json
      |> Result.map_error (fun detail ->
        `Msg
          (Printf.sprintf
             "current event queue contract rejected path=%s: %s"
             path
             detail))
    in
    Ok ()
  with
  | Sys_error detail ->
    errorf "current event queue file is unreadable path=%s: %s" path detail
  | Yojson.Json_error detail ->
    errorf "current event queue JSON is malformed path=%s: %s" path detail
;;

let child_exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> 128 + signal
;;

let lease_owner_environment_key =
  "MASC_EVENT_QUEUE_V15_CUTOVER_LEASE_OWNER_PID="
;;

let environment_without_lease_owner () =
  Unix.environment ()
  |> Array.to_list
  |> List.filter (fun binding ->
    not (String.starts_with ~prefix:lease_owner_environment_key binding))
;;

let environment_for_lease_child () =
  Printf.sprintf "%s%d" lease_owner_environment_key (Unix.getpid ())
  :: environment_without_lease_owner ()
  |> Array.of_list
;;

let run_child command environment =
  match command with
  | [] -> errorf "lease command is empty"
  | executable :: _ ->
    (try
       let pid =
         Unix.create_process_env
           executable
           (Array.of_list command)
           environment
           Unix.stdin
           Unix.stdout
           Unix.stderr
       in
       Ok (Unix.waitpid [] pid |> snd)
     with
     | Unix.Unix_error (error, syscall, argument) ->
       errorf
         "cutover command failed to start or wait syscall=%s argument=%s: %s"
         syscall
         argument
         (Unix.error_message error))
;;

let run_under_base_path_lease base_path command =
  match command with
  | [] -> errorf "lease-run requires a command"
  | _ :: _ ->
    let run_dir = (Host_config.host ()).run_dir in
    (match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
     | Server_startup_takeover.Base_path_already_owned { pid } ->
       errorf
         "workspace writer lease is already owned base_path=%s pid=%s"
         base_path
         (match pid with
          | Some value -> string_of_int value
          | None -> "unknown")
     | Server_startup_takeover.Base_path_rejected rejection ->
       errorf
         "workspace writer lease rejected base_path=%s: %s"
         base_path
         (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
     | Server_startup_takeover.Base_path_acquired lease ->
       let status =
         Fun.protect
           ~finally:(fun () ->
             Server_startup_takeover.release_base_path_lease lease)
           (fun () -> run_child command (environment_for_lease_child ()))
       in
       let* status = status in
       Stdlib.exit (child_exit_code status))
;;

let handoff_base_path_lease base_path next_executable next_arguments prepare_command =
  match prepare_command with
  | [] -> errorf "lease-handoff requires a preparation command"
  | _ ->
    let run_dir = (Host_config.host ()).run_dir in
    (match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
     | Server_startup_takeover.Base_path_already_owned { pid } ->
       errorf
         "workspace writer lease is already owned base_path=%s pid=%s"
         base_path
         (match pid with
          | Some value -> string_of_int value
          | None -> "unknown")
     | Server_startup_takeover.Base_path_rejected rejection ->
       errorf
         "workspace writer lease rejected base_path=%s: %s"
         base_path
         (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
     | Server_startup_takeover.Base_path_acquired lease ->
       let release () = Server_startup_takeover.release_base_path_lease lease in
       (match run_child prepare_command (environment_for_lease_child ()) with
        | Error _ as error ->
          release ();
          error
        | Ok prepare_status ->
          let prepare_exit_code = child_exit_code prepare_status in
          if prepare_exit_code <> 0
          then (
            release ();
            Stdlib.exit prepare_exit_code)
          else (
            match
              Server_startup_takeover.prepare_base_path_lease_exec_handoff lease
            with
            | Error rejection ->
              release ();
              errorf
                "workspace writer lease handoff rejected base_path=%s: %s"
                base_path
                (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
            | Ok () ->
              let arguments = Array.of_list (next_executable :: next_arguments) in
              let environment = environment_without_lease_owner () |> Array.of_list in
              (try Unix.execve next_executable arguments environment with
               | exn ->
                 release ();
                 errorf
                   "cutover runtime handoff failed executable=%s: %s"
                   next_executable
                   (Printexc.to_string exn)))))
;;

let signal_files =
  let doc = "Validate each schedule signal JSONL file with the production decoder." in
  Arg.(non_empty & pos_all file [] & info [] ~docv:"SIGNAL_FILE" ~doc)
;;

let validate_signals_cmd =
  let doc = "validate current schedule signal rows" in
  Cmd.v
    (Cmd.info "validate-signals" ~doc)
    Term.(ret (const (fun paths -> cmdliner_result (validate_signals paths)) $ signal_files))
;;

let current_queue_file =
  let doc = "Validate one current event-queue v15 snapshot." in
  Arg.(required & pos 0 (some file) None & info [] ~docv:"QUEUE_FILE" ~doc)
;;

let validate_current_queue_cmd =
  let doc = "validate one current event-queue v15 snapshot" in
  Cmd.v
    (Cmd.info "validate-current-queue" ~doc)
    Term.(
      ret
        (const
           (fun path -> cmdliner_result (validate_current_queue path))
         $ current_queue_file))
;;

let base_path =
  let doc = "Workspace BasePath whose process-lifetime writer lease must be free." in
  Arg.(required & opt (some dir) None & info [ "base-path" ] ~docv:"PATH" ~doc)
;;

let command =
  let doc = "Command executed while the BasePath writer lease remains held." in
  Arg.(non_empty & pos_all string [] & info [] ~docv:"COMMAND" ~doc)
;;

let lease_run_cmd =
  let doc = "run a cutover check under the canonical BasePath writer lease" in
  Cmd.v
    (Cmd.info "lease-run" ~doc)
    Term.(
      ret
        (const
           (fun base_path command ->
              cmdliner_result (run_under_base_path_lease base_path command))
         $ base_path
         $ command))
;;

let next_executable =
  let doc = "Runtime executable that replaces the lease owner after preparation." in
  Arg.(required & opt (some string) None & info [ "next-executable" ] ~docv:"PATH" ~doc)
;;

let next_arguments =
  let doc = "One runtime argument. Repeat for every argument in order." in
  Arg.(value & opt_all string [] & info [ "next-argument" ] ~docv:"ARG" ~doc)
;;

let lease_handoff_cmd =
  let doc = "prepare a cutover under lease, then atomically exec the new runtime" in
  Cmd.v
    (Cmd.info "lease-handoff" ~doc)
    Term.(
      ret
        (const
           (fun base_path next_executable next_arguments command ->
              cmdliner_result
                (handoff_base_path_lease
                   base_path
                   next_executable
                   next_arguments
                   command))
         $ base_path
         $ next_executable
         $ next_arguments
         $ command))
;;

let () =
  let doc = "typed helpers for the event-queue v15 hard-cut gate" in
  exit
    (Cmd.eval
       (Cmd.group
          (Cmd.info "masc-keeper-event-queue-v15-cutover-helper" ~doc)
          [ lease_run_cmd
          ; lease_handoff_cmd
          ; validate_current_queue_cmd
          ; validate_signals_cmd
          ]))
;;
