open Alcotest
open Masc

type fixture =
  { host : string
  ; port : int
  ; key_dir : string
  }

let fixture () =
  match Sys.getenv_opt "MASC_TEST_SSH_FIXTURE" with
  | None | Some "" -> Alcotest.skip ()
  | Some value ->
    (match String.split_on_char ':' value with
     | [ host; port; key_dir ] ->
       (match int_of_string_opt port with
        | Some port -> { host; port; key_dir }
        | None -> failf "invalid fixture port: %S" port)
     | _ ->
       failf
         "MASC_TEST_SSH_FIXTURE must be host:port:keydir, got %S"
         value)
;;

let endpoint fixture : Exec_ssh_endpoint.t =
  { name = "integration"
  ; host = fixture.host
  ; user = "masc"
  ; port = fixture.port
  ; identity_file = Filename.concat fixture.key_dir "id_ed25519"
  ; known_hosts_file = Filename.concat fixture.key_dir "known_hosts"
  ; remote_root = "/srv/masc/playground"
  ; connect_timeout_sec = 2
  ; max_concurrent_sessions = 4
  ; env_allowlist = [ "FOO"; "PATH" ]
  ; capabilities = []
  ; private_home = false
  }
;;

let with_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect
    ~finally:Process_eio.reset_for_testing
    (fun () -> f (Eio.Stdenv.clock env))
;;

let state fixture =
  match
    Keeper_sandbox_ssh.create ~base_path:fixture.key_dir
      ~keeper_name:"keeper-a" ~endpoint:(endpoint fixture) ()
  with
  | Ok state -> state
  | Error error -> fail error
;;

let run_remote ?(timeout_sec = 10.0) ?stdin ?(env = [||]) state argv =
  Masc_exec.Sandbox_target.status_tuple
    (Keeper_sandbox_remote.runner ~timeout_sec state
       ~on_stdout_chunk:None ~on_stderr_chunk:None
       ~stdin_content:stdin ~argv ~env ~cwd:None)
;;

let status_is expected actual = expected = actual

let status_to_string = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
;;

let test_echo_split_and_status () =
  let fixture = fixture () in
  with_eio @@ fun _clock ->
  let status, stdout, stderr =
    run_remote (state fixture)
      [ "sh"; "-c"; "printf remote-out; printf remote-err >&2" ]
  in
  check bool "exit 0" true (status_is (Unix.WEXITED 0) status);
  check string "stdout split" "remote-out" stdout;
  check string "stderr split" "remote-err" stderr
;;

let test_hostile_bytes_and_large_stdin () =
  let fixture = fixture () in
  with_eio @@ fun _clock ->
  let ssh = state fixture in
  let hostile = "invalid-utf8-\xff-byte" in
  let status, stdout, stderr = run_remote ssh [ "printf"; "%s"; hostile ] in
  check bool "hostile argv exit 0" true (status_is (Unix.WEXITED 0) status);
  check bool "invalid UTF-8 argv round-trips" true (String.equal hostile stdout);
  check string "hostile argv stderr" "" stderr;
  let payload =
    String.init (1024 * 1024) (fun index ->
      if index mod 4093 = 0 then '\x00' else Char.chr (index mod 251))
  in
  let status, stdout, stderr =
    run_remote ~timeout_sec:20.0 ~stdin:payload ssh [ "cat" ]
  in
  check bool "large stdin exit 0" true (status_is (Unix.WEXITED 0) status);
  check int "large stdin byte count" (String.length payload) (String.length stdout);
  check bool "NUL + 1 MiB round-trip" true (String.equal payload stdout);
  check string "large stdin stderr" "" stderr
;;

let test_exit_signal_and_fast_exit_sigpipe_regression () =
  let fixture = fixture () in
  with_eio @@ fun _clock ->
  let ssh = state fixture in
  let status, _, _ = run_remote ssh [ "sh"; "-c"; "exit 3" ] in
  check bool "exit 3" true (status_is (Unix.WEXITED 3) status);
  let status, _, _ = run_remote ssh [ "sh"; "-c"; "kill -9 $$" ] in
  check bool "signal 9" true (status_is (Unix.WSIGNALED 9) status);
  let payload = String.make (128 * 1024) 'x' in
  let status, stdout, stderr = run_remote ~stdin:payload ssh [ "true" ] in
  check bool "fast exit remains successful" true
    (status_is (Unix.WEXITED 0) status);
  check string "fast exit stdout" "" stdout;
  check string "fast exit has no transport error" "" stderr
;;

let direct_ssh_argv ssh command =
  match List.rev (Keeper_sandbox_remote.transport_argv ssh) with
  | _fixed :: rest -> List.rev (command :: rest)
  | [] -> fail "empty SSH argv"
;;

let direct_status ssh command =
  let status, _, _ =
    Process_eio.run_argv_with_status_split
      ~timeout_sec:5.0
      ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
      (direct_ssh_argv ssh command)
  in
  status
;;

exception Cancel_quiet_payload

let test_cancel_reaps_remote_process_group () =
  let fixture = fixture () in
  with_eio @@ fun clock ->
  let ssh = state fixture in
  let cancelled =
    try
      Eio.Switch.run (fun sw ->
        Eio.Fiber.fork ~sw (fun () ->
          ignore (run_remote ~timeout_sec:600.0 ssh [ "sleep"; "600" ]));
        Eio.Time.sleep clock 1.0;
        Eio.Switch.fail sw Cancel_quiet_payload);
      false
    with Cancel_quiet_payload -> true
  in
  check bool "runner cancelled" true cancelled;
  let rec wait_for_reap attempts =
    if attempts = 0
    then false
    else
      match direct_status ssh "pgrep -f '[s]leep 600'" with
      | Unix.WEXITED 1 -> true
      | _ ->
        Eio.Time.sleep clock 0.1;
        wait_for_reap (attempts - 1)
  in
  check bool "remote sleep process group reaped" true (wait_for_reap 50)
;;

let test_payload_argv_absent_from_host_process_table () =
  let fixture = fixture () in
  with_eio @@ fun clock ->
  let ssh = state fixture in
  let marker = Printf.sprintf "masc-payload-marker-%d" (Unix.getpid ()) in
  let result = ref None in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      result := Some (run_remote ssh [ "sh"; "-c"; "sleep 3"; marker ]));
    Eio.Time.sleep clock 0.5;
    let status, process_table, stderr =
      Process_eio.run_argv_with_status_split
        ~timeout_sec:3.0 ~env:(Unix.environment ())
        [ "ps"; "-Ao"; "args" ]
    in
    check bool "host ps succeeded" true (status_is (Unix.WEXITED 0) status);
    check string "host ps stderr" "" stderr;
    check bool "payload argv marker absent from host ps" false
      (String_util.contains_substring process_table marker));
  match !result with
  | Some (Unix.WEXITED 0, _, _) -> ()
  | Some (status, _, stderr) ->
    failf "marker payload failed: status=%s stderr=%s"
      (status_to_string status) stderr
  | None -> fail "marker payload did not settle"
;;

let test_env_policy () =
  let fixture = fixture () in
  with_eio @@ fun _clock ->
  let status, stdout, stderr =
    run_remote ~env:[| "PATH=/wire/evil"; "FOO=fixture-value" |]
      (state fixture) [ "env" ]
  in
  check bool "env exits 0" true (status_is (Unix.WEXITED 0) status);
  check string "env stderr" "" stderr;
  check bool "allowlisted FOO crosses" true
    (String_util.contains_substring stdout "FOO=fixture-value");
  check bool "wire PATH is dropped" false
    (String_util.contains_substring stdout "PATH=/wire/evil");
  check bool "shim base PATH remains" true
    (String_util.contains_substring stdout
       "PATH=/usr/local/bin:/usr/bin:/bin")
;;

let closed_local_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close socket) @@ fun () ->
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  match Unix.getsockname socket with
  | Unix.ADDR_INET (_, port) -> port
  | Unix.ADDR_UNIX _ -> failwith "expected INET socket"
;;

let test_preflight_ready_and_unreachable () =
  let fixture = fixture () in
  with_eio @@ fun _clock ->
  let ready = state fixture in
  Keeper_sandbox_remote.For_testing.clear_preflight_cache ();
  check (result unit string) "fixture ready" (Ok ())
    (Keeper_sandbox_remote.check_preflight ~force:true ready);
  let stopped_endpoint =
    { (endpoint fixture) with
      name = "stopped-port"
    ; port = closed_local_port ()
    ; connect_timeout_sec = 1
    }
  in
  let stopped =
    match
      Keeper_sandbox_ssh.create ~base_path:fixture.key_dir
        ~keeper_name:"keeper-a" ~endpoint:stopped_endpoint ()
    with
    | Ok state -> state
    | Error error -> fail error
  in
  match Keeper_sandbox_remote.check_preflight ~force:true stopped with
  | Error error ->
    check bool "unreachable is named" true
      (String.starts_with ~prefix:"remote_ssh_endpoint_unreachable:" error)
  | Ok () -> fail "stopped endpoint passed preflight"
;;

let () =
  run "keeper SSH integration"
    [ ( "live fixture"
      , [ test_case "stdout stderr and exit" `Quick test_echo_split_and_status
        ; test_case "hostile bytes and 1 MiB stdin" `Quick
            test_hostile_bytes_and_large_stdin
        ; test_case "exit signal and SIGPIPE regression" `Quick
            test_exit_signal_and_fast_exit_sigpipe_regression
        ; test_case "cancel reaps remote pgid" `Quick
            test_cancel_reaps_remote_process_group
        ; test_case "payload argv absent from host ps" `Quick
            test_payload_argv_absent_from_host_process_table
        ; test_case "env policy" `Quick test_env_policy
        ; test_case "preflight ready and unreachable" `Quick
            test_preflight_ready_and_unreachable
        ] )
    ]
