(* The [container exec] transport of the remote lane (RFC-0400).

   A stub stands in for the [container] CLI: it records the argv it was
   given, reads the framed request off stdin, and answers by mode with the
   same trailer the shim writes. The runner must not be able to tell the two
   transports apart except through the argv it spawns and the error codes it
   mints. *)

open Alcotest
open Masc

let binary_fixture () =
  let chunk = "/masc-work/keeper-a/payload\000\255" in
  let capture_limit = Common.max_process_capture_head_bytes + Common.max_process_capture_tail_bytes in
  "RIFF" ^ String.concat "" (List.init (capture_limit / String.length chunk + 1) (fun _ -> chunk))

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
      if got = 0 then failwith "container stub: truncated frame" else loop (offset + got)
  in
  loop 0;
  Bytes.unsafe_to_string bytes
;;

let save path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let stub_main () =
  let frame_path = Sys.argv.(2) in
  let mode = Sys.argv.(3) in
  let args = Array.to_list (Array.sub Sys.argv 4 (Array.length Sys.argv - 4)) in
  save (frame_path ^ ".argv") (String.concat "\n" args);
  (* The CLI's own failure: nothing was exec'd, so no frame is consumed and
     no trailer is written. Observed live on container 1.3.1 for a missing
     guest: exit 1, "Error: get failed: container <name> not found". *)
  if String.equal mode "cli-not-found"
  then (
    write_all Unix.stderr "Error: get failed: container masc-keeper-vm-keeper-a not found\n";
    exit 1);
  (* [--probe] takes no frame: the shim answers its identity on stdout and
     exits. The two probe modes differ only in what the shim says it can
     build, which is the one fact the observe stage reads (RFC-0422). *)
  if List.exists (String.equal "--probe") args
  then (
    let capabilities =
      if String.equal mode "probe-observe" then [ Exec_ssh_protocol.observe_capability ] else []
    in
    (* "probe-v2" stands in for a shim one release behind: it speaks the
       previous major and has no box. Every other mode answers the current
       major, so the runner frames v3 as before. *)
    let major =
      if String.equal mode "probe-v2"
      then Exec_ssh_protocol.protocol_version - 1
      else Exec_ssh_protocol.protocol_version
    in
    write_all Unix.stdout
      (Exec_ssh_protocol.render_probe
         { name = "masc-exec-shim"
           ; version = string_of_int major ^ ".0.0"
           ; capabilities
           ; release = None
           ; boot_id = None
           });
    exit 0);
  let header = read_exact Unix.stdin 8 in
  let body_len = Bytes.get_int64_be (Bytes.unsafe_of_string header) 0 |> Int64.to_int in
  let frame = header ^ read_exact Unix.stdin body_len in
  save frame_path frame;
  (* The trailer answers in the request's own major, as the shim does. *)
  let request =
    match Exec_ssh_protocol.decode_request frame with
    | Ok (request, _) -> request
    | Error error -> failwith ("container stub could not read the frame: " ^ error)
  in
  let v = request.Exec_ssh_protocol.v in
  let trailer ?exit ?signal ?(timed_out = false) ?shim_error () =
    Exec_ssh_protocol.render_trailer
      { v; exit; signal; timed_out; shim_error; observed_syscalls = [] }
  in
  match mode with
  | "binary" ->
    write_all Unix.stdout (binary_fixture ());
    write_all Unix.stderr (trailer ~exit:0 ());
    exit 0
  | "timeout-receipt" ->
    let execution_receipt : Exec_ssh_protocol.execution_receipt =
      { mode = request.mode; boundary = Sandbox_applied } in
    write_all Unix.stderr
      (Exec_ssh_protocol.render_trailer ~execution_receipt
         { v; exit = None; signal = Some 15; timed_out = true; shim_error = None
         ; observed_syscalls = [] });
    exit 0
  | "receipt" ->
    let code = match request.mode with
      | Exec_ssh_protocol.Observe -> 0
      | Effect -> 7
      | Guest_local -> 3 in
    let execution_receipt : Exec_ssh_protocol.execution_receipt =
      { mode = request.mode; boundary = Sandbox_applied } in
    write_all Unix.stderr
      (Exec_ssh_protocol.render_trailer ~execution_receipt
         { v; exit = Some code; signal = None; timed_out = false; shim_error = None
         ; observed_syscalls = [] });
    exit 0
  | "bad-receipt" ->
    write_all Unix.stderr
      ("\x1e" ^ Yojson.Safe.to_string
         (`Assoc ["masc_exec_result", `Assoc
           ["v", `Int (Exec_ssh_protocol.int_of_major v); "exit", `Int 3;
            "signal", `Null; "timed_out", `Bool false; "shim_error", `Null;
            "execution_receipt", `Null]]) ^ "\x1e");
    exit 0
  | "exit3" | "probe-observe" | "probe-plain" | "probe-v2" ->
    write_all Unix.stdout "guest-out";
    write_all Unix.stderr ("guest-err" ^ trailer ~exit:3 ());
    exit 0
  | "shim-error" ->
    write_all Unix.stderr
      (trailer ~shim_error:"remote_ssh_path_jail_violation: outside root" ());
    exit 1
  | "shim-error-invalid" ->
    write_all Unix.stderr
      ("\x1e" ^ Yojson.Safe.to_string
         (`Assoc ["masc_exec_result", `Assoc
           ["v", `Int (Exec_ssh_protocol.int_of_major v); "exit", `Null;
            "signal", `Null; "timed_out", `Bool false;
            "shim_error", `String "fixture refusal"; "execution_receipt", `Null]]) ^ "\x1e");
    exit 1
  | "shim-error-receipt" ->
    let execution_receipt : Exec_ssh_protocol.execution_receipt =
      { mode = request.mode; boundary = Refused } in
    write_all Unix.stderr
      (Exec_ssh_protocol.render_trailer ~execution_receipt
         { v; exit = None; signal = None; timed_out = false
         ; shim_error = Some "fixture refusal"; observed_syscalls = [] });
    exit 1
  | "malformed" ->
    write_all Unix.stderr "guest-err\x1ebad\x1e";
    exit 0
  | other -> failwith ("unknown container stub mode: " ^ other)
;;

let shell_quote s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let temp_dir () =
  let path = Filename.temp_file "masc-remote-guest-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;

let make_stub ~dir ~mode =
  let frame_path = Filename.concat dir ("frame-" ^ mode) in
  let script_path = Filename.concat dir ("container-" ^ mode) in
  save script_path
    (Printf.sprintf "#!/bin/sh\nexec %s --container-stub %s %s \"$@\"\n"
       (shell_quote Sys.executable_name)
       (shell_quote frame_path)
       (shell_quote mode));
  Unix.chmod script_path 0o755;
  script_path, frame_path
;;

let with_eio_env f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () -> f env)
;;

let with_eio f = with_eio_env (fun _ -> f ())
;;

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv key (Option.value previous ~default:""))
    f
;;

let guest_name = "masc-keeper-vm-keeper-a"
let shim_path = "/opt/masc-exec-shim/masc-exec-shim"
let shim_config_path = "/opt/masc-exec-shim/masc-exec-shim.conf"
let remote_root = "/masc-work"
let gh_config_dir = "/masc-runtime/.masc/keepers/keeper-a/github-cli"

(* The prefix is built by the declaring microVM runtime and handed over whole
   ({!Keeper_sandbox_microvm.shim_exec_prefix_for}), so the fixture spells out
   what Apple's runtime produces rather than letting this file re-derive it. *)
let exec_prefix ~cli =
  [ cli; "exec"; "-i"; "--user"; "501:20"; "-w"; remote_root
  ; "--env"; "HOME=" ^ Masc.Keeper_microvm_backend.scratch_guest_root
  ; "--env"; "MASC_EXEC_SHIM_CONFIG=" ^ shim_config_path; guest_name ]
;;

let guest ~cli ?probe_prefix () : Keeper_sandbox_remote.container_exec =
  { prefix = exec_prefix ~cli; probe_prefix; container_name = guest_name; shim_path }
;;

let make_state ~base_path ~cli =
  Keeper_sandbox_remote.of_container_exec ~base_path ~keeper_name:"keeper-a"
    ~remote_root ~gh_config_dir ~injected_env:[] ~env_allowlist:[ "LANG" ]
    ~connect_timeout_sec:1 ~max_concurrent_sessions:2 (guest ~cli ())
;;

let make_docker_state ~base_path ~cli =
  Keeper_sandbox_remote.of_docker_exec ~base_path ~keeper_name:"keeper-a"
    ~remote_root ~gh_config_dir ~injected_env:[] ~env_allowlist:[ "LANG" ]
    ~connect_timeout_sec:1 ~max_concurrent_sessions:2 (guest ~cli ())
;;

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  go 0
;;

let status_testable =
  testable
    (fun fmt -> function
      | Unix.WEXITED code -> Format.fprintf fmt "exit %d" code
      | Unix.WSIGNALED signal -> Format.fprintf fmt "signal %d" signal
      | Unix.WSTOPPED signal -> Format.fprintf fmt "stopped %d" signal)
    ( = )
;;

let test_transport_and_probe_argv () =
  let state = make_state ~base_path:"/workspace" ~cli:"container" in
  let prefix = exec_prefix ~cli:"container" in
  (* The other tests here drive a stub CLI, so the fixture has to stay
     parameterised by executable. This one is about the argv, so it first
     pins the fixture against the builder that actually runs: without this
     the two can drift and every assertion below would keep passing against
     a prefix production no longer produces. *)
  (match
     Keeper_sandbox_microvm.shim_exec_prefix_for
       Keeper_microvm_backend.Apple_container
       ~container_name:guest_name
       ~uid:501
       ~gid:20
       ~remote_root
       ~shim_config_path
   with
   | Error detail -> fail ("the declaring runtime refused its own prefix: " ^ detail)
   | Ok built ->
     check (list string) "the fixture is what the production builder emits" built prefix);
  check (list string) "exec argv delivers the frame to the shim"
    (prefix @ [ shim_path ])
    (Keeper_sandbox_remote.transport_argv state);
  check (list string) "probe is its own argv element"
    (prefix @ [ shim_path; "--probe" ])
    (Keeper_sandbox_remote.probe_argv state);
  check string "endpoint name is the guest" guest_name (Keeper_sandbox_remote.name state);
  check string "keeper root on the volume" "/masc-work/keeper-a"
    (Keeper_sandbox_remote.workspace_root state);
  check string "lane prefix" "microvm_remote"
    (Keeper_sandbox_remote.lane_prefix (Keeper_sandbox_remote.transport state))
;;

let test_container_exec_probe_argv_prefers_probe_prefix () =
  let prefix = [ "container"; "exec"; "-i"; "guest" ] in
  let probe_prefix = [ "container"; "exec"; "guest" ] in
  let custom_guest : Keeper_sandbox_remote.container_exec =
    { prefix; probe_prefix = Some probe_prefix; container_name = guest_name; shim_path }
  in
  let state =
    Keeper_sandbox_remote.of_container_exec ~base_path:"/workspace" ~keeper_name:"keeper-a"
      ~remote_root ~gh_config_dir ~injected_env:[] ~env_allowlist:[ "LANG" ]
      ~connect_timeout_sec:1 ~max_concurrent_sessions:2 custom_guest
  in
  check (list string) "transport argv uses prefix"
    (prefix @ [ shim_path ])
    (Keeper_sandbox_remote.transport_argv state);
  check (list string) "probe argv uses probe_prefix without -i"
    (probe_prefix @ [ shim_path; "--probe" ])
    (Keeper_sandbox_remote.probe_argv state)
;;

let build_box : Exec_ssh_endpoint.t =
  { name = "build-box"; host = "build.example"; user = "masc"; port = 22
  ; identity_file = ".masc/ssh/build-box.key"
  ; known_hosts_file = ".masc/ssh/known_hosts.d/build-box"
  ; remote_root = "/srv/masc/playground"; connect_timeout_sec = 1
  ; max_concurrent_sessions = 1; env_allowlist = []; capabilities = []; private_home = false
  ; allowed_paths = [] }
;;

(* The OpenSSH probe stays one shell word, because sshd hands the remote
   command to a shell. *)
let test_openssh_probe_stays_one_word () =
  let base_path = temp_dir () in
  match Keeper_sandbox_ssh.create ~base_path ~keeper_name:"keeper-a" ~endpoint:build_box () with
  | Error error -> fail error
  | Ok state ->
    check string "workspace root" "/srv/masc/playground/keeper-a"
      (Keeper_sandbox_remote.workspace_root state);
    check string "Keeper control root" "/srv/masc/playground/keeper-a"
      (Keeper_sandbox_remote.keeper_control_root state);
    (match List.rev (Keeper_sandbox_remote.probe_argv state) with
     | last :: _ -> check string "probe word" "masc-exec-shim --probe" last
     | [] -> fail "empty probe argv");
    check string "lane prefix" "remote_ssh"
      (Keeper_sandbox_remote.lane_prefix (Keeper_sandbox_remote.transport state))
;;

(* A shim from another release is repaired where the transport keeps it: on
   the remote host for OpenSSH, in this host's shim directory for a microVM
   guest, in the container for Docker. One sentence for all three told the
   operator of a microVM to run the SSH bootstrap. *)
let test_the_outdated_shim_repair_is_the_transports () =
  let base_path = temp_dir () in
  let bootstrap = "masc-exec-ssh-bootstrap" in
  let asset = "the masc-exec-shim-linux-ARCH asset of " ^ Build_version.current in
  (match Keeper_sandbox_ssh.create ~base_path ~keeper_name:"keeper-a" ~endpoint:build_box () with
   | Error error -> fail error
   | Ok state ->
     check string "OpenSSH: the bootstrap, for this endpoint"
       (Printf.sprintf "reinstall it with %s --endpoint build-box --shim <%s>" bootstrap asset)
       (Keeper_sandbox_remote.outdated_shim_repair state));
  let microvm =
    Keeper_sandbox_remote.outdated_shim_repair (make_state ~base_path ~cli:"container")
  in
  let host_shim =
    Filename.concat (Config_dir_resolver.microvm_shim_dir ~base_path) "masc-exec-shim"
  in
  check bool "microVM: the host's copy, by its path" true
    (contains (Printf.sprintf "replace %s with %s" host_shim asset) microvm);
  check bool "microVM: and the hash beside it" true (contains ".sha256" microvm);
  check bool "microVM: not the SSH bootstrap" false (contains bootstrap microvm);
  let docker =
    Keeper_sandbox_remote.outdated_shim_repair (make_docker_state ~base_path ~cli:"docker")
  in
  check string "Docker: the path the server execs, and no claim about who placed it"
    (Printf.sprintf
       "replace the shim container %s runs at %s with %s; whatever started that \
        container put it there"
       guest_name shim_path asset)
    docker
;;

let run_request runner ?(env = [| "LANG=C" |]) ?(cwd = None) () =
  Masc_exec.Sandbox_target.status_tuple
    (runner ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:(Some "in")
       ~argv:[ "/usr/bin/printf"; "hello" ] ~env ~cwd)
;;

let test_binary_stdout_is_complete_and_not_rewritten () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, _ = make_stub ~dir:base_path ~mode:"binary" in
  let state = make_state ~base_path ~cli in
  let runner = Keeper_sandbox_remote.runner ~stdout_mode:Keeper_sandbox_remote.Binary_bytes ~timeout_sec:10. state in
  let status, stdout, _ = run_request runner ~cwd:None () in
  check status_testable "binary exit" (Unix.WEXITED 0) status;
  let expected = binary_fixture () in
  check int "complete length" (String.length expected) (String.length stdout);
  check string "exact binary SHA" Agent_core_sha256.(digest_string expected |> to_hex)
    Agent_core_sha256.(digest_string stdout |> to_hex);
  check string "remote path bytes unchanged" expected stdout

let test_frame_exit_and_injected_env () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, frame_path = make_stub ~dir:base_path ~mode:"exit3" in
  let state = make_state ~base_path ~cli in
  let runner = Keeper_sandbox_remote.runner ~timeout_sec:2.0 state in
  let status, stdout, stderr =
    run_request runner
      ~cwd:(Some (Filename.concat base_path ".masc/playground/keeper-a/src")) ()
  in
  check status_testable "payload exit from trailer" (Unix.WEXITED 3) status;
  check string "stdout" "guest-out" stdout;
  check string "stderr trailer stripped" "guest-err" stderr;
  check (list string) "spawned argv is the transport argv minus the CLI"
    (List.tl (Keeper_sandbox_remote.transport_argv state))
    (String.split_on_char '\n' (read_file (frame_path ^ ".argv")));
  match Exec_ssh_protocol.decode_request (read_file frame_path) with
  | Error error -> fail error
  | Ok (request, stdin) ->
    check (list string) "request argv" [ "/usr/bin/printf"; "hello" ] request.argv;
    check string "host bookkeeping cwd lands on the volume" "/masc-work/keeper-a/src"
      request.cwd;
    check string "request root is the keeper workspace" "/masc-work/keeper-a"
      request.remote_root;
    check string "raw stdin" "in" stdin;
    check (list (pair string string))
      "identity env names the mounted snapshot and the keeper's commit names, \
       then allowlisted caller env"
      [ "GH_CONFIG_DIR", gh_config_dir
      ; "GIT_TERMINAL_PROMPT", "0"
      ; "GIT_AUTHOR_NAME", "keeper-a"
      ; "GIT_COMMITTER_NAME", "keeper-a"
      ; "LANG", "C"
      ]
      request.env
;;

(* An endpoint may allowlist the runner-owned names for callers. The caller's
   copy must still lose: the frame carries each name once, with the value the
   runtime chose for this Keeper. *)
let test_caller_cannot_replace_runner_owned_env () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, frame_path = make_stub ~dir:base_path ~mode:"exit3" in
  let state =
    Keeper_sandbox_remote.of_container_exec ~base_path ~keeper_name:"keeper-a"
      ~remote_root ~gh_config_dir ~injected_env:[]
      ~env_allowlist:
        [ "LANG"; "GIT_AUTHOR_NAME"; "GIT_COMMITTER_NAME"; "GH_CONFIG_DIR" ]
      ~connect_timeout_sec:1 ~max_concurrent_sessions:2 (guest ~cli ())
  in
  let runner = Keeper_sandbox_remote.runner ~timeout_sec:2.0 state in
  ignore
    (run_request runner ~cwd:None
       ~env:
         [| "LANG=C"
          ; "GIT_AUTHOR_NAME=impostor"
          ; "GIT_COMMITTER_NAME=impostor"
          ; "GH_CONFIG_DIR=/impostor/gh"
         |]
       ()
     : Unix.process_status * string * string);
  match Exec_ssh_protocol.decode_request (read_file frame_path) with
  | Error error -> fail error
  | Ok (request, _) ->
    let values name =
      List.filter_map
        (fun (key, value) -> if String.equal key name then Some value else None)
        request.env
    in
    check (list string) "author is the keeper, once" [ "keeper-a" ]
      (values "GIT_AUTHOR_NAME");
    check (list string) "committer is the keeper, once" [ "keeper-a" ]
      (values "GIT_COMMITTER_NAME");
    check (list string) "GitHub config is the lane's, once" [ gh_config_dir ]
      (values "GH_CONFIG_DIR");
    check (list string) "ordinary allowlisted caller env still passes" [ "C" ]
      (values "LANG")
;;

let test_default_cwd_is_the_request_root () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, frame_path = make_stub ~dir:base_path ~mode:"exit3" in
  let state = make_state ~base_path ~cli in
  let runner = Keeper_sandbox_remote.runner ~timeout_sec:2.0 state in
  ignore (run_request runner ~cwd:None () : Unix.process_status * string * string);
  match Exec_ssh_protocol.decode_request (read_file frame_path) with
  | Error error -> fail error
  | Ok (request, _) ->
    check string "default cwd" "/masc-work/keeper-a" request.cwd;
    check string "same request root" request.cwd request.remote_root;
    let runner =
      Keeper_sandbox_remote.runner ~mode:Exec_ssh_protocol.Observe ~timeout_sec:2.0
        (make_docker_state ~base_path ~cli)
    in
    ignore (run_request runner ~cwd:None () : Unix.process_status * string * string);
    (match Exec_ssh_protocol.decode_request (read_file frame_path) with
     | Error error -> fail error
     | Ok (request, _) ->
       check string "Docker cwd stays at its resolved root" remote_root request.cwd;
       check string "Docker request root" request.cwd request.remote_root)
;;

let test_docker_relative_cwd_is_rejected () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, _ = make_stub ~dir:base_path ~mode:"exit3" in
  let runner =
    Keeper_sandbox_remote.runner ~mode:Exec_ssh_protocol.Observe ~timeout_sec:2.0
      (make_docker_state ~base_path ~cli)
  in
  let status, _, stderr = run_request runner ~cwd:(Some "relative/path") () in
  check status_testable "request refused before dispatch" (Unix.WEXITED 1) status;
  check bool "names absolute-cwd contract" true
    (contains "docker_observe_cwd_requires_guest_absolute_path" stderr)
;;

(* ── the box (RFC-0422) ─────────────────────────────────────────────── *)

let decoded_mode frame_path =
  match Exec_ssh_protocol.decode_request (read_file frame_path) with
  | Error error -> fail error
  | Ok (request, _) -> Exec_ssh_protocol.mode_to_string request.mode
;;

(* The runner asks for the box in the request and nowhere else: same
   transport argv, same env, one more field. Omitted, it is Effect, so every
   caller that never heard of the box still runs what it ran. *)
let test_the_requested_mode_travels_in_the_frame () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, frame_path = make_stub ~dir:base_path ~mode:"exit3" in
  let state = make_state ~base_path ~cli in
  let run mode =
    let runner = Keeper_sandbox_remote.runner ?mode ~timeout_sec:2.0 state in
    ignore (run_request runner ~cwd:None () : Unix.process_status * string * string);
    decoded_mode frame_path
  in
  check string "omitted is effect" "effect" (run None);
  check string "observe is asked for by name" "observe" (run (Some Exec_ssh_protocol.Observe));
  check string "guest_local likewise" "guest_local" (run (Some Exec_ssh_protocol.Guest_local))
;;

(* Whether there is a box is the shim's answer, read from its probe: a shim
   that advertises none gets no observe run, one that does gets one, and a
   probe that cannot run is a no. Each state has its own base path because
   the answer is remembered per endpoint for the life of the process. *)
let test_observe_support_is_what_the_shim_advertises () =
  with_eio @@ fun () ->
  let supported mode =
    let base_path = temp_dir () in
    let cli, _ = make_stub ~dir:base_path ~mode in
    Keeper_sandbox_remote.observe_supported (make_state ~base_path ~cli)
  in
  check bool "a shim without the box" false (supported "probe-plain");
  check bool "a shim with the box" true (supported "probe-observe");
  check bool "a probe that fails" false (supported "cli-not-found")
;;

(* The stub's shim names no release, which the server reports as outdated. The
   line it logs for a microVM guest is the one an operator reads, so it is
   read here as logged: the host path of this workspace, not the bootstrap. *)
let test_the_outdated_shim_warning_names_the_microvm_repair () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, _ = make_stub ~dir:base_path ~mode:"probe-plain" in
  let state = make_state ~base_path ~cli in
  (* Asking is what probes; this stub's shim offers no box. *)
  check bool "a shim without the box" false (Keeper_sandbox_remote.observe_supported state);
  let host_shim =
    Filename.concat (Config_dir_resolver.microvm_shim_dir ~base_path) "masc-exec-shim"
  in
  match
    Log.Ring.recent ~limit:50 ~module_filter:"Keeper" ()
    |> List.find_opt (fun (entry : Log.Ring.entry) -> contains host_shim entry.message)
  with
  | None -> fail "no log line names this workspace's shim"
  | Some entry ->
    check bool "it is the outdated-shim warning" true
      (contains ("remote_shim_outdated: endpoint " ^ guest_name) entry.message);
    check bool "and it does not send a microVM to the SSH bootstrap" false
      (contains "masc-exec-ssh-bootstrap" entry.message)
;;

(* A shim one release behind speaks v2. The runner reads that from the
   probe before its first dispatch and frames every request to that
   endpoint in v2 -- no mode field -- so an upgrade of the server alone
   does not stop a single tool_execute; and a box can only be asked of a
   shim that speaks v3, which the endpoint's probe also says. *)
let test_a_v2_shim_is_spoken_to_in_v2 () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, frame_path = make_stub ~dir:base_path ~mode:"probe-v2" in
  let state = make_state ~base_path ~cli in
  let runner = Keeper_sandbox_remote.runner ~timeout_sec:2.0 state in
  let status, stdout, _ = run_request runner ~cwd:None () in
  check status_testable "the v2 shim's answer is read" (Unix.WEXITED 3) status;
  check string "stdout" "guest-out" stdout;
  (match Exec_ssh_protocol.decode_request (read_file frame_path) with
   | Error error -> fail error
   | Ok (request, _) ->
     check int "framed in the shim's major" 2 (Exec_ssh_protocol.int_of_major request.v);
     check string "and therefore unboxed" "effect" (Exec_ssh_protocol.mode_to_string request.mode));
  check bool "no box from a v2 shim" false (Keeper_sandbox_remote.observe_supported state);
  let boxed = Keeper_sandbox_remote.runner ~mode:Exec_ssh_protocol.Observe ~timeout_sec:2.0 state in
  let status, _, stderr = run_request boxed ~cwd:None () in
  check status_testable "asking a v2 shim for a box is refused before the wire" (Unix.WEXITED 1) status;
  check bool "by name" true (contains "remote_ssh_version_error" stderr)
;;

(* RFC-0427 D-1: the lane report is the last dispatch's own branch and the
   probe's own answer, kept with the endpoint's shared state -- not a reading
   of the message text, and empty before anything has been asked. *)
let test_the_lane_report_is_what_the_last_dispatch_said () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, _ = make_stub ~dir:base_path ~mode:"exit3" in
  let state = make_state ~base_path ~cli in
  (match Keeper_sandbox_remote.report state with
   | { probe = Probe_not_asked; last_dispatch = None; lane = "microvm_remote"; _ } -> ()
   | { probe = Probe_answered _ | Probe_failed _; _ } -> fail "probed before anything asked"
   | { last_dispatch = Some _; _ } -> fail "a dispatch recorded before any ran"
   | { lane; _ } -> fail ("lane label " ^ lane));
  let before = Unix.gettimeofday () in
  let _ = run_request (Keeper_sandbox_remote.runner ~timeout_sec:2.0 state) ~cwd:None () in
  let after = Unix.gettimeofday () in
  (match Keeper_sandbox_remote.report state with
   | { probe = Probe_answered { observed_at; _ }; _ } ->
     check bool "the answer is stamped when this process got it" true
       (observed_at >= before && observed_at <= after)
   | { probe = Probe_not_asked | Probe_failed _; _ } -> fail "the first dispatch probes");
  (match Keeper_sandbox_remote.report state with
   | { probe = Probe_answered { major = Exec_ssh_protocol.V3; _ }
     ; last_dispatch = Some (Payload_finished { status = Unix.WEXITED 3; _ })
     ; _ } -> ()
   | { probe = Probe_answered { major = Exec_ssh_protocol.V2; _ }; _ } -> fail "the stub speaks v3"
   | { probe = Probe_not_asked | Probe_failed _; _ } -> fail "the first dispatch probes"
   | { last_dispatch = Some (Payload_finished { status; _ }); _ } ->
     fail ("payload status " ^ Keeper_sandbox_exec_failure.status_label status)
   | { last_dispatch = Some (Dispatch_failed { detail; _ }); _ } -> fail ("lane failed: " ^ detail)
   | { last_dispatch = None; _ } -> fail "exit3 left no record");
  let cli, _ = make_stub ~dir:base_path ~mode:"shim-error" in
  let state = make_state ~base_path ~cli in
  let _ = run_request (Keeper_sandbox_remote.runner ~timeout_sec:2.0 state) ~cwd:None () in
  (match (Keeper_sandbox_remote.report state).last_dispatch with
   | Some (Dispatch_failed { failure = Shim_refused; detail; _ }) ->
     check bool "the shim's own words" true (contains "remote_ssh_path_jail_violation" detail)
   | Some (Dispatch_failed { failure = Local_timeout | Remote_timeout | Transport_failed | Trailer_disagreement; detail; _ }) ->
     fail ("wrong class for a shim_error trailer: " ^ detail)
   | Some (Payload_finished _) | None -> fail "a shim_error trailer is a lane failure");
  let cli, _ = make_stub ~dir:base_path ~mode:"malformed" in
  let state = make_state ~base_path ~cli in
  let _ = run_request (Keeper_sandbox_remote.runner ~timeout_sec:2.0 state) ~cwd:None () in
  match (Keeper_sandbox_remote.report state).last_dispatch with
  | Some (Dispatch_failed { failure = Transport_failed; _ }) -> ()
  | Some (Dispatch_failed { failure = Local_timeout | Remote_timeout | Shim_refused | Trailer_disagreement; detail; _ }) ->
    fail ("wrong class for an unreadable trailer: " ^ detail)
  | Some (Payload_finished _) | None -> fail "an unreadable trailer is a lane failure"
;;

let test_fresh_probe_and_boot_comparison () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let response_path = Filename.concat base_path "probe-response.json" in
  let cli = Filename.concat base_path "probe-cli" in
  save cli ("#!/bin/sh\ncat " ^ shell_quote response_path ^ "\n");
  Unix.chmod cli 0o700;
  let state = make_state ~base_path ~cli in
  let boot_a = "70d55243-7a2b-47bc-95b3-c133f134854e" in
  let boot_b = "8c4c50be-d69a-497a-a5a8-d80e4848b0f3" in
  let answer boot_id =
    save response_path (Exec_ssh_protocol.render_probe
      { name = "masc-exec-shim"; version = "3.0.0"; capabilities = [];
        release = None; boot_id }) in
  let ask () = Keeper_sandbox_remote.For_testing.run_probe state in
  let observed expected_change expected_id =
    match (Keeper_sandbox_remote.report state).probe with
    | Probe_answered { boot; _ } ->
      check bool "boot comparison" true (boot.change = expected_change);
      check (option string) "boot observation" expected_id boot.boot_id;
      boot.last_changed_at
    | Probe_not_asked | Probe_failed _ -> fail "expected answered probe" in
  answer (Some boot_a);
  ignore (ask ());
  ignore (observed Boot_first (Some boot_a));
  ignore (ask ());
  ignore (observed Boot_unchanged (Some boot_a));
  Sys.remove response_path;
  (match ask () with Error _ -> () | Ok _ -> fail "missing endpoint answer was accepted");
  (match (Keeper_sandbox_remote.report state).probe with
   | Probe_failed _ -> () | Probe_not_asked | Probe_answered _ -> fail "old success hid a newer failure");
  answer None;
  ignore (ask ());
  ignore (observed Boot_unreported None);
  answer (Some boot_b);
  ignore (ask ());
  let changed_at = observed Boot_changed (Some boot_b) in
  check bool "change time retained" true (Option.is_some changed_at);
  ignore (ask ());
  check bool "last change remains visible" true
    (observed Boot_unchanged (Some boot_b) = changed_at)
;;

(* The first shim captures the old boot but cannot answer until released.
   A second Keeper names the same endpoint and would answer the new boot
   immediately if probes were allowed to overlap. *)
let delayed_probe_fixture ~base_path ~fail_first ~fail_second =
  let boot_a = "70d55243-7a2b-47bc-95b3-c133f134854e" in
  let boot_b = "8c4c50be-d69a-497a-a5a8-d80e4848b0f3" in
  let path name = Filename.concat base_path name in
  let first_started = path "first-started" in
  let second_started = path "second-started" in
  let release_first = path "release-first" in
  let probe boot_id = Exec_ssh_protocol.render_probe
      { name = "masc-exec-shim"; version = "3.0.0"; capabilities = [];
        release = None; boot_id = Some boot_id } in
  save (path "boot-a") (probe boot_a);
  save (path "boot-b") (probe boot_b);
  let first_response = if fail_first then "echo first-offline >&2; exit 255"
    else "cat " ^ shell_quote (path "boot-a") in
  let second_response = if fail_second then "echo second-offline >&2; exit 255"
    else "cat " ^ shell_quote (path "boot-b") in
  let cli = path "serial-probe-cli" in
  save cli
    (Printf.sprintf
       "#!/bin/sh\nprintf x >> %s\nif mkdir %s 2>/dev/null; then\n  : > %s\n  while [ ! -e %s ]; do sleep 0.02; done\n  %s\nelse\n  : > %s\n  %s\nfi\n"
       (shell_quote (path "probe-invocations")) (shell_quote (path "first-owner")) (shell_quote first_started)
       (shell_quote release_first) first_response
       (shell_quote second_started) second_response);
  Unix.chmod cli 0o700;
  let state keeper_name =
    Keeper_sandbox_remote.of_container_exec ~base_path ~keeper_name
      ~remote_root ~gh_config_dir ~injected_env:[] ~env_allowlist:[ "LANG" ]
      ~connect_timeout_sec:1 ~max_concurrent_sessions:2 (guest ~cli ()) in
  state "keeper-a", state "keeper-b", first_started, second_started, release_first, boot_a, boot_b
;;

let await_fixture_file clock path =
  Eio.Time.with_timeout_exn clock 3.0 (fun () ->
    let rec wait () =
      if not (Sys.file_exists path) then (Eio.Time.sleep clock 0.01; wait ()) in
    wait ())
;;

let assert_new_boot state boot_b =
  match (Keeper_sandbox_remote.report state).probe with
  | Probe_answered { boot; _ } ->
    check (option string) "last probe observed the new boot" (Some boot_b) boot.boot_id;
    check bool "the boot changed after the first answer" true (boot.change = Boot_changed)
  | Probe_not_asked | Probe_failed _ -> fail "expected the second probe to answer"
;;

let test_concurrent_probes_do_not_reorder_boots () =
  with_eio_env @@ fun env ->
  let base_path = temp_dir () in
  let first, second, first_started, second_started, release_first, boot_a, boot_b =
    delayed_probe_fixture ~base_path ~fail_first:false ~fail_second:false in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let first_result, finish_first = Eio.Promise.create () in
  let second_entered, enter_second = Eio.Promise.create () in
  let second_result, finish_second = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve finish_first (Keeper_sandbox_remote.For_testing.run_probe first));
  await_fixture_file clock first_started;
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve enter_second ();
    Eio.Promise.resolve finish_second (Keeper_sandbox_remote.For_testing.run_probe second));
  Eio.Promise.await second_entered;
  Eio.Time.sleep clock 0.1;
  check bool "the second endpoint probe waits for the first" false (Sys.file_exists second_started);
  save release_first "release";
  (match Eio.Promise.await first_result, Eio.Promise.await second_result with
   | Ok _, Ok _ -> ()
   | _ -> fail "a serialized probe failed");
  check bool "the waiting Keeper reused the first probe" false (Sys.file_exists second_started);
  (match (Keeper_sandbox_remote.report second).probe with
   | Probe_answered { boot; _ } ->
     check (option string) "shared observation is the first boot" (Some boot_a) boot.boot_id;
     check bool "one shared probe establishes only one baseline" true (boot.change = Boot_first)
   | Probe_not_asked | Probe_failed _ -> fail "expected the shared probe to answer");
  (match Keeper_sandbox_remote.For_testing.run_probe second with Ok _ -> () | Error error -> fail error);
  assert_new_boot second boot_b
;;

let test_concurrent_failed_probes_are_shared () =
  with_eio_env @@ fun env ->
  let base_path = temp_dir () in
  let first, second, first_started, second_started, release_first, _, boot_b =
    delayed_probe_fixture ~base_path ~fail_first:true ~fail_second:false in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let first_result, finish_first = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve finish_first (Keeper_sandbox_remote.For_testing.run_probe first));
  await_fixture_file clock first_started;
  let waiters = List.init 3 (fun _ ->
    let entered, enter = Eio.Promise.create () in
    let result, finish = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve enter ();
      Eio.Promise.resolve finish (Keeper_sandbox_remote.For_testing.run_probe second));
    entered, result) in
  List.iter (fun (entered, _) -> Eio.Promise.await entered) waiters;
  Eio.Time.sleep clock 0.1;
  check bool "failure waiters did not launch another probe" false (Sys.file_exists second_started);
  save release_first "release";
  let first_error = match Eio.Promise.await first_result with
    | Error error -> error | Ok _ -> fail "the first probe should fail" in
  List.iter (fun (_, result) -> match Eio.Promise.await result with
    | Error error -> check string "waiter shares the exact failure" first_error error
    | Ok _ -> fail "a shared failed probe became success") waiters;
  check bool "no waiting caller spawned a probe" false (Sys.file_exists second_started);
  (match Keeper_sandbox_remote.For_testing.run_probe second with Ok _ -> () | Error error -> fail error);
  (match (Keeper_sandbox_remote.report second).probe with
   | Probe_answered { boot; _ } ->
     check (option string) "a later probe observes recovery" (Some boot_b) boot.boot_id;
     check bool "failure did not create a boot baseline" true (boot.change = Boot_first)
   | Probe_not_asked | Probe_failed _ -> fail "later recovery was not observed")
;;

let test_forced_preflights_share_only_a_new_probe () =
  with_eio_env @@ fun env ->
  let base_path = temp_dir () in
  let first, second, first_started, second_started, release_first, _, _ =
    delayed_probe_fixture ~base_path ~fail_first:true ~fail_second:true in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let first_result, finish_first = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve finish_first (Keeper_sandbox_remote.For_testing.run_probe first));
  await_fixture_file clock first_started;
  let forced = List.init 4 (fun index ->
    let target = Keeper_sandbox_remote.of_container_exec ~base_path
        ~keeper_name:(Printf.sprintf "keeper-force-%d" index)
        ~remote_root ~gh_config_dir ~injected_env:[] ~env_allowlist:[ "LANG" ]
        ~connect_timeout_sec:1 ~max_concurrent_sessions:2
        (guest ~cli:(Filename.concat base_path "serial-probe-cli") ()) in
    let entered, enter = Eio.Promise.create () in
    let result, finish = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve enter ();
      Eio.Promise.resolve finish (Keeper_sandbox_remote.check_preflight ~force:true target));
    entered, result) in
  List.iter (fun (entered, _) -> Eio.Promise.await entered) forced;
  Eio.Time.sleep clock 0.1;
  check bool "forced probe still waits for the active probe" false (Sys.file_exists second_started);
  save release_first "release";
  (match Eio.Promise.await first_result with Error error ->
     check bool "first failure came from first probe" true (contains "first-offline" error)
   | Ok _ -> fail "the first probe should fail");
  List.iter (fun (_, result) -> match Eio.Promise.await result with Error error ->
      check bool "forced preflight observes the newer probe" true (contains "second-offline" error)
    | Ok () -> fail "the forced probe should fail") forced;
  check bool "force starts a fresh probe" true (Sys.file_exists second_started);
  let count () = String.length (read_file (Filename.concat base_path "probe-invocations")) in
  check int "four forced waiters shared one new probe" 2 (count ());
  (match Keeper_sandbox_remote.check_preflight ~force:true second with Error error ->
     check bool "sequential force observes its own probe" true (contains "second-offline" error)
   | Ok () -> fail "the later forced probe should fail");
  check int "a later forced call starts another probe" 3 (count ())
;;

let test_cancelled_probe_waiter_releases_ownership () =
  with_eio_env @@ fun env ->
  let base_path = temp_dir () in
  let first, second, first_started, second_started, release_first, _, boot_b =
    delayed_probe_fixture ~base_path ~fail_first:false ~fail_second:false in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let first_result, finish_first = Eio.Promise.create () in
  let waiter_context, provide_waiter_context = Eio.Promise.create () in
  let waiter_result, finish_waiter = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve finish_first (Keeper_sandbox_remote.For_testing.run_probe first));
  await_fixture_file clock first_started;
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      try Eio.Cancel.sub (fun context ->
        Eio.Promise.resolve provide_waiter_context context;
        ignore (Keeper_sandbox_remote.For_testing.run_probe second);
        `Returned)
      with Eio.Cancel.Cancelled _ -> `Cancelled in
    Eio.Promise.resolve finish_waiter result);
  let context = Eio.Promise.await waiter_context in
  Eio.Cancel.cancel context Exit;
  (match Eio.Promise.await waiter_result with
   | `Cancelled -> () | `Returned -> fail "a cancelled waiter entered the probe");
  check bool "the cancelled waiter did not start a process" false (Sys.file_exists second_started);
  save release_first "release";
  (match Eio.Promise.await first_result with Ok _ -> () | Error error -> fail error);
  (match Keeper_sandbox_remote.For_testing.run_probe second with Ok _ -> () | Error error -> fail error);
  assert_new_boot second boot_b
;;

let test_cancelled_probe_owner_releases_ownership () =
  with_eio_env @@ fun env ->
  let base_path = temp_dir () in
  let first, second, first_started, _, _, _, boot_b =
    delayed_probe_fixture ~base_path ~fail_first:false ~fail_second:false in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let owner_context, provide_owner_context = Eio.Promise.create () in
  let owner_result, finish_owner = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      try Eio.Cancel.sub (fun context ->
        Eio.Promise.resolve provide_owner_context context;
        ignore (Keeper_sandbox_remote.For_testing.run_probe first);
        `Returned)
      with Eio.Cancel.Cancelled _ -> `Cancelled in
    Eio.Promise.resolve finish_owner result);
  let context = Eio.Promise.await owner_context in
  await_fixture_file clock first_started;
  Eio.Cancel.cancel context Exit;
  (match Eio.Promise.await owner_result with
   | `Cancelled -> () | `Returned -> fail "the owner ignored cancellation");
  (match Keeper_sandbox_remote.For_testing.run_probe second with Ok _ -> () | Error error -> fail error);
  (match (Keeper_sandbox_remote.report second).probe with
   | Probe_answered { boot; _ } ->
     check (option string) "the next probe observed the new boot" (Some boot_b) boot.boot_id;
     check bool "a cancelled probe did not establish a baseline" true (boot.change = Boot_first)
   | Probe_not_asked | Probe_failed _ -> fail "probe did not resume after owner cancellation")
;;

(* The tool's JSON names the operator action from the failure's class. *)
(* RFC-0427 B-3. The shim names the release it came from, so the keeper reading
   its own lane sees whether the endpoint runs this server's shim. A shim from
   this release asks nothing of anyone. An unequal reported release and a
   release that cannot be compared are distinct provenance observations. *)
let test_the_lane_status_names_a_shim_from_another_release () =
  let report probe =
    Keeper_tool_lane_status.json_of_report
      { Keeper_sandbox_remote.lane = "remote_ssh"
      ; endpoint = "builder"
      ; probe
      ; last_dispatch = None
      }
  in
  let field name json = Yojson.Safe.Util.member name json in
  let answered release =
    report
      (Keeper_sandbox_remote.Probe_answered
         { major = Exec_ssh_protocol.V3; capabilities = []; release; observed_at = 100.0
         ; boot = { boot_id = None; change = Boot_unreported; last_changed_at = None } })
  in
  let same = answered (Some Build_version.current) in
  check bool "a shim from this release asks nothing" true
    (field "operator_action" same = `Null);
  check string "the probe names the shim's release" Build_version.current
    (Yojson.Safe.Util.to_string (field "shim_release" (field "probe" same)));
  check string "and the server's own" Build_version.current
    (Yojson.Safe.Util.to_string (field "server_release" (field "probe" same)));
  check (float 0.0) "and when it answered, so an old reading reads as old" 100.0
    (Yojson.Safe.Util.to_float (field "observed_at_unix" (field "probe" same)));
  let older = answered (Some "0.1.0") in
  check bool "another release is the operator's" true
    (contains "different release"
       (Yojson.Safe.Util.to_string (field "operator_action" older)));
  let unstamped = answered None in
  check bool "an unreported release has provenance guidance" true
    (match field "operator_action" unstamped with `String _ -> true | _ -> false);
  check bool "unknown provenance is distinct from a known mismatch" false
    (field "operator_action" unstamped = field "operator_action" older);
  check bool "an unreported release still answered" true
    (field "state" (field "probe" unstamped) = `String "answered");
  check int "the negotiated protocol is preserved" 3
    (Yojson.Safe.Util.to_int (field "protocol_major" (field "probe" unstamped)));
  check (float 0.0) "unknown provenance retains its observation time" 100.0
    (Yojson.Safe.Util.to_float (field "observed_at_unix" (field "probe" unstamped)));
  check bool "and its release reads as null" true
    (field "shim_release" (field "probe" unstamped) = `Null)

let test_the_lane_status_names_who_acts () =
  let at = 1.0 in
  let report last_dispatch probe =
    Keeper_tool_lane_status.json_of_report
      { Keeper_sandbox_remote.lane = "microvm_remote"; endpoint = "vm-x"; probe; last_dispatch }
  in
  let field name json = Yojson.Safe.Util.member name json in
  let version_skew =
    report
      (Some
         (Keeper_sandbox_remote.Dispatch_failed
            { at = 101.0; failure = Transport_failed
            ; detail = "remote_ssh_version_error: trailer carries v=2, this build speaks v3" }))
      (Keeper_sandbox_remote.Probe_answered
         { major = Exec_ssh_protocol.V3; capabilities = []; release = None; observed_at = 100.0
         ; boot = { boot_id = None; change = Boot_unreported; last_changed_at = None } })
  in
  check string "failure class" "transport_failed"
    (Yojson.Safe.Util.to_string (field "failure" (field "last_dispatch" version_skew)));
  check bool "transport failure does not prove power state" true
    (contains "does not establish" (Yojson.Safe.Util.to_string (field "operator_action" version_skew)));
  check bool "the action says who replaces the shim" true
    (contains "operator has to replace the shim" (Yojson.Safe.Util.to_string (field "operator_action" version_skew)));
  let timeout_action failure =
    report
      (Some (Keeper_sandbox_remote.Dispatch_failed { at; failure; detail = "timeout" }))
      (Keeper_sandbox_remote.Probe_answered
         { major = Exec_ssh_protocol.V3; capabilities = []; release = Some Build_version.current
         ; observed_at = 0.5
         ; boot = { boot_id = None; change = Boot_unreported; last_changed_at = None } })
    |> field "operator_action"
    |> Yojson.Safe.Util.to_string
  in
  let local_timeout = timeout_action Keeper_sandbox_remote.Local_timeout in
  check bool "a local timeout keeps payload execution and effects unknown" true
    (contains "unknown" local_timeout && contains "before retrying" local_timeout);
  check bool "an old probe does not prove current health" true
    (contains "earlier probe does not prove" local_timeout);
  check bool "a local timeout does not claim the lane worked" false
    (contains "lane itself worked" local_timeout);
  let remote_timeout = timeout_action Keeper_sandbox_remote.Remote_timeout in
  check bool "a remote timeout is attributed to the shim" true
    (contains "shim reported" remote_timeout && contains "before retrying" remote_timeout);
  check bool "local and remote timeouts have distinct guidance" false
    (String.equal local_timeout remote_timeout);
  let finished =
    report (Some (Keeper_sandbox_remote.Payload_finished { at; status = Unix.WEXITED 0 })) Keeper_sandbox_remote.Probe_not_asked
  in
  check bool "a finished payload asks nothing of the operator" true
    (field "operator_action" finished = `Null);
  let probe_down = report None (Keeper_sandbox_remote.Probe_failed { at; detail = "endpoint_unreachable" }) in
  check string "probe state" "failed" (Yojson.Safe.Util.to_string (field "state" (field "probe" probe_down)));
  check bool "a failed probe is the operator's" true
    (contains "operator" (Yojson.Safe.Util.to_string (field "operator_action" probe_down)));
  let recovered = report
      (Some (Keeper_sandbox_remote.Payload_finished { at = 2.0; status = Unix.WEXITED 0 }))
      (Keeper_sandbox_remote.Probe_failed { at = 1.0; detail = "old failure" }) in
  check bool "a later successful dispatch supersedes old probe advice" true
    (field "operator_action" recovered = `Null);
  let failed_again = report
      (Some (Keeper_sandbox_remote.Payload_finished { at = 1.0; status = Unix.WEXITED 0 }))
      (Keeper_sandbox_remote.Probe_failed { at = 2.0; detail = "new failure" }) in
  check bool "a later failed probe is reported" true
    (match field "operator_action" failed_again with `String _ -> true | _ -> false);
  let reconnected = report
      (Some (Keeper_sandbox_remote.Dispatch_failed { at = 1.0; failure = Transport_failed; detail = "lost" }))
      (Keeper_sandbox_remote.Probe_answered
        { major = Exec_ssh_protocol.V3; capabilities = []; release = Some Build_version.current; observed_at = 2.0
        ; boot = { boot_id = None; change = Boot_unreported; last_changed_at = None } }) in
  check bool "a successful probe does not settle an uncertain dispatch" true
    (contains "effect may have happened" (Yojson.Safe.Util.to_string (field "operator_action" reconnected)))
;;

let test_lane_error_codes () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let expect mode ~code =
    let cli, _ = make_stub ~dir:base_path ~mode in
    let runner = Keeper_sandbox_remote.runner ~timeout_sec:2.0 (make_state ~base_path ~cli) in
    let status, _, stderr = run_request runner () in
    check status_testable (mode ^ " status") (Unix.WEXITED 1) status;
    check bool (mode ^ " names the guest lane") true (contains code stderr)
  in
  expect "malformed" ~code:"microvm_remote_transport_error:";
  expect "cli-not-found" ~code:"microvm_remote_transport_error:";
  let cli, frame_path = make_stub ~dir:base_path ~mode:"exit3" in
  let runner = Keeper_sandbox_remote.runner ~timeout_sec:2.0 (make_state ~base_path ~cli) in
  let status, _, stderr = run_request runner ~env:[| "NOPE=value" |] () in
  check status_testable "policy failure" (Unix.WEXITED 1) status;
  check bool "allowlist error names the guest lane" true
    (contains "microvm_remote_env_not_allowlisted:" stderr);
  check bool "CLI was not spawned" false (Sys.file_exists frame_path);
  let cli, _ = make_stub ~dir:base_path ~mode:"shim-error" in
  let runner = Keeper_sandbox_remote.runner ~timeout_sec:2.0 (make_state ~base_path ~cli) in
  let _, _, stderr = run_request runner () in
  check bool "shim-minted code passes through unchanged" true
    (String.starts_with ~prefix:"remote_ssh_path_jail_violation:" stderr)
;;

let test_preflight_unreachable_names_the_guest () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "0" @@ fun () ->
  let base_path = temp_dir () in
  let cli, _ = make_stub ~dir:base_path ~mode:"cli-not-found" in
  let state = make_state ~base_path ~cli in
  Keeper_sandbox_remote.For_testing.clear_preflight_cache ();
  match Keeper_sandbox_remote.check_preflight ~force:true state with
  | Ok () -> fail "a missing guest passed preflight"
  | Error error ->
    check bool "unreachable is named for the guest lane" true
      (String.starts_with ~prefix:"microvm_remote_endpoint_unreachable:" error);
    check bool "the guest is named" true (contains guest_name error)
;;

let test_receipts_are_owned_by_each_transport_call () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, _ = make_stub ~dir:base_path ~mode:"receipt" in
  let state = make_state ~base_path ~cli in
  let observe_receipts = ref [] and effect_receipts = ref [] in
  let observe = Keeper_sandbox_remote.runner ~mode:Exec_ssh_protocol.Observe
      ~on_receipt:(fun receipt -> observe_receipts := receipt :: !observe_receipts)
      ~timeout_sec:2.0 state in
  let effect_runner = Keeper_sandbox_remote.runner ~mode:Exec_ssh_protocol.Effect
      ~on_receipt:(fun receipt -> effect_receipts := receipt :: !effect_receipts)
      ~timeout_sec:2.0 state in
  let observe_result, effect_result = Eio.Fiber.pair
      (fun () -> run_request observe ()) (fun () -> run_request effect_runner ()) in
  let check_receipt mode code = function
    | [Keeper_sandbox_remote.Execution_observed (receipt, outcome)] ->
      check bool "exact responding shim mode" true (receipt.mode = mode);
      check bool "actual applied acknowledgement" true
        (receipt.boundary = Exec_ssh_protocol.Sandbox_applied);
      check (option int) "same response process exit" (Some code) outcome.exit
    | _ -> fail "per-call receipt was missing or crossed concurrent calls"
  in
  check_receipt Exec_ssh_protocol.Observe 0 !observe_receipts;
  check_receipt Exec_ssh_protocol.Effect 7 !effect_receipts;
  let observe_status, _, _ = observe_result and effect_status, _, _ = effect_result in
  check status_testable "Observe status remains real" (Unix.WEXITED 0) observe_status;
  check status_testable "Effect status remains real" (Unix.WEXITED 7) effect_status;
  ignore (run_request effect_runner ());
  check int "multiple stages preserve every receipt" 2 (List.length !effect_receipts)
;;

let test_interrupted_wire_publishes_unknown_receipt () =
  with_eio_env @@ fun env ->
  let base_path = temp_dir () in
  let cli, _ = make_stub ~dir:base_path ~mode:"exit3" in
  let observations = ref [] in
  let runner = Keeper_sandbox_remote.runner
      ~on_receipt:(fun receipt -> observations := receipt :: !observations)
      ~timeout_sec:2.0 (make_state ~base_path ~cli) in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let cancel_context, provide_context = Eio.Promise.create () in
  let received_output, signal_output = Eio.Promise.create () in
  let wait_for_cancel, release_callback = Eio.Promise.create () in
  let result, finish = Eio.Promise.create () in
  Fun.protect ~finally:(fun () -> Eio.Promise.resolve release_callback ()) @@ fun () ->
  Eio.Fiber.fork ~sw (fun () ->
    let outcome =
      try Eio.Cancel.sub (fun context ->
        Eio.Promise.resolve provide_context context;
        ignore (runner
          ~on_stdout_chunk:(Some (fun _ ->
            Eio.Promise.resolve signal_output ();
            Eio.Promise.await wait_for_cancel))
          ~on_stderr_chunk:None ~stdin_content:None ~argv:["/bin/true"] ~env:[||] ~cwd:None);
        `Returned)
      with Eio.Cancel.Cancelled cause -> `Cancelled cause in
    Eio.Promise.resolve finish outcome);
  let context = Eio.Promise.await cancel_context in
  Eio.Time.with_timeout_exn clock 5.0 (fun () -> Eio.Promise.await received_output);
  Eio.Cancel.cancel context Exit;
  let rec cancellation_cause_is_exit = function
    | Exit -> true
    | Eio.Cancel.Cancelled cause -> cancellation_cause_is_exit cause
    | _ -> false in
  (match Eio.Time.with_timeout_exn clock 10.0 (fun () -> Eio.Promise.await result) with
   | `Cancelled cause ->
     check bool "cancellation keeps the requested cause" true (cancellation_cause_is_exit cause)
   | `Returned -> fail "the runner swallowed cancellation");
  let open Keeper_sandbox_remote in
  match !observations with
  | [Execution_unavailable Transport_unavailable] -> ()
  | [] | _ :: _ :: _
  | [Execution_observed _]
  | [Execution_unavailable
       (Request_not_sent | Peer_receipt_missing | Invalid_receipt _ | Shim_refused_without_receipt)] ->
    fail "an interrupted wire did not publish its uncertain effect"
;;

let test_trusted_remote_timeout_retains_receipt () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, _ = make_stub ~dir:base_path ~mode:"timeout-receipt" in
  let observed = ref None in
  let runner = Keeper_sandbox_remote.runner ~mode:Exec_ssh_protocol.Observe
      ~on_receipt:(fun receipt -> observed := Some receipt)
      ~timeout_sec:2.0 (make_state ~base_path ~cli) in
  (match runner ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:None
           ~argv:["/bin/true"] ~env:[||] ~cwd:None with
   | Masc_exec.Sandbox_target.Transport_failed _ -> ()
   | Ran _ -> fail "remote timeout became a successful transport result");
  match !observed with
  | Some (Keeper_sandbox_remote.Execution_observed (receipt, outcome)) ->
    check bool "actual timeout outcome retained" true outcome.timed_out;
    check (option int) "remote signal retained" (Some 15) outcome.signal;
    check bool "same response's child acknowledgement retained" true
      (receipt.mode = Exec_ssh_protocol.Observe
       && receipt.boundary = Exec_ssh_protocol.Sandbox_applied)
  | _ -> fail "validated remote timeout was mislabeled as missing transport evidence"
;;

let test_missing_and_invalid_receipts_keep_actual_status () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  List.iter (fun fixture ->
    let cli, _ = make_stub ~dir:base_path ~mode:fixture in
    let observed = ref None in
    let runner = Keeper_sandbox_remote.runner
        ~on_receipt:(fun receipt -> observed := Some receipt)
        ~timeout_sec:2.0 (make_state ~base_path ~cli) in
    let status, _, _ = run_request runner () in
    check status_testable "receipt loss never rewrites payload exit" (Unix.WEXITED 3) status;
    match fixture, !observed with
    | "exit3", Some (Keeper_sandbox_remote.Execution_unavailable Peer_receipt_missing)
    | "bad-receipt", Some (Keeper_sandbox_remote.Execution_unavailable (Invalid_receipt _)) -> ()
    | _ -> fail "missing or malformed receipt became caller-inferred execution")
    ["exit3"; "bad-receipt"]
;;

let test_shim_refusal_preserves_its_distinct_observation () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  List.iter (fun fixture ->
    let cli, _ = make_stub ~dir:base_path ~mode:fixture in
    let observed = ref None in
    let runner = Keeper_sandbox_remote.runner
        ~on_receipt:(fun receipt -> observed := Some receipt)
        ~timeout_sec:2.0 (make_state ~base_path ~cli) in
    (match runner ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:None
             ~argv:["/bin/true"] ~env:[||] ~cwd:None with
     | Masc_exec.Sandbox_target.Transport_failed _ -> ()
     | Ran _ -> fail "shim refusal became a child result");
    match fixture, !observed with
    | ("shim-error" | "shim-error-invalid"),
      Some (Keeper_sandbox_remote.Execution_unavailable Shim_refused_without_receipt) -> ()
    | "shim-error-receipt", Some (Keeper_sandbox_remote.Execution_observed (_, outcome))
      when Option.is_some outcome.shim_error -> ()
    | _ -> fail "shim refusal lost the distinction from a child exit")
    ["shim-error"; "shim-error-invalid"; "shim-error-receipt"]
;;

let test_openssh_observation_reads_the_dispatch_cache () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, _ = make_stub ~dir:base_path ~mode:"exit3" in
  let ssh_bin = Filename.concat base_path "ssh-protocol-stub" in
  save ssh_bin
    (Printf.sprintf
       "#!/bin/sh\ncase \"$*\" in\n  *--probe*) exec %s --probe ;;\n  *) exec %s \"$@\" ;;\nesac\n"
       (shell_quote cli) (shell_quote cli));
  Unix.chmod ssh_bin 0o700;
  let endpoint : Exec_ssh_endpoint.t =
    { name = "observed-box"; host = "fleet.invalid"; user = "masc"; port = 22
    ; identity_file = "key"; known_hosts_file = "hosts"
    ; remote_root = "/srv/masc"; connect_timeout_sec = 1
    ; max_concurrent_sessions = 1; env_allowlist = [ "LANG" ]; capabilities = []
    ; private_home = false; allowed_paths = [] }
  in
  let openssh : Keeper_sandbox_remote.openssh =
    { endpoint; ssh_bin; identity_file = "key"; known_hosts_file = "hosts"
    }
  in
  let cached () =
    Keeper_sandbox_remote.report_openssh
      ~scope:Keeper_sandbox_remote.Endpoint_dispatch ~base_path openssh
  in
  (match (cached ()).probe with
   | Probe_not_asked -> ()
   | _ -> fail "an unused endpoint cannot have a probe observation");
  let state =
    Keeper_sandbox_remote.of_openssh ~base_path ~keeper_name:"keeper-a"
      openssh
  in
  let status, _, stderr = run_request (Keeper_sandbox_remote.runner ~timeout_sec:2.0 state) () in
  check status_testable ("stub dispatch ran: " ^ stderr) (Unix.WEXITED 3) status;
  Sys.remove ssh_bin;
  let observed = cached () in
  (match observed.probe, observed.last_dispatch with
   | Probe_answered _, Some (Payload_finished _) -> ()
   | _ -> fail "the observation must contain the dispatch's probe and outcome");
  check string "cached observation is exactly the runner's report"
    (Yojson.Safe.to_string (Keeper_tool_lane_status.json_of_report (Keeper_sandbox_remote.report state)))
    (Yojson.Safe.to_string (Keeper_tool_lane_status.json_of_report observed));
  let assert_unobserved label report =
    (match report.Keeper_sandbox_remote.probe with
     | Probe_not_asked -> ()
     | _ -> fail (label ^ " inherited another endpoint's probe"));
    check bool (label ^ " has no inherited dispatch") true
      (Option.is_none report.last_dispatch)
  in
  List.iter
    (fun (label, changed) ->
       assert_unobserved (label ^ " projection")
         (Keeper_sandbox_remote.report_openssh
            ~scope:Keeper_sandbox_remote.Endpoint_dispatch ~base_path changed);
       let runner = Keeper_sandbox_remote.of_openssh ~base_path ~keeper_name:"keeper-a" changed in
       assert_unobserved (label ^ " runner") (Keeper_sandbox_remote.report runner))
    [ "host", { openssh with endpoint = { endpoint with host = "changed.invalid" } }
    ; "user", { openssh with endpoint = { endpoint with user = "other-user" } }
    ; "port", { openssh with endpoint = { endpoint with port = 2222 } }
    ; "root", { openssh with endpoint = { endpoint with remote_root = "/new-root" } }
    ; "key declaration", { openssh with endpoint = { endpoint with identity_file = "new-key" } }
    ; "key transport", { openssh with identity_file = "resolved-new-key" }
    ; "host pin", { openssh with known_hosts_file = "resolved-new-hosts" }
    ; "allowlist", { openssh with endpoint = { endpoint with env_allowlist = [ "TERM" ] } }
    ; "paths", { openssh with endpoint = { endpoint with allowed_paths = [ "/app" ] } }
    ; "home policy", { openssh with endpoint = { endpoint with private_home = true } }
    ; "capabilities", { openssh with endpoint = { endpoint with capabilities = [ "observe" ] } }
    ; "SSH binary", { openssh with ssh_bin = "another-ssh" }
    ];
  (match (Keeper_sandbox_remote.report_openssh
            ~scope:Keeper_sandbox_remote.Endpoint_dispatch
            ~base_path:(base_path ^ "-other") openssh).probe with
   | Probe_not_asked -> ()
   | _ -> fail "another workspace cannot see this workspace's observation")
;;

let test_shared_openssh_dispatches_belong_to_their_keepers () =
  with_eio @@ fun () ->
  let base_path = temp_dir () in
  let cli, _ = make_stub ~dir:base_path ~mode:"receipt" in
  let openssh : Keeper_sandbox_remote.openssh =
    { endpoint =
        { name = "shared-box"; host = "fleet.invalid"; user = "masc"; port = 22
        ; identity_file = "key"; known_hosts_file = "hosts"
        ; remote_root = "/srv/masc"; connect_timeout_sec = 1
        ; max_concurrent_sessions = 2; env_allowlist = [ "LANG" ]; capabilities = []
        ; private_home = false; allowed_paths = [] }
    ; ssh_bin = cli; identity_file = "key"; known_hosts_file = "hosts" }
  in
  let state keeper_name =
    Keeper_sandbox_remote.of_openssh ~base_path ~keeper_name openssh
  in
  let keeper_a = state "keeper-a" and keeper_b = state "keeper-b" in
  let report keeper_name =
    Keeper_sandbox_remote.report_openssh
      ~scope:(Keeper_sandbox_remote.Keeper_dispatch keeper_name) ~base_path openssh
  in
  let expect_status label expected report =
    match report.Keeper_sandbox_remote.last_dispatch with
    | Some (Payload_finished { status; _ }) -> check status_testable label expected status
    | Some (Dispatch_failed _) | None -> fail (label ^ ": expected a completed dispatch")
  in
  let status_a, _, _ =
    run_request (Keeper_sandbox_remote.runner ~mode:Exec_ssh_protocol.Effect
      ~timeout_sec:2.0 keeper_a) ()
  in
  check status_testable "keeper A actually ran" (Unix.WEXITED 7) status_a;
  (match (report "keeper-b").probe with
   | Probe_answered _ -> ()
   | Probe_not_asked | Probe_failed _ -> fail "endpoint probe should be shared");
  check bool "keeper B has not dispatched" true
    (Option.is_none (report "keeper-b").last_dispatch);
  let status_b, _, _ =
    run_request (Keeper_sandbox_remote.runner ~mode:Exec_ssh_protocol.Observe
      ~timeout_sec:2.0 keeper_b) ()
  in
  check status_testable "keeper B actually ran" (Unix.WEXITED 0) status_b;
  expect_status "keeper A keeps its own result" (Unix.WEXITED 7) (report "keeper-a");
  expect_status "keeper B sees its own result" (Unix.WEXITED 0) (report "keeper-b");
  expect_status "runner A agrees with its projection" (Unix.WEXITED 7)
    (Keeper_sandbox_remote.report keeper_a);
  expect_status "endpoint view sees the latest dispatch" (Unix.WEXITED 0)
    (Keeper_sandbox_remote.report_openssh
       ~scope:Keeper_sandbox_remote.Endpoint_dispatch ~base_path openssh)
;;

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--container-stub"
  then stub_main ()
  else
    run "keeper_sandbox_remote"
      [ ( "container_exec"
        , [ test_case "concurrent calls retain their own shim receipts" `Quick
              test_receipts_are_owned_by_each_transport_call
          ; test_case "missing and invalid receipts retain actual status" `Quick
              test_missing_and_invalid_receipts_keep_actual_status
          ; test_case "shim refusals remain distinct from child exits" `Quick
              test_shim_refusal_preserves_its_distinct_observation
          ; test_case "remote timeout retains its trusted receipt" `Quick
              test_trusted_remote_timeout_retains_receipt
          ; test_case "interrupted wire retains unknown receipt" `Quick
              test_interrupted_wire_publishes_unknown_receipt
          ; test_case "transport + probe argv" `Quick test_transport_and_probe_argv
          ; test_case "latest probe and boot comparison" `Quick test_fresh_probe_and_boot_comparison
          ; test_case "shared endpoint probes cannot reorder boots" `Quick test_concurrent_probes_do_not_reorder_boots
          ; test_case "concurrent failed probes share one result" `Quick test_concurrent_failed_probes_are_shared
          ; test_case "forced preflights share only a new probe" `Quick test_forced_preflights_share_only_a_new_probe
          ; test_case "cancelled probe waiter leaves lock reusable" `Quick test_cancelled_probe_waiter_releases_ownership
          ; test_case "cancelled probe owner leaves lock reusable" `Quick test_cancelled_probe_owner_releases_ownership
          ; test_case "caller cannot replace runner-owned env" `Quick
              test_caller_cannot_replace_runner_owned_env
          ; test_case "probe prefers probe_prefix when present" `Quick
              test_container_exec_probe_argv_prefers_probe_prefix
          ; test_case "openssh probe stays one word" `Quick
              test_openssh_probe_stays_one_word
          ; test_case "an outdated shim's repair is the transport's" `Quick
              test_the_outdated_shim_repair_is_the_transports
          ; test_case "the outdated-shim warning names the microVM repair" `Quick
              test_the_outdated_shim_warning_names_the_microvm_repair
          ; test_case "binary transport retains complete raw bytes" `Quick test_binary_stdout_is_complete_and_not_rewritten
          ; test_case "frame, exit and injected env" `Quick
              test_frame_exit_and_injected_env
          ; test_case "default cwd is the request root" `Quick
              test_default_cwd_is_the_request_root
          ; test_case "Docker rejects relative cwd" `Quick
              test_docker_relative_cwd_is_rejected
          ; test_case "the requested mode travels in the frame" `Quick
              test_the_requested_mode_travels_in_the_frame
          ; test_case "observe support is what the shim advertises" `Quick
              test_observe_support_is_what_the_shim_advertises
          ; test_case "a v2 shim is spoken to in v2" `Quick
              test_a_v2_shim_is_spoken_to_in_v2
          ; test_case "the lane report is what the last dispatch said" `Quick
              test_the_lane_report_is_what_the_last_dispatch_said
          ; test_case "the lane status names who acts" `Quick
              test_the_lane_status_names_who_acts
          ; test_case "the lane status names a shim from another release" `Quick
              test_the_lane_status_names_a_shim_from_another_release
          ; test_case "SSH observation reads the dispatch cache" `Quick
              test_openssh_observation_reads_the_dispatch_cache
          ; test_case "shared SSH dispatches belong to their Keepers" `Quick
              test_shared_openssh_dispatches_belong_to_their_keepers
          ; test_case "lane error codes" `Quick test_lane_error_codes
          ; test_case "preflight unreachable names the guest" `Quick
              test_preflight_unreachable_names_the_guest
          ] )
      ]
