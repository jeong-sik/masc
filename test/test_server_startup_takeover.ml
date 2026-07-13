open Masc

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> close_quietly socket)
    (fun () ->
      (match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
       | () -> ()
       | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) ->
           Alcotest.skip ());
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | _ -> Alcotest.fail "unexpected socket address")

let process_alive pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> true
  | _ -> false
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> false

let rec waitpid_nointr pid =
  try Some (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid
  | Unix.Unix_error (Unix.ECHILD, _, _) -> None

let with_dev_null_fds f =
  let in_fd = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let out_fd = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let err_fd = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  Fun.protect
    ~finally:(fun () ->
      close_quietly in_fd;
      close_quietly out_fd;
      close_quietly err_fd)
    (fun () -> f ~in_fd ~out_fd ~err_fd)

let wait_until ~timeout_sec f =
  let deadline = Unix.gettimeofday () +. timeout_sec in
  let rec loop () =
    if f () then
      true
    else if Unix.gettimeofday () >= deadline then
      false
    else begin
      ignore (Unix.select [] [] [] 0.02);
      loop ()
    end
  in
  loop ()

let port_accepting port =
  try
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> close_quietly socket)
      (fun () ->
        Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
        true)
  with _ -> false

let rec write_all fd payload off len =
  if len > 0 then
    let written = Unix.write_substring fd payload off len in
    if written = 0 then
      raise End_of_file
    else
      write_all fd payload (off + written) (len - written)

let spawn_http_server ~status_code =
  let port = find_free_port () in
  match Unix.fork () with
  | 0 ->
      let server = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Unix.setsockopt server Unix.SO_REUSEADDR true;
      Fun.protect
        ~finally:(fun () ->
          close_quietly server;
          Unix._exit 0)
        (fun () ->
          Unix.bind server (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
          Unix.listen server 8;
          let response =
            Printf.sprintf
              "HTTP/1.1 %d Test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
              status_code
          in
          let scratch = Bytes.create 256 in
          while true do
            let client, _ = Unix.accept server in
            ignore (Unix.read client scratch 0 (Bytes.length scratch));
            write_all client response 0 (String.length response);
            close_quietly client
          done)
  | pid ->
      if not (wait_until ~timeout_sec:1.0 (fun () -> port_accepting port)) then begin
        (try Unix.kill pid Sys.sigkill with _ -> ());
        ignore (waitpid_nointr pid);
        Alcotest.fail "HTTP test server did not start"
      end;
      (pid, port)

let spawn_forever_process ?argv0 ~ignore_sigterm () =
  match argv0 with
  | Some name ->
      let script =
        if ignore_sigterm then
          "trap '' TERM; while :; do sleep 1; done"
        else
          "while :; do sleep 1; done"
      in
      with_dev_null_fds (fun ~in_fd ~out_fd ~err_fd ->
          Unix.create_process "/bin/sh" [| name; "-c"; script |]
            in_fd out_fd err_fd)
  | None ->
      match Unix.fork () with
      | 0 ->
          if ignore_sigterm then
            Sys.set_signal Sys.sigterm Sys.Signal_ignore;
          while true do
            ignore (Unix.select [] [] [] 1.0)
          done
      | pid -> pid

let stop_process pid =
  if process_alive pid then
    (try Unix.kill pid Sys.sigkill with _ -> ());
  ignore (waitpid_nointr pid)

let with_http_server ~status_code f =
  let pid, port = spawn_http_server ~status_code in
  Fun.protect ~finally:(fun () -> stop_process pid) (fun () -> f ~pid ~port)

let with_forever_process ?argv0 ~ignore_sigterm f =
  let pid = spawn_forever_process ?argv0 ~ignore_sigterm () in
  Fun.protect ~finally:(fun () -> stop_process pid) (fun () -> f pid)

let lock_path dir =
  Filename.concat dir "masc.pid"

let base_path_lock_path ~run_dir base_path =
  Server_startup_takeover.base_path_lock_path
    ~run_dir:(Unix.realpath run_dir)
    ~canonical_base_path:(Unix.realpath base_path)

let established_base_path_lock_path ~run_dir base_path =
  match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
  | Server_startup_takeover.Base_path_acquired lease ->
    Server_startup_takeover.release_base_path_lease lease;
    base_path_lock_path ~run_dir base_path
  | Server_startup_takeover.Base_path_already_owned _ ->
    Alcotest.fail "test fixture BasePath was already owned"
  | Server_startup_takeover.Base_path_rejected rejection ->
    Alcotest.failf
      "test fixture BasePath was rejected: %s"
      (Server_startup_takeover.base_path_lock_rejection_to_string rejection)

let with_base_and_run prefix f =
  with_temp_dir (prefix ^ "-base") (fun base_path ->
    with_temp_dir (prefix ^ "-run") (fun run_dir ->
      f ~base_path ~run_dir))

let pid_from_file path =
  match read_file path |> String.trim |> int_of_string_opt with
  | Some pid -> pid
  | None -> Alcotest.failf "invalid pid file contents in %s" path

let test_status_line_parser () =
  Alcotest.(check bool) "200 ok" true
    (Server_startup_takeover.status_line_is_healthy "HTTP/1.1 200 OK");
  Alcotest.(check bool) "2000 rejected" false
    (Server_startup_takeover.status_line_is_healthy "HTTP/1.1 2000 Weird");
  Alcotest.(check bool) "503 rejected" false
    (Server_startup_takeover.status_line_is_healthy "HTTP/1.1 503 Service Unavailable")

let test_server_command_heuristic () =
  Alcotest.(check bool) "main_eio path accepted" true
    (Server_startup_takeover.looks_like_server_command
       "/tmp/_build/default/bin/main_eio.exe --port 8935");
  Alcotest.(check bool) "public name accepted" true
    (Server_startup_takeover.looks_like_server_command
       "/usr/local/bin/masc --host 127.0.0.1");
  Alcotest.(check bool) "unrelated process rejected" false
    (Server_startup_takeover.looks_like_server_command
       "python3 -m http.server 8935")

let test_rejects_responsive_holder () =
  with_temp_dir "startup-takeover-responsive" (fun dir ->
      with_http_server ~status_code:200 (fun ~pid ~port ->
          let path = lock_path dir in
          write_file path (Printf.sprintf "%d\n" pid);
          match Server_startup_takeover.acquire_pid_lock ~lock_path:path port with
          | Server_startup_takeover.Already_running { pid = running_pid } ->
              Alcotest.(check int) "pid preserved" pid running_pid;
              Alcotest.(check bool) "server process stays alive" true
                (process_alive pid)
          | Server_startup_takeover.Acquired ->
              Alcotest.fail "responsive holder should block takeover"))

let test_reclaims_stale_pid_file () =
  with_temp_dir "startup-takeover-stale" (fun dir ->
      with_forever_process ~ignore_sigterm:false (fun pid ->
          stop_process pid;
          let path = lock_path dir in
          write_file path (Printf.sprintf "%d\n" pid);
          let port = find_free_port () in
          match Server_startup_takeover.acquire_pid_lock ~lock_path:path port with
          | Server_startup_takeover.Acquired ->
              Alcotest.(check int) "current pid written" (Unix.getpid ())
                (pid_from_file path)
          | Server_startup_takeover.Already_running _ ->
              Alcotest.fail "stale pid should be reclaimed"))

let test_tolerates_invalid_pid_file () =
  with_temp_dir "startup-takeover-invalid" (fun dir ->
      let path = lock_path dir in
      write_file path "not-a-pid\n";
      let port = find_free_port () in
      match Server_startup_takeover.acquire_pid_lock ~lock_path:path port with
      | Server_startup_takeover.Acquired ->
          Alcotest.(check int) "current pid written" (Unix.getpid ())
            (pid_from_file path)
      | Server_startup_takeover.Already_running _ ->
          Alcotest.fail "invalid pid file should be overwritten")

let test_escalates_sigkill_for_unresponsive_holder () =
  with_temp_dir "startup-takeover-unresponsive" (fun dir ->
      with_forever_process ~argv0:"main_eio.exe" ~ignore_sigterm:true (fun pid ->
          let path = lock_path dir in
          write_file path (Printf.sprintf "%d\n" pid);
          let port = find_free_port () in
          match
            Server_startup_takeover.acquire_pid_lock ~lock_path:path
              ~probe_timeout_sec:0.1 ~term_timeout_sec:0.05 ~kill_wait_sec:0.2
              ~poll_interval_sec:0.01 port
          with
          | Server_startup_takeover.Acquired ->
              Alcotest.(check bool) "child terminated" false (process_alive pid);
              Alcotest.(check int) "current pid written" (Unix.getpid ())
                (pid_from_file path)
          | Server_startup_takeover.Already_running _ ->
              Alcotest.fail "unresponsive holder should be reclaimed"))

let test_base_path_lock_rejects_concurrent_lease () =
  with_base_and_run "startup-takeover-base-path-live"
    (fun ~base_path ~run_dir ->
    let ready_read, ready_write = Unix.pipe () in
    let release_read, release_write = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
      close_quietly ready_read;
      close_quietly release_write;
      (match
         Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
       with
       | Server_startup_takeover.Base_path_acquired lease ->
         ignore (Unix.write_substring ready_write "1" 0 1 : int);
         let buffer = Bytes.create 1 in
         ignore (Unix.read release_read buffer 0 1 : int);
         Server_startup_takeover.release_base_path_lease lease;
         exit 0
       | Server_startup_takeover.Base_path_already_owned _ -> exit 2
       | Server_startup_takeover.Base_path_rejected _ -> exit 3)
    | child_pid ->
      close_quietly ready_write;
      close_quietly release_read;
      Fun.protect
        ~finally:(fun () ->
          close_quietly ready_read;
          close_quietly release_write;
          if process_alive child_pid then stop_process child_pid)
        (fun () ->
           let buffer = Bytes.create 1 in
           Alcotest.(check int)
             "child acquired lease"
             1
             (Unix.read ready_read buffer 0 1);
           (match
              Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
            with
            | Server_startup_takeover.Base_path_already_owned { pid } ->
              Alcotest.(check (option int)) "owner pid is observable"
                (Some child_pid) pid
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "concurrent BasePath lease was acquired twice"
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "valid BasePath was rejected: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection));
           ignore (Unix.write_substring release_write "1" 0 1 : int);
           match waitpid_nointr child_pid with
           | Some (_, Unix.WEXITED 0) -> ()
           | _ -> Alcotest.fail "BasePath lease holder did not exit cleanly"))

let test_base_path_lock_reclaims_stale_pid_file () =
  with_base_and_run "startup-takeover-base-path-stale"
    (fun ~base_path ~run_dir ->
      with_forever_process ~ignore_sigterm:false (fun pid ->
          stop_process pid;
          let path = established_base_path_lock_path ~run_dir base_path in
          write_file path (Printf.sprintf "%d\n" pid);
          match
            Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
          with
          | Server_startup_takeover.Base_path_acquired lease ->
              Alcotest.(check int) "current pid written" (Unix.getpid ())
                (pid_from_file path);
              Server_startup_takeover.release_base_path_lease lease
          | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "stale base-path owner should be reclaimed"
          | Server_startup_takeover.Base_path_rejected rejection ->
            Alcotest.failf
              "valid BasePath was rejected: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string
                 rejection)))

let test_base_path_lock_rejects_same_process_symlink_alias () =
  with_temp_dir "startup-takeover-base-path-alias" (fun dir ->
    with_temp_dir "startup-takeover-base-path-alias-run" (fun run_dir ->
    let real_base = Filename.concat dir "real" in
    let alias_base = Filename.concat dir "alias" in
    Unix.mkdir real_base 0o755;
    Unix.symlink real_base alias_base;
    match
      Server_startup_takeover.acquire_base_path_lock ~run_dir real_base
    with
    | Server_startup_takeover.Base_path_already_owned _ ->
      Alcotest.fail "first BasePath identity was already owned"
    | Server_startup_takeover.Base_path_acquired lease ->
      Fun.protect
        ~finally:(fun () ->
          Server_startup_takeover.release_base_path_lease lease;
          Sys.remove alias_base)
        (fun () ->
           match
             Server_startup_takeover.acquire_base_path_lock ~run_dir alias_base
           with
           | Server_startup_takeover.Base_path_already_owned { pid } ->
             Alcotest.(check (option int))
               "symlink alias observes the same process-local owner"
               (Some (Unix.getpid ()))
               pid
           | Server_startup_takeover.Base_path_acquired alias_lease ->
             Server_startup_takeover.release_base_path_lease alias_lease;
             Alcotest.fail
               "symlink alias bypassed the process-local BasePath lease"
           | Server_startup_takeover.Base_path_rejected rejection ->
             Alcotest.failf
               "canonical BasePath alias was rejected: %s"
               (Server_startup_takeover.base_path_lock_rejection_to_string
                  rejection))
    | Server_startup_takeover.Base_path_rejected rejection ->
      Alcotest.failf
        "valid BasePath was rejected: %s"
        (Server_startup_takeover.base_path_lock_rejection_to_string rejection)))

let test_stale_lease_release_preserves_new_active_lease () =
  with_base_and_run "startup-takeover-stale-release"
    (fun ~base_path ~run_dir ->
      let acquire () =
        match
          Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
        with
        | Server_startup_takeover.Base_path_acquired lease -> lease
        | Server_startup_takeover.Base_path_already_owned _ ->
          Alcotest.fail "fresh lease fixture was already owned"
        | Server_startup_takeover.Base_path_rejected rejection ->
          Alcotest.failf
            "fresh lease fixture was rejected: %s"
            (Server_startup_takeover.base_path_lock_rejection_to_string
               rejection)
      in
      let stale_lease = acquire () in
      Server_startup_takeover.release_base_path_lease stale_lease;
      let active_lease = acquire () in
      Server_startup_takeover.release_base_path_lease stale_lease;
      (match
         Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
       with
       | Server_startup_takeover.Base_path_already_owned { pid } ->
         Alcotest.(check (option int))
           "stale release preserves current owner"
           (Some (Unix.getpid ()))
           pid
       | Server_startup_takeover.Base_path_rejected rejection ->
         Alcotest.failf
           "stale release corrupted active ownership: %s"
           (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
       | Server_startup_takeover.Base_path_acquired unexpected ->
         Server_startup_takeover.release_base_path_lease unexpected;
         Alcotest.fail "stale release removed the current ownership fence");
      Server_startup_takeover.release_base_path_lease active_lease;
      let final_lease = acquire () in
      Server_startup_takeover.release_base_path_lease final_lease)

let test_base_path_lock_rejects_linked_runtime_directory () =
  with_base_and_run "startup-takeover-linked-runtime"
    (fun ~base_path ~run_dir ->
    with_temp_dir "startup-takeover-linked-runtime-outside" (fun outside ->
      let runtime_directory = Filename.concat base_path Common.masc_dirname in
      let canonical_runtime_directory =
        Filename.concat (Unix.realpath base_path) Common.masc_dirname
      in
      Unix.symlink outside runtime_directory;
      Fun.protect
        ~finally:(fun () -> Unix.unlink runtime_directory)
        (fun () ->
           (match
              Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
            with
            | Server_startup_takeover.Base_path_rejected
                (Server_startup_takeover.Runtime_directory_rejected
                  (Fs_compat.Owned_path_non_directory
                    { path; kind = Unix.S_LNK })) ->
              Alcotest.(check string)
                "linked runtime directory is identified"
                canonical_runtime_directory
                path
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "unexpected runtime-directory rejection: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
            | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "linked runtime directory looked owned"
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "linked runtime directory acquired ownership");
           Alcotest.(check bool)
             "outside lease file was not created"
             false
             (Sys.file_exists (Filename.concat outside "server-owner.pid")))))

let test_base_path_lock_rejects_linked_lease_directory () =
  with_base_and_run "startup-takeover-linked-lease-directory"
    (fun ~base_path ~run_dir ->
      with_temp_dir "startup-takeover-linked-lease-directory-outside"
        (fun outside ->
          let path = base_path_lock_path ~run_dir base_path in
          let lease_directory = Filename.dirname path in
          Unix.symlink outside lease_directory;
          Fun.protect
            ~finally:(fun () -> Unix.unlink lease_directory)
            (fun () ->
              match
                Server_startup_takeover.acquire_base_path_lock
                  ~run_dir
                  base_path
              with
              | Server_startup_takeover.Base_path_rejected
                  (Server_startup_takeover.Lease_directory_not_directory
                    { path = rejected_path; kind = Unix.S_LNK }) ->
                Alcotest.(check string)
                  "linked private lease directory is identified"
                  lease_directory
                  rejected_path;
                Alcotest.(check int)
                  "linked target remains empty"
                  0
                  (Array.length (Sys.readdir outside))
              | Server_startup_takeover.Base_path_rejected rejection ->
                Alcotest.failf
                  "unexpected private lease-directory rejection: %s"
                  (Server_startup_takeover.base_path_lock_rejection_to_string
                     rejection)
              | Server_startup_takeover.Base_path_already_owned _ ->
                Alcotest.fail "linked private lease directory looked owned"
              | Server_startup_takeover.Base_path_acquired lease ->
                Server_startup_takeover.release_base_path_lease lease;
                Alcotest.fail "linked private lease directory acquired ownership")))

let test_base_path_lock_rejects_permissive_lease_directory () =
  with_base_and_run "startup-takeover-permissive-lease-directory"
    (fun ~base_path ~run_dir ->
      let path = base_path_lock_path ~run_dir base_path in
      let lease_directory = Filename.dirname path in
      Unix.mkdir lease_directory 0o700;
      Unix.chmod lease_directory 0o755;
      match
        Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
      with
      | Server_startup_takeover.Base_path_rejected
          (Server_startup_takeover.Lease_directory_insecure_permissions
            { path = rejected_path; permissions }) ->
        Alcotest.(check string)
          "permissive private lease directory is identified"
          lease_directory
          rejected_path;
        Alcotest.(check int) "observed private mode" 0o755 permissions
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "unexpected permissive lease-directory rejection: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
      | Server_startup_takeover.Base_path_already_owned _ ->
        Alcotest.fail "permissive private lease directory looked owned"
      | Server_startup_takeover.Base_path_acquired lease ->
        Server_startup_takeover.release_base_path_lease lease;
        Alcotest.fail "permissive private lease directory acquired ownership")

let test_base_path_lock_rejects_unprotected_shared_run_directory () =
  with_base_and_run "startup-takeover-unprotected-run-directory"
    (fun ~base_path ~run_dir ->
      Unix.chmod run_dir 0o777;
      match
        Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
      with
      | Server_startup_takeover.Base_path_rejected
          (Server_startup_takeover.Run_directory_insecure_permissions
            { path; permissions }) ->
        Alcotest.(check string)
          "unprotected host run directory is identified"
          (Unix.realpath run_dir)
          path;
        Alcotest.(check int) "observed host run mode" 0o777 permissions
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "unexpected host run-directory rejection: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
      | Server_startup_takeover.Base_path_already_owned _ ->
        Alcotest.fail "unprotected host run directory looked owned"
      | Server_startup_takeover.Base_path_acquired lease ->
        Server_startup_takeover.release_base_path_lease lease;
        Alcotest.fail "unprotected host run directory acquired ownership")

let test_base_path_lock_accepts_sticky_shared_run_directory () =
  with_base_and_run "startup-takeover-sticky-run-directory"
    (fun ~base_path ~run_dir ->
      Unix.chmod run_dir 0o1777;
      match
        Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
      with
      | Server_startup_takeover.Base_path_acquired lease ->
        Server_startup_takeover.release_base_path_lease lease
      | Server_startup_takeover.Base_path_already_owned _ ->
        Alcotest.fail "fresh sticky host run directory looked owned"
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "sticky host run directory was rejected: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string rejection))

let test_base_path_lock_rejects_lease_directory_retarget_before_open () =
  with_base_and_run "startup-takeover-lease-directory-pre-open-retarget"
    (fun ~base_path ~run_dir ->
      let path = base_path_lock_path ~run_dir base_path in
      let lease_directory = Filename.dirname path in
      let retired = lease_directory ^ ".retired" in
      Fun.protect
        ~finally:(fun () ->
          if Sys.file_exists lease_directory then rm_rf lease_directory;
          if Sys.file_exists retired then Unix.rename retired lease_directory)
        (fun () ->
          match
            Server_startup_takeover.For_testing.acquire_base_path_lock
              ~before_lease_open:(fun () ->
                Unix.rename lease_directory retired;
                Unix.mkdir lease_directory 0o700)
              ~before_commit_identity_check:(fun () -> ())
              ~before_runtime_identity_check:(fun () -> ())
              ~run_dir
              base_path
          with
          | Server_startup_takeover.Base_path_rejected
              (Server_startup_takeover.Lease_directory_identity_changed
                { path = rejected_path }) ->
            Alcotest.(check string)
              "pre-open private lease-directory retarget is identified"
              lease_directory
              rejected_path
          | Server_startup_takeover.Base_path_rejected rejection ->
            Alcotest.failf
              "unexpected pre-open lease-directory rejection: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string
                 rejection)
          | Server_startup_takeover.Base_path_already_owned _ ->
            Alcotest.fail "pre-open lease-directory retarget looked owned"
          | Server_startup_takeover.Base_path_acquired lease ->
            Server_startup_takeover.release_base_path_lease lease;
            Alcotest.fail "pre-open lease-directory retarget acquired ownership"))

let test_base_path_lock_rejects_lease_directory_retarget_after_open () =
  with_base_and_run "startup-takeover-lease-directory-post-open-retarget"
    (fun ~base_path ~run_dir ->
      let path = base_path_lock_path ~run_dir base_path in
      let lease_directory = Filename.dirname path in
      let retired = lease_directory ^ ".retired" in
      Fun.protect
        ~finally:(fun () ->
          if Sys.file_exists lease_directory then rm_rf lease_directory;
          if Sys.file_exists retired then Unix.rename retired lease_directory)
        (fun () ->
          match
            Server_startup_takeover.For_testing.acquire_base_path_lock
              ~before_lease_open:(fun () -> ())
              ~before_commit_identity_check:(fun () ->
                Unix.rename lease_directory retired;
                Unix.mkdir lease_directory 0o700)
              ~before_runtime_identity_check:(fun () -> ())
              ~run_dir
              base_path
          with
          | Server_startup_takeover.Base_path_rejected
              (Server_startup_takeover.Lease_directory_identity_changed
                { path = rejected_path }) ->
            Alcotest.(check string)
              "post-open private lease-directory retarget is identified"
              lease_directory
              rejected_path
          | Server_startup_takeover.Base_path_rejected rejection ->
            Alcotest.failf
              "unexpected post-open lease-directory rejection: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string
                 rejection)
          | Server_startup_takeover.Base_path_already_owned _ ->
            Alcotest.fail "post-open lease-directory retarget looked owned"
          | Server_startup_takeover.Base_path_acquired lease ->
            Server_startup_takeover.release_base_path_lease lease;
            Alcotest.fail "post-open lease-directory retarget acquired ownership"))

let test_base_path_lock_rejects_linked_lease_file () =
  with_base_and_run "startup-takeover-linked-lease"
    (fun ~base_path ~run_dir ->
    with_temp_dir "startup-takeover-linked-lease-outside" (fun outside ->
      let runtime_directory = Filename.concat base_path Common.masc_dirname in
      Unix.mkdir runtime_directory 0o755;
      let outside_file = Filename.concat outside "sentinel" in
      write_file outside_file "unchanged";
      let path = established_base_path_lock_path ~run_dir base_path in
      Sys.remove path;
      Unix.symlink outside_file path;
      Fun.protect
        ~finally:(fun () -> Unix.unlink path)
        (fun () ->
           (match
              Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
            with
            | Server_startup_takeover.Base_path_rejected
                (Server_startup_takeover.Lease_file_non_regular
                  { path = rejected_path; kind = Unix.S_LNK }) ->
              Alcotest.(check string)
                "linked lease file is identified"
                path
                rejected_path
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "unexpected lease-file rejection: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
            | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "linked lease file looked owned"
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "linked lease file acquired ownership");
           Alcotest.(check string)
             "outside sentinel remains unchanged"
           "unchanged"
           (read_file outside_file))))

let test_base_path_lock_rejects_multiply_linked_lease_file () =
  with_base_and_run "startup-takeover-hardlinked-lease"
    (fun ~base_path ~run_dir ->
    with_temp_dir "startup-takeover-hardlinked-lease-outside" (fun outside ->
      let runtime_directory = Filename.concat base_path Common.masc_dirname in
      Unix.mkdir runtime_directory 0o755;
      let outside_file = Filename.concat outside "sentinel" in
      write_file outside_file "unchanged";
      let path = established_base_path_lock_path ~run_dir base_path in
      Sys.remove path;
      Unix.link outside_file path;
      Fun.protect
        ~finally:(fun () -> Unix.unlink path)
        (fun () ->
           (match
              Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
            with
            | Server_startup_takeover.Base_path_rejected
                (Server_startup_takeover.Lease_file_multiply_linked
                  { path = rejected_path; links }) ->
              Alcotest.(check string)
                "multiply linked lease file is identified"
                path
                rejected_path;
              Alcotest.(check bool) "link count is unsafe" true (links > 1)
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "unexpected hardlink rejection: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
            | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "hardlinked lease file looked owned"
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "hardlinked lease file acquired ownership");
           Alcotest.(check string)
             "outside hardlink target remains unchanged"
             "unchanged"
             (read_file outside_file))))

let test_base_path_lock_rejects_lease_retarget_before_commit () =
  with_base_and_run "startup-takeover-retargeted-lease"
    (fun ~base_path ~run_dir ->
    with_temp_dir "startup-takeover-retargeted-lease-outside" (fun outside ->
      let runtime_directory = Filename.concat base_path Common.masc_dirname in
      Unix.mkdir runtime_directory 0o755;
      let path = established_base_path_lock_path ~run_dir base_path in
      let retired = Filename.concat run_dir "base-path-owner.retired" in
      let outside_file = Filename.concat outside "sentinel" in
      write_file path "stale\n";
      write_file outside_file "unchanged";
      Fun.protect
        ~finally:(fun () ->
          match Unix.lstat path with
          | _ -> Unix.unlink path
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ())
        (fun () ->
           (match
              Server_startup_takeover.For_testing.acquire_base_path_lock
                ~before_lease_open:(fun () -> ())
                ~before_commit_identity_check:(fun () ->
                  Unix.rename path retired;
                  Unix.symlink outside_file path)
                ~before_runtime_identity_check:(fun () -> ())
                ~run_dir
                base_path
            with
            | Server_startup_takeover.Base_path_rejected
                (Server_startup_takeover.Lease_file_non_regular
                  { path = rejected_path; kind = Unix.S_LNK }) ->
              Alcotest.(check string)
                "retargeted lease path is identified"
                path
                rejected_path
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "unexpected retarget rejection: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
            | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "retargeted lease file looked owned"
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "retargeted lease file acquired ownership");
           Alcotest.(check string)
             "opened lease inode was not truncated"
             "stale\n"
             (read_file retired);
           Alcotest.(check string)
             "outside retarget remains unchanged"
             "unchanged"
             (read_file outside_file))))

let test_base_path_lock_rejects_lease_retarget_at_final_commit () =
  with_base_and_run "startup-takeover-final-lease-retarget"
    (fun ~base_path ~run_dir ->
      with_temp_dir "startup-takeover-final-lease-retarget-outside"
        (fun outside ->
          let path = base_path_lock_path ~run_dir base_path in
          let retired = path ^ ".retired" in
          let outside_file = Filename.concat outside "sentinel" in
          write_file outside_file "unchanged";
          Fun.protect
            ~finally:(fun () ->
              (match Unix.lstat path with
               | _ -> Unix.unlink path
               | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
              (match Unix.lstat retired with
               | _ -> Unix.unlink retired
               | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()))
            (fun () ->
              match
                Server_startup_takeover.For_testing.acquire_base_path_lock
                  ~before_lease_open:(fun () -> ())
                  ~before_commit_identity_check:(fun () -> ())
                  ~before_runtime_identity_check:(fun () ->
                    Unix.rename path retired;
                    Unix.symlink outside_file path)
                  ~run_dir
                  base_path
              with
              | Server_startup_takeover.Base_path_rejected
                  (Server_startup_takeover.Lease_file_non_regular
                    { path = rejected_path; kind = Unix.S_LNK }) ->
                Alcotest.(check string)
                  "final-commit lease retarget is identified"
                  path
                  rejected_path;
                Alcotest.(check string)
                  "final-commit outside target remains unchanged"
                  "unchanged"
                  (read_file outside_file)
              | Server_startup_takeover.Base_path_rejected rejection ->
                Alcotest.failf
                  "unexpected final-commit retarget rejection: %s"
                  (Server_startup_takeover.base_path_lock_rejection_to_string
                     rejection)
              | Server_startup_takeover.Base_path_already_owned _ ->
                Alcotest.fail "final-commit retarget looked already owned"
              | Server_startup_takeover.Base_path_acquired lease ->
                Server_startup_takeover.release_base_path_lease lease;
                Alcotest.fail "final-commit retarget acquired ownership")))

let test_base_path_lock_external_location_and_full_digest () =
  with_base_and_run "startup-takeover-external-location"
    (fun ~base_path ~run_dir ->
      let canonical_base_path = Unix.realpath base_path in
      let path = base_path_lock_path ~run_dir base_path in
      let lease_directory = Filename.dirname path in
      let digest =
        Digestif.SHA256.(digest_string canonical_base_path |> to_hex)
      in
      Alcotest.(check string)
        "lease filename is the full canonical BasePath digest"
        (Printf.sprintf "masc-base-path-owner-v1-%s.lease" digest)
        (Filename.basename path);
      (match
         Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
       with
       | Server_startup_takeover.Base_path_acquired lease ->
         Fun.protect
           ~finally:(fun () ->
             Server_startup_takeover.release_base_path_lease lease)
           (fun () ->
             let runtime_directory =
               Filename.concat base_path Common.masc_dirname
             in
             Alcotest.(check bool)
               "runtime directory is established only after the external lease"
               true
               (Sys.file_exists runtime_directory
                && Sys.is_directory runtime_directory);
             Alcotest.(check string)
               "private lease directory is stored in canonical host run directory"
               (Unix.realpath run_dir)
               (Filename.dirname lease_directory);
             let lease_directory_stat = Unix.lstat lease_directory in
             Alcotest.(check int)
               "private lease directory owner"
               (Unix.geteuid ())
               lease_directory_stat.st_uid;
             Alcotest.(check int)
               "private lease directory mode"
               0o700
               (lease_directory_stat.st_perm land 0o7777);
             Alcotest.(check bool)
               "no BasePath-local lease file is created"
               false
               (Sys.file_exists
                  (Filename.concat runtime_directory "server-owner.pid")))
       | Server_startup_takeover.Base_path_already_owned _ ->
         Alcotest.fail "fresh external BasePath lease was already owned"
       | Server_startup_takeover.Base_path_rejected rejection ->
         Alcotest.failf
           "fresh external BasePath lease was rejected: %s"
           (Server_startup_takeover.base_path_lock_rejection_to_string rejection)))

let test_base_path_lock_pre_open_runtime_retarget_has_no_outside_write () =
  with_base_and_run "startup-takeover-pre-open-runtime-retarget"
    (fun ~base_path ~run_dir ->
      with_temp_dir "startup-takeover-pre-open-runtime-outside" (fun outside ->
        let runtime_directory =
          Filename.concat base_path Common.masc_dirname
        in
        let canonical_runtime_directory =
          Filename.concat (Unix.realpath base_path) Common.masc_dirname
        in
        Fun.protect
          ~finally:(fun () ->
            match Unix.lstat runtime_directory with
            | stat when stat.Unix.st_kind = Unix.S_LNK ->
              Unix.unlink runtime_directory
            | _ -> ()
            | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ())
          (fun () ->
            match
              Server_startup_takeover.For_testing.acquire_base_path_lock
                ~before_lease_open:(fun () ->
                  Unix.symlink outside runtime_directory)
                ~before_commit_identity_check:(fun () -> ())
                ~before_runtime_identity_check:(fun () -> ())
                ~run_dir
                base_path
            with
            | Server_startup_takeover.Base_path_rejected
                (Server_startup_takeover.Runtime_directory_rejected
                  (Fs_compat.Owned_path_non_directory
                    { path; kind = Unix.S_LNK })) ->
              Alcotest.(check string)
                "pre-open runtime retarget is identified"
                canonical_runtime_directory
                path;
              Alcotest.(check bool)
                "retarget cannot create a BasePath lease outside"
                false
                (Sys.file_exists (Filename.concat outside "server-owner.pid"))
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "unexpected pre-open runtime rejection: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
            | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "pre-open retarget looked already owned"
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "pre-open runtime symlink acquired ownership")))

let test_base_path_lock_rejects_invalid_run_directory () =
  with_temp_dir "startup-takeover-invalid-run-base" (fun base_path ->
    with_temp_dir "startup-takeover-invalid-run-parent" (fun parent ->
      let missing = Filename.concat parent "missing" in
      (match
         Server_startup_takeover.acquire_base_path_lock
           ~run_dir:missing
           base_path
       with
       | Server_startup_takeover.Base_path_rejected
           (Server_startup_takeover.Run_directory_canonicalization_failed
             { run_dir; _ }) ->
         Alcotest.(check string) "missing run directory" missing run_dir
       | Server_startup_takeover.Base_path_rejected rejection ->
         Alcotest.failf
           "unexpected missing run-directory rejection: %s"
           (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
       | Server_startup_takeover.Base_path_already_owned _
       | Server_startup_takeover.Base_path_acquired _ ->
         Alcotest.fail "missing run directory admitted a lease");
      let file = Filename.concat parent "not-a-directory" in
      write_file file "occupied";
      match
        Server_startup_takeover.acquire_base_path_lock ~run_dir:file base_path
      with
      | Server_startup_takeover.Base_path_rejected
          (Server_startup_takeover.Run_directory_not_directory
            { path; kind = Unix.S_REG }) ->
        Alcotest.(check string)
          "non-directory run path"
          (Unix.realpath file)
          path
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "unexpected non-directory run rejection: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
      | Server_startup_takeover.Base_path_already_owned _
      | Server_startup_takeover.Base_path_acquired _ ->
        Alcotest.fail "non-directory run path admitted a lease"))

let test_base_path_lock_rejects_run_directory_retarget () =
  with_base_and_run "startup-takeover-run-retarget"
    (fun ~base_path ~run_dir ->
      let canonical_run_dir = Unix.realpath run_dir in
      let retired = run_dir ^ ".retired" in
      Fun.protect
        ~finally:(fun () ->
          if Sys.file_exists run_dir then rm_rf run_dir;
          if Sys.file_exists retired then Unix.rename retired run_dir)
        (fun () ->
          match
            Server_startup_takeover.For_testing.acquire_base_path_lock
              ~before_lease_open:(fun () ->
                Unix.rename run_dir retired;
                Unix.mkdir run_dir 0o755)
              ~before_commit_identity_check:(fun () -> ())
              ~before_runtime_identity_check:(fun () -> ())
              ~run_dir
              base_path
          with
          | Server_startup_takeover.Base_path_rejected
              (Server_startup_takeover.Lease_identity_changed
                { path = rejected_path }) ->
            Alcotest.(check string)
              "retargeted host run directory identity"
              canonical_run_dir
              rejected_path
          | Server_startup_takeover.Base_path_rejected rejection ->
            Alcotest.failf
              "unexpected run-directory retarget rejection: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string
                 rejection)
          | Server_startup_takeover.Base_path_already_owned _ ->
            Alcotest.fail "retargeted run directory looked already owned"
          | Server_startup_takeover.Base_path_acquired lease ->
            Server_startup_takeover.release_base_path_lease lease;
            Alcotest.fail "retargeted run directory acquired ownership"))

let test_base_path_lock_rejects_runtime_retarget_after_establish () =
  with_base_and_run "startup-takeover-runtime-retarget-after-establish"
    (fun ~base_path ~run_dir ->
      let runtime_directory = Filename.concat base_path Common.masc_dirname in
      let canonical_runtime_directory =
        Filename.concat (Unix.realpath base_path) Common.masc_dirname
      in
      let retired_runtime = Filename.concat base_path ".masc-retired" in
      Unix.mkdir runtime_directory 0o755;
      match
        Server_startup_takeover.For_testing.acquire_base_path_lock
          ~before_lease_open:(fun () -> ())
          ~before_commit_identity_check:(fun () -> ())
          ~before_runtime_identity_check:(fun () ->
            Unix.rename runtime_directory retired_runtime;
            Unix.mkdir runtime_directory 0o755)
          ~run_dir
          base_path
      with
      | Server_startup_takeover.Base_path_rejected
          (Server_startup_takeover.Lease_identity_changed
            { path = rejected_path }) ->
        Alcotest.(check string)
          "post-establish runtime replacement is identified"
          canonical_runtime_directory
          rejected_path;
        Alcotest.(check bool)
          "runtime replacement never receives a local lease file"
          false
          (Sys.file_exists
             (Filename.concat runtime_directory "server-owner.pid"))
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "unexpected post-establish runtime rejection: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
      | Server_startup_takeover.Base_path_already_owned _ ->
        Alcotest.fail "post-establish runtime replacement looked already owned"
      | Server_startup_takeover.Base_path_acquired lease ->
        Server_startup_takeover.release_base_path_lease lease;
        Alcotest.fail "post-establish runtime replacement acquired ownership")

let () =
  Alcotest.run "Server_startup_takeover"
    [
      ( "helpers",
        [
          Alcotest.test_case "status line parser is exact" `Quick
            test_status_line_parser;
          Alcotest.test_case "server command heuristic rejects unrelated processes"
            `Quick test_server_command_heuristic;
        ] );
      ( "takeover",
        [
          Alcotest.test_case "responsive holder blocks takeover" `Quick
            test_rejects_responsive_holder;
          Alcotest.test_case "stale pid file is reclaimed" `Quick
            test_reclaims_stale_pid_file;
          Alcotest.test_case "invalid pid file is overwritten" `Quick
            test_tolerates_invalid_pid_file;
          Alcotest.test_case "unresponsive holder escalates to sigkill" `Quick
            test_escalates_sigkill_for_unresponsive_holder;
          Alcotest.test_case "concurrent BasePath lease blocks takeover" `Quick
            test_base_path_lock_rejects_concurrent_lease;
          Alcotest.test_case "stale base-path owner is reclaimed" `Quick
            test_base_path_lock_reclaims_stale_pid_file;
          Alcotest.test_case "same-process symlink alias is rejected" `Quick
            test_base_path_lock_rejects_same_process_symlink_alias;
          Alcotest.test_case "stale lease release preserves active ownership"
            `Quick test_stale_lease_release_preserves_new_active_lease;
          Alcotest.test_case "linked runtime directory is rejected" `Quick
            test_base_path_lock_rejects_linked_runtime_directory;
          Alcotest.test_case "linked private lease directory is rejected" `Quick
            test_base_path_lock_rejects_linked_lease_directory;
          Alcotest.test_case "permissive private lease directory is rejected"
            `Quick test_base_path_lock_rejects_permissive_lease_directory;
          Alcotest.test_case "unprotected shared run directory is rejected"
            `Quick test_base_path_lock_rejects_unprotected_shared_run_directory;
          Alcotest.test_case "sticky shared run directory is accepted" `Quick
            test_base_path_lock_accepts_sticky_shared_run_directory;
          Alcotest.test_case "private lease directory pre-open retarget is rejected"
            `Quick
            test_base_path_lock_rejects_lease_directory_retarget_before_open;
          Alcotest.test_case "private lease directory post-open retarget is rejected"
            `Quick
            test_base_path_lock_rejects_lease_directory_retarget_after_open;
          Alcotest.test_case "linked lease file is rejected" `Quick
            test_base_path_lock_rejects_linked_lease_file;
          Alcotest.test_case "multiply linked lease file is rejected" `Quick
            test_base_path_lock_rejects_multiply_linked_lease_file;
          Alcotest.test_case "lease retarget before commit is rejected" `Quick
            test_base_path_lock_rejects_lease_retarget_before_commit;
          Alcotest.test_case "lease retarget at final commit is rejected" `Quick
            test_base_path_lock_rejects_lease_retarget_at_final_commit;
          Alcotest.test_case "lease is external and full-digest keyed" `Quick
            test_base_path_lock_external_location_and_full_digest;
          Alcotest.test_case "pre-open runtime retarget has no outside write" `Quick
            test_base_path_lock_pre_open_runtime_retarget_has_no_outside_write;
          Alcotest.test_case "invalid host run directory is rejected" `Quick
            test_base_path_lock_rejects_invalid_run_directory;
          Alcotest.test_case "host run directory retarget is rejected" `Quick
            test_base_path_lock_rejects_run_directory_retarget;
          Alcotest.test_case "post-establish runtime retarget is rejected" `Quick
            test_base_path_lock_rejects_runtime_retarget_after_establish;
        ] );
    ]
