(** Tests for Keeper_sandbox_read_backend.

    RFC-0006 Phase B-2: docker-routed reads for Docker keepers.
    These tests cover the pure path-mapping and routing logic;
    the actual [docker run] call is exercised only in environments
    where docker is available, gated through env-set integration
    tests. *)

module Workspace = Masc.Workspace
module Keeper_sandbox_read_backend = Masc.Keeper_sandbox_read_backend
module Keeper_sandbox_shell_ir_target = Masc.Keeper_sandbox_shell_ir_target
module Keeper_turn_sandbox_runtime = Masc.Keeper_turn_sandbox_runtime
module Keeper_sandbox_factory = Masc.Keeper_sandbox_factory
module Keeper_types = Keeper_types
module Keeper_alerting_path = Masc.Keeper_alerting_path
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_sandbox_runtime = Masc.Keeper_sandbox_runtime
module Keeper_sandbox_remote_lane = Masc.Keeper_sandbox_remote_lane
module Keeper_sandbox_remote = Masc.Keeper_sandbox_remote
module Keeper_sandbox_microvm = Masc.Keeper_sandbox_microvm
module Keeper_microvm_backend = Masc.Keeper_microvm_backend
module Fd_accountant = Fd_accountant
module Env_config_keeper = Env_config_keeper

(* ── Helpers ─────────────────────────────────────────────────────── *)

let with_env key value f =
  let prior = try Some (Sys.getenv key) with Not_found -> None in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let temp_dir () =
  let d = Filename.temp_file "keeper_sandbox_read_backend_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with _ -> ()

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let env_file_path_from_docker_line line =
  let rec loop = function
    | "--env-file" :: path :: _ -> Some path
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop (String.split_on_char ' ' line)

let docker_spawn_in_flight () =
  let snapshot = Fd_accountant.fd_snapshot () in
  List.assoc Fd_accountant.Docker_spawn snapshot.per_kind

let wait_until ~clock ~attempts predicate =
  let rec loop remaining =
    if predicate () then true
    else if remaining <= 0 then false
    else (
      Eio.Time.sleep clock 0.001;
      loop (remaining - 1))
  in
  loop attempts

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let make_meta ~name ~sandbox =
  let json =
    `Assoc
      [
        ("name", `String name);
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m ->
    { m with Masc.Keeper_meta_contract.sandbox_profile = sandbox }
  | Error e -> Alcotest.fail e

(* ── should_route_read profile policy ────────────────────────────── *)

(* The case that answered [false] was the [Local] profile, and it is gone:
   every profile a keeper may declare routes reads through its backend. *)
let test_docker_keeper_routes () =
  let meta =
    make_meta ~name:"acme-sandbox" ~sandbox:Keeper_types_profile_sandbox.Docker
  in
  Alcotest.(check bool) "docker keeper routes through docker"
    true
    (Keeper_sandbox_read_backend.should_route_read ~meta)

let test_docker_second_keeper_routes () =
  let meta =
    make_meta ~name:"poe" ~sandbox:Keeper_types_profile_sandbox.Docker
  in
  Alcotest.(check bool) "docker second keeper also routes" true
    (Keeper_sandbox_read_backend.should_route_read ~meta)

let test_remote_ssh_keeper_routes () =
  let meta =
    make_meta ~name:"remote" ~sandbox:Keeper_types_profile_sandbox.Remote_ssh
  in
  Alcotest.(check bool) "remote SSH keeper routes through backend"
    true
    (Keeper_sandbox_read_backend.should_route_read ~meta)

(* ── container_path_of_host pure mapping ─────────────────────────── *)

let setup_config name =
  let base = temp_dir () in
  Unix.mkdir (Filename.concat base Common.masc_dirname) 0o755;
  let config = Workspace.default_config base in
  let meta =
    make_meta ~name ~sandbox:Keeper_types_profile_sandbox.Docker
  in
  base, config, meta

let with_fake_docker script f =
  let dir = temp_dir () in
  let docker_path = Filename.concat dir "docker" in
  write_file docker_path script;
  Unix.chmod docker_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) @@ fun () ->
  with_env "MASC_TEST_FAKE_DOCKER_PATH" docker_path @@ fun () ->
  with_env "PATH" path f

let with_fake_ssh script f =
  let dir = temp_dir () in
  let ssh_path = Filename.concat dir "ssh" in
  write_file ssh_path script;
  Unix.chmod ssh_path 0o755;
  Masc.Keeper_sandbox_ssh.For_testing.set_ssh_bin_override (Some ssh_path);
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_sandbox_ssh.For_testing.set_ssh_bin_override None;
      cleanup_dir dir)
    f

let fake_docker_log_path () =
  Filename.concat
    (Filename.dirname (Sys.getenv "MASC_TEST_FAKE_DOCKER_PATH"))
    "docker.log"

let test_container_path_root_maps () =
  let base, config, meta = setup_config "acme-sandbox" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let croot = Keeper_sandbox.container_root meta.name in
  match
    Keeper_sandbox_read_backend.container_path_of_host ~config ~meta
      ~host_path:host_root
  with
  | Ok mapped ->
      Alcotest.(check string) "host playground root maps to container root"
        croot mapped
  | Error e -> Alcotest.fail e

let test_container_path_nested_maps_with_suffix () =
  let base, config, meta = setup_config "acme-sandbox" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_path = Filename.concat host_root "scratch/scratch.md" in
  let croot = Keeper_sandbox.container_root meta.name in
  match
    Keeper_sandbox_read_backend.container_path_of_host ~config ~meta ~host_path
  with
  | Ok mapped ->
      Alcotest.(check string)
        "host nested path maps with suffix"
        (Filename.concat croot "scratch/scratch.md")
        mapped
  | Error e -> Alcotest.fail e

let test_container_path_outside_playground_errors () =
  let base, config, meta = setup_config "acme-sandbox" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let outside = "/etc/passwd" in
  match
    Keeper_sandbox_read_backend.container_path_of_host ~config ~meta
      ~host_path:outside
  with
  | Ok mapped ->
      Alcotest.failf
        "expected error for outside-playground path, got Ok %s" mapped
  | Error _ -> ()

(* ── Integration: read_file error paths
   (exercised without invoking docker) ──────────────────────────── *)

let test_read_outside_playground_returns_mapping_error () =
  let base, config, meta = setup_config "acme-sandbox" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.read_file ~config ~meta
      ~host_path:"/etc/passwd" ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected mapping error for /etc/passwd"
  | Error msg ->
      Alcotest.(check bool) "error mentions playground" true
        (let needle = "playground" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let test_read_missing_file_preflight_errors () =
  let base, config, meta = setup_config "acme-sandbox" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_path = Filename.concat host_root "scratch/x" in
  match
    Keeper_sandbox_read_backend.read_file ~config ~meta ~host_path
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected missing-file preflight error"
  | Error msg ->
      Alcotest.(check bool) "error mentions path_not_found" true
        (let needle = "path_not_found" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0);
      (* The preflight never ran a backend, so its tag names the sandbox
         profile the keeper actually has, not a docker program. *)
      Alcotest.(check bool) "preflight tag names the sandbox profile" true
        (String_util.contains_substring msg
           (Keeper_types_profile_sandbox.sandbox_profile_to_string
              meta.Masc.Keeper_meta_contract.sandbox_profile
            ^ "_read_failed"))

(* Read on a directory must point the keeper at a tool that actually
   exists. The old message said "use the currently exposed read/listing
   tools" without naming one; the current surface directs agents to
   Execute ls. Guards against the message regressing to a phantom-tool
   reference. *)
let test_read_directory_names_a_real_listing_tool () =
  let base, config, meta = setup_config "acme-sandbox" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let dir_path = Filename.concat host_root "scratch/somedir" in
  ensure_dir dir_path;
  match
    Keeper_sandbox_read_backend.read_file ~config ~meta ~host_path:dir_path
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected path_is_directory error for a directory"
  | Error msg ->
      Alcotest.(check bool) "error reports path_is_directory" true
        (String_util.contains_substring msg "path_is_directory");
      Alcotest.(check bool)
        "error names a real listing command"
        true
        (String_util.contains_substring msg "argv=['ls'")

(* ── run_command error paths
   (exercised without invoking docker) ──────────────────────────── *)

let test_run_command_empty_argv_errors () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command ~config ~meta
      ~command_argv:[] ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected error for empty command_argv"
  | Error msg ->
      Alcotest.(check bool) "mentions empty command_argv" true
        (let needle = "command_argv is empty" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let test_run_command_empty_image_errors () =
  let base, config, meta = setup_config "acme-sandbox" in
  let meta = { meta with sandbox_image = Some "" } in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command ~config ~meta
      ~command_argv:[ "ls"; "/" ] ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected image-config error"
  | Error msg ->
      Alcotest.(check bool) "mentions docker image" true
        (let needle = "docker image" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let test_run_command_remote_ssh_endpoint_error_before_image_guard () =
  (* A remote_ssh keeper with no endpoint declaration must see the named
     endpoint error, not the Docker empty-image complaint. *)
  let base, config, meta = setup_config "remote-ssh" in
  let meta =
    { meta with
      sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh
    ; sandbox_image = Some ""
    }
  in
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_sandbox_factory.cleanup factory;
      cleanup_dir base)
  @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command_with_status
      ~turn_sandbox_factory:factory ~config ~meta
      ~command_argv:[ "ls"; "/" ] ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected remote_ssh_endpoint_missing"
  | Error msg ->
      Alcotest.(check bool) "named read error, not image guard" true
        (let needle = "remote_ssh_endpoint_missing" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let test_run_command_rejects_factory_profile_drift_in_both_directions () =
  let base, config, docker = setup_config "read-profile-contract" in
  let remote =
    { docker with sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh }
  in
  let assert_mismatch ~factory_meta ~caller_meta =
    let factory = Keeper_sandbox_factory.create ~config ~meta:factory_meta () in
    Fun.protect
      ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
    @@ fun () ->
    match
      Keeper_sandbox_read_backend.run_command_with_status
        ~turn_sandbox_factory:factory
        ~config
        ~meta:caller_meta
        ~command_argv:[ "ls"; "/" ]
        ~max_bytes:4096
        ~timeout_sec:5.0
        ()
    with
    | Ok _ -> Alcotest.fail "profile drift reached a read backend"
    | Error message ->
      Alcotest.(check bool)
        "typed contract mismatch"
        true
        (String_util.contains_substring
           message
           "sandbox profile contract mismatch")
  in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  assert_mismatch ~factory_meta:docker ~caller_meta:remote;
  assert_mismatch ~factory_meta:remote ~caller_meta:docker

(* The refusal these tests used to pin claimed the guest was "known only to
   the turn's sandbox factory". It is not: the name below is built from the
   keeper and the base path alone, which every caller already has, and the
   guest outlives the turn that booted it. What the old test was really
   protecting -- that a microvm read never quietly becomes a Docker or host
   read -- is asserted here on the route and the endpoint instead. *)
(* Three pieces, matching the name the runtime builds: the network mode sits
   between the keeper and the base-path hash so a guest booted under one mode
   is never adopted under another. *)
let expected_guest_name ~config ~keeper_name ~network_mode =
  Printf.sprintf
    "masc-keeper-vm-%s-%s-%s"
    keeper_name
    (Keeper_types_profile_sandbox.network_mode_to_string network_mode)
    (String.sub
       (Keeper_sandbox_runtime.base_path_hash
          (config : Workspace.config).base_path)
       0
       8)

let test_microvm_without_a_turn_factory_routes_to_the_attached_guest () =
  let base, config, docker = setup_config "read-microvm-no-factory" in
  let microvm =
    { docker with sandbox_profile = Keeper_types_profile_sandbox.Micro_vm }
  in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.resolve_read_dispatch
      ~turn_sandbox_factory:None
      ~meta:microvm
      ~cwd:(Keeper_sandbox.host_root_abs_of_meta ~config microvm)
  with
  | Ok Keeper_sandbox_read_backend.Attached_guest -> ()
  | Ok Keeper_sandbox_read_backend.Docker_fallback ->
    Alcotest.fail "a microvm read fell back to Docker"
  | Ok Keeper_sandbox_read_backend.Remote_dispatch ->
    Alcotest.fail "a microvm read took the turn-owned lane without a turn"
  | Ok (Keeper_sandbox_read_backend.Turn_runtime _) ->
    Alcotest.fail "a microvm read resolved a runtime with no factory to hold it"
  | Error message ->
    Alcotest.failf "a running guest was reported unreachable: %s" message

let test_attached_guest_endpoint_names_the_derived_guest () =
  let base, config, docker = setup_config "read-microvm-attach" in
  let microvm =
    (* A backend, because attaching means building that runtime's exec argv.
       This fixture predates the field and had been declaring a microvm
       keeper with no runtime under it, which the endpoint now refuses. *)
    { docker with
      sandbox_profile = Keeper_types_profile_sandbox.Micro_vm
    ; microvm_backend = Some Keeper_microvm_backend.Apple_container
    }
  in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_remote_lane.attached_guest_endpoint ~config ~meta:microvm ()
  with
  | Error message -> Alcotest.failf "attaching to a named guest failed: %s" message
  | Ok endpoint ->
    Alcotest.(check string)
      "the guest name comes from the keeper and the base path"
      (expected_guest_name
         ~config
         ~keeper_name:microvm.name
         ~network_mode:microvm.network_mode)
      (Keeper_sandbox_remote.name endpoint);
    (match Keeper_sandbox_remote.transport endpoint with
     | Keeper_sandbox_remote.Container_exec _ -> ()
     | Keeper_sandbox_remote.Openssh _ ->
       Alcotest.fail "a microvm attach produced an SSH endpoint");
    Alcotest.(check string)
      "reads land on the guest work volume, not the host playground"
      Keeper_sandbox_microvm.work_volume_guest_root
      (Keeper_sandbox_remote.remote_root endpoint)

(* The reachable half of the same guard: attaching is reached by routing, and
   routing must not send a Docker keeper there. Its tree is a shared mount, so
   the read stays in a container over that mount. *)
let test_docker_without_a_turn_factory_still_routes_to_the_container () =
  let base, config, docker = setup_config "read-docker-no-factory" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.resolve_read_dispatch
      ~turn_sandbox_factory:None
      ~meta:docker
      ~cwd:(Keeper_sandbox.host_root_abs_of_meta ~config docker)
  with
  | Ok Keeper_sandbox_read_backend.Docker_fallback -> ()
  | Ok Keeper_sandbox_read_backend.Attached_guest ->
    Alcotest.fail "a docker read was routed to a guest attach"
  | Ok _ -> Alcotest.fail "a docker read left the shared-mount route"
  | Error message -> Alcotest.failf "a shared mount was reported unreachable: %s" message

(* Attaching is a microvm affordance, not a way around the lane for every
   profile: a Docker keeper's tree is a shared mount with no endpoint, and
   asking for one still says so. *)
let test_attached_guest_endpoint_refuses_docker () =
  let base, config, docker = setup_config "read-attach-docker" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_remote_lane.attached_guest_endpoint ~config ~meta:docker ()
  with
  | Ok _ -> Alcotest.fail "a docker keeper produced a guest endpoint"
  | Error message ->
    Alcotest.(check bool)
      "docker has no remote lane"
      true
      (String_util.contains_substring message "docker_has_no_remote_lane")

(* The trailer the fake shim writes, rendered by the same function the real
   shim renders it with. It was a hand-typed string carrying ["v":1] while
   the wire had moved to 2, and nothing caught that because the fixture sat
   on a dead path (task-888). Typing the current version in its place would
   arm the same drift for the next one -- the version, the field names and
   the framing all come from [Exec_ssh_protocol] now, so a wire change either
   updates this fixture or fails to compile.

   [printf '%%s'] rather than the trailer as a format: the renderer escapes
   what belongs to JSON, not what belongs to printf. *)
let fake_ssh_success_script =
  Printf.sprintf
    {|#!/bin/sh
cat >/dev/null 2>/dev/null &
printf 'remote-file-content'
printf '%%s' '%s' >&2
exit 0
|}
    (Exec_ssh_protocol.render_trailer
       { v = Exec_ssh_protocol.newest
       ; exit = Some 0
       ; signal = None
       ; timed_out = false
       ; shim_error = None
       })

let test_remote_ssh_read_skips_host_existence_preflight () =
  let base, config, meta = setup_config "remote-reader" in
  let meta =
    { meta with
      sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh
    }
  in
  let keepers_dir = Filename.concat base ".masc/config/keepers" in
  ensure_dir keepers_dir;
  write_file (Filename.concat keepers_dir "remote-reader.toml")
    {|[keeper]
instructions = "remote read test"
sandbox_profile = "remote_ssh"
remote_endpoint = "fixture"
|};
  (* RFC-0121: the endpoint resolver reads .masc/config/runtime.toml — the live
     layout — not the .masc root this fixture used to write to. *)
    write_file
    (Filename.concat base ".masc/config/runtime.toml")
    (* R00: derive the fixture table from the typed record via
       Exec_ssh_endpoint.to_toml, the strict decoder mirror, so the
       fixture cannot drift from what Runtime_toml accepts. *)
    (Exec_ssh_endpoint.to_toml
       Exec_ssh_endpoint.
         { name = "fixture"
         ; host = "fixture.invalid"
         ; user = "masc"
         ; port = default_port
         ; identity_file = default_identity_file ~name:"fixture"
         ; known_hosts_file = default_known_hosts_file ~name:"fixture"
         ; remote_root = "/srv/masc/playground"
         ; connect_timeout_sec = 1
         ; max_concurrent_sessions = 2
         ; env_allowlist = []
         ; capabilities = []
         ; private_home = false
         });
  let missing_host_path =
    Filename.concat
      (Keeper_sandbox.host_root_abs_of_meta ~config meta)
      "remote-only.txt"
  in
  Alcotest.(check bool) "host path intentionally absent" false
    (Sys.file_exists missing_host_path);
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "false" @@ fun () ->
  with_fake_ssh fake_ssh_success_script @@ fun () ->
  match
    Keeper_sandbox_read_backend.read_file ~config ~meta
      ~host_path:missing_host_path ~max_bytes:4096 ~timeout_sec:2.0 ()
  with
  | Error error -> Alcotest.fail error
  | Ok content ->
    Alcotest.(check string) "remote content" "remote-file-content" content

let fake_docker_exit_1_script =
  "#!/bin/sh\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"run\" ]; then\n\
  printf 'no matches\\n'\n\
  exit 1\n\
fi\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_echo_command_script =
  "#!/bin/sh\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" != \"run\" ]; then\n\
  printf 'unexpected docker invocation\\n' >&2\n\
  exit 2\n\
fi\n\
shift\n\
while [ \"$#\" -gt 0 ]; do\n\
  if [ \"$1\" = \"alpine:test\" ]; then\n\
    shift\n\
    break\n\
  fi\n\
  shift\n\
done\n\
printf '%s\\n' \"$*\"\n\
exit 0\n"

let fake_docker_slow_run_script =
  "#!/bin/sh\n\
log_file=\"$(dirname \"$0\")/docker.log\"\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"run\" ]; then\n\
  if [ -n \"$log_file\" ]; then\n\
    printf 'run-started\\n' >> \"$log_file\"\n\
  fi\n\
  sleep 0.2\n\
  printf 'slow ok\\n'\n\
  exit 0\n\
fi\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_log_run_script =
  "#!/bin/sh\n\
log_file=\"$(dirname \"$0\")/docker.log\"\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"run\" ]; then\n\
  printf 'ok\\n'\n\
  exit 0\n\
fi\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_env_dump_script =
  "#!/bin/sh\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"run\" ]; then\n\
  env > \"$(dirname \"$0\")/docker.log.env\"\n\
  printf 'ok\\n'\n\
  exit 0\n\
fi\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_turn_runtime_script =
  "#!/bin/sh\n\
log_file=\"$(dirname \"$0\")/docker.log\"\n\
state_dir=$(dirname \"$0\")\n\
state_inspect_count_file=\"$state_dir/turn-state-inspect.count\"\n\
read_count() {\n\
  if [ -f \"$1\" ]; then\n\
    cat \"$1\"\n\
  else\n\
    printf '0'\n\
  fi\n\
}\n\
write_count() {\n\
  printf '%s' \"$2\" > \"$1\"\n\
}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'runtime-container\\n'\n\
    exit 0\n\
    ;;\n\
  start)\n\
    printf 'started\\n'\n\
    exit 0\n\
    ;;\n\
  ps)\n\
    # Absent modelling: the state inspect fails and the exact-name inventory\n\
    # probe must succeed with empty output.\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    case \"$3\" in\n\
      *State.Running*)\n\
        count=$(read_count \"$state_inspect_count_file\")\n\
        count=$((count + 1))\n\
        write_count \"$state_inspect_count_file\" \"$count\"\n\
        if [ \"$count\" = \"1\" ]; then\n\
          printf 'no such container\\n' >&2\n\
          exit 1\n\
        fi\n\
        printf 'true\\n'\n\
        exit 0\n\
        ;;\n\
    esac\n\
    printf 'runtime-container-id\\n'\n\
    exit 0\n\
    ;;\n\
  exec)\n\
    case \"$*\" in\n\
      *stderr-only*)\n\
        printf 'only stderr\\n' >&2\n\
        exit 7\n\
        ;;\n\
    esac\n\
    printf 'exec ok\\n'\n\
    exit 0\n\
    ;;\n\
  rm)\n\
    printf 'removed\\n'\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_stale_streaming_retry_script =
  "#!/bin/sh\n\
log_file=\"$(dirname \"$0\")/docker.log\"\n\
inspect_count_file=${KEEPER_DOCKER_INSPECT_COUNT:-}\n\
exec_count_file=${KEEPER_DOCKER_EXEC_COUNT:-}\n\
state_inspect_count_file=\"$(dirname \"$0\")/stale-state-inspect.count\"\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
read_count() {\n\
  if [ -n \"$1\" ] && [ -f \"$1\" ]; then\n\
    cat \"$1\"\n\
  else\n\
    printf '0'\n\
  fi\n\
}\n\
write_count() {\n\
  if [ -n \"$1\" ]; then\n\
    printf '%s' \"$2\" > \"$1\"\n\
  fi\n\
}\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'runtime-container\\n'\n\
    exit 0\n\
    ;;\n\
  ps)\n\
    # The failed state inspect is followed by an exact-name inventory probe.\n\
    # Empty successful output proves that the cached container disappeared.\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    case \"$3\" in\n\
      *State.Running*)\n\
        state_count=$(read_count \"$state_inspect_count_file\")\n\
        state_count=$((state_count + 1))\n\
        write_count \"$state_inspect_count_file\" \"$state_count\"\n\
        if [ \"$state_count\" = \"1\" ]; then\n\
          printf 'no such container\\n' >&2\n\
          exit 1\n\
        fi\n\
        printf 'true\\n'\n\
        exit 0\n\
        ;;\n\
    esac\n\
    count=$(read_count \"$inspect_count_file\")\n\
    count=$((count + 1))\n\
    write_count \"$inspect_count_file\" \"$count\"\n\
    if [ \"$count\" = \"2\" ]; then\n\
      printf 'synthetic opaque state inspection failure\\n' >&2\n\
      exit 1\n\
    fi\n\
    printf 'runtime-container-id\\n'\n\
    exit 0\n\
    ;;\n\
  exec)\n\
    exec_count=$(read_count \"$exec_count_file\")\n\
    exec_count=$((exec_count + 1))\n\
    write_count \"$exec_count_file\" \"$exec_count\"\n\
    inspect_count=$(read_count \"$inspect_count_file\")\n\
    if [ \"$exec_count\" = \"2\" ] && [ \"$inspect_count\" -lt 2 ]; then\n\
      printf 'synthetic opaque exec failure\\n' >&2\n\
      exit 127\n\
    fi\n\
    printf 'exec ok\\n'\n\
    exit 0\n\
    ;;\n\
  rm)\n\
    printf 'removed\\n'\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_stopped_streaming_retry_script =
  "#!/bin/sh\n\
log_file=\"$(dirname \"$0\")/docker.log\"\n\
state_dir=$(dirname \"$0\")\n\
run_count_file=\"$state_dir/stopped-run.count\"\n\
exec_count_file=\"$state_dir/stopped-exec.count\"\n\
state_inspect_count_file=\"$state_dir/stopped-state-inspect.count\"\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
read_count() {\n\
  if [ -f \"$1\" ]; then\n\
    cat \"$1\"\n\
  else\n\
    printf '0'\n\
  fi\n\
}\n\
write_count() {\n\
  if [ -n \"$1\" ]; then\n\
    printf '%s' \"$2\" > \"$1\"\n\
  fi\n\
}\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    count=$(read_count \"$run_count_file\")\n\
    count=$((count + 1))\n\
    write_count \"$run_count_file\" \"$count\"\n\
    printf 'runtime-container\\n'\n\
    exit 0\n\
    ;;\n\
  start)\n\
    printf 'started\\n'\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    case \"$3\" in\n\
      *State.Running*)\n\
    count=$(read_count \"$state_inspect_count_file\")\n\
    count=$((count + 1))\n\
    write_count \"$state_inspect_count_file\" \"$count\"\n\
    if [ \"$count\" = \"1\" ]; then\n\
      printf 'false\\n'\n\
    else\n\
      printf 'true\\n'\n\
    fi\n\
    exit 0\n\
    ;;\n\
    esac\n\
    printf 'runtime-container-id\\n'\n\
    exit 0\n\
    ;;\n\
  exec)\n\
    exec_count=$(read_count \"$exec_count_file\")\n\
    exec_count=$((exec_count + 1))\n\
    write_count \"$exec_count_file\" \"$exec_count\"\n\
    printf 'exec ok\\n'\n\
    exit 0\n\
    ;;\n\
  rm)\n\
    printf 'removed\\n'\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_streaming_script =
  "#!/bin/sh\n\
log_file=\"$(dirname \"$0\")/docker.log\"\n\
state_dir=$(dirname \"$0\")\n\
literal_failure_count_file=\"$state_dir/literal-failure.count\"\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'runtime-container\\n'\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    case \"$3\" in\n\
      *State.Running*)\n\
        printf 'true\\n'\n\
        exit 0\n\
        ;;\n\
    esac\n\
    printf 'runtime-container-id\\n'\n\
    exit 0\n\
    ;;\n\
  exec)\n\
    case \"$*\" in\n\
      *slow-timeout*)\n\
        sleep 2\n\
        printf 'late\\n'\n\
        exit 0\n\
        ;;\n\
      *sparse-progress*)\n\
        printf 'ready\\n'\n\
        sleep 1\n\
        printf 'done\\n'\n\
        exit 0\n\
        ;;\n\
      *progress*)\n\
        printf 'progress-1\\n'\n\
        sleep 1\n\
        printf 'progress-2\\n'\n\
        sleep 1\n\
        printf 'done\\n'\n\
        exit 0\n\
        ;;\n\
      *literal-failure*)\n\
        literal_failure_count=0\n\
        if [ -f \"$literal_failure_count_file\" ]; then\n\
          literal_failure_count=$(cat \"$literal_failure_count_file\")\n\
        fi\n\
        literal_failure_count=$((literal_failure_count + 1))\n\
        printf '%s' \"$literal_failure_count\" > \"$literal_failure_count_file\"\n\
        printf 'literal failure stdout\\n'\n\
        printf 'opaque process stderr\\n' >&2\n\
        exit 127\n\
        ;;\n\
    esac\n\
    printf 'exec ok\\n'\n\
    exit 0\n\
    ;;\n\
  rm)\n\
    printf 'removed\\n'\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_preflight_ok_script =
  "#!/bin/sh\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'missing image\\n' >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'preflight must not execute product/tool inventory\\n' >&2\n\
    exit 2\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_preflight_missing_image_script =
  "#!/bin/sh\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    printf 'Error: No such image: %s\\n' \"$3\" >&2\n\
    exit 1\n\
    ;;\n\
  run)\n\
    printf 'run should not execute when image inspect fails\\n' >&2\n\
    exit 2\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_preflight_daemon_unavailable_script =
  "#!/bin/sh\n\
case \"$1\" in\n\
  info)\n\
    printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\\n' >&2\n\
    exit 1\n\
    ;;\n\
  image)\n\
    if [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
      printf '[]\\n'\n\
      exit 0\n\
    fi\n\
    printf 'unexpected image inspect\\n' >&2\n\
    exit 2\n\
    ;;\n\
  run)\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let fake_docker_preflight_image_timeout_script =
  "#!/bin/sh\n\
case \"$1\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  image)\n\
    printf 'process error: timeout after 5s\\n' >&2\n\
    exit 124\n\
    ;;\n\
  run)\n\
    printf 'run should not execute when image inspect times out\\n' >&2\n\
    exit 2\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation\\n' >&2\n\
exit 2\n"

let test_sandbox_container_label_args_include_owner_scope () =
  let args =
    Keeper_sandbox_runtime.docker_label_args
      ~base_path:"/tmp/masc"
      ~keeper_name:"min/jae"
      ~container_kind:"turn"
      ~network_label:"none" ()
  in
  let has_label value = List.mem value args in
  let has_label_prefix prefix =
    List.exists (String.starts_with ~prefix) args
  in
  Alcotest.(check bool) "component label" true
    (has_label "masc.mcp.component=keeper-sandbox");
  Alcotest.(check bool) "base path hash label" true
    (has_label_prefix "masc.mcp.base_path_hash=");
  Alcotest.(check bool) "sanitized keeper label" true
    (has_label "masc.mcp.keeper=min_jae");
  Alcotest.(check bool) "kind label" true
    (has_label "masc.mcp.kind=turn");
  Alcotest.(check bool) "owner pid label" true
    (has_label
       ("masc.mcp.owner_pid=" ^ string_of_int (Unix.getpid ())));
  Alcotest.(check bool) "started_at label" true
    (has_label_prefix "masc.mcp.started_at=");
  Alcotest.(check bool) "network label" true
    (has_label "masc.mcp.network=none")

let test_base_path_hash_relative_input_anchors_to_cwd_not_env_base () =
  let root = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir root) @@ fun () ->
  let cwd = Filename.concat root "cwd" in
  let env_base = Filename.concat root "env-base" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir env_base 0o755;
  let saved_cwd = Sys.getcwd () in
  with_env "MASC_BASE_PATH" env_base @@ fun () ->
  Fun.protect
    ~finally:(fun () -> Sys.chdir saved_cwd)
    (fun () ->
       Sys.chdir cwd;
       Alcotest.(check string)
         "relative base hash anchor"
         (Filename.concat (Unix.realpath cwd) "relative-base")
         (Keeper_sandbox_runtime.normalize_base_path_for_hash "relative-base"))

let test_sandbox_container_label_args_include_managed_ttl () =
  let args =
    Keeper_sandbox_runtime.docker_label_args
      ~ttl_sec:90.0
      ~base_path:"/tmp/masc"
      ~keeper_name:"kappa-keeper"
      ~container_kind:"managed"
      ~network_label:"inherit" ()
  in
  let has_label value = List.mem value args in
  Alcotest.(check bool) "managed kind label" true
    (has_label "masc.mcp.kind=managed");
  Alcotest.(check bool) "ttl label" true
    (has_label "masc.mcp.ttl_sec=90");
  Alcotest.(check bool) "inherit network label" true
    (has_label "masc.mcp.network=inherit")

let docker_network_args_exn mode =
  match Keeper_sandbox_runtime.docker_network_args mode with
  | Ok pair -> pair
  | Error detail -> Alcotest.failf "expected docker network args, got %s" detail
;;

let test_docker_network_args_follow_masc_policy () =
  let args_none, label_none =
    docker_network_args_exn Keeper_types_profile_sandbox.Network_none
  in
  Alcotest.(check (list string)) "network none passes docker flag"
    [ "--network"; "none" ] args_none;
  Alcotest.(check string) "network none label" "none" label_none;
  let args_inherit, label_inherit =
    docker_network_args_exn Keeper_types_profile_sandbox.Network_inherit
  in
  Alcotest.(check (list string)) "network inherit uses host network (#10431)"
    [ "--network"; "host" ] args_inherit;
  Alcotest.(check string) "network inherit label" "inherit" label_inherit

(* The listing is parsed by column, not by substring: a network whose name
   contains the policy network's must not read as it already existing, or a
   policy guest boots onto a network nobody created. *)
let network_row id = Printf.sprintf {|{"id":"%s","status":{}}|} id

let present listing =
  match Masc.Keeper_sandbox_microvm.policy_network_present ~keeper_name:"probe" ~listing with
  | Ok answer -> answer
  | Error detail -> Alcotest.failf "expected the listing to decode: %s" detail
;;

let test_the_policy_network_is_matched_by_id_not_substring () =
  let name = Masc.Keeper_sandbox_microvm.policy_network_name ~keeper_name:"probe" in
  Alcotest.(check bool) "an exact id matches" true
    (present (Printf.sprintf "[%s]" (network_row name)));
  Alcotest.(check bool) "a longer name does not" false
    (present (Printf.sprintf "[%s]" (network_row (name ^ "-staging"))));
  Alcotest.(check bool) "a name it is a suffix of does not" false
    (present (Printf.sprintf "[%s]" (network_row ("old-" ^ name))));
  Alcotest.(check bool) "an empty array does not" false (present "[]");
  Alcotest.(check bool) "and it is found beside others" true
    (present (Printf.sprintf "[%s,%s]" (network_row "default") (network_row name)))

(* Output that does not decode is an error, never "absent": reading it as
   absence drives a create against a network that may already exist, and the
   guest is then refused with a message about the wrong step. *)
let test_undecodable_output_is_an_error_not_absence () =
  List.iter
    (fun (listing, label) ->
      Alcotest.(check bool) label true
        (Result.is_error
           (Masc.Keeper_sandbox_microvm.policy_network_present ~keeper_name:"probe" ~listing)))
    [ "NETWORK  SUBNET\nmasc-egress-policy  192.168.128.0/24\n", "the human table is refused"
    ; "", "empty output is refused"
    ; "{\"id\":\"masc-egress-policy\"}", "a bare object is refused"
    ; "not json", "garbage is refused"
    ]

(* A policy guest has one route and it is the proxy. A boot that does not
   know that address would produce a guest reaching nothing with no way to
   say why, so it is refused instead -- which is the shape this lane shipped
   in and did not work. *)
let test_a_policy_boot_without_its_proxy_is_refused () =
  match
    Masc.Keeper_sandbox_microvm.network_args_for
      Masc.Keeper_microvm_backend.Apple_container
      ~dns:None
      ~keeper_name:"probe"
      ~policy_proxy:None
      Keeper_types_profile_sandbox.Network_policy
  with
  | Ok args ->
    Alcotest.failf "a policy guest booted with no proxy address: %s"
      (String.concat " " args)
  | Error detail ->
    Alcotest.(check bool) "the refusal names the missing address" true
      (String_util.contains_substring detail "proxy")

(* And with one, the guest is told where it is. Every spelling, because the
   clients do not agree on which they read. *)
let test_a_policy_boot_points_the_guest_at_its_proxy () =
  match
    Masc.Keeper_sandbox_microvm.network_args_for
      Masc.Keeper_microvm_backend.Apple_container
      ~dns:None
      ~keeper_name:"probe"
      ~policy_proxy:(Some { Masc.Keeper_sandbox_microvm.gateway = "192.168.128.1"; port = 51234 })
      Keeper_types_profile_sandbox.Network_policy
  with
  | Error detail -> Alcotest.failf "expected a policy boot, got %s" detail
  | Ok args ->
    let joined = String.concat " " args in
    Alcotest.(check bool) "attached to the host-only network" true
      (String_util.contains_substring
         joined
         (Masc.Keeper_sandbox_microvm.policy_network_name ~keeper_name:"probe"));
    Alcotest.(check bool) "with no resolver of its own" true
      (List.mem "--no-dns" args);
    List.iter
      (fun name ->
        Alcotest.(check bool) (name ^ " points at the proxy") true
          (String_util.contains_substring joined
             (name ^ "=http://192.168.128.1:51234")))
      [ "http_proxy"; "https_proxy"; "HTTP_PROXY"; "HTTPS_PROXY" ];
    (* An exception list here would be a second allowlist the proxy never
       sees and cannot record. *)
    Alcotest.(check bool) "and no NO_PROXY exception list" false
      (String_util.contains_substring joined "NO_PROXY")

(* Two keepers, two networks. A shared network plus a listener on every
   interface let a guest reach a neighbour's proxy port through the common
   gateway and go out under that keeper's allowlist, recorded as that keeper.
   Measured 2026-09-05: separate [--internal] networks get separate subnets
   and a guest on one cannot reach the other's gateway on any port. *)
let test_each_keeper_gets_its_own_policy_network () =
  let name keeper = Masc.Keeper_sandbox_microvm.policy_network_name ~keeper_name:keeper in
  Alcotest.(check bool) "two keepers do not share a network" false
    (String.equal (name "alder") (name "spruce"));
  Alcotest.(check bool) "and the name says whose it is" true
    (String_util.contains_substring (name "alder") "alder");
  (* The boot attaches the guest to its own keeper's network and no other. *)
  let args_for keeper =
    match
      Masc.Keeper_sandbox_microvm.network_args_for
        Masc.Keeper_microvm_backend.Apple_container
        ~dns:None
        ~keeper_name:keeper
        ~policy_proxy:
          (Some { Masc.Keeper_sandbox_microvm.gateway = "192.168.128.1"; port = 51234 })
        Keeper_types_profile_sandbox.Network_policy
    with
    | Ok args -> String.concat " " args
    | Error detail -> Alcotest.failf "expected a policy boot, got %s" detail
  in
  Alcotest.(check bool) "alder attaches to alder's network" true
    (String_util.contains_substring (args_for "alder") (name "alder"));
  Alcotest.(check bool) "and not to spruce's" false
    (String_util.contains_substring (args_for "alder") (name "spruce"))

(* The gateway is whatever container assigned the network, read rather than
   assumed: a compiled-in address is right until a host has a network on that
   subnet already. *)
let test_the_gateway_is_read_from_the_network () =
  Alcotest.(check (result string string)) "the inspected gateway comes through"
    (Ok "192.168.130.1")
    (Masc.Keeper_sandbox_microvm.policy_network_gateway
       ~inspect:{|[{"id":"masc-egress-policy","status":{"ipv4Gateway":"192.168.130.1"}}]|});
  List.iter
    (fun (inspect, label) ->
      Alcotest.(check bool) label true
        (Result.is_error
           (Masc.Keeper_sandbox_microvm.policy_network_gateway ~inspect)))
    [ {|[{"id":"masc-egress-policy","status":{}}]|}, "an absent gateway is an error"
    ; "[]", "an empty listing is an error"
    ; "not json", "garbage is an error"
    ]

(* Only the backend that carries the lane has a network to create. *)
let test_only_the_policy_backend_has_a_policy_network () =
  Alcotest.(check bool) "apple_container answers" true
    (match
       Masc.Keeper_sandbox_microvm.policy_network_create_argv_for
         Masc.Keeper_microvm_backend.Apple_container ~keeper_name:"probe"
     with
     | Ok argv -> List.mem "--internal" argv
     | Error _ -> false);
  List.iter
    (fun backend ->
      Alcotest.(check bool)
        (Masc.Keeper_microvm_backend.to_string backend ^ " refuses") true
        (match Masc.Keeper_sandbox_microvm.policy_network_create_argv_for backend ~keeper_name:"probe" with
         | Error _ -> true
         | Ok _ -> false))
    [ Masc.Keeper_microvm_backend.Microsandbox; Masc.Keeper_microvm_backend.Nerdctl_kata ]

(* Docker's egress boundary is unmeasured, so the policy lane refuses there
   rather than emitting args that might not close (RFC-0415). A silent
   fallback to inherit is the failure this pins. *)
let test_docker_refuses_the_policy_lane () =
  match Keeper_sandbox_runtime.docker_network_args Keeper_types_profile_sandbox.Network_policy with
  | Ok (args, label) ->
    Alcotest.failf "docker accepted the policy lane: args=[%s] label=%s"
      (String.concat " " args) label
  | Error detail ->
    Alcotest.(check bool) "the refusal names the mode and the profile" true
      (String_util.contains_substring detail "policy"
       && String_util.contains_substring detail "docker")

let test_docker_nofile_args_follow_config () =
  with_env "MASC_KEEPER_SANDBOX_NOFILE_LIMIT" "not-a-number" @@ fun () ->
  Alcotest.(check (list string)) "default nofile limit"
    [ "--ulimit"; "nofile=245760:245760" ]
    (Keeper_sandbox_runtime.docker_nofile_args ());
  with_env "MASC_KEEPER_SANDBOX_NOFILE_LIMIT" "8192" @@ fun () ->
  Alcotest.(check (list string)) "configured nofile limit"
    [ "--ulimit"; "nofile=8192:8192" ]
    (Keeper_sandbox_runtime.docker_nofile_args ());
  with_env "MASC_KEEPER_SANDBOX_NOFILE_LIMIT" "256" @@ fun () ->
  Alcotest.(check (list string)) "nofile floor"
    [ "--ulimit"; "nofile=1024:1024" ]
    (Keeper_sandbox_runtime.docker_nofile_args ())

let test_docker_masc_config_binding_pins_container_runtime_paths () =
  let base = "/tmp/masc-base" in
  let container_root = "/home/keeper/playground/acme-sandbox" in
  let expected_host_config =
    Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "config"
  in
  Alcotest.(check string)
    "host config dir"
    expected_host_config
    (Keeper_sandbox_runtime.host_masc_config_dir ~base_path:base);
  Alcotest.(check string)
    "container config dir"
    "/tmp/masc-runtime/.masc/config"
    (Keeper_sandbox_runtime.container_masc_config_dir ~container_root);
  Alcotest.(check (list string))
    "runtime env args"
    [ "--env"
    ; "MASC_BASE_PATH=/tmp/masc-runtime"
    ; "--env"
    ; "MASC_CONFIG_DIR=/tmp/masc-runtime/.masc/config"
    ]
    (Keeper_sandbox_runtime.docker_masc_runtime_env_args ~container_root);
  Alcotest.(check (list string))
    "config bind mount"
    [ "-v"
    ; expected_host_config ^ ":/tmp/masc-runtime/.masc/config:ro"
    ]
    (Keeper_sandbox_runtime.docker_masc_config_mount_args
       ~base_path:base
       ~container_root)

let test_docker_config_mount_and_env_args () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let config_root = Filename.concat base ".masc/config" in
  ensure_dir config_root;
  let container_root = "/home/keeper/playground/acme-sandbox" in
  with_env "MASC_CONFIG_DIR" "" @@ fun () ->
  Alcotest.(check string) "default host config root"
    config_root
    (Keeper_sandbox_runtime.docker_config_host_root ~base_path:base);
  Alcotest.(check (list string)) "default config mount"
    [ "-v"
    ; config_root ^ ":/tmp/masc-runtime/.masc/config:ro"
    ]
    (Keeper_sandbox_runtime.docker_config_mount_args
       ~base_path:base
       ~container_root);
  Alcotest.(check (list string)) "default config env"
    [ "--env"
    ; "MASC_BASE_PATH=/tmp/masc-runtime"
    ; "--env"
    ; "MASC_BASE_PATH_INPUT=/tmp/masc-runtime"
    ; "--env"
    ; "MASC_CONFIG_DIR=/tmp/masc-runtime/.masc/config"
    ]
    (Keeper_sandbox_runtime.docker_config_env_args
       ~base_path:base
       ~container_root);
  let override_base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir override_base) @@ fun () ->
  let override_root = Filename.concat override_base "config" in
  ensure_dir override_root;
  with_env "MASC_CONFIG_DIR" override_root @@ fun () ->
  Alcotest.(check string) "override host config root"
    override_root
    (Keeper_sandbox_runtime.docker_config_host_root ~base_path:base);
  Alcotest.(check (list string)) "override config mount"
    [ "-v"
    ; override_root ^ ":/tmp/masc-runtime/.masc/config:ro"
    ]
    (Keeper_sandbox_runtime.docker_config_mount_args
       ~base_path:base
       ~container_root)

let test_docker_failure_class_is_typed_and_serializes_stable_string () =
  let open Masc.Keeper_sandbox_runtime_classify in
  Alcotest.(check string)
    "runtime error class serializes to stable string"
    "docker_runtime_error"
    (docker_failure_class_to_string Docker_runtime_error);
  Alcotest.(check bool)
    "info classifier maps timeout output to Docker_daemon_timeout"
    true
    (match
       classify_docker_info_failure
         ~status:(Unix.WEXITED 124)
     with
     | Docker_daemon_timeout -> true
     | _ -> false)

(* Under a non-default cluster the board, task and goal stores live in
   .masc/clusters/<name>/, which is where Board_paths reads them. A mount
   rooted at .masc/ handed the container a different set of files — usually
   none, since the default-cluster copies do not exist (#28953). *)
let test_docker_workspace_state_mounts_follow_the_cluster () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_CLUSTER_NAME" "cluster-alpha" @@ fun () ->
  let default_root = Filename.concat base ".masc" in
  let cluster_root =
    Filename.concat (Filename.concat default_root "clusters") "cluster-alpha"
  in
  ensure_dir cluster_root;
  write_file (Filename.concat cluster_root "board_posts.jsonl") "";
  (* A same-named file in the default root, so a mount that ignores the cluster
     still finds something and the assertion below is about which one. *)
  ensure_dir default_root;
  write_file (Filename.concat default_root "board_posts.jsonl") "";
  let specs =
    Keeper_sandbox_runtime.docker_workspace_state_mount_specs
      ~base_path:base
      ~container_root:"/home/keeper/playground/acme-sandbox"
  in
  Alcotest.(check bool) "mounts the cluster's board posts" true
    (List.mem
       (Filename.concat cluster_root "board_posts.jsonl"
        ^ ":/tmp/masc-runtime/.masc/board_posts.jsonl:ro")
       specs);
  Alcotest.(check bool) "does not mount the default-cluster copy" false
    (List.mem
       (Filename.concat default_root "board_posts.jsonl"
        ^ ":/tmp/masc-runtime/.masc/board_posts.jsonl:ro")
       specs)
;;

let test_docker_workspace_state_mount_args_expose_safe_subset () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let masc_root = Filename.concat base ".masc" in
  ensure_dir (Filename.concat masc_root "tasks");
  write_file (Filename.concat (Filename.concat masc_root "tasks") "backlog.json") "{}";
  write_file (Filename.concat masc_root "board_posts.jsonl") "";
  ensure_dir (Filename.concat masc_root "auth");
  write_file (Filename.concat (Filename.concat masc_root "auth") "keeper.token") "secret";
  let container_root = "/home/keeper/playground/acme-sandbox" in
  let specs =
    Keeper_sandbox_runtime.docker_workspace_state_mount_specs
      ~base_path:base
      ~container_root
  in
  let tasks_host = Filename.concat masc_root "tasks" in
  let board_host = Filename.concat masc_root "board_posts.jsonl" in
  Alcotest.(check bool) "mounts tasks under runtime .masc" true
    (List.mem
       (tasks_host ^ ":/tmp/masc-runtime/.masc/tasks:ro")
       specs);
  Alcotest.(check bool) "does not mount tasks at host absolute target" false
    (List.mem (tasks_host ^ ":" ^ tasks_host ^ ":ro") specs);
  Alcotest.(check bool) "mounts board posts" true
    (List.mem
       (board_host ^ ":/tmp/masc-runtime/.masc/board_posts.jsonl:ro")
       specs);
  Alcotest.(check bool) "all targets stay under runtime .masc" true
    (List.for_all
       (fun spec ->
         match String.split_on_char ':' spec with
         | [ _source; target; "ro" ] ->
           String.starts_with ~prefix:"/tmp/masc-runtime/.masc/" target
         | _ -> false)
       specs);
  Alcotest.(check bool) "no targets nested under playground bind mount" true
    (List.for_all
       (fun spec ->
         match String.split_on_char ':' spec with
         | [ _source; target; "ro" ] ->
           not (String.starts_with ~prefix:(container_root ^ "/") target)
         | _ -> false)
       specs);
  Alcotest.(check bool) "does not mount auth" false
    (List.exists (fun spec -> String_util.contains_substring spec "/auth/") specs)

let test_docker_preflight_reports_ready_image () =
  with_fake_docker fake_docker_preflight_ok_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  match Keeper_sandbox_runtime.docker_preflight ~timeout_sec:5.0 () with
  | None -> Alcotest.fail "expected docker preflight report"
  | Some preflight ->
    Alcotest.(check bool) "preflight ok" true preflight.ok;
    Alcotest.(check bool) "image present" true preflight.image_present;
    Alcotest.(check (list string)) "no failure classes" []
      preflight.failure_classes;
    let json = Keeper_sandbox_runtime.docker_preflight_to_yojson preflight in
    Alcotest.(check bool)
      "no product command inventory"
      true
      Yojson.Safe.Util.(member "required_commands" json = `Null);
    Alcotest.(check bool)
      "no missing command admission field"
      true
      Yojson.Safe.Util.(member "missing_commands" json = `Null)

let test_docker_preflight_surfaces_image_inspect_error () =
  with_fake_docker fake_docker_preflight_missing_image_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "missing:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  match Keeper_sandbox_runtime.docker_preflight ~timeout_sec:5.0 () with
  | None -> Alcotest.fail "expected docker preflight report"
  | Some preflight ->
      Alcotest.(check bool) "preflight fails" false preflight.ok;
      Alcotest.(check bool) "image unavailable" false preflight.image_present;
      Alcotest.(check bool) "failure class is image_inspect_error" true
        (List.mem "image_inspect_error" preflight.failure_classes);
      Alcotest.(check bool) "failure class is not image timeout" false
        (List.mem "image_inspect_timeout" preflight.failure_classes);
      Alcotest.(check (list string))
        "next action preserves the generic inspect boundary"
        [ "Inspect the configured Docker image and daemon using the exact command output above." ]
        preflight.next_actions

let test_docker_preflight_does_not_infer_daemon_state_from_stderr () =
  with_fake_docker fake_docker_preflight_daemon_unavailable_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  match Keeper_sandbox_runtime.docker_preflight ~timeout_sec:5.0 () with
  | None -> Alcotest.fail "expected docker preflight report"
  | Some preflight ->
      Alcotest.(check bool) "preflight fails" false preflight.ok;
      Alcotest.(check bool) "failure class is generic runtime error" true
        (List.mem "docker_runtime_error" preflight.failure_classes);
      Alcotest.(check bool) "stderr does not create daemon semantic class" false
        (List.mem "docker_daemon_unavailable" preflight.failure_classes)

let test_docker_preflight_classifies_image_inspect_timeout () =
  with_fake_docker fake_docker_preflight_image_timeout_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  match Keeper_sandbox_runtime.docker_preflight ~timeout_sec:5.0 () with
  | None -> Alcotest.fail "expected docker preflight report"
  | Some preflight ->
      Alcotest.(check bool) "preflight fails" false preflight.ok;
      Alcotest.(check bool) "image absent after timeout" false preflight.image_present;
      Alcotest.(check bool) "failure class is image inspect timeout" true
        (List.mem "image_inspect_timeout" preflight.failure_classes);
      Alcotest.(check bool) "not misclassified as image missing" false
        (List.mem "image_missing" preflight.failure_classes)

let test_run_command_nonzero_exit_errors_by_default () =
  with_fake_docker fake_docker_exit_1_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command_with_status ~config ~meta
      ~command_argv:[ "rg"; "needle"; "/home/keeper/playground/demo.txt" ]
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok (_st, _out) ->
      Alcotest.fail "expected exit=1 docker command to error by default"
  | Error msg ->
      Alcotest.(check bool) "error preserves exit code" true
        (let needle = "exit=1" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let test_run_command_allows_configured_nonzero_exit () =
  with_fake_docker fake_docker_exit_1_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command_with_status
      ~ok_exit_codes:[ 0; 1 ] ~config ~meta
      ~command_argv:[ "rg"; "needle"; "/home/keeper/playground/demo.txt" ]
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Error msg ->
      Alcotest.failf "expected exit=1 to be allowed for rg, got %s" msg
  | Ok (st, out) ->
      Alcotest.(check (pair string int)) "preserves rg no-match status"
        ("exit", 1)
        (match st with
         | Unix.WEXITED code -> ("exit", code)
         | Unix.WSIGNALED code -> ("signaled", code)
         | Unix.WSTOPPED code -> ("stopped", code));
      Alcotest.(check string) "preserves stdout on allowed exit"
        "no matches\n" out

let test_run_command_preserves_bare_command_argv () =
  with_fake_docker fake_docker_echo_command_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command_with_status ~config ~meta
      ~command_argv:
        [ "head"; "-n"; "1"; "/home/keeper/playground/acme-sandbox/scratch/demo.txt" ]
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Error msg ->
      Alcotest.failf "expected bare command argv echo, got %s" msg
  | Ok (st, out) ->
      Alcotest.(check (pair string int)) "echo script exits cleanly"
        ("exit", 0)
        (match st with
         | Unix.WEXITED code -> ("exit", code)
         | Unix.WSIGNALED code -> ("signaled", code)
         | Unix.WSTOPPED code -> ("stopped", code));
      Alcotest.(check string) "preserves bare head argv"
        "head -n 1 /home/keeper/playground/acme-sandbox/scratch/demo.txt\n" out

let test_run_command_fallback_uses_docker_spawn_slot ~clock () =
  with_fake_docker fake_docker_slow_run_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let log_path = fake_docker_log_path () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let result = ref None in
  Eio.Switch.run (fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
          result :=
            Some
              (Keeper_sandbox_read_backend.run_command_with_status
                 ~config ~meta
                 ~command_argv:
                   [ "cat"; "/home/keeper/playground/acme-sandbox/scratch/demo.txt" ]
                 ~max_bytes:4096 ~timeout_sec:5.0 ()));
      let run_started () =
        Sys.file_exists log_path
        && String_util.contains_substring (read_file log_path) "run-started"
      in
      Alcotest.(check bool)
        "fallback docker run holds Docker_spawn slot after run starts"
        true
        (wait_until ~clock ~attempts:300 (fun () ->
             run_started () && docker_spawn_in_flight () > 0)));
  (match !result with
   | None -> Alcotest.fail "expected docker read command result"
   | Some (Error msg) ->
       Alcotest.failf "expected docker read command success, got %s" msg
   | Some (Ok (st, out)) ->
       Alcotest.(check (pair string int)) "slow docker exits cleanly"
         ("exit", 0)
         (match st with
          | Unix.WEXITED code -> ("exit", code)
          | Unix.WSIGNALED code -> ("signaled", code)
          | Unix.WSTOPPED code -> ("stopped", code));
       Alcotest.(check string) "slow docker stdout" "slow ok\n" out);
   Alcotest.(check int) "Docker_spawn slot released" 0
     (docker_spawn_in_flight ())

let test_run_command_projects_keeper_secret_dir () =
  with_fake_docker fake_docker_log_run_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let log_path = fake_docker_log_path () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let secret_root =
    Filename.concat
      (Filename.concat (Filename.concat base Common.masc_dirname) "secrets")
      (Workspace_utils.safe_filename meta.name)
  in
  let token_path = Filename.concat (Filename.concat secret_root "env") "GH_TOKEN" in
  let ssh_path =
    Filename.concat
      (Filename.concat secret_root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  ensure_dir (Filename.dirname token_path);
  ensure_dir (Filename.dirname ssh_path);
  write_file token_path "projected-token\n";
  write_file ssh_path "PRIVATE KEY";
  match
    Keeper_sandbox_read_backend.run_command_with_status
      ~config
      ~meta
      ~command_argv:[ "echo"; "hello" ]
      ~max_bytes:4096
      ~timeout_sec:5.0
      ()
  with
  | Error msg -> Alcotest.failf "expected success, got %s" msg
  | Ok (_st, _out) ->
    let line = read_file log_path in
    Alcotest.(check bool) "projected raw token not in docker argv" false
      (String_util.contains_substring line "projected-token");
    Alcotest.(check bool) "projected env uses env-file" true
      (String_util.contains_substring line "--env-file ");
    Alcotest.(check bool) "projected file mounted read-only" true
      (String_util.contains_substring line (ssh_path ^ ":/home/keeper/.ssh/id_ed25519:ro"));
    (match env_file_path_from_docker_line line with
     | None -> Alcotest.fail "missing --env-file path in docker log"
     | Some env_file ->
       Alcotest.(check bool) "env-file cleaned after docker run" false
         (Sys.file_exists env_file))

let test_run_command_scrubs_sensitive_env () =
  with_fake_docker fake_docker_env_dump_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "GH_TOKEN" "ghp_secret" @@ fun () ->
  with_env "ANTHROPIC_API_KEY" "sk-ant-secret" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let log_path = fake_docker_log_path () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_sandbox_read_backend.run_command_with_status ~config ~meta
      ~command_argv:[ "echo"; "hello" ]
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Error msg -> Alcotest.failf "expected success, got %s" msg
  | Ok (_st, _out) ->
      let env_dump_path = log_path ^ ".env" in
      let env_dump = read_file env_dump_path in
      Alcotest.(check bool) "GH_TOKEN scrubbed" false
        (String_util.contains_substring env_dump "GH_TOKEN=");
      Alcotest.(check bool) "ANTHROPIC_API_KEY scrubbed" false
        (String_util.contains_substring env_dump "ANTHROPIC_API_KEY=")

let test_turn_runtime_reuses_single_container () =
  with_fake_docker fake_docker_turn_runtime_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let log_path = fake_docker_log_path () in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_sandbox_factory.cleanup factory;
    cleanup_dir base) @@ fun () ->
  let run_once () =
    match
      Keeper_sandbox_read_backend.run_command_with_status
        ~turn_sandbox_factory:factory
        ~config ~meta
        ~command_argv:[ "cat"; "/home/keeper/playground/acme-sandbox/scratch/demo.txt" ]
        ~max_bytes:4096 ~timeout_sec:5.0 ()
    with
    | Error msg -> Alcotest.failf "expected turn runtime command success, got %s" msg
    | Ok (st, out) ->
        Alcotest.(check (pair string int)) "runtime exec exits cleanly"
          ("exit", 0)
          (match st with
           | Unix.WEXITED code -> ("exit", code)
           | Unix.WSIGNALED code -> ("signaled", code)
           | Unix.WSTOPPED code -> ("stopped", code));
        Alcotest.(check string) "runtime exec output preserved" "exec ok\n" out
  in
  run_once ();
  run_once ();
  Keeper_sandbox_factory.cleanup factory;
  let lines =
    read_file log_path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  let count prefix =
    List.fold_left
      (fun acc line ->
        if String.starts_with ~prefix line then acc + 1 else acc)
      0 lines
  in
  Alcotest.(check int) "docker run happens once" 1 (count "run -d ");
  Alcotest.(check int) "docker exec happens twice" 2 (count "exec ");
  (* The container is keeper-lifetime: turn cleanup drops the handle without
     a docker rm, so the second command adopts the container the first one
     created and nothing is removed. *)
  Alcotest.(check int) "docker rm never happens" 0 (count "rm -f ");
  let container_root = Keeper_sandbox.container_root meta.name in
  let container_config_dir =
    Keeper_sandbox_runtime.container_masc_config_dir ~container_root
  in
  let run_line =
    lines
    |> List.find_opt (fun line -> String.starts_with ~prefix:"run -d " line)
    |> Option.value ~default:""
  in
  let exec_line =
    lines
    |> List.find_opt (fun line -> String.starts_with ~prefix:"exec " line)
    |> Option.value ~default:""
  in
  Alcotest.(check bool) "turn run mounts config read-only" true
    (String_util.contains_substring
       run_line
       (host_config_dir ^ ":" ^ container_config_dir ^ ":ro"));
  Alcotest.(check bool) "turn run pins MASC_CONFIG_DIR" true
    (String_util.contains_substring run_line ("MASC_CONFIG_DIR=" ^ container_config_dir));
  Alcotest.(check bool) "turn exec pins MASC_CONFIG_DIR" true
    (String_util.contains_substring exec_line ("MASC_CONFIG_DIR=" ^ container_config_dir))

let test_typed_guest_target_leaves_image_preflight_to_runtime_creation () =
  with_fake_docker fake_docker_turn_runtime_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "typed-target-preflight" in
  let log_path = fake_docker_log_path () in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir host_root;
  ensure_dir (Filename.concat (Filename.concat base Common.masc_dirname) "config");
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_sandbox_factory.cleanup factory;
      cleanup_dir base)
  @@ fun () ->
  let run_once () =
    let binding =
      match Keeper_sandbox_factory.resolve factory ~cwd:host_root with
      | Runtime binding -> binding
      | No_factory -> Alcotest.fail "expected a guest runtime"
      | Remote_ssh_profile -> Alcotest.fail "expected Docker, not remote SSH"
    in
    match
      Keeper_sandbox_shell_ir_target.guest_target
        ~binding
        ~meta
        ~cwd:host_root
        ~timeout_sec:60.0
        ~base_path:base
        ()
    with
    | Error error -> Alcotest.fail error.message
    | Ok { target = Masc_exec.Sandbox_target.Docker { runner; _ }; _ } ->
      let status, _stdout, stderr =
        runner
          ~on_stdout_chunk:None
          ~on_stderr_chunk:None
          ~stdin_content:None
          ~argv:[ "true" ]
          ~env:[||]
          ~cwd:None
      in
      (match status with
       | Unix.WEXITED 0 -> ()
       | _ -> Alcotest.failf "typed target execution failed: %s" stderr)
    | Ok _ -> Alcotest.fail "Docker factory produced a non-Docker target"
  in
  run_once ();
  run_once ();
  let image_inspects =
    read_file log_path
    |> String.split_on_char '\n'
    |> List.filter (String.starts_with ~prefix:"image inspect alpine:test")
    |> List.length
  in
  Alcotest.(check int)
    "only runtime creation inspects the image"
    1
    image_inspects

let test_streaming_exec_validates_cached_container_before_retry () =
  with_fake_docker fake_docker_stale_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let inspect_count_path = Filename.concat base "inspect.count" in
  let exec_count_path = Filename.concat base "exec.count" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  with_env "KEEPER_DOCKER_INSPECT_COUNT" inspect_count_path @@ fun () ->
  with_env "KEEPER_DOCKER_EXEC_COUNT" exec_count_path @@ fun () ->
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/first" ]
   with
   | Error msg -> Alcotest.failf "expected initial exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out, _) ->
       Alcotest.(check string) "initial exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected initial exec exit 0");
  let stderr_chunks = ref [] in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~on_stderr_chunk:(fun chunk -> stderr_chunks := chunk :: !stderr_chunks)
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/second" ]
   with
   | Error msg -> Alcotest.failf "expected retried exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out, _) ->
       Alcotest.(check string) "retried exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected retried exec exit 0");
  let streamed_stderr = String.concat "" (List.rev !stderr_chunks) in
  Alcotest.(check bool)
    "stale container error is not streamed"
    false
    (String_util.contains_substring streamed_stderr "synthetic opaque state inspection failure")

let test_streaming_exec_preserves_split_stderr () =
  with_fake_docker fake_docker_turn_runtime_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  match
    Keeper_turn_sandbox_runtime.run_exec_with_status_split
      ~on_stdout_chunk:(fun chunk -> stdout_chunks := chunk :: !stdout_chunks)
      ~on_stderr_chunk:(fun chunk -> stderr_chunks := chunk :: !stderr_chunks)
      ~timeout_sec:5.0
      runtime
      ~cwd:host_root
      ~command_argv:[ "stderr-only" ]
  with
  | Error msg -> Alcotest.failf "expected split exec result, got %s" msg
  | Ok (Unix.WEXITED 7, stdout, stderr) ->
      Alcotest.(check string) "split stdout stays empty" "" stdout;
      Alcotest.(check string) "split stderr is preserved" "only stderr\n" stderr;
      Alcotest.(check string)
        "stdout callback stays empty"
        ""
        (String.concat "" (List.rev !stdout_chunks));
      Alcotest.(check string)
        "stderr callback receives stderr"
        "only stderr\n"
      (String.concat "" (List.rev !stderr_chunks))
  | Ok _ -> Alcotest.fail "expected stderr-only exec exit 7"

let test_streaming_exec_forwards_timeout_to_split_exec () =
  with_fake_docker fake_docker_streaming_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let start = Unix.gettimeofday () in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~timeout_sec:0.2
       runtime
       ~cwd:host_root
       ~command_argv:[ "slow-timeout" ]
   with
   | Error msg -> Alcotest.failf "expected split timeout result, got %s" msg
   | Ok (Unix.WEXITED 124, stdout, stderr) ->
       Alcotest.(check string) "timeout stdout" "" stdout;
       Alcotest.(check bool)
         "timeout stderr surfaced"
         true
         (String_util.contains_substring stderr "timeout after")
   | Ok _ -> Alcotest.fail "expected split exec timeout exit 124");
  let elapsed = Unix.gettimeofday () -. start in
  Alcotest.(check bool)
    "split exec timeout uses caller budget"
    true
    (elapsed < 1.5)

let test_streaming_pipeline_forwards_timeout_to_split_exec () =
  with_fake_docker fake_docker_streaming_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let stdout_chunks = ref [] in
  let start = Unix.gettimeofday () in
  (match
     Keeper_turn_sandbox_runtime.run_exec_pipeline_with_status
       ~on_stdout_chunk:(fun chunk -> stdout_chunks := chunk :: !stdout_chunks)
       ~timeout_sec:0.2
       runtime
       ~cwd:host_root
       ~stages:
         [ { Keeper_turn_sandbox_runtime.command_argv = [ "slow-timeout" ]
           ; cwd = None
           }
         ; { command_argv = [ "slow-timeout" ]; cwd = None }
         ]
   with
   | Error msg -> Alcotest.failf "expected pipeline timeout result, got %s" msg
   | Ok (Unix.WEXITED 124, stdout, stderr) ->
       Alcotest.(check string) "pipeline timeout stdout" "" stdout;
       Alcotest.(check bool)
         "pipeline timeout stderr surfaced"
         true
         (String_util.contains_substring stderr "timeout after")
   | Ok _ -> Alcotest.fail "expected pipeline timeout exit 124");
  let elapsed = Unix.gettimeofday () -. start in
  Alcotest.(check string)
    "pipeline timeout callback stdout"
    ""
    (String.concat "" (List.rev !stdout_chunks));
  Alcotest.(check bool)
    "split pipeline timeout uses caller budget"
    true
    (elapsed < 1.5)

let test_streaming_exec_restarts_stopped_container_before_exec () =
  with_fake_docker fake_docker_stopped_streaming_retry_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/first" ]
   with
   | Error msg -> Alcotest.failf "expected initial exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out, _) ->
       Alcotest.(check string) "initial exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected initial exec exit 0");
  let stderr_chunks = ref [] in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~on_stderr_chunk:(fun chunk -> stderr_chunks := chunk :: !stderr_chunks)
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "cat"; "/tmp/second" ]
   with
   | Error msg -> Alcotest.failf "expected restarted exec success, got %s" msg
   | Ok (Unix.WEXITED 0, out, _) ->
       Alcotest.(check string) "restarted exec output" "exec ok\n" out
   | Ok _ -> Alcotest.fail "expected restarted exec exit 0");
  let streamed_stderr = String.concat "" (List.rev !stderr_chunks) in
  Alcotest.(check bool)
    "stopped container error is not streamed"
    false
    (String_util.contains_substring streamed_stderr "synthetic opaque stopped-container exec failure")

let test_streaming_exec_surfaces_process_failure_once () =
  with_fake_docker fake_docker_streaming_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let count_path =
    Filename.concat
      (Filename.dirname (Sys.getenv "MASC_TEST_FAKE_DOCKER_PATH"))
      "literal-failure.count"
  in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~on_stdout_chunk:(fun chunk -> stdout_chunks := chunk :: !stdout_chunks)
       ~on_stderr_chunk:(fun chunk -> stderr_chunks := chunk :: !stderr_chunks)
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "literal-failure" ]
   with
   | Error msg -> Alcotest.failf "expected exact process result, got %s" msg
   | Ok (Unix.WEXITED 127, stdout, stderr) ->
       Alcotest.(check string) "exact stdout" "literal failure stdout\n" stdout;
       Alcotest.(check string) "exact stderr" "opaque process stderr\n" stderr
   | Ok _ -> Alcotest.fail "expected literal failure exit 127");
  let streamed_stdout = String.concat "" (List.rev !stdout_chunks) in
  let streamed_stderr = String.concat "" (List.rev !stderr_chunks) in
  Alcotest.(check string)
    "callback receives exact stdout"
    "literal failure stdout\n"
    streamed_stdout;
  Alcotest.(check string)
    "callback receives exact stderr"
    "opaque process stderr\n"
    streamed_stderr;
  let literal_failure_invocations = read_file count_path |> int_of_string in
  Alcotest.(check int) "subprocess invoked once" 1 literal_failure_invocations

let test_streaming_exec_keeps_successful_progress_live () =
  with_fake_docker fake_docker_streaming_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let start = Unix.gettimeofday () in
  let first_stdout_at = ref None in
  let stdout_chunks = ref [] in
  (match
     Keeper_turn_sandbox_runtime.run_exec_with_status_split
       ~on_stdout_chunk:(fun chunk ->
         if Option.is_none !first_stdout_at
         then first_stdout_at := Some (Unix.gettimeofday () -. start);
         stdout_chunks := chunk :: !stdout_chunks)
       ~timeout_sec:5.0
       runtime
       ~cwd:host_root
       ~command_argv:[ "progress" ]
   with
   | Error msg -> Alcotest.failf "expected progress exec success, got %s" msg
   | Ok (Unix.WEXITED 0, stdout, stderr) ->
       Alcotest.(check string)
         "progress stdout"
         "progress-1\nprogress-2\ndone\n"
         stdout;
       Alcotest.(check string) "progress stderr" "" stderr
   | Ok _ -> Alcotest.fail "expected progress exec exit 0");
  let elapsed = Unix.gettimeofday () -. start in
  let first_stdout_at =
    match !first_stdout_at with
    | Some at -> at
    | None -> Alcotest.fail "expected progress stdout callback"
  in
  Alcotest.(check string)
    "progress callback stdout"
    "progress-1\nprogress-2\ndone\n"
    (String.concat "" (List.rev !stdout_chunks));
  Alcotest.(check bool)
    "progress callback arrives before command completion"
    true
    (first_stdout_at < elapsed -. 0.5)

let test_streaming_exec_keeps_sparse_progress_live () =
  with_fake_docker fake_docker_streaming_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let host_config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir host_root;
  ensure_dir host_config_dir;
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_turn_sandbox_runtime.cleanup runtime;
    cleanup_dir base) @@ fun () ->
  let start = Unix.gettimeofday () in
  let first_stdout_at = Atomic.make None in
  let callback_on_turn_switch = ref [] in
  let stdout_chunks = ref [] in
  let stdout_mu = Stdlib.Mutex.create () in
  Eio.Switch.run (fun turn_sw ->
    Eio_context.with_turn_switch turn_sw (fun () ->
      match
        Keeper_turn_sandbox_runtime.run_exec_with_status_split
          ~on_stdout_chunk:(fun chunk ->
            if Option.is_none (Atomic.get first_stdout_at)
            then Atomic.set first_stdout_at (Some (Unix.gettimeofday () -. start));
            let saw_turn_switch =
              match Eio_context.get_switch_opt () with
              | Some sw -> sw == turn_sw
              | None -> false
            in
            Stdlib.Mutex.protect stdout_mu (fun () ->
              callback_on_turn_switch := saw_turn_switch :: !callback_on_turn_switch;
              stdout_chunks := chunk :: !stdout_chunks))
          ~timeout_sec:5.0
          runtime
          ~cwd:host_root
          ~command_argv:[ "sparse-progress" ]
      with
      | Error msg ->
        Alcotest.failf "expected sparse progress exec success, got %s" msg
      | Ok (Unix.WEXITED 0, stdout, stderr) ->
        Alcotest.(check string) "sparse progress stdout" "ready\ndone\n" stdout;
        Alcotest.(check string) "sparse progress stderr" "" stderr
      | Ok _ -> Alcotest.fail "expected sparse progress exec exit 0"));
  let elapsed = Unix.gettimeofday () -. start in
  let first_stdout_at =
    match Atomic.get first_stdout_at with
    | Some at -> at
    | None -> Alcotest.fail "expected sparse progress stdout callback"
  in
  let streamed_stdout =
    Stdlib.Mutex.protect stdout_mu (fun () ->
      String.concat "" (List.rev !stdout_chunks))
  in
  let callback_on_turn_switch =
    Stdlib.Mutex.protect stdout_mu (fun () -> List.rev !callback_on_turn_switch)
  in
  Alcotest.(check string)
    "sparse progress callback stdout"
    "ready\ndone\n"
    streamed_stdout;
  Alcotest.(check bool)
    "sparse progress callback keeps turn switch"
    true
    (List.for_all Fun.id callback_on_turn_switch);
  Alcotest.(check bool)
    "single sparse progress callback arrives before command completion"
    true
    (first_stdout_at < elapsed -. 0.2)

let test_default_fs_hardening_helpers () =
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "false" @@ fun () ->
  Alcotest.(check (list string)) "default helper keeps read-only rootfs"
    [ "--read-only" ]
    (Env_config_sandbox.Hardening.read_only_rootfs_args ());
  Alcotest.(check bool) "default helper keeps tmpfs noexec" true
    (String_util.contains_substring
       (Env_config_sandbox.Hardening.tmpfs_mount ())
       "/tmp:rw,nosuid,nodev,noexec,size=")

let test_relaxed_fs_helpers () =
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "true" @@ fun () ->
  Alcotest.(check (list string)) "relaxed helper drops read-only rootfs"
    [] (Env_config_sandbox.Hardening.read_only_rootfs_args ());
  Alcotest.(check bool) "relaxed helper drops tmpfs noexec" false
    (String_util.contains_substring
       (Env_config_sandbox.Hardening.tmpfs_mount ())
       "/tmp:rw,nosuid,nodev,noexec,size=");
  Alcotest.(check bool) "relaxed helper keeps writable tmpfs mount" true
    (String_util.contains_substring
       (Env_config_sandbox.Hardening.tmpfs_mount ())
       "/tmp:rw,nosuid,nodev,size=")

let test_turn_runtime_relaxed_fs_omits_readonly_and_noexec () =
  with_fake_docker fake_docker_turn_runtime_script @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "true" @@ fun () ->
  let base, config, meta = setup_config "acme-sandbox" in
  let log_path = fake_docker_log_path () in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir host_root;
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect ~finally:(fun () ->
    Keeper_sandbox_factory.cleanup factory;
    cleanup_dir base) @@ fun () ->
  (match
     Keeper_sandbox_read_backend.run_command_with_status
       ~turn_sandbox_factory:factory
       ~config ~meta
       ~command_argv:[ "cat"; "/home/keeper/playground/acme-sandbox/scratch/demo.txt" ]
       ~max_bytes:4096 ~timeout_sec:5.0 ()
   with
   | Error msg -> Alcotest.failf "expected turn runtime command success, got %s" msg
   | Ok _ -> ());
  Keeper_sandbox_factory.cleanup factory;
  let run_line =
    read_file log_path
    |> String.split_on_char '\n'
    |> List.find_opt (fun line -> String.starts_with ~prefix:"run -d " line)
  in
  match run_line with
  | None -> Alcotest.fail "expected docker run log line"
  | Some line ->
      Alcotest.(check bool) "relaxed runtime drops read-only rootfs" false
        (String_util.contains_substring line "--read-only");
      Alcotest.(check bool) "relaxed runtime drops tmpfs noexec" false
        (String_util.contains_substring line "/tmp:rw,nosuid,nodev,noexec,size=");
      Alcotest.(check bool) "relaxed runtime keeps tmpfs mount" true
        (String_util.contains_substring line "/tmp:rw,nosuid,nodev,size=")

let run_tests ~clock () =
  Alcotest.run "Keeper_sandbox_read_backend"
    [
      ( "should_route_read",
        [
          Alcotest.test_case "docker keeper routes" `Quick
            test_docker_keeper_routes;
          Alcotest.test_case "docker second keeper also routes" `Quick
            test_docker_second_keeper_routes;
          Alcotest.test_case "remote SSH keeper routes" `Quick
            test_remote_ssh_keeper_routes;
        ] );
      ( "container_path_of_host",
        [
          Alcotest.test_case "docker network args follow policy" `Quick
            test_docker_network_args_follow_masc_policy;
          Alcotest.test_case "docker refuses the policy lane" `Quick
            test_docker_refuses_the_policy_lane;
          Alcotest.test_case "the policy network is matched by id not substring" `Quick
            test_the_policy_network_is_matched_by_id_not_substring;
          Alcotest.test_case "undecodable output is an error not absence" `Quick
            test_undecodable_output_is_an_error_not_absence;
          Alcotest.test_case "only the policy backend has a policy network" `Quick
            test_only_the_policy_backend_has_a_policy_network;
          Alcotest.test_case "a policy boot without its proxy is refused" `Quick
            test_a_policy_boot_without_its_proxy_is_refused;
          Alcotest.test_case "a policy boot points the guest at its proxy" `Quick
            test_a_policy_boot_points_the_guest_at_its_proxy;
          Alcotest.test_case "the gateway is read from the network" `Quick
            test_the_gateway_is_read_from_the_network;
          Alcotest.test_case "each keeper gets its own policy network" `Quick
            test_each_keeper_gets_its_own_policy_network;
          Alcotest.test_case "docker nofile args follow config" `Quick
            test_docker_nofile_args_follow_config;
          Alcotest.test_case "docker MASC config binding pins paths" `Quick
            test_docker_masc_config_binding_pins_container_runtime_paths;
          Alcotest.test_case "docker config mount and env args" `Quick
            test_docker_config_mount_and_env_args;
          Alcotest.test_case "docker failure class is typed and serializes stable string" `Quick
            test_docker_failure_class_is_typed_and_serializes_stable_string;
          Alcotest.test_case "docker workspace state mount exposes safe subset" `Quick
            test_docker_workspace_state_mount_args_expose_safe_subset;
          Alcotest.test_case "docker-workspace-state-mounts-follow-the-cluster" `Quick
            test_docker_workspace_state_mounts_follow_the_cluster;
          Alcotest.test_case "managed label args include ttl" `Quick
            test_sandbox_container_label_args_include_managed_ttl;
          Alcotest.test_case "sandbox label args include owner scope" `Quick
            test_sandbox_container_label_args_include_owner_scope;
          Alcotest.test_case "relative base hash anchors to cwd" `Quick
            test_base_path_hash_relative_input_anchors_to_cwd_not_env_base;
          Alcotest.test_case "playground root maps to container root"
            `Quick test_container_path_root_maps;
          Alcotest.test_case "nested host path maps with suffix" `Quick
            test_container_path_nested_maps_with_suffix;
          Alcotest.test_case "outside playground errors" `Quick
            test_container_path_outside_playground_errors;
        ] );
      ( "read_file",
        [
          Alcotest.test_case "outside playground returns mapping error"
            `Quick test_read_outside_playground_returns_mapping_error;
          Alcotest.test_case "missing file preflight errors" `Quick
            test_read_missing_file_preflight_errors;
          Alcotest.test_case "directory read names a real listing tool" `Quick
            test_read_directory_names_a_real_listing_tool;
          Alcotest.test_case "remote read skips host existence preflight" `Quick
            test_remote_ssh_read_skips_host_existence_preflight;
        ] );
      ( "run_command",
        [
          Alcotest.test_case "empty command_argv errors" `Quick
            test_run_command_empty_argv_errors;
          Alcotest.test_case "empty image configuration errors" `Quick
            test_run_command_empty_image_errors;
          Alcotest.test_case "remote_ssh endpoint error precedes image guard" `Quick
            test_run_command_remote_ssh_endpoint_error_before_image_guard;
          Alcotest.test_case "factory profile drift is rejected both ways" `Quick
            test_run_command_rejects_factory_profile_drift_in_both_directions;
          Alcotest.test_case "microvm without a turn factory routes to the attached guest"
            `Quick test_microvm_without_a_turn_factory_routes_to_the_attached_guest;
          Alcotest.test_case "an attached endpoint names the derived guest" `Quick
            test_attached_guest_endpoint_names_the_derived_guest;
          Alcotest.test_case "attaching refuses a docker keeper" `Quick
            test_attached_guest_endpoint_refuses_docker;
          Alcotest.test_case "docker without a turn factory keeps the container route"
            `Quick test_docker_without_a_turn_factory_still_routes_to_the_container;
          Alcotest.test_case "nonzero exit errors by default" `Quick
            test_run_command_nonzero_exit_errors_by_default;
          Alcotest.test_case "configured nonzero exit is allowed" `Quick
            test_run_command_allows_configured_nonzero_exit;
          Alcotest.test_case "preserves bare command argv" `Quick
            test_run_command_preserves_bare_command_argv;
          Alcotest.test_case "fallback uses Docker_spawn slot" `Quick
            (test_run_command_fallback_uses_docker_spawn_slot ~clock);
          Alcotest.test_case "projects keeper secret directory" `Quick
            test_run_command_projects_keeper_secret_dir;
          Alcotest.test_case "default fs hardening helpers" `Quick
            test_default_fs_hardening_helpers;
          Alcotest.test_case "relaxed fs helpers" `Quick
            test_relaxed_fs_helpers;
          Alcotest.test_case "turn runtime reuses single container" `Quick
            test_turn_runtime_reuses_single_container;
          Alcotest.test_case
            "typed target leaves image preflight to runtime creation"
            `Quick test_typed_guest_target_leaves_image_preflight_to_runtime_creation;
          Alcotest.test_case
            "streaming exec validates cached container before retry"
            `Quick test_streaming_exec_validates_cached_container_before_retry;
          Alcotest.test_case
            "streaming exec preserves split stderr"
            `Quick test_streaming_exec_preserves_split_stderr;
          Alcotest.test_case
            "streaming exec forwards timeout to split exec"
            `Quick test_streaming_exec_forwards_timeout_to_split_exec;
          Alcotest.test_case
            "streaming pipeline forwards timeout to split exec"
            `Quick test_streaming_pipeline_forwards_timeout_to_split_exec;
          Alcotest.test_case
            "streaming exec restarts stopped container before exec"
            `Quick test_streaming_exec_restarts_stopped_container_before_exec;
          Alcotest.test_case
            "streaming exec surfaces process failure once"
            `Quick test_streaming_exec_surfaces_process_failure_once;
          Alcotest.test_case
            "streaming exec keeps successful progress live"
            `Quick test_streaming_exec_keeps_successful_progress_live;
          Alcotest.test_case
            "streaming exec keeps sparse progress live"
            `Quick test_streaming_exec_keeps_sparse_progress_live;
          Alcotest.test_case
            "turn runtime relaxed fs omits readonly and noexec"
            `Quick test_turn_runtime_relaxed_fs_omits_readonly_and_noexec;
        ] );
      ( "docker_preflight",
        [
          Alcotest.test_case "ready image reports ok" `Quick
            test_docker_preflight_reports_ready_image;
          Alcotest.test_case "image inspect error stays structural" `Quick
            test_docker_preflight_surfaces_image_inspect_error;
          Alcotest.test_case "daemon stderr does not create a semantic class" `Quick
            test_docker_preflight_does_not_infer_daemon_state_from_stderr;
          Alcotest.test_case "image inspect timeout has distinct failure class" `Quick
            test_docker_preflight_classifies_image_inspect_timeout;
        ] );
      ( "docker_cleanup",
        [
          Alcotest.test_case "label args include owner scope" `Quick
            test_sandbox_container_label_args_include_owner_scope;
        ] );
    ]

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  Eio_context.set_clock clock;
  Eio_context.set_switch sw;
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock;
  run_tests ~clock ()
