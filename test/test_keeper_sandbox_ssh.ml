open Alcotest
open Masc

let write_all fd content =
  let bytes = Bytes.unsafe_of_string content in
  let rec loop offset =
    if offset < Bytes.length bytes
    then
      let wrote = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      loop (offset + wrote)
  in
  loop 0
;;

let read_exact fd length =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset < length
    then
      let got = Unix.read fd bytes offset (length - offset) in
      if got = 0 then failwith "ssh stub: truncated frame" else loop (offset + got)
  in
  loop 0;
  Bytes.unsafe_to_string bytes
;;

let save path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)
;;

let stub_main () =
  let frame_path = Sys.argv.(2) in
  let mode = Sys.argv.(3) in
  let args =
    Array.to_list (Array.sub Sys.argv 4 (Array.length Sys.argv - 4))
  in
  save (frame_path ^ ".argv") (String.concat "\n" args);
  let header = read_exact Unix.stdin 8 in
  let body_len =
    Bytes.get_int64_be (Bytes.unsafe_of_string header) 0 |> Int64.to_int
  in
  let frame = header ^ read_exact Unix.stdin body_len in
  save frame_path frame;
  let trailer ?exit ?signal ?(timed_out = false) ?shim_error () =
    Exec_ssh_protocol.render_trailer
      { v = Exec_ssh_protocol.protocol_version
      ; exit
      ; signal
      ; timed_out
      ; shim_error
      }
  in
  match mode with
  | "exit3" ->
    write_all Unix.stdout "remote-out";
    write_all Unix.stderr ("remote-err" ^ trailer ~exit:3 ());
    exit 0
  | "signal9" ->
    write_all Unix.stderr (trailer ~signal:9 ());
    exit 0
  | "remote-timeout" ->
    write_all Unix.stderr (trailer ~timed_out:true ());
    exit 0
  | "shim-error" ->
    write_all Unix.stderr
      (trailer ~shim_error:"remote_ssh_path_jail_violation: outside root" ());
    exit 1
  | "path-output" ->
    let remote = "/srv/masc/playground/keeper-a/src/main.ml" in
    write_all Unix.stdout ("out=" ^ remote);
    write_all Unix.stderr ("err=" ^ remote ^ trailer ~exit:0 ());
    exit 0
  | "malformed" ->
    write_all Unix.stderr "remote-err\x1ebad\x1e";
    exit 0
  | "ssh255" ->
    write_all Unix.stderr "connection refused";
    exit 255
  | "block" ->
    save (frame_path ^ ".pid") (string_of_int (Unix.getpid ()));
    ignore (Unix.select [] [] [] 600.0);
    exit 0
  | other -> failwith ("unknown ssh stub mode: " ^ other)
;;

let shell_quote s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv key (Option.value previous ~default:""))
    f
;;

let temp_dir () =
  let path = Filename.temp_file "masc-ssh-runner-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;

let make_stub ~dir ~mode =
  let frame_path = Filename.concat dir ("frame-" ^ mode) in
  let script_path = Filename.concat dir ("ssh-" ^ mode) in
  save script_path
    (Printf.sprintf "#!/bin/sh\nexec %s --ssh-stub %s %s \"$@\"\n"
       (shell_quote Sys.executable_name)
       (shell_quote frame_path)
       (shell_quote mode));
  Unix.chmod script_path 0o755;
  script_path, frame_path
;;

let endpoint : Exec_ssh_endpoint.t =
  { name = "build-box"
  ; host = "build.example"
  ; user = "masc"
  ; port = 2222
  ; identity_file = ".masc/ssh/build-box.key"
  ; known_hosts_file = ".masc/ssh/known_hosts.d/build-box"
  ; remote_root = "/srv/masc/playground"
  ; connect_timeout_sec = 1
  ; max_concurrent_sessions = 2
  ; env_allowlist = [ "LANG"; "PATH" ]
  ; capabilities = []
  }
;;

let test_destination_validation_before_side_effects () =
  let base_path = temp_dir () in
  let unsafe =
    { endpoint with user = "-oProxyCommand=/bin/echo option-injection #" }
  in
  (match
     Keeper_sandbox_ssh.create ~base_path ~keeper_name:"keeper-a"
       ~endpoint:unsafe ()
   with
   | Ok _ -> fail "unsafe typed endpoint reached SSH runner creation"
   | Error error ->
     check bool "named endpoint error" true
       (String.starts_with ~prefix:"remote_ssh_endpoint_invalid:" error));
  check bool "no control-path side effect" false
    (Sys.file_exists (Filename.concat base_path ".masc/run/ssh"))
;;

let with_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    f ~clock:(Eio.Stdenv.clock env))
;;

let make_runner ~base_path ~ssh_bin =
  match
    Keeper_sandbox_ssh.create ~ssh_bin ~base_path ~keeper_name:"keeper-a"
      ~endpoint ()
  with
  | Ok state -> state, Keeper_sandbox_remote.runner ~timeout_sec:2.0 state
  | Error error -> fail error
;;

let run_request runner ?on_stdout_chunk ?on_stderr_chunk ?(stdin_content = Some "stdin\x00bytes")
    ?(env = [| "LANG=C"; "PATH=/host/bin" |])
    ?(cwd = Some "/srv/masc/playground/keeper-a") () =
  runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content
    ~argv:[ "/usr/bin/printf"; "hello" ] ~env ~cwd
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))
;;

let contains needle haystack =
  let needle_len = String.length needle and haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  loop 0
;;

let status_testable =
  testable
    (fun ppf -> function
      | Unix.WEXITED n -> Format.fprintf ppf "WEXITED %d" n
      | Unix.WSIGNALED n -> Format.fprintf ppf "WSIGNALED %d" n
      | Unix.WSTOPPED n -> Format.fprintf ppf "WSTOPPED %d" n)
    ( = )
;;

let test_argv_frame_stream_and_exit () =
  with_eio @@ fun ~clock:_ ->
  let base_path = temp_dir () in
  let ssh_bin, frame_path = make_stub ~dir:base_path ~mode:"exit3" in
  let state, runner = make_runner ~base_path ~ssh_bin in
  let stdout_chunks = Buffer.create 32 and stderr_chunks = Buffer.create 32 in
  let status, stdout, stderr =
    with_env "GH_TOKEN" "ambient-host-secret" @@ fun () ->
    run_request runner
      ~on_stdout_chunk:(Buffer.add_string stdout_chunks)
      ~on_stderr_chunk:(Buffer.add_string stderr_chunks)
      ~cwd:(Some (Filename.concat base_path ".masc/playground/keeper-a")) ()
  in
  check status_testable "payload exit from trailer" (Unix.WEXITED 3) status;
  check string "stdout" "remote-out" stdout;
  check string "stderr trailer stripped" "remote-err" stderr;
  check string "stdout streamed" "remote-out" (Buffer.contents stdout_chunks);
  check string "stderr streamed without trailer" "remote-err" (Buffer.contents stderr_chunks);
  let expected_argv = List.tl (Keeper_sandbox_remote.transport_argv state) in
  check (list string) "pinned ssh argv" expected_argv
    (String.split_on_char '\n' (read_file (frame_path ^ ".argv")));
  let frame = read_file frame_path in
  (match Exec_ssh_protocol.decode_request frame with
   | Error error -> fail error
   | Ok (request, stdin) ->
     check (list string) "request argv" [ "/usr/bin/printf"; "hello" ] request.argv;
     check string "request cwd" "/srv/masc/playground/keeper-a" request.cwd;
     check string "raw stdin" "stdin\x00bytes" stdin;
     check (list (pair string string))
       "injected identity env first, then allowlisted caller env; ambient GH_TOKEN absent"
       [ "GH_CONFIG_DIR", "/srv/masc/playground/keeper-a/.config/gh"
       ; "GIT_TERMINAL_PROMPT", "0"
       ; "LANG", "C"
       ]
       request.env)
;;

let test_nonallowlisted_env_fails_before_spawn () =
  with_eio @@ fun ~clock:_ ->
  let base_path = temp_dir () in
  let ssh_bin, frame_path = make_stub ~dir:base_path ~mode:"exit3" in
  let _, runner = make_runner ~base_path ~ssh_bin in
  let status, _, stderr = run_request runner ~env:[| "NOPE=value" |] () in
  check status_testable "policy failure" (Unix.WEXITED 1) status;
  check bool "named allowlist error" true
    (contains "remote_ssh_env_not_allowlisted:" stderr);
  check bool "ssh was not spawned" false (Sys.file_exists frame_path)
;;

let test_signal_and_remote_timeout () =
  with_eio @@ fun ~clock:_ ->
  let base_path = temp_dir () in
  let signal_bin, _ = make_stub ~dir:base_path ~mode:"signal9" in
  let _, signal_runner = make_runner ~base_path ~ssh_bin:signal_bin in
  let status, _, _ = run_request signal_runner () in
  check status_testable "payload signal from trailer" (Unix.WSIGNALED 9) status;
  let timeout_bin, _ = make_stub ~dir:base_path ~mode:"remote-timeout" in
  let _, timeout_runner = make_runner ~base_path ~ssh_bin:timeout_bin in
  let status, _, stderr = run_request timeout_runner () in
  check status_testable "remote timeout fails" (Unix.WEXITED 1) status;
  check bool "remote timeout named" true
    (String.starts_with ~prefix:"remote_ssh_remote_timeout:" stderr)
;;

let test_transport_failures () =
  with_eio @@ fun ~clock:_ ->
  let base_path = temp_dir () in
  List.iter
    (fun mode ->
      let ssh_bin, _ = make_stub ~dir:base_path ~mode in
      let _, runner = make_runner ~base_path ~ssh_bin in
      let status, _, stderr = run_request runner () in
      check status_testable (mode ^ " status") (Unix.WEXITED 1) status;
      check bool (mode ^ " named") true
        (contains "remote_ssh_transport_error:" stderr))
    [ "malformed"; "ssh255" ]
;;

let test_shim_error () =
  with_eio @@ fun ~clock:_ ->
  let base_path = temp_dir () in
  let ssh_bin, _ = make_stub ~dir:base_path ~mode:"shim-error" in
  let _, runner = make_runner ~base_path ~ssh_bin in
  let status, _, stderr = run_request runner () in
  check status_testable "shim error status" (Unix.WEXITED 1) status;
  check bool "shim error preserved" true
    (String.starts_with ~prefix:"remote_ssh_path_jail_violation:" stderr)
;;

let test_remote_paths_rewritten_in_streams () =
  with_eio @@ fun ~clock:_ ->
  let base_path = temp_dir () in
  let ssh_bin, _ = make_stub ~dir:base_path ~mode:"path-output" in
  let _, runner = make_runner ~base_path ~ssh_bin in
  let stdout_chunks = Buffer.create 64 and stderr_chunks = Buffer.create 64 in
  let status, stdout, stderr =
    run_request runner
      ~on_stdout_chunk:(Buffer.add_string stdout_chunks)
      ~on_stderr_chunk:(Buffer.add_string stderr_chunks)
      ()
  in
  let host =
    Filename.concat
      (Keeper_alerting_path.normalize_path_for_check base_path)
      ".masc/playground/keeper-a/src/main.ml"
  in
  check status_testable "exit" (Unix.WEXITED 0) status;
  check string "captured stdout" ("out=" ^ host) stdout;
  check string "captured stderr" ("err=" ^ host) stderr;
  check string "streamed stdout" stdout (Buffer.contents stdout_chunks);
  check string "streamed stderr" stderr (Buffer.contents stderr_chunks)
;;

exception Cancel_blocked_ssh

let test_cancellation_kills_local_ssh () =
  with_eio @@ fun ~clock ->
  let base_path = temp_dir () in
  let ssh_bin, frame_path = make_stub ~dir:base_path ~mode:"block" in
  let _, runner = make_runner ~base_path ~ssh_bin in
  let pid_path = frame_path ^ ".pid" in
  let cancelled =
    try
      Eio.Switch.run (fun sw ->
        Eio.Fiber.fork ~sw (fun () -> ignore (run_request runner ()));
        Eio.Time.with_timeout_exn clock 3.0 (fun () ->
          while not (Sys.file_exists pid_path) do
            Eio.Time.sleep clock 0.01
          done);
        Eio.Switch.fail sw Cancel_blocked_ssh);
      false
    with Cancel_blocked_ssh -> true
  in
  check bool "runner cancelled" true cancelled;
  check bool "stub reached blocked state" true (Sys.file_exists pid_path);
  let pid = read_file pid_path |> String.trim |> int_of_string in
  Eio.Time.sleep clock 0.05;
  let alive =
    try
      Unix.kill pid 0;
      true
    with Unix.Unix_error (Unix.ESRCH, _, _) -> false
  in
  check bool "local ssh process reaped" false alive
;;

let test_shell_ir_target_resolves_endpoint () =
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "false" @@ fun () ->
  with_eio @@ fun ~clock:_ ->
  let base_path = temp_dir () in
  let keepers_dir = Filename.concat base_path ".masc/config/keepers" in
  Fs_compat.mkdir_p keepers_dir;
  save (Filename.concat keepers_dir "keeper-a.toml")
    {|[keeper]
instructions = "remote test keeper"
sandbox_profile = "remote_ssh"
remote_endpoint = "build-box"
|};
  (* RFC-0121: the resolver reads .masc/config/runtime.toml — the path the
     live layout uses — not the .masc root this fixture used to write to. *)
    save
    (Filename.concat base_path ".masc/config/runtime.toml")
    (* R00: derive the fixture table from the typed record via
       Exec_ssh_endpoint.to_toml, the strict decoder mirror, so the
       fixture cannot drift from what Runtime_toml accepts. *)
    (Exec_ssh_endpoint.to_toml
       Exec_ssh_endpoint.
         { name = "build-box"
         ; host = "build.example"
         ; user = "masc"
         ; port = 2222
         ; identity_file = ".masc/ssh/build-box.key"
         ; known_hosts_file = ".masc/ssh/known_hosts.d/build-box"
         ; remote_root = "/srv/masc/playground"
         ; connect_timeout_sec = 1
         ; max_concurrent_sessions = 2
         ; env_allowlist = [ "LANG" ]
         ; capabilities = []
         });
  let ssh_bin, _ = make_stub ~dir:base_path ~mode:"exit3" in
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String "keeper-a" ]) with
    | Error error -> fail error
    | Ok meta ->
      { meta with
        Keeper_meta_contract.sandbox_profile =
          Keeper_types_profile_sandbox.Remote_ssh
      }
  in
  match
    Keeper_sandbox_shell_ir_target.ssh_target ~base_path ~meta ~timeout_sec:2.0
      ~ssh_bin ()
  with
  | Error error -> fail error.message
  | Ok { target = Masc_exec.Sandbox_target.Ssh { endpoint; _ } } ->
    check string "resolved endpoint" "build-box" endpoint.name;
    check string "resolved identity path"
      (Filename.concat base_path ".masc/ssh/build-box.key")
      endpoint.identity_file
  | Ok { target = Host | Docker _ | Micro_vm _ | Delegated _ } ->
    fail "expected SSH target"
;;

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--ssh-stub"
  then stub_main ()
  else
    run "keeper_sandbox_ssh"
      [ ( "runner"
        , [ test_case "pinned argv + framed streams" `Quick test_argv_frame_stream_and_exit
          ; test_case "signal + remote timeout" `Quick test_signal_and_remote_timeout
          ; test_case "transport failures" `Quick test_transport_failures
          ; test_case "nonallowlisted env fails before spawn" `Quick
              test_nonallowlisted_env_fails_before_spawn
          ; test_case "shim error" `Quick test_shim_error
          ; test_case "remote paths rewritten in streams" `Quick
              test_remote_paths_rewritten_in_streams
          ; test_case "cancellation reaps local ssh" `Quick
              test_cancellation_kills_local_ssh
          ; test_case "Shell IR target resolves endpoint" `Quick
              test_shell_ir_target_resolves_endpoint
          ; test_case "unsafe typed destination rejected before side effects"
              `Quick test_destination_validation_before_side_effects
          ] )
      ]
