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

(* The two rejection classes call for different operator action, so each
   verdict carries a single-token [class=] label: cmdliner re-wraps the error
   text at the terminal margin and can split a phrase across lines, a token
   survives intact. *)
let validate_current_meta path =
  Masc.Keeper_meta_store.validate_current_meta_file_result path
  |> Result.map_error (function
    | Masc.Keeper_meta_store.Unreadable detail ->
      `Msg
        (Printf.sprintf
           "current keeper meta is unreadable class=unreadable_json path=%s \
            (on boot the runtime refuses this keeper instead of \
            re-materialising it; restore the file from backup): %s"
           path
           detail)
    | Masc.Keeper_meta_store.Not_current detail ->
      `Msg
        (Printf.sprintf
           "current keeper meta production validation rejected \
            class=not_current_schema path=%s (on boot the runtime reads this \
            meta as absent and re-materialises the keeper from its \
            declaration, losing the accumulated counters and the task \
            binding; strip retired fields or fill missing ones): %s"
           path
           detail))
;;

(* The gate prints this next to its verdict so the operator can tell a
   freshly built helper from an older installed one. [binary_commit] is the
   SHA the Dune build rule embeds; a helper built outside a checkout has none. *)
let print_build_commit () =
  match (Masc.Build_identity.current ()).Masc.Build_identity.binary_commit with
  | Some commit -> Printf.printf "%s\n%!" commit
  | None -> Printf.printf "unstamped\n%!"
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
    let lease_dir = (Host_config.host ()).base_path_lease_dir in
    match
      Server_startup_takeover.acquire_base_path_lock
        ~run_dir:lease_dir
        base_path
    with
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
    let lease_dir = (Host_config.host ()).base_path_lease_dir in
    (match
       Server_startup_takeover.acquire_base_path_lock
         ~run_dir:lease_dir
         base_path
     with
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
  let lease_dir = (Host_config.host ()).base_path_lease_dir in
  match
    Server_startup_takeover.acquire_base_path_lock
      ~run_dir:lease_dir
      base_path
  with
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
    let lease_dir = (Host_config.host ()).base_path_lease_dir in
    (match
       Server_startup_takeover.acquire_base_path_lock
         ~run_dir:lease_dir
         base_path
     with
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

let durable_filenames_cmd =
  let doc = "print the durable event-queue filenames this binary reads and writes" in
  Cmd.v
    (Cmd.info "durable-filenames" ~doc)
    Term.(
      const (fun () ->
        (* The preflight script builds fixtures at these exact names. It used
           to spell them out, so bumping the snapshot filename in OCaml left
           the fixtures one version behind and the self-test failed. *)
        Printf.printf
          "snapshot=%s\nwal=%s\n"
          Keeper_event_queue_persistence.snapshot_filename
          Keeper_event_queue_persistence.transition_wal_filename)
      $ const ())
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

let current_meta_file =
  let doc = "Validate one persisted Keeper meta against the current closed schema." in
  Arg.(required & pos 0 (some file) None & info [] ~docv:"KEEPER_META" ~doc)
;;

let validate_current_meta_cmd =
  let doc = "validate one keeper meta with the production decoder" in
  Cmd.v
    (Cmd.info "validate-current-meta" ~doc)
    Term.(
      ret
        (const (fun path -> cmdliner_result (validate_current_meta path))
           $ current_meta_file))
;;

let build_commit_cmd =
  let doc = "print the git commit stamped into this helper at build time" in
  Cmd.v (Cmd.info "build-commit" ~doc) Term.(const print_build_commit $ const ())
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

(* Every durable store this gate can read, in one list.

   The shell gate reads a store by knowing its layout: it runs [find] for a
   glob and calls a per-file subcommand. That works while one command covers
   one store, and it is why five stores are covered and the rest are not --
   each new one is a new subcommand and a new [find]. The path conventions
   already live in OCaml (a keeper's memory snapshot is a suffix on a
   configured id, a disposition receipt sits under a sha256 of the keeper
   name), so the enumeration belongs where the convention is.

   Adding a store here is adding a row.

   [on_refusal] says what the runtime does with a row it cannot read. That is
   the part an operator needs at 3am and it differs per store: some refuse the
   whole file and stop the keeper, some drop the row and never say so. It is
   stated per row rather than inferred, because it is a property of the
   consumer and not of the decoder.

   Every scan runs the production decoder. A fixture cannot go stale here
   because there is no fixture -- these are the rows on disk, read by the
   binary about to serve them. *)
type store_report =
  { rows : int
  ; refused : int
  ; first_refusal : string option
  }

type store_scan =
  { store : string
  ; on_refusal : string
  ; scan : base_path:string -> (store_report, string) result
  }

let empty_report = { rows = 0; refused = 0; first_refusal = None }

let count_row report = function
  | Ok () -> { report with rows = report.rows + 1 }
  | Error detail ->
    { rows = report.rows + 1
    ; refused = report.refused + 1
    ; first_refusal =
        (match report.first_refusal with
         | Some _ as kept -> kept
         | None -> Some detail)
    }
;;

let scan_files ~paths ~decode =
  List.fold_left
    (fun report path ->
       match Fs_compat.load_file path with
       | exception exn ->
         count_row report (Error (path ^ ": " ^ Printexc.to_string exn))
       | contents ->
         count_row
           report
           (decode ~path contents |> Result.map_error (fun d -> path ^ ": " ^ d)))
    empty_report
    paths
;;

let scan_jsonl ~path ~decode =
  if not (Fs_compat.file_exists path)
  then empty_report
  else
    Fs_compat.load_jsonl path
    |> List.fold_left (fun report json -> count_row report (decode json)) empty_report
;;

let files_under dir ~keep =
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | entries ->
    Array.to_list entries
    |> List.filter keep
    |> List.sort String.compare
    |> List.map (Filename.concat dir)
;;

let keeper_meta_store =
  { store = "keeper meta"
  ; on_refusal =
      "the runtime reads the meta as absent and re-materialises the keeper \
       from its declaration, losing accumulated counters and the task binding"
  ; scan =
      (fun ~base_path ->
         let dir =
           Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers"
         in
         Ok
           (scan_files
              ~paths:
                (files_under dir ~keep:(fun name ->
                   Filename.check_suffix name ".json"))
              ~decode:(fun ~path _ ->
                Masc.Keeper_meta_store.validate_current_meta_file_result path
                |> Result.map (fun _ -> ())
                |> Result.map_error (function
                  | Masc.Keeper_meta_store.Unreadable detail
                  | Masc.Keeper_meta_store.Not_current detail -> detail))))
  }
;;

let memory_os_current_store =
  { store = "memory OS current snapshot"
  ; on_refusal =
      "recall injection, the librarian and keeper_memory_write all fail for \
       that keeper, and neither writer repairs it because both read first"
  ; scan =
      (fun ~base_path ->
         let keepers_dir =
           Config_dir_resolver.keepers_dir_for_base_path ~base_path
         in
         Ok
           (Masc.Keeper_memory_os_current.list_keeper_ids_for_keepers_dir
              ~keepers_dir
            |> List.fold_left
                 (fun report keeper_id ->
                    match
                      Masc.Keeper_memory_os_current.read_for_keepers_dir
                        ~keepers_dir
                        ~keeper_id
                    with
                    | Ok None -> report
                    | Ok (Some _) -> count_row report (Ok ())
                    | Error detail ->
                      count_row report (Error (keeper_id ^ ": " ^ detail)))
                 empty_report))
  }
;;

let disposition_receipt_store =
  { store = "paused-work disposition receipts"
  ; on_refusal =
      "the operation id neither replays its receipt nor records a new one, \
       because save_if_absent reads before it writes"
  ; scan =
      (fun ~base_path ->
         let root =
           Filename.concat
             (Common.masc_dir_from_base_path ~base_path)
             ("paused-work-dispositions-"
              ^ Masc.Keeper_paused_work_disposition_receipt.store_version)
         in
         let receipts =
           files_under root ~keep:(fun name ->
             String.starts_with ~prefix:"keeper-" name)
           |> List.concat_map (fun keeper_dir ->
             files_under keeper_dir ~keep:(fun name ->
               String.starts_with ~prefix:"operation-" name
               && Filename.check_suffix name ".json"))
         in
         Ok
           (scan_files ~paths:receipts ~decode:(fun ~path:_ contents ->
              match Yojson.Safe.from_string contents with
              | exception Yojson.Json_error detail -> Error detail
              | json ->
                Masc.Keeper_paused_work_disposition_receipt.of_yojson json
                |> Result.map (fun _ -> ()))))
  }
;;

let board_posts_store =
  { store = "board posts"
  ; on_refusal =
      "the loader drops the row without a log or a counter, and the next \
       full-snapshot write removes it from disk"
  ; scan =
      (fun ~base_path ->
         let path =
           Filename.concat
             (Common.masc_dir_from_base_path ~base_path)
             "board_posts.jsonl"
         in
         Ok
           (scan_jsonl ~path ~decode:(fun json ->
              match Masc_board_handlers.Board_votes_json.post_of_yojson json with
              | Some _ -> Ok ()
              | None -> Error "post rejected by the current field set")))
  }
;;

(* #29590 removed [generation] from TurnRecord as well as from the memory
   snapshot. [Turn_record.of_json] rejects unknown fields, and
   [Keeper_raw_trace_retention.protected_references] folds the whole sweep on
   the first refusal while its caller only warns -- so raw traces stop being
   collected and the disk grows with nothing failing loudly. The rows age out
   after [history_limit] new turns, which is exactly the window this gate
   exists to check before a deploy rather than after (#29666). *)
let turn_record_store =
  { store = "keeper turn records"
  ; on_refusal =
      "raw-trace retention folds its whole sweep on the first refused row and \
       the caller only warns, so traces accumulate with no failing turn"
  ; scan =
      (fun ~base_path ->
         let keepers_dir =
           Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers"
         in
         let store_dir =
           Common.keeper_runtime_store_dirname Common.Keeper_turn_records
         in
         let recent_files keeper_dir =
           let root = Filename.concat keeper_dir store_dir in
           files_under root ~keep:(fun name ->
             not (String.starts_with ~prefix:"." name))
           |> List.concat_map (fun month ->
             files_under month ~keep:(fun name ->
               Filename.check_suffix name ".jsonl"))
         in
         let scan_file report path =
           match open_in path with
           | exception Sys_error _ -> report
           | ic ->
             Fun.protect
               ~finally:(fun () -> close_in_noerr ic)
               (fun () ->
                  let acc = ref report in
                  (try
                     while true do
                       let line = input_line ic in
                       if String.trim line <> ""
                       then
                         acc :=
                           count_row
                             !acc
                             (match Yojson.Safe.from_string line with
                              | exception _ ->
                                Error (Filename.basename path ^ ": not JSON")
                              | json ->
                                (match Turn_record.of_json json with
                                 | Ok _ -> Ok ()
                                 | Error detail ->
                                   Error (Filename.basename path ^ ": " ^ detail)))
                     done
                   with End_of_file -> ());
                  !acc)
         in
         Ok
           (files_under keepers_dir ~keep:(fun name ->
              not (Filename.check_suffix name ".json"))
            |> List.concat_map recent_files
            |> List.fold_left scan_file empty_report))
  }
;;

(* The official-client session store decodes with the same exact-field
   contract the memory snapshot and TurnRecord use, and it lives on disk per
   keeper. A refused row does not start a fresh session -- [load] documents
   that malformed state is an error and never degrades -- so the keeper's
   provider conversation stops resuming and the surrounding adapters have no
   state to plan a claim from. It was the one exact-field decoder with a
   durable store and no entry here (#29666). *)
let official_client_session_store =
  { store = "official-client session state"
  ; on_refusal =
      "the keeper cannot resume its provider conversation and every adapter        that plans a claim reads the same refusal"
  ; scan =
      (fun ~base_path ->
         let keepers_dir =
           Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers"
         in
         Ok
           (files_under keepers_dir ~keep:(fun name ->
              not (Filename.check_suffix name ".json"))
            |> List.fold_left
                 (fun report keeper_dir ->
                    let keeper_name = Filename.basename keeper_dir in
                    match
                      Masc.Keeper_official_client_session_store.load
                        ~base_path
                        ~keeper_name
                    with
                    | Ok None -> report
                    | Ok (Some _) -> count_row report (Ok ())
                    | Error detail ->
                      count_row report (Error (keeper_name ^ ": " ^ detail)))
                 empty_report))
  }
;;

let durable_stores =
  [ keeper_meta_store
  ; official_client_session_store
  ; memory_os_current_store
  ; disposition_receipt_store
  ; board_posts_store
  ; turn_record_store
  ]
;;

let validate_stores base_path =
  let reports =
    List.map
      (fun store -> store, store.scan ~base_path)
      durable_stores
  in
  List.iter
    (fun (store, result) ->
       match result with
       | Error detail -> Printf.printf "%s scan_failed=%s\n%!" store.store detail
       | Ok report ->
         Printf.printf
           "%s rows=%d refused=%d\n%!"
           store.store
           report.rows
           report.refused;
         (match report.first_refusal with
          | None -> ()
          | Some detail ->
            Printf.printf "  first refusal: %s\n%!" detail;
            Printf.printf "  on refusal: %s\n%!" store.on_refusal))
    reports;
  let refused =
    List.fold_left
      (fun total (_, result) ->
         match result with
         | Ok report -> total + report.refused
         | Error _ -> total)
      0
      reports
  in
  let failed_scans =
    List.filter_map
      (fun (store, result) ->
         match result with
         | Error _ -> Some store.store
         | Ok _ -> None)
      reports
  in
  if failed_scans <> []
  then errorf "store scan failed: %s" (String.concat ", " failed_scans)
  else if refused = 0
  then Ok ()
  else
    errorf
      "%d stored row(s) the runtime about to serve them cannot read"
      refused
;;

let validate_stores_cmd =
  let doc =
    "read every durable store this gate knows with the production decoders \
     and report the rows the runtime could not read"
  in
  Cmd.v
    (Cmd.info "validate-stores" ~doc)
    Term.(ret (const (fun base_path -> cmdliner_result (validate_stores base_path)) $ base_path))
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

let scan_run_registries base_path ~execute =
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  List.map
    (fun (filename, cut) ->
       let report = cut ~execute (Filename.concat masc_dir filename) in
       Printf.printf
         "%s lines=%d unreadable=%d retained=%d whole_file=%b rewritten=%b\n%!"
         filename
         report.Run_registry_core.lines_read
         report.malformed_lines
         report.retained_entries
         report.reached_end
         report.rewritten;
       filename, report)
    run_registry_cuts
;;

let cut_run_registries_report ~execute reports =
  let dropped =
    List.fold_left
      (fun total (_, r) -> total + r.Run_registry_core.malformed_lines)
      0
      reports
  in
  (* A store whose last line is unterminated is left alone, which is what a
     crashed server leaves behind — exactly the state a deployment runs into.
     Reporting that as success would tell the deploy script the store was
     cleaned when it was not. *)
  let unfinished =
    List.filter (fun (_, r) -> not r.Run_registry_core.reached_end) reports
    |> List.map fst
  in
  if unfinished <> []
  then
    errorf
      "store(s) end in an unterminated line and were left alone: %s"
      (String.concat ", " unfinished)
  else if not execute
  then
    if dropped = 0
    then Ok ()
    else
      errorf
        "%d unreadable row(s) across the run registries; re-run with --execute \
         to cut them"
        dropped
  else (
    let uncut =
      List.filter
        (fun (_, r) ->
           r.Run_registry_core.malformed_lines > 0 && not r.rewritten)
        reports
      |> List.map fst
    in
    if uncut = []
    then Ok ()
    else
      errorf
        "store(s) still hold unreadable rows after the cut: %s"
        (String.concat ", " uncut))
;;

(* The rewrite replaces the inode and drops rows that are Running on disk, so
   it must not run under a live server. The lease is the same one
   [tool-blob-maintenance] takes for its own destructive pass. *)
let cut_run_registries base_path ~execute =
  if not execute
  then cut_run_registries_report ~execute (scan_run_registries base_path ~execute)
  else (
    let lease_dir = (Host_config.host ()).base_path_lease_dir in
    match
      Server_startup_takeover.acquire_base_path_lock
        ~run_dir:lease_dir
        base_path
    with
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
           cut_run_registries_report
             ~execute
             (scan_run_registries base_path ~execute)))
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
          [ durable_filenames_cmd
          ; lease_run_cmd
          ; lease_handoff_cmd
          ; tool_blob_maintenance_cmd
          ; verify_lease_owner_cmd
          ; validate_current_queue_cmd
          ; validate_current_wal_cmd
          ; validate_current_meta_cmd
          ; build_commit_cmd
          ; validate_schedule_ledger_cmd
          ; validate_signals_cmd
          ; cut_run_registries_cmd
          ; validate_stores_cmd
          ]))
;;
