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

let validate_schedule_ledger path =
  try
    let json = Yojson.Safe.from_file path in
    let* state =
      Schedule_store.state_of_yojson json
      |> Result.map_error (fun detail ->
        `Msg
          (Printf.sprintf
             "schedule ledger contract rejected path=%s: %s"
             path
             detail))
    in
    let nonempty field value =
      if String.equal (String.trim value) ""
      then errorf "schedule ledger has an empty %s path=%s" field path
      else Ok ()
    in
    let* () =
      List.fold_left
        (fun result (schedule : Schedule_domain.schedule_request) ->
           let* () = result in
           nonempty "schedule.schedule_instance_id" schedule.schedule_instance_id)
        (Ok ())
        state.schedules
    in
    let* () =
      List.fold_left
        (fun result (execution : Schedule_domain.execution_record) ->
           let* () = result in
           nonempty "execution.schedule_instance_id" execution.schedule_instance_id)
        (Ok ())
        state.executions
    in
    let unsettled =
      List.filter
        (fun (execution : Schedule_domain.execution_record) ->
           match execution.status with
           | Schedule_domain.Execution_running
           | Schedule_domain.Execution_dispatched -> true
           | Schedule_domain.Execution_succeeded
           | Schedule_domain.Execution_failed -> false)
        state.executions
    in
    let execution_json (execution : Schedule_domain.execution_record) =
      `Assoc
        [ "execution_id", `String execution.execution_id
        ; "schedule_id", `String execution.schedule_id
        ; "status", `String (Schedule_domain.execution_status_to_string execution.status)
        ]
    in
    Yojson.Safe.to_channel
      stdout
      (`Assoc
         [ "unsettled_count", `Int (List.length unsettled)
         ; "unsettled", `List (List.map execution_json unsettled)
         ]);
    output_char stdout '\n';
    flush stdout;
    Ok ()
  with
  | Sys_error detail ->
    errorf "schedule ledger file is unreadable path=%s: %s" path detail
  | Yojson.Json_error detail ->
    errorf "schedule ledger JSON is malformed path=%s: %s" path detail
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

let rec waitpid_nointr pid =
  try Unix.waitpid [] pid |> snd with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid
;;

let run_child command environment =
  match command with
  | [] -> errorf "lease command is empty"
  | executable :: _ ->
    (try
       let arguments = Array.of_list command in
       (* [Process_eio_detached] redirects child output and returns immediately.
          Cutover preparation must inherit the operator streams and be reaped
          synchronously, so this helper owns the process group directly. *)
       let pid = Unix.fork () in
       if pid = 0
       then (
         try
           ignore (Unix.setsid ());
           Unix.execvpe executable arguments environment
         with
         | exn ->
           Printf.eprintf
             "cutover command failed to start executable=%s: %s\n%!"
             executable
             (Printexc.to_string exn);
           Unix._exit 127);
       let forwarded_signal = ref None in
       let signal_process_group signal =
         try Unix.kill (-pid) signal with
         | Unix.Unix_error (Unix.ESRCH, _, _) ->
           (try Unix.kill pid signal with
            | Unix.Unix_error (Unix.ESRCH, _, _) -> ())
       in
       let forward signal =
         forwarded_signal := Some signal;
         signal_process_group signal
       in
       let previous_sigterm =
         Sys.signal Sys.sigterm (Sys.Signal_handle forward)
       in
       let previous_sigint =
         Sys.signal Sys.sigint (Sys.Signal_handle forward)
       in
       Fun.protect
         ~finally:(fun () ->
           Sys.set_signal Sys.sigterm previous_sigterm;
           Sys.set_signal Sys.sigint previous_sigint;
           match !forwarded_signal with
           | Some _ ->
             (try Unix.kill (-pid) Sys.sigkill with
              | Unix.Unix_error (Unix.ESRCH, _, _) -> ())
           | None -> ())
         (fun () ->
            let status = waitpid_nointr pid in
            match !forwarded_signal with
            | Some signal -> Ok (Unix.WSIGNALED signal)
            | None -> Ok status)
     with
     | Unix.Unix_error (error, syscall, argument) ->
       errorf
         "cutover command failed to start or wait syscall=%s argument=%s: %s"
         syscall
         argument
         (Unix.error_message error))
;;

let verify_base_path_lease_owner base_path owner_pid =
  if owner_pid <= 0
  then errorf "lease owner PID must be positive"
  else
    let run_dir = (Host_config.host ()).run_dir in
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Server_startup_takeover.Base_path_already_owned { pid = Some actual_pid }
      when actual_pid = owner_pid -> Ok ()
    | Server_startup_takeover.Base_path_already_owned { pid } ->
      errorf
        "workspace writer lease owner mismatch base_path=%s expected_pid=%d actual_pid=%s"
        base_path
        owner_pid
        (match pid with
         | Some value -> string_of_int value
         | None -> "unknown")
    | Server_startup_takeover.Base_path_rejected rejection ->
      errorf
        "workspace writer lease verification rejected base_path=%s: %s"
        base_path
        (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
    | Server_startup_takeover.Base_path_acquired lease ->
      Server_startup_takeover.release_base_path_lease lease;
      errorf
        "workspace writer lease is not held by the expected process base_path=%s expected_pid=%d"
        base_path
        owner_pid
;;

let write_prepared_file path =
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let output = Unix.out_channel_of_descr descriptor in
    Fun.protect
      ~finally:(fun () -> close_out_noerr output)
      (fun () ->
         output_string output "prepared\n";
         flush output;
         Unix.fsync descriptor);
    Ok ()
  with
  | Unix.Unix_error (error, syscall, argument) ->
    errorf
      "cutover preparation marker failed syscall=%s argument=%s: %s"
      syscall
      argument
      (Unix.error_message error)
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

let handoff_base_path_lease
      base_path
      next_executable
      next_arguments
      prepared_file
      prepare_command
  =
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
              match prepared_file with
              | None -> Ok ()
              | Some path -> write_prepared_file path
            with
            | Error _ as error ->
              release ();
              error
            | Ok () ->
              (match
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
                      (Printexc.to_string exn))))))
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

let schedule_ledger_file =
  let doc = "Validate one current schedule ledger." in
  Arg.(required & pos 0 (some file) None & info [] ~docv:"SCHEDULE_LEDGER" ~doc)
;;

let validate_schedule_ledger_cmd =
  let doc = "validate one schedule ledger with the production decoder" in
  Cmd.v
    (Cmd.info "validate-schedule-ledger" ~doc)
    Term.(
      ret
        (const
           (fun path -> cmdliner_result (validate_schedule_ledger path))
         $ schedule_ledger_file))
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

let owner_pid =
  let doc = "Expected process ID of the current BasePath lease owner." in
  Arg.(required & opt (some int) None & info [ "owner-pid" ] ~docv:"PID" ~doc)
;;

let verify_lease_owner_cmd =
  let doc = "verify the exact process that owns the canonical BasePath lease" in
  Cmd.v
    (Cmd.info "verify-lease-owner" ~doc)
    Term.(
      ret
        (const
           (fun base_path owner_pid ->
              cmdliner_result (verify_base_path_lease_owner base_path owner_pid))
         $ base_path
         $ owner_pid))
;;

let next_executable =
  let doc = "Runtime executable that replaces the lease owner after preparation." in
  Arg.(required & opt (some string) None & info [ "next-executable" ] ~docv:"PATH" ~doc)
;;

let next_arguments =
  let doc = "One runtime argument. Repeat for every argument in order." in
  Arg.(value & opt_all string [] & info [ "next-argument" ] ~docv:"ARG" ~doc)
;;

let prepared_file =
  let doc = "Exclusive marker created after preparation succeeds and before exec." in
  Arg.(value & opt (some string) None & info [ "prepared-file" ] ~docv:"PATH" ~doc)
;;

let lease_handoff_cmd =
  let doc = "prepare a cutover under lease, then atomically exec the new runtime" in
  Cmd.v
    (Cmd.info "lease-handoff" ~doc)
    Term.(
      ret
        (const
           (fun base_path next_executable next_arguments prepared_file command ->
              cmdliner_result
                (handoff_base_path_lease
                   base_path
                   next_executable
                   next_arguments
                   prepared_file
                   command))
         $ base_path
         $ next_executable
         $ next_arguments
         $ prepared_file
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
          ; verify_lease_owner_cmd
          ; validate_current_queue_cmd
          ; validate_schedule_ledger_cmd
          ; validate_signals_cmd
          ]))
;;
