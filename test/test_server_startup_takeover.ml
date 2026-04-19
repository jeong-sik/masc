open Masc_mcp

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
       "/usr/local/bin/masc-mcp --host 127.0.0.1");
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
        ] );
    ]
