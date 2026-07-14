type acquire_result =
  | Acquired
  | Already_running of { pid : int }

type base_path_lease =
  { fd : Unix.file_descr
  ; path : string
  }

type base_path_lock_rejection =
  | Base_path_canonicalization_failed of
      { base_path : string
      ; reason : string
      }
  | Base_path_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Run_directory_canonicalization_failed of
      { run_dir : string
      ; reason : string
      }
  | Run_directory_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Run_directory_untrusted_owner of
      { path : string
      ; effective_uid : int
      ; observed_uid : int
      }
  | Run_directory_insecure_permissions of
      { path : string
      ; permissions : int
      }
  | Lease_directory_creation_failed of
      { path : string
      ; reason : string
      }
  | Lease_directory_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Lease_directory_wrong_owner of
      { path : string
      ; expected_uid : int
      ; observed_uid : int
      }
  | Lease_directory_insecure_permissions of
      { path : string
      ; permissions : int
      }
  | Lease_directory_identity_changed of { path : string }
  | Runtime_directory_rejected of Fs_compat.owned_directory_chain_rejection
  | Runtime_directory_creation_failed of
      { path : string
      ; reason : string
      }
  | Lease_file_non_regular of
      { path : string
      ; kind : Unix.file_kind
      }
  | Lease_file_multiply_linked of
      { path : string
      ; links : int
      }
  | Lease_file_wrong_owner of
      { path : string
      ; expected_uid : int
      ; observed_uid : int
      }
  | Lease_identity_changed of { path : string }
  | Lease_io_failed of
      { operation : string
      ; path : string
      ; reason : string
      }

type base_path_acquire_result =
  | Base_path_acquired of base_path_lease
  | Base_path_already_owned of { pid : int option }
  | Base_path_rejected of base_path_lock_rejection

let file_kind_to_string = function
  | Unix.S_REG -> "regular_file"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character_device"
  | Unix.S_BLK -> "block_device"
  | Unix.S_LNK -> "symbolic_link"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let base_path_lock_rejection_to_string = function
  | Base_path_canonicalization_failed { base_path; reason } ->
    Printf.sprintf "BasePath canonicalization failed path=%s error=%s" base_path reason
  | Base_path_not_directory { path; kind } ->
    Printf.sprintf
      "BasePath is not a directory path=%s kind=%s"
      path
      (file_kind_to_string kind)
  | Run_directory_canonicalization_failed { run_dir; reason } ->
    Printf.sprintf
      "host run directory canonicalization failed path=%s error=%s"
      run_dir
      reason
  | Run_directory_not_directory { path; kind } ->
    Printf.sprintf
      "host run directory is not a directory path=%s kind=%s"
      path
      (file_kind_to_string kind)
  | Run_directory_untrusted_owner { path; effective_uid; observed_uid } ->
    Printf.sprintf
      "host run directory owner is outside the process/system trust boundary path=%s effective_uid=%d observed_uid=%d"
      path
      effective_uid
      observed_uid
  | Run_directory_insecure_permissions { path; permissions } ->
    Printf.sprintf
      "host run directory is writable by another UID without sticky-bit protection path=%s permissions=%04o"
      path
      permissions
  | Lease_directory_creation_failed { path; reason } ->
    Printf.sprintf
      "private BasePath lease directory creation failed path=%s error=%s"
      path
      reason
  | Lease_directory_not_directory { path; kind } ->
    Printf.sprintf
      "private BasePath lease path is not a directory path=%s kind=%s"
      path
      (file_kind_to_string kind)
  | Lease_directory_wrong_owner { path; expected_uid; observed_uid } ->
    Printf.sprintf
      "private BasePath lease directory owner mismatch path=%s expected_uid=%d observed_uid=%d"
      path
      expected_uid
      observed_uid
  | Lease_directory_insecure_permissions { path; permissions } ->
    Printf.sprintf
      "private BasePath lease directory permissions are not 0700 path=%s permissions=%04o"
      path
      permissions
  | Lease_directory_identity_changed { path } ->
    Printf.sprintf
      "private BasePath lease directory identity changed before ownership commit path=%s"
      path
  | Runtime_directory_rejected rejection ->
    Fs_compat.owned_directory_chain_rejection_to_string rejection
  | Runtime_directory_creation_failed { path; reason } ->
    Printf.sprintf "runtime directory creation failed path=%s error=%s" path reason
  | Lease_file_non_regular { path; kind } ->
    Printf.sprintf
      "BasePath lease is not a regular file path=%s kind=%s"
      path
      (file_kind_to_string kind)
  | Lease_file_multiply_linked { path; links } ->
    Printf.sprintf
      "BasePath lease has multiple hard links path=%s links=%d"
      path
      links
  | Lease_file_wrong_owner { path; expected_uid; observed_uid } ->
    Printf.sprintf
      "BasePath lease owner mismatch path=%s expected_uid=%d observed_uid=%d"
      path
      expected_uid
      observed_uid
  | Lease_identity_changed { path } ->
    Printf.sprintf "BasePath lease identity changed before ownership commit path=%s" path
  | Lease_io_failed { operation; path; reason } ->
    Printf.sprintf
      "BasePath lease I/O failed operation=%s path=%s error=%s"
      operation
      path
      reason
;;

let base_path_lease_mu = Mutex.create ()

type retained_base_path_fd =
  | Active_lease of base_path_lease
  | Failed_close of base_path_lease * base_path_lock_rejection

let base_path_leases : (string, retained_base_path_fd) Hashtbl.t =
  Hashtbl.create 2
;;

let close_acquisition_fd ~operation ~path ~context fd =
  try
    Unix.close fd;
    Ok ()
  with
  | exn ->
    let rejection =
      Lease_io_failed
        { operation
        ; path
        ; reason =
            Printf.sprintf
              "%s; close failed: %s"
              context
              (Printexc.to_string exn)
        }
    in
    (* [acquire_base_path_lock_with] holds [base_path_lease_mu]. A failed
       close leaves descriptor and kernel-lock ownership ambiguous, so retain
       a process-local fence and return an explicit typed rejection. *)
    Hashtbl.replace
      base_path_leases
      path
      (Failed_close ({ fd; path }, rejection));
    Error rejection
;;

let pid_lock_path port =
  Filename.concat (Host_config.host ()).run_dir (Printf.sprintf "masc-%d.pid" port)
;;

let private_lease_directory_permissions = 0o700
let private_lease_directory_prefix = "masc-base-path-leases-v1"

let base_path_lease_directory ~run_dir ~owner_uid =
  Filename.concat
    run_dir
    (Printf.sprintf "%s-%d" private_lease_directory_prefix owner_uid)
;;

let base_path_lock_path_for_owner ~run_dir ~canonical_base_path ~owner_uid =
  let digest =
    Digestif.SHA256.(digest_string canonical_base_path |> to_hex)
  in
  Filename.concat
    (base_path_lease_directory ~run_dir ~owner_uid)
    (Printf.sprintf "masc-base-path-owner-v1-%s.lease" digest)
;;

let base_path_lock_path ~run_dir ~canonical_base_path =
  base_path_lock_path_for_owner
    ~run_dir
    ~canonical_base_path
    ~owner_uid:(Unix.geteuid ())
;;

let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()
;;

let pid_exists pid =
  try
    Unix.kill pid 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true
;;

let sleep_poll seconds = if seconds > 0.0 then ignore (Unix.select [] [] [] seconds)

let wait_for_pid_exit ?(poll_interval_sec = 0.1) ~timeout_sec pid =
  let deadline = Unix.gettimeofday () +. max 0.0 timeout_sec in
  let rec loop () =
    if not (pid_exists pid)
    then true
    else (
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0.0
      then false
      else (
        sleep_poll (Float.min poll_interval_sec remaining);
        loop ()))
  in
  loop ()
;;

let rec write_all fd payload off len =
  if len > 0
  then (
    let written = Unix.write_substring fd payload off len in
    if written = 0
    then raise End_of_file
    else write_all fd payload (off + written) (len - written))
;;

let status_line_from_buffer buf =
  let contents = Buffer.contents buf in
  match String.index_opt contents '\n' with
  | None -> None
  | Some idx -> Some (String.sub contents 0 idx |> String.trim)
;;

let status_line_is_healthy line =
  let parts =
    String.split_on_char ' ' line |> List.filter (fun value -> String.trim value <> "")
  in
  match parts with
  | version :: code :: _ ->
    (String.equal version "HTTP/1.1" || String.equal version "HTTP/1.0")
    && String.equal code "200"
  | _ -> false
;;


let looks_like_server_command command =
  List.exists
    (fun marker -> String_util.contains_substring command marker)
    [ "main_eio"; "masc" ]
;;

let process_command pid =
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "system/startup_takeover")
      ~raw_source:(Printf.sprintf "ps -p %d -o command=" pid)
      ~summary:"startup takeover ps probe"

      [ "ps"; "-p"; string_of_int pid; "-o"; "command=" ]
  with
  | Unix.WEXITED 0, output ->
    let trimmed = String.trim output in
    if trimmed = "" then None else Some trimmed
  | _ -> None
;;

let read_status_line fd ~timeout_sec =
  let deadline = Unix.gettimeofday () +. max 0.0 timeout_sec in
  let scratch = Bytes.create 256 in
  let buf = Buffer.create 128 in
  let rec loop () =
    match status_line_from_buffer buf with
    | Some line -> Some line
    | None ->
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0.0
      then None
      else (
        let readable, _, _ = Unix.select [ fd ] [] [] remaining in
        if readable = []
        then None
        else (
          match Unix.read fd scratch 0 (Bytes.length scratch) with
          | 0 -> status_line_from_buffer buf
          | count ->
            Buffer.add_subbytes buf scratch 0 count;
            loop ()))
  in
  loop ()
;;

let probe_liveness ?(timeout_sec = 3.0) ?(path = Server_health_paths.liveness) port =
  Safe_ops.protect ~default:false (fun () ->
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Eio_guard.protect
      ~finally:(fun () -> close_quietly socket)
      (fun () ->
         (* Keep the startup probe in-process so takeover logic does not depend on
           shelling out to curl before the Eio runtime is initialized. *)
         Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
         let request =
           Printf.sprintf
             "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n"
             path
             port
         in
         write_all socket request 0 (String.length request);
         match read_status_line socket ~timeout_sec with
         | Some line -> status_line_is_healthy line
         | None -> false))
;;

let read_pid_file path =
  Safe_ops.protect ~default:None (fun () -> Some (Fs_compat.load_file path))
;;

let parsed_pid path =
  match read_pid_file path with
  | Some data ->
    (match String.trim data |> int_of_string_opt with
     | Some pid when pid > 0 -> Some pid
     | _ -> None)
  | None -> None
;;

let register_pid_cleanup ~path ~pid =
  at_exit (fun () ->
    match parsed_pid path with
    | Some current when current = pid ->
      Safe_ops.protect ~default:() (fun () -> Sys.remove path)
    | Some _ -> ()
    | None -> ())
;;

let write_pid_file path pid =
  let oc = open_out path in
  Eio_guard.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> Printf.fprintf oc "%d\n" pid)
;;

let claim_pid_file path =
  Fs_compat.mkdir_p (Filename.dirname path);
  let pid = Unix.getpid () in
  write_pid_file path pid;
  register_pid_cleanup ~path ~pid;
  Acquired
;;

let acquire_pid_lock
      ?lock_path
      ?(probe_timeout_sec = 3.0)
      ?(term_timeout_sec = 1.0)
      ?(kill_wait_sec = 0.5)
      ?(poll_interval_sec = 0.1)
      port
  =
  let path =
    match lock_path with
    | Some value -> value
    | None -> pid_lock_path port
  in
  (match read_pid_file path with
   | Some data ->
     (match String.trim data |> int_of_string_opt with
      | Some pid when pid > 0 ->
        if pid_exists pid
        then
          if probe_liveness ~timeout_sec:probe_timeout_sec port
          then Already_running { pid }
          else if
            match process_command pid with
            | Some command -> not (looks_like_server_command command)
            | None -> true
          then (
            Log.legacy_stderr
              ~level:Log.Error
              ~module_name:"Server"
              (Printf.sprintf
                 "[FATAL] PID %d is alive but does not look like a masc server; \
                  refusing takeover"
                 pid);
            Already_running { pid })
          else (
            Log.legacy_stderr
              ~level:Log.Warn
              ~module_name:"Server"
              (Printf.sprintf
                 "[WARN] PID %d alive but unresponsive on port %d; sending SIGTERM to \
                  reclaim"
                 pid
                 port);
            Safe_ops.protect ~default:() (fun () -> Unix.kill pid Sys.sigterm);
            if
              not (wait_for_pid_exit ~poll_interval_sec ~timeout_sec:term_timeout_sec pid)
            then (
              Log.legacy_stderr
                ~level:Log.Warn
                ~module_name:"Server"
                (Printf.sprintf "[WARN] PID %d did not exit; sending SIGKILL" pid);
              Safe_ops.protect ~default:() (fun () -> Unix.kill pid Sys.sigkill);
              if not (wait_for_pid_exit ~poll_interval_sec ~timeout_sec:kill_wait_sec pid)
              then
                Log.legacy_stderr
                  ~level:Log.Warn
                  ~module_name:"Server"
                  (Printf.sprintf
                     "[WARN] PID %d still appears alive after SIGKILL escalation"
                     pid));
            Acquired)
        else (
          Log.legacy_stderr
            ~level:Log.Warn
            ~module_name:"Server"
            (Printf.sprintf
               "[WARN] Removing stale PID file (PID %d no longer running)"
               pid);
          Acquired)
      | _ ->
        Log.legacy_stderr
          ~level:Log.Warn
          ~module_name:"Server"
          "[WARN] Invalid PID file contents, overwriting";
        Acquired)
   | None -> Acquired)
  |> function
  | Already_running _ as result -> result
  | Acquired -> claim_pid_file path
;;

let write_all fd content =
  let rec loop offset =
    if offset < String.length content
    then
      let written =
        Unix.write_substring fd content offset (String.length content - offset)
      in
      if written = 0 then raise End_of_file else loop (offset + written)
  in
  loop 0
;;

let release_base_path_lease lease =
  Mutex.protect base_path_lease_mu (fun () ->
    let owns_table_entry =
      match Hashtbl.find_opt base_path_leases lease.path with
      | Some (Active_lease current) -> current == lease
      | Some (Failed_close _) -> false
      | None -> false
    in
    if not owns_table_entry
    then
      (* File-descriptor integers may be reused immediately after close. Never
         touch an fd from a stale/double-released abstract handle: it may now
         designate an unrelated resource or a newer lease. *)
      Log.Server.error
        "BasePath lease release ignored because the handle is not the active owner: path=%s"
        lease.path
    else (
      (try
         let (_ : int) = Unix.lseek lease.fd 0 Unix.SEEK_SET in
         Unix.lockf lease.fd Unix.F_ULOCK 0
       with
       | Unix.Unix_error (error, syscall, argument) ->
         Log.Server.error
           "BasePath lease unlock failed: path=%s error=%s syscall=%s argument=%s"
           lease.path
           (Unix.error_message error)
           syscall
           argument);
      let closed =
        try
          Unix.close lease.fd;
          true
        with
        | Unix.Unix_error (error, syscall, argument) ->
          Log.Server.error
            "BasePath lease close failed: path=%s error=%s syscall=%s argument=%s"
            lease.path
            (Unix.error_message error)
            syscall
            argument;
          false
      in
      (* A failed close leaves descriptor ownership ambiguous. Retain the
         process-local fence in that case; admitting an alias after a failed
         release would be worse than an explicit fail-closed leak. *)
      if closed then Hashtbl.remove base_path_leases lease.path))
;;

type prepared_base_path_lock =
  { canonical_base_path : string
  ; base_path_stat : Unix.stats
  ; run_directory : string
  ; run_directory_stat : Unix.stats
  ; lease_directory : string
  ; lease_directory_stat : Unix.stats
  ; runtime_directory : string
  ; path : string
  ; owner_uid : int
  }

let same_file_identity (left : Unix.stats) (right : Unix.stats) =
  left.st_dev = right.st_dev && left.st_ino = right.st_ino
;;

let permission_bits (stat : Unix.stats) = stat.st_perm land 0o7777

let validate_run_directory_boundary ~path ~owner_uid (stat : Unix.stats) =
  let permissions = permission_bits stat in
  (* Sticky mode protects an entry from peer UIDs, but the parent owner keeps
     removal authority. Limit that authority to the system or effective-UID
     host principal before relying on the sticky bit. *)
  let owner_is_trusted = stat.st_uid = owner_uid || stat.st_uid = 0 in
  if not owner_is_trusted
  then
    Error
      (Run_directory_untrusted_owner
         { path; effective_uid = owner_uid; observed_uid = stat.st_uid })
  else if permissions land 0o022 <> 0 && permissions land 0o1000 = 0
  then Error (Run_directory_insecure_permissions { path; permissions })
  else Ok ()
;;

type lease_directory_observation =
  | Lease_directory_missing
  | Lease_directory_ready of Unix.stats

let inspect_lease_directory ~path ~owner_uid =
  match Unix.lstat path with
  | stat when stat.Unix.st_kind <> Unix.S_DIR ->
    Error (Lease_directory_not_directory { path; kind = stat.st_kind })
  | stat when stat.st_uid <> owner_uid ->
    Error
      (Lease_directory_wrong_owner
         { path; expected_uid = owner_uid; observed_uid = stat.st_uid })
  | stat when permission_bits stat <> private_lease_directory_permissions ->
    Error
      (Lease_directory_insecure_permissions
         { path; permissions = permission_bits stat })
  | stat -> Ok (Lease_directory_ready stat)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Lease_directory_missing
  | exception Unix.Unix_error (error, syscall, argument) ->
    Error
      (Lease_io_failed
         { operation = "inspect_private_lease_directory"
         ; path
         ; reason =
             Printf.sprintf
               "%s syscall=%s argument=%s"
               (Unix.error_message error)
               syscall
               argument
         })
;;

let establish_lease_directory ~path ~owner_uid =
  let inspect () = inspect_lease_directory ~path ~owner_uid in
  match inspect () with
  | Error _ as error -> error
  | Ok (Lease_directory_ready stat) -> Ok stat
  | Ok Lease_directory_missing ->
    (match
       try
         Unix.mkdir path private_lease_directory_permissions;
         Ok ()
       with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
       | Unix.Unix_error (error, syscall, argument) ->
         Error
           (Lease_directory_creation_failed
              { path
              ; reason =
                  Printf.sprintf
                    "%s syscall=%s argument=%s"
                    (Unix.error_message error)
                    syscall
                    argument
              })
     with
     | Error _ as error -> error
     | Ok () ->
       (match inspect () with
        | Error _ as error -> error
        | Ok Lease_directory_missing ->
          Error
            (Lease_directory_creation_failed
               { path; reason = "directory remained missing after mkdir" })
        | Ok (Lease_directory_ready stat) -> Ok stat))
;;

let verify_directory_identity ~path ~expected =
  match Unix.lstat path with
  | current
    when current.Unix.st_kind = Unix.S_DIR
         && same_file_identity expected current -> Ok ()
  | _ -> Error (Lease_identity_changed { path })
  | exception Unix.Unix_error (error, syscall, argument) ->
    Error
      (Lease_io_failed
         { operation = "verify_directory_identity"
         ; path
         ; reason =
             Printf.sprintf
               "%s syscall=%s argument=%s"
               (Unix.error_message error)
               syscall
               argument
         })
;;

let verify_run_directory_identity ~path ~owner_uid ~expected =
  match Unix.lstat path with
  | current
    when current.Unix.st_kind = Unix.S_DIR
         && same_file_identity expected current ->
    validate_run_directory_boundary ~path ~owner_uid current
  | _ -> Error (Lease_identity_changed { path })
  | exception Unix.Unix_error (error, syscall, argument) ->
    Error
      (Lease_io_failed
         { operation = "verify_run_directory_identity"
         ; path
         ; reason =
             Printf.sprintf
               "%s syscall=%s argument=%s"
               (Unix.error_message error)
               syscall
               argument
         })
;;

let verify_lease_directory_identity ~path ~owner_uid ~expected =
  match inspect_lease_directory ~path ~owner_uid with
  | Error _ as error -> error
  | Ok Lease_directory_missing -> Error (Lease_directory_identity_changed { path })
  | Ok (Lease_directory_ready current) ->
    if same_file_identity expected current
    then Ok ()
    else Error (Lease_directory_identity_changed { path })
;;

let inspect_runtime_directory ~base_path runtime_directory =
  try
    match
      Fs_compat.inspect_owned_directory_chain
        ~ownership_root:base_path
        runtime_directory
    with
    | Ok (Fs_compat.Owned_directory stat) -> Ok (`Ready stat)
    | Ok Fs_compat.Owned_directory_missing -> Ok `Missing
    | Error rejection -> Error (Runtime_directory_rejected rejection)
  with
  | exn ->
    Error
      (Lease_io_failed
         { operation = "inspect_runtime_directory"
         ; path = runtime_directory
         ; reason = Printexc.to_string exn
         })
;;

let prepare_base_path_lock ~run_dir base_path =
  let ( let* ) = Result.bind in
  let* canonical_base_path =
    try Ok (Unix.realpath base_path) with
    | exn ->
      Error
        (Base_path_canonicalization_failed
           { base_path; reason = Printexc.to_string exn })
  in
  let* base_path_stat =
    match Unix.lstat canonical_base_path with
    | stat when stat.Unix.st_kind = Unix.S_DIR -> Ok stat
    | stat ->
      Error
        (Base_path_not_directory
           { path = canonical_base_path; kind = stat.st_kind })
    | exception exn ->
      Error
        (Lease_io_failed
           { operation = "lstat_base_path"
           ; path = canonical_base_path
           ; reason = Printexc.to_string exn
           })
  in
  let* run_directory =
    try Ok (Unix.realpath run_dir) with
    | exn ->
      Error
        (Run_directory_canonicalization_failed
           { run_dir; reason = Printexc.to_string exn })
  in
  let* run_directory_stat =
    match Unix.lstat run_directory with
    | stat when stat.Unix.st_kind = Unix.S_DIR -> Ok stat
    | stat ->
      Error
        (Run_directory_not_directory
           { path = run_directory; kind = stat.st_kind })
    | exception exn ->
      Error
        (Lease_io_failed
           { operation = "lstat_run_directory"
           ; path = run_directory
           ; reason = Printexc.to_string exn
           })
  in
  let owner_uid = Unix.geteuid () in
  let* () =
    validate_run_directory_boundary
      ~path:run_directory
      ~owner_uid
      run_directory_stat
  in
  let lease_directory =
    base_path_lease_directory ~run_dir:run_directory ~owner_uid
  in
  let* lease_directory_stat =
    establish_lease_directory ~path:lease_directory ~owner_uid
  in
  let* () =
    verify_run_directory_identity
      ~path:run_directory
      ~owner_uid
      ~expected:run_directory_stat
  in
  let* () =
    verify_lease_directory_identity
      ~path:lease_directory
      ~owner_uid
      ~expected:lease_directory_stat
  in
  Ok
    { canonical_base_path
    ; base_path_stat
    ; run_directory
    ; run_directory_stat
    ; lease_directory
    ; lease_directory_stat
    ; runtime_directory =
        Filename.concat canonical_base_path Common.masc_dirname
    ; path =
        base_path_lock_path_for_owner
          ~run_dir:run_directory
          ~canonical_base_path
          ~owner_uid
    ; owner_uid
    }
;;

let establish_runtime_directory prepared =
  let inspect () =
    inspect_runtime_directory
      ~base_path:prepared.canonical_base_path
      prepared.runtime_directory
  in
  match inspect () with
  | Error _ as error -> error
  | Ok (`Ready stat) -> Ok stat
  | Ok `Missing ->
    (match
       try
         Unix.mkdir prepared.runtime_directory 0o755;
         Ok ()
       with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
       | exn ->
         Error
           (Runtime_directory_creation_failed
              { path = prepared.runtime_directory; reason = Printexc.to_string exn })
     with
     | Error _ as error -> error
     | Ok () ->
       (match inspect () with
        | Error _ as error -> error
        | Ok `Missing ->
          Error
            (Runtime_directory_creation_failed
               { path = prepared.runtime_directory
               ; reason = "directory remained missing after mkdir"
               })
        | Ok (`Ready stat) -> Ok stat))
;;

type lease_path_observation =
  | Lease_path_missing
  | Lease_path_regular of Unix.stats
  | Lease_path_other of Unix.file_kind

let observe_lease_path path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind = Unix.S_REG
    then Ok (Lease_path_regular stat)
    else Ok (Lease_path_other stat.st_kind)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Lease_path_missing
  | exn ->
    Error
      (Lease_io_failed
         { operation = "lstat_lease_file"
         ; path
         ; reason = Printexc.to_string exn
         })
;;

let verify_open_lease_file prepared fd expected_file_stat =
  let reject rejection =
    match
      close_acquisition_fd
        ~operation:"close_rejected_lease_file"
        ~path:prepared.path
        ~context:(base_path_lock_rejection_to_string rejection)
        fd
    with
    | Ok () -> Error rejection
    | Error close_rejection -> Error close_rejection
  in
  try
    let descriptor_stat = Unix.fstat fd in
    if descriptor_stat.Unix.st_kind <> Unix.S_REG
    then reject (Lease_file_non_regular { path = prepared.path; kind = descriptor_stat.st_kind })
    else if descriptor_stat.st_nlink <> 1
    then
      reject
        (Lease_file_multiply_linked
           { path = prepared.path; links = descriptor_stat.st_nlink })
    else if descriptor_stat.st_uid <> prepared.owner_uid
    then
      reject
        (Lease_file_wrong_owner
           { path = prepared.path
           ; expected_uid = prepared.owner_uid
           ; observed_uid = descriptor_stat.st_uid
           })
    else
      match
        verify_run_directory_identity
          ~path:prepared.run_directory
          ~owner_uid:prepared.owner_uid
          ~expected:prepared.run_directory_stat
      with
      | Error rejection -> reject rejection
      | Ok () ->
        (match
           verify_lease_directory_identity
             ~path:prepared.lease_directory
             ~owner_uid:prepared.owner_uid
             ~expected:prepared.lease_directory_stat
         with
         | Error rejection -> reject rejection
         | Ok () ->
           (match Unix.lstat prepared.path with
         | path_stat when path_stat.Unix.st_kind <> Unix.S_REG ->
           reject
             (Lease_file_non_regular
                { path = prepared.path; kind = path_stat.st_kind })
         | path_stat when path_stat.st_nlink <> 1 ->
           reject
             (Lease_file_multiply_linked
                { path = prepared.path; links = path_stat.st_nlink })
         | path_stat when path_stat.st_uid <> prepared.owner_uid ->
           reject
             (Lease_file_wrong_owner
                { path = prepared.path
                ; expected_uid = prepared.owner_uid
                ; observed_uid = path_stat.st_uid
                })
         | path_stat
           when not (same_file_identity descriptor_stat path_stat)
                ||
                (match expected_file_stat with
                 | None -> false
                 | Some expected -> not (same_file_identity expected path_stat)) ->
           reject (Lease_identity_changed { path = prepared.path })
           | _ ->
             (match
                verify_lease_directory_identity
                  ~path:prepared.lease_directory
                  ~owner_uid:prepared.owner_uid
                  ~expected:prepared.lease_directory_stat
              with
              | Error rejection -> reject rejection
              | Ok () ->
                (match
                   verify_run_directory_identity
                     ~path:prepared.run_directory
                     ~owner_uid:prepared.owner_uid
                     ~expected:prepared.run_directory_stat
                 with
                 | Error rejection -> reject rejection
                 | Ok () ->
                   (match
                      verify_directory_identity
                        ~path:prepared.canonical_base_path
                        ~expected:prepared.base_path_stat
                    with
                    | Error rejection -> reject rejection
                    | Ok () -> Ok fd)))))
  with
  | exn ->
    reject
      (Lease_io_failed
         { operation = "verify_lease_identity"
         ; path = prepared.path
         ; reason = Printexc.to_string exn
         })
;;

let open_existing_lease_file prepared expected_file_stat =
  if expected_file_stat.Unix.st_uid <> prepared.owner_uid
  then
    Error
      (Lease_file_wrong_owner
         { path = prepared.path
         ; expected_uid = prepared.owner_uid
         ; observed_uid = expected_file_stat.st_uid
         })
  else
    try
      let fd = Unix.openfile prepared.path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
      verify_open_lease_file prepared fd (Some expected_file_stat)
    with
    | exn ->
      Error
        (Lease_io_failed
           { operation = "open_existing_lease_file"
           ; path = prepared.path
           ; reason = Printexc.to_string exn
           })
;;

let open_lease_file prepared =
  match
    verify_run_directory_identity
      ~path:prepared.run_directory
      ~owner_uid:prepared.owner_uid
      ~expected:prepared.run_directory_stat
  with
  | Error _ as error -> error
  | Ok () ->
    (match
       verify_lease_directory_identity
         ~path:prepared.lease_directory
         ~owner_uid:prepared.owner_uid
         ~expected:prepared.lease_directory_stat
     with
     | Error _ as error -> error
     | Ok () ->
       (match observe_lease_path prepared.path with
     | Error _ as error -> error
     | Ok (Lease_path_other kind) ->
       Error (Lease_file_non_regular { path = prepared.path; kind })
     | Ok (Lease_path_regular stat) -> open_existing_lease_file prepared stat
     | Ok Lease_path_missing ->
       (try
          let fd =
            Unix.openfile
              prepared.path
              [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
              0o600
          in
          verify_open_lease_file prepared fd None
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) ->
          (match observe_lease_path prepared.path with
           | Ok (Lease_path_regular stat) -> open_existing_lease_file prepared stat
           | Ok (Lease_path_other kind) ->
             Error (Lease_file_non_regular { path = prepared.path; kind })
           | Ok Lease_path_missing ->
             Error (Lease_identity_changed { path = prepared.path })
           | Error _ as error -> error)
          | exn ->
            Error
              (Lease_io_failed
                 { operation = "create_lease_file"
                 ; path = prepared.path
                 ; reason = Printexc.to_string exn
                 }))))
;;

let parsed_pid_fd fd =
  let maximum_length = String.length (string_of_int max_int) + 1 in
  let payload = Bytes.create maximum_length in
  try
    let (_ : int) = Unix.lseek fd 0 Unix.SEEK_SET in
    let rec read offset =
      if offset = maximum_length
      then offset
      else
        let count = Unix.read fd payload offset (maximum_length - offset) in
        if count = 0 then offset else read (offset + count)
    in
    let length = read 0 in
    Bytes.sub_string payload 0 length |> String.trim |> int_of_string_opt
  with
  | exn ->
    Log.Server.error
      "BasePath lease owner read failed path_fd error=%s"
      (Printexc.to_string exn);
    None
;;

let acquire_base_path_lock_with
      ~before_lease_open
      ~before_commit_identity_check
      ~before_runtime_identity_check
      ~run_dir
      base_path
  =
  match prepare_base_path_lock ~run_dir base_path with
  | Error rejection -> Base_path_rejected rejection
  | Ok prepared ->
    before_lease_open ();
    (* [lockf] locks are process-associated on POSIX, so a second descriptor in
       this process may successfully acquire the same kernel lock. The key is
       a full SHA-256 projection of the canonical BasePath into the validated,
       current-UID private lease directory. A digest collision remains
       fail-closed because both identities contend on the same lease file. *)
    Mutex.protect base_path_lease_mu (fun () ->
      match Hashtbl.find_opt base_path_leases prepared.path with
      | Some (Active_lease _) ->
        (* NDT-OK: the OS process id is the observed owner identity. *)
        Base_path_already_owned { pid = Some (Unix.getpid ()) }
      | Some (Failed_close (_, rejection)) -> Base_path_rejected rejection
      | None ->
        (match open_lease_file prepared with
         | Error rejection -> Base_path_rejected rejection
         | Ok fd ->
           (try
              Unix.lockf fd Unix.F_TLOCK 0;
              before_commit_identity_check ();
              (* Establish [.masc] only after the external lifetime lease is
                 held. OCaml's portable Unix surface has no directory-relative
                 no-follow open. The private lease directory blocks other-UID
                 path replacement; same-UID mutation remains an explicit
                 composition-root invariant tracked by #24344. *)
              (match verify_open_lease_file prepared fd None with
               | Error rejection -> Base_path_rejected rejection
               | Ok fd ->
                 (match establish_runtime_directory prepared with
                  | Error rejection ->
                    (match
                       close_acquisition_fd
                         ~operation:"close_failed_runtime_establishment"
                         ~path:prepared.path
                         ~context:
                           (base_path_lock_rejection_to_string rejection)
                         fd
                     with
                     | Ok () -> Base_path_rejected rejection
                     | Error close_rejection -> Base_path_rejected close_rejection)
                  | Ok runtime_directory_stat ->
                    before_runtime_identity_check ();
                    (match
                       verify_directory_identity
                         ~path:prepared.runtime_directory
                         ~expected:runtime_directory_stat
                     with
                     | Error rejection ->
                       (match
                          close_acquisition_fd
                            ~operation:"close_retargeted_runtime_directory"
                            ~path:prepared.path
                            ~context:
                              (base_path_lock_rejection_to_string rejection)
                            fd
                        with
                        | Ok () -> Base_path_rejected rejection
                        | Error close_rejection ->
                          Base_path_rejected close_rejection)
                     | Ok () ->
                       (match verify_open_lease_file prepared fd None with
                        | Error rejection -> Base_path_rejected rejection
                        | Ok fd ->
                          (* NDT-OK: persist the OS lease holder identity for operator observation. *)
                          let pid = Unix.getpid () in
                          let payload = Printf.sprintf "%d\n" pid in
                          Unix.ftruncate fd 0;
                          let (_ : int) = Unix.lseek fd 0 Unix.SEEK_SET in
                          write_all fd payload;
                          Unix.fsync fd;
                          let lease = { fd; path = prepared.path } in
                          Hashtbl.add
                            base_path_leases
                            prepared.path
                            (Active_lease lease);
                          Base_path_acquired lease))))
            with
            | Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
              let pid = parsed_pid_fd fd in
              (match
                 close_acquisition_fd
                   ~operation:"close_contended_lease_file"
                   ~path:prepared.path
                   ~context:"kernel lease is owned by another process"
                   fd
               with
               | Ok () -> Base_path_already_owned { pid }
               | Error rejection -> Base_path_rejected rejection)
            | exn ->
              let commit_rejection =
                Lease_io_failed
                  { operation = "commit_base_path_lease"
                  ; path = prepared.path
                  ; reason = Printexc.to_string exn
                  }
              in
              (match
                 close_acquisition_fd
                   ~operation:"close_failed_lease_commit"
                   ~path:prepared.path
                   ~context:
                     (base_path_lock_rejection_to_string commit_rejection)
                   fd
               with
               | Ok () -> Base_path_rejected commit_rejection
               | Error rejection -> Base_path_rejected rejection))))
;;

let acquire_base_path_lock =
  acquire_base_path_lock_with
    ~before_lease_open:(fun () -> ())
    ~before_commit_identity_check:(fun () -> ())
    ~before_runtime_identity_check:(fun () -> ())
;;

module For_testing = struct
  let acquire_base_path_lock = acquire_base_path_lock_with
end
