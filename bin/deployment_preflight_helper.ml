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

let validate_queue ~load ~base_path ~keeper_name =
  load ~base_path ~keeper_name
  |> Result.map (fun (_ : Keeper_event_queue_state.t) -> ())
  |> Result.map_error (fun detail ->
    `Msg
      (Printf.sprintf
         "current event queue production validation rejected keeper=%s base_path=%s: %s"
         keeper_name
         base_path
         detail))
;;

let validate_current_queue ~base_path ~keeper_name =
  validate_queue
    ~load:Keeper_event_queue_persistence.validate_existing_state_read_only_result
    ~base_path
    ~keeper_name
;;

let validate_current_wal ~base_path ~keeper_name =
  validate_queue
    ~load:Keeper_event_queue_persistence.validate_state_read_only_result
    ~base_path
    ~keeper_name
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
        (fun result (wake : Schedule_domain.wake_record) ->
           let* () = result in
           nonempty "wake.schedule_instance_id" wake.schedule_instance_id)
        (Ok ())
        state.wakes
    in
    let in_progress =
      List.filter
        (fun (wake : Schedule_domain.wake_record) ->
           match wake.status with
           | Schedule_domain.Wake_running -> true
           | Schedule_domain.Wake_succeeded
           | Schedule_domain.Wake_failed -> false)
        state.wakes
    in
    let wake_json (wake : Schedule_domain.wake_record) =
      `Assoc
        [ "schedule_instance_id", `String wake.schedule_instance_id
        ; "schedule_id", `String wake.schedule_id
        ; "due_at", `Float wake.due_at
        ; "status", `String (Schedule_domain.wake_status_to_string wake.status)
        ]
    in
    Yojson.Safe.to_channel
      stdout
      (`Assoc
         [ "in_progress_count", `Int (List.length in_progress)
         ; "in_progress", `List (List.map wake_json in_progress)
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

let lease_owner_environment_key = "MASC_DEPLOYMENT_LEASE_OWNER_PID="
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
          Deployment preparation must inherit the operator streams and be reaped
          synchronously, so this helper owns the process group directly. *)
       let forwarded_signals = [ Sys.sigterm; Sys.sigint ] in
       let previous_signal_mask =
         Unix.sigprocmask Unix.SIG_BLOCK forwarded_signals
       in
       let restore_signal_mask () =
         (* See the pre-fork signal masking protocol below. *)
         ignore (Unix.sigprocmask Unix.SIG_SETMASK previous_signal_mask)
       in
       let pid =
         try Unix.fork () with
         | exn ->
           restore_signal_mask ();
           raise exn
       in
       if pid = 0
       then (
         try
           (* See the parent-side process-group signal forwarding below. *)
           ignore (Unix.setsid ());
           restore_signal_mask ();
           Unix.execvpe executable arguments environment
         with
         | exn ->
           Printf.eprintf
             "deployment command failed to start executable=%s: %s\n%!"
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
         try Sys.signal Sys.sigterm (Sys.Signal_handle forward) with
         | exn ->
           restore_signal_mask ();
           raise exn
       in
       let previous_sigint =
         try Sys.signal Sys.sigint (Sys.Signal_handle forward) with
         | exn ->
           Sys.set_signal Sys.sigterm previous_sigterm;
           restore_signal_mask ();
           raise exn
       in
       restore_signal_mask ();
       Fun.protect
         ~finally:(fun () ->
           (* See the pre-fork signal masking protocol above. *)
           ignore (Unix.sigprocmask Unix.SIG_BLOCK forwarded_signals);
           (match !forwarded_signal with
            | Some _ ->
              (try Unix.kill (-pid) Sys.sigkill with
               | Unix.Unix_error (Unix.ESRCH, _, _) -> ())
            | None -> ());
           Sys.set_signal Sys.sigterm previous_sigterm;
           Sys.set_signal Sys.sigint previous_sigint;
           restore_signal_mask ())
         (fun () ->
            let status = waitpid_nointr pid in
            match !forwarded_signal with
            | Some signal -> Ok (Unix.WSIGNALED signal)
            | None -> Ok status)
     with
     | Unix.Unix_error (error, syscall, argument) ->
       errorf
         "deployment command failed to start or wait syscall=%s argument=%s: %s"
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
      "deployment preparation marker failed syscall=%s argument=%s: %s"
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

let run_tool_blob_maintenance base_path delete_previous_candidates =
  let run_dir = (Host_config.host ()).run_dir in
  match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
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
    Fun.protect
      ~finally:(fun () ->
        Server_startup_takeover.release_base_path_lease lease)
      (fun () ->
         match Unix.realpath base_path with
         | exception exn ->
           errorf
             "workspace BasePath canonicalization failed base_path=%s: %s"
             base_path
             (Printexc.to_string exn)
         | canonical_base_path ->
           let mode =
             if delete_previous_candidates
             then Tool_blob_maintenance.Delete_previous_candidates
             else Tool_blob_maintenance.Observe_only
           in
           (match
              Tool_blob_maintenance.run
                ~base_path:canonical_base_path
                ~mode
            with
            | Error error ->
              errorf
                "tool blob maintenance failed base_path=%s: %s"
                canonical_base_path
                (Tool_blob_maintenance.error_to_string error)
            | Ok report ->
              Yojson.Safe.to_channel
                stdout
                (`Assoc
                  [ "base_path", `String canonical_base_path
                  ; "live_references", `Int report.live_references
                  ; "blobs_observed", `Int report.blobs_observed
                  ; "candidates_recorded", `Int report.candidates_recorded
                  ; "deleted", `Int report.deleted
                  ]);
              output_char stdout '\n';
              flush stdout;
              Ok ()))
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
                      "deployment runtime handoff failed executable=%s: %s"
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

let current_queue_base_path =
  let doc = "Workspace BasePath containing the current queue owner." in
  Arg.(required & opt (some dir) None & info [ "base-path" ] ~docv:"PATH" ~doc)
;;

let current_queue_keeper_name =
  let doc = "Exact Keeper owner whose snapshot and/or transition WAL must load." in
  Arg.(required & opt (some string) None & info [ "keeper-name" ] ~docv:"KEEPER" ~doc)
;;

let validate_current_queue_cmd =
  let doc = "validate a current event-queue through production decode and replay" in
  Cmd.v
    (Cmd.info "validate-current-queue" ~doc)
    Term.(
      ret
        (const
           (fun base_path keeper_name ->
              cmdliner_result (validate_current_queue ~base_path ~keeper_name))
         $ current_queue_base_path
         $ current_queue_keeper_name))
;;

let validate_current_wal_cmd =
  let doc = "validate the current WAL with the production empty-state replay path" in
  Cmd.v
    (Cmd.info "validate-current-wal" ~doc)
    Term.(
      ret
        (const
           (fun base_path keeper_name ->
              cmdliner_result (validate_current_wal ~base_path ~keeper_name))
         $ current_queue_base_path
         $ current_queue_keeper_name))
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
  let doc = "run a deployment check under the canonical BasePath writer lease" in
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

let delete_previous_candidates =
  let doc =
    "Delete blobs present in both the previous and current complete candidate snapshots."
  in
  Arg.(value & flag & info [ "delete-previous-candidates" ] ~doc)
;;

let tool_blob_maintenance_cmd =
  let doc =
    "scan tool-blob ownership under the exclusive BasePath lease; record candidates by default"
  in
  Cmd.v
    (Cmd.info "tool-blob-maintenance" ~doc)
    Term.(
      ret
        (const
           (fun base_path delete_previous_candidates ->
              cmdliner_result
                (run_tool_blob_maintenance
                   base_path
                   delete_previous_candidates))
         $ base_path
         $ delete_previous_candidates))
;;

(* A hard-cut field leaves rows no current decoder can read. [replay] refuses
   to compact while such a row is on disk and the row only leaves through
   compaction, so the store keeps it and its retention bound stops applying —
   #29277. Cutting the store is a deployment step because it drops rows, and
   the operator has to see how many before authorising it. *)
let run_registry_cuts =
  [ ( Masc.Exact_lane_run_registry.storage_filename
    , Masc.Exact_lane_run_registry.cut_replay_log )
  ; Fusion_run_registry.storage_filename, Fusion_run_registry.cut_replay_log
  ; ( Masc.Verification_run_registry.storage_filename
    , Masc.Verification_run_registry.cut_replay_log )
  ; ( Masc.Goal_verification_run_registry.storage_filename
    , Masc.Goal_verification_run_registry.cut_replay_log )
  ]
;;

let cut_run_registries base_path ~execute =
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  let dropped_total =
    List.fold_left
      (fun dropped_total (filename, cut) ->
         let path = Filename.concat masc_dir filename in
         let report = cut ~execute path in
         Printf.printf
           "%s lines=%d unreadable=%d retained=%d rewritten=%b\n%!"
           filename
           report.Run_registry_core.lines_read
           report.malformed_lines
           report.retained_entries
           report.rewritten;
         dropped_total + report.malformed_lines)
      0
      run_registry_cuts
  in
  if execute
  then Ok ()
  else if dropped_total = 0
  then Ok ()
  else
    (* Reporting a store that needs cutting is not a preflight failure; the
       operator decides. The distinct exit code lets the deploy script tell
       "nothing to cut" from "rows are being dropped" without parsing stdout. *)
    errorf
      "%d unreadable row(s) across the run registries; re-run with --execute to \
       cut them"
      dropped_total
;;

let execute_cut =
  let doc = "Rewrite each store, dropping the rows no current decoder reads." in
  Arg.(value & flag & info [ "execute" ] ~doc)
;;

let cut_run_registries_cmd =
  let doc =
    "report run-registry rows the current decoders refuse; --execute rewrites \
     the stores without them (run with the server stopped)"
  in
  Cmd.v
    (Cmd.info "cut-run-registries" ~doc)
    Term.(
      ret
        (const (fun base_path execute ->
           cmdliner_result (cut_run_registries base_path ~execute))
         $ base_path
         $ execute_cut))
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
  let doc = "prepare a deployment under lease, then atomically exec the new runtime" in
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
  let doc = "typed helpers for runtime deployment preflight" in
  exit
    (Cmd.eval
       (Cmd.group
          (Cmd.info "masc-deployment-preflight-helper" ~doc)
          [ lease_run_cmd
          ; lease_handoff_cmd
          ; tool_blob_maintenance_cmd
          ; verify_lease_owner_cmd
          ; validate_current_queue_cmd
          ; validate_current_wal_cmd
          ; validate_schedule_ledger_cmd
          ; validate_signals_cmd
          ; cut_run_registries_cmd
          ]))
;;
