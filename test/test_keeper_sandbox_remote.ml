(* The [container exec] transport of the remote lane (RFC-0400).

   A stub stands in for the [container] CLI: it records the argv it was
   given, reads the framed request off stdin, and answers by mode with the
   same trailer the shim writes. The runner must not be able to tell the two
   transports apart except through the argv it spawns and the error codes it
   mints. *)

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
         { name = "masc-exec-shim"; version = string_of_int major ^ ".0.0"; capabilities });
    exit 0);
  let header = read_exact Unix.stdin 8 in
  let body_len = Bytes.get_int64_be (Bytes.unsafe_of_string header) 0 |> Int64.to_int in
  let frame = header ^ read_exact Unix.stdin body_len in
  save frame_path frame;
  (* The trailer answers in the request's own major, as the shim does. *)
  let v =
    match Exec_ssh_protocol.decode_request frame with
    | Ok (request, _) -> request.v
    | Error error -> failwith ("container stub could not read the frame: " ^ error)
  in
  let trailer ?exit ?signal ?(timed_out = false) ?shim_error () =
    Exec_ssh_protocol.render_trailer { v; exit; signal; timed_out; shim_error }
  in
  match mode with
  | "exit3" | "probe-observe" | "probe-plain" | "probe-v2" ->
    write_all Unix.stdout "guest-out";
    write_all Unix.stderr ("guest-err" ^ trailer ~exit:3 ());
    exit 0
  | "shim-error" ->
    write_all Unix.stderr
      (trailer ~shim_error:"remote_ssh_path_jail_violation: outside root" ());
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

let with_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f
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
  ; "--env"; "MASC_EXEC_SHIM_CONFIG=" ^ shim_config_path; guest_name ]
;;

let guest ?probe_prefix ~cli : Keeper_sandbox_remote.container_exec =
  { prefix = exec_prefix ~cli; probe_prefix; container_name = guest_name; shim_path }
;;

let make_state ~base_path ~cli =
  Keeper_sandbox_remote.of_container_exec ~base_path ~keeper_name:"keeper-a"
    ~remote_root ~gh_config_dir ~injected_env:[] ~env_allowlist:[ "LANG" ]
    ~connect_timeout_sec:1 ~max_concurrent_sessions:2 (guest ~cli)
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
    (Keeper_sandbox_remote.remote_keeper_root state);
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

(* The OpenSSH probe stays one shell word, because sshd hands the remote
   command to a shell. *)
let test_openssh_probe_stays_one_word () =
  let base_path = temp_dir () in
  let endpoint : Exec_ssh_endpoint.t =
    { name = "build-box"; host = "build.example"; user = "masc"; port = 22
    ; identity_file = ".masc/ssh/build-box.key"
    ; known_hosts_file = ".masc/ssh/known_hosts.d/build-box"
    ; remote_root = "/srv/masc/playground"; connect_timeout_sec = 1
    ; max_concurrent_sessions = 1; env_allowlist = []; capabilities = []; private_home = false }
  in
  match Keeper_sandbox_ssh.create ~base_path ~keeper_name:"keeper-a" ~endpoint () with
  | Error error -> fail error
  | Ok state ->
    (match List.rev (Keeper_sandbox_remote.probe_argv state) with
     | last :: _ -> check string "probe word" "masc-exec-shim --probe" last
     | [] -> fail "empty probe argv");
    check string "lane prefix" "remote_ssh"
      (Keeper_sandbox_remote.lane_prefix (Keeper_sandbox_remote.transport state))
;;

let run_request runner ?(env = [| "LANG=C" |]) ?(cwd = None) () =
  runner ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:(Some "in")
    ~argv:[ "/usr/bin/printf"; "hello" ] ~env ~cwd
;;

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
    check string "request root is the volume" remote_root request.remote_root;
    check string "raw stdin" "in" stdin;
    check (list (pair string string))
      "identity env names the mounted snapshot, then allowlisted caller env"
      [ "GH_CONFIG_DIR", gh_config_dir; "GIT_TERMINAL_PROMPT", "0"; "LANG", "C" ]
      request.env
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

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--container-stub"
  then stub_main ()
  else
    run "keeper_sandbox_remote"
      [ ( "container_exec"
        , [ test_case "transport + probe argv" `Quick test_transport_and_probe_argv
          ; test_case "probe prefers probe_prefix when present" `Quick
              test_container_exec_probe_argv_prefers_probe_prefix
          ; test_case "openssh probe stays one word" `Quick
              test_openssh_probe_stays_one_word
          ; test_case "frame, exit and injected env" `Quick
              test_frame_exit_and_injected_env
          ; test_case "the requested mode travels in the frame" `Quick
              test_the_requested_mode_travels_in_the_frame
          ; test_case "observe support is what the shim advertises" `Quick
              test_observe_support_is_what_the_shim_advertises
          ; test_case "a v2 shim is spoken to in v2" `Quick
              test_a_v2_shim_is_spoken_to_in_v2
          ; test_case "lane error codes" `Quick test_lane_error_codes
          ; test_case "preflight unreachable names the guest" `Quick
              test_preflight_unreachable_names_the_guest
          ] )
      ]
