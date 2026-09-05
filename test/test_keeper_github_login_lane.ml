(* Which machine a Keeper's GitHub device-flow login is written to.

   A stub stands in for the ssh binary: it reads the framed request off stdin,
   records it under the call it belongs to, and answers with the trailer the
   shim writes. The login case does not answer until the test has seen the
   one-time code arrive through the chunk callback, so a lane that only handed
   over its output after the process ended would fail here on a distinct exit
   code rather than pass quietly. *)

open Alcotest
open Masc

let write_all fd content =
  let bytes = Bytes.unsafe_of_string content in
  let rec loop offset =
    if offset < Bytes.length bytes
    then (
      let wrote = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      loop (offset + wrote))
  in
  loop 0
;;

let read_exact fd length =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset < length
    then (
      let got = Unix.read fd bytes offset (length - offset) in
      if got = 0 then failwith "ssh stub: truncated frame" else loop (offset + got))
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

let hostname = "github.com"
let keeper_name = "gh-lane-keeper"
let endpoint_name = "login-box"
let endpoint_remote_root = "/srv/masc/playground"

(* Pinned rather than read back off the endpoint value: this string is the
   contract the endpoint bootstrap installs and the preflight checks. *)
let expected_gh_dir = "/srv/masc/playground/gh-lane-keeper/.config/gh"
let device_code_line = "! First copy your one-time code: C3ED-117C\n"
let probe_login = "octocat"
let frame_path ~dir tag = Filename.concat dir ("frame-" ^ tag)
let observed_path ~dir = Filename.concat dir "device-code-observed"

(* Exit codes the stub mints for its own refusals, so a failure here says
   which contract broke instead of "exit 1". *)
let exit_code_never_streamed = 7
let exit_code_unexpected_argv = 64

let stub_main () =
  let dir = Sys.argv.(2) in
  let header = read_exact Unix.stdin 8 in
  let body_len = Bytes.get_int64_be (Bytes.unsafe_of_string header) 0 |> Int64.to_int in
  let frame = header ^ read_exact Unix.stdin body_len in
  let trailer exit_code =
    Exec_ssh_protocol.render_trailer
      { v = Exec_ssh_protocol.newest
      ; exit = Some exit_code
      ; signal = None
      ; timed_out = false
      ; shim_error = None
      }
  in
  match Exec_ssh_protocol.decode_request frame with
  | Error error ->
    write_all Unix.stderr ("ssh stub: " ^ error);
    exit 1
  | Ok (request, _stdin) ->
    let record tag = save (frame_path ~dir tag) frame in
    (match request.argv with
     | argv when List.equal String.equal argv (Keeper_github_identity.login_argv ~hostname)
       ->
       record "login";
       (* stderr, not stdout: measured 2026-09-03, [gh auth login] with no
          terminal writes nothing to stdout and puts the one-time code there.
          It is also the stream the result trailer shares, so this is the one
          a lane can withhold while it waits for a trailer that has not
          arrived. *)
       write_all Unix.stderr device_code_line;
       (* Wait for the code to reach the caller before this process ends. A
          lane that buffered output until exit never creates the file. *)
       let deadline = Unix.gettimeofday () +. 10.0 in
       let rec wait () =
         if Sys.file_exists (observed_path ~dir)
         then write_all Unix.stderr (trailer 0)
         else if Unix.gettimeofday () >= deadline
         then write_all Unix.stderr (trailer exit_code_never_streamed)
         else (
           ignore (Unix.select [] [] [] 0.02);
           wait ())
       in
       wait ()
     | argv
       when List.equal String.equal argv (Keeper_github_identity.auth_probe_argv ~hostname)
       ->
       record "probe";
       write_all Unix.stdout (probe_login ^ "\n");
       write_all Unix.stderr (trailer 0)
     | "mkdir" :: _ ->
       record "mkdir";
       write_all Unix.stderr (trailer 0)
     | "chmod" :: mode :: _ ->
       record ("chmod-" ^ mode);
       write_all Unix.stderr (trailer 0)
     | "find" :: rest when List.mem "-exec" rest ->
       record "find-chmod";
       write_all Unix.stderr (trailer 0)
     | "find" :: _ ->
       (* The probe for an entry that exists but is not a regular file. This
          endpoint has none, so it prints nothing and exits 0. *)
       record "find-irregular";
       write_all Unix.stderr (trailer 0)
     | argv ->
       record "unexpected";
       write_all Unix.stderr ("ssh stub: unexpected argv " ^ String.concat " " argv);
       write_all Unix.stderr (trailer exit_code_unexpected_argv));
    exit 0
;;

let shell_quote s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let temp_dir () =
  let path = Filename.temp_file "masc-gh-login-lane-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;

let install_stub ~dir =
  let script_path = Filename.concat dir "ssh" in
  save
    script_path
    (Printf.sprintf
       "#!/bin/sh\nexec %s --ssh-stub %s \"$@\"\n"
       (shell_quote Sys.executable_name)
       (shell_quote dir));
  Unix.chmod script_path 0o755;
  script_path
;;

let write_runtime_toml ~base_path =
  let path = Filename.concat base_path ".masc/config/runtime.toml" in
  Fs_compat.mkdir_p (Filename.dirname path);
  save
    path
    (Exec_ssh_endpoint.to_toml
       Exec_ssh_endpoint.
         { name = endpoint_name
         ; host = "fixture.invalid"
         ; user = "masc"
         ; port = default_port
         ; identity_file = default_identity_file ~name:endpoint_name
         ; known_hosts_file = default_known_hosts_file ~name:endpoint_name
         ; remote_root = endpoint_remote_root
         ; connect_timeout_sec = 1
         ; max_concurrent_sessions = 2
         ; env_allowlist = []
         ; capabilities = []
         ; private_home = false
         })
;;

let write_keeper_toml ~base_path =
  let path = Keeper_sandbox_config.keeper_toml_path ~base_path ~agent_name:keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  save
    path
    (Printf.sprintf
       "[keeper]\n\
        instructions = \"github login lane fixture\"\n\
        sandbox_profile = \"remote_ssh\"\n\
        remote_endpoint = %S\n"
       endpoint_name)
;;

let workspace ~base_path =
  let config = Workspace.default_config base_path in
  (* [local_lane] provisions under an existing keepers root rather than
     creating the workspace, so the fixture has to stand that root up. *)
  Fs_compat.mkdir_p (Workspace.keepers_runtime_dir config);
  config
;;

let meta ~sandbox =
  match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper_name ]) with
  | Ok fixture -> { fixture with Keeper_meta_contract.sandbox_profile = sandbox }
  | Error detail -> fail detail
;;

let with_eio f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f
;;

let with_stub_ssh ~dir f =
  let script = install_stub ~dir in
  Keeper_sandbox_ssh.For_testing.set_ssh_bin_override (Some script);
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_ssh.For_testing.set_ssh_bin_override None)
    f
;;

let status_testable =
  testable
    (fun fmt -> function
      | Unix.WEXITED code -> Format.fprintf fmt "exit %d" code
      | Unix.WSIGNALED signal -> Format.fprintf fmt "signal %d" signal
      | Unix.WSTOPPED signal -> Format.fprintf fmt "stopped %d" signal)
    ( = )
;;

let contains needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec go i =
    i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1))
  in
  go 0
;;

let decoded_request path =
  match Exec_ssh_protocol.decode_request (read_file path) with
  | Ok (request, _stdin) -> request
  | Error error -> fail error
;;

(* A Remote_ssh Keeper with no endpoint is an error, not a host login. Were it
   to fall back, the operator would see a successful login on a directory the
   Keeper's turns never read, and every turn would keep failing the endpoint's
   identity preflight. *)
let test_profile_picks_the_lane () =
  with_eio
  @@ fun () ->
  let base_path = temp_dir () in
  let config = workspace ~base_path in
  (match
     Keeper_github_login_lane.for_keeper
       ~config
       ~meta:(meta ~sandbox:Keeper_types_profile_sandbox.Docker)
       ~hostname
   with
   (* A lane is opaque closures, so [Ok] cannot be read as "the host one"
      directly. It discriminates here because this base path declares no ssh
      endpoint: had the profile routed to the remote lane, it would have failed
      to resolve one, which is exactly what the Remote_ssh case below asserts. *)
   | Ok _ -> ()
   | Error error -> failf "docker keeper built no lane: %s" error);
  (match
     Keeper_github_login_lane.for_keeper
       ~config
       ~meta:(meta ~sandbox:Keeper_types_profile_sandbox.Micro_vm)
       ~hostname
   with
   | Ok _ -> ()
   | Error error -> failf "micro_vm keeper built no lane: %s" error);
  match
    Keeper_github_login_lane.for_keeper
      ~config
      ~meta:(meta ~sandbox:Keeper_types_profile_sandbox.Remote_ssh)
      ~hostname
  with
  | Ok _ -> fail "a remote_ssh keeper with no endpoint fell back to a host login"
  | Error error ->
    check
      bool
      "the unresolved endpoint is named"
      true
      (String.starts_with ~prefix:"remote_ssh_endpoint_missing:" error)
;;

let test_remote_login_runs_and_is_observed_on_the_endpoint () =
  with_eio
  @@ fun () ->
  let base_path = temp_dir () in
  let dir = temp_dir () in
  write_runtime_toml ~base_path;
  write_keeper_toml ~base_path;
  with_stub_ssh ~dir
  @@ fun () ->
  let config = workspace ~base_path in
  match
    Keeper_github_login_lane.for_keeper
      ~config
      ~meta:(meta ~sandbox:Keeper_types_profile_sandbox.Remote_ssh)
      ~hostname
  with
  | Error error -> failf "remote lane was not built: %s" error
  | Ok lane ->
    check
      (list string)
      "the lane creates the endpoint's gh directory before logging in"
      [ "mkdir"; "-p"; expected_gh_dir ]
      (decoded_request (frame_path ~dir "mkdir")).argv;
    let streamed = Buffer.create 128 in
    let status, _stdout, _stderr =
      lane.Keeper_github_identity.run_login
        ~on_stdout_chunk:(fun _chunk -> ())
        ~on_stderr_chunk:(fun chunk ->
          Buffer.add_string streamed chunk;
          if contains "one-time code" (Buffer.contents streamed)
          then save (observed_path ~dir) "seen")
    in
    check status_testable "the endpoint login exited 0" (Unix.WEXITED 0) status;
    check
      bool
      "the one-time code reached the caller before the process ended"
      true
      (contains "C3ED-117C" (Buffer.contents streamed));
    let login = decoded_request (frame_path ~dir "login") in
    check
      (list string)
      "the endpoint runs masc's own login argv"
      (Keeper_github_identity.login_argv ~hostname)
      login.argv;
    check
      bool
      "the login sees the endpoint's gh config directory"
      true
      (List.exists
         (fun (name, value) ->
           String.equal name "GH_CONFIG_DIR" && String.equal value expected_gh_dir)
         login.env);
    check
      bool
      "no GitHub token is projected onto the endpoint"
      false
      (List.exists (fun (name, _value) -> String.equal name "GH_TOKEN") login.env);
    (match lane.Keeper_github_identity.secure_after_login () with
     | Error error -> failf "securing the endpoint identity failed: %s" error
     | Ok () ->
       (* Both names the host lane secures, and only regular files, so an
          absent one is nothing to do rather than a failed login. *)
       check
         (list string)
         "the identity files are narrowed on the endpoint"
         [ "find"
         ; expected_gh_dir
         ; "-maxdepth"
         ; "1"
         ; "("
         ; "-name"
         ; "hosts.yml"
         ; "-o"
         ; "-name"
         ; "config.yml"
         ; ")"
         ; "-type"
         ; "f"
         ; "-exec"
         ; "chmod"
         ; "0600"
         ; "{}"
         ; "+"
         ]
         (decoded_request (frame_path ~dir "find-chmod")).argv);
    (match lane.Keeper_github_identity.observe_after_login () with
     | Error error -> failf "observing the endpoint identity failed: %s" error
     | Ok observation ->
       check
         string
         "the observation names the endpoint directory"
         expected_gh_dir
         observation.Keeper_github_identity.config_dir;
       check
         (option string)
         "stored identity is the endpoint's"
         (Some probe_login)
         observation.Keeper_github_identity.stored.Keeper_github_identity.login;
       check
         (option string)
         "effective is that same reading, not a second probe"
         (Some probe_login)
         observation.Keeper_github_identity.effective.Keeper_github_identity.login;
       check
         (list string)
         "no projected token names on an endpoint"
         []
         observation.Keeper_github_identity.projected_token_env_names;
       check
         string
         "the probe is explicitly endpoint-scoped"
         "endpoint_process_only"
         (match observation.Keeper_github_identity.effective_probe_scope with
          | `Host_process_credential_only -> "host_process_credential_only"
          | `Endpoint_process_only -> "endpoint_process_only"))
;;

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--ssh-stub"
  then stub_main ()
  else
    run
      "keeper_github_login_lane"
      [ ( "lane"
        , [ test_case "sandbox profile picks the lane" `Quick test_profile_picks_the_lane
          ; test_case
              "remote login runs and is observed on the endpoint"
              `Quick
              test_remote_login_runs_and_is_observed_on_the_endpoint
          ] )
      ]
;;
