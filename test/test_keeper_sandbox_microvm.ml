(* The argv is built before anything can run it, so these tests are what say
   it is right. Measured against container CLI 1.3.0 on 2026-08-28: every
   flag asserted here was accepted by a live `container run`, and the two in
   [unsupported_docker_flags] were rejected with "Unknown option". *)

module M = Masc.Keeper_sandbox_microvm
module Backend = Masc.Keeper_microvm_backend
module Runtime = Masc.Keeper_sandbox_runtime
module Profile = Keeper_types_profile_sandbox

(* This file is Apple's lane. Measured against container CLI 1.3.0, and the
   per-runtime table lives in test_keeper_microvm_backend.ml, so a boot argv
   here is the Apple one made unconditional. A refusal would mean the Apple
   arm lost a guarantee it has a flag for, which is the failure worth a loud
   test rather than a silent [Error]. *)
let apple_boot_argv = function
  | Ok argv -> argv
  | Error refusals ->
    Alcotest.fail
      (M.constraint_refusals_message Backend.Apple_container refusals)
;;

let probe_mount_args =
  [ "-v"; "/base/.masc/config:/tmp/masc-runtime/.masc/config:ro" ]
  @ M.work_volume_mount_args ~volume_name:"masc-keeper-work-probe"
  @ M.shim_mount_args ~host_dir:"/base/.masc/microvm/shim"

let argv ?(network = Profile.Network_none) () =
  apple_boot_argv
  @@ M.turn_start_argv_for
    Backend.Apple_container
    ~container_name:"masc-keeper-vm-probe"
    ~label_args:[ "--label"; "masc.mcp.kind=keeper-vm" ]
    ~uid:501
    ~gid:20
    ~memory:"2g"
    ~cpus:None
    ~network_args:(M.network_args ~dns:(Some "1.1.1.1") network)
    ~mount_args:probe_mount_args
    ~image:"masc-keeper-sandbox:local"
    ~constraints:Backend.all_guest_constraints

let contains needle haystack = List.exists (String.equal needle) haystack

let index_of needle haystack =
  let rec go i = function
    | [] -> None
    | x :: _ when String.equal x needle -> Some i
    | _ :: rest -> go (i + 1) rest
  in
  go 0 haystack


let adjacent ~flag ~value argv =
  let rec go = function
    | a :: b :: rest -> (String.equal a flag && String.equal b value) || go (b :: rest)
    | _ -> false
  in
  go argv

(* container errors on an unknown option instead of ignoring it, so copying
   Docker's argv wholesale would fail every call rather than quietly weaken
   the sandbox. This is the assertion that catches that copy. *)
let test_omits_flags_container_rejects () =
  let a = argv () in
  List.iter
    (fun flag ->
       if contains flag a
       then
         Alcotest.failf
           "turn_start_argv passes %s, which container run rejects with \"Unknown \
            option\" -- every boot would fail"
           flag)
    M.unsupported_docker_flags

(* The hardening that does carry over. Dropping any of these silently is the
   failure this pins: the profile is chosen for isolation, so an argv that
   forgets --read-only still runs, and nothing else would notice. *)
let test_keeps_the_hardening_container_accepts () =
  let a = argv () in
  Alcotest.(check bool) "drops capabilities" true (adjacent ~flag:"--cap-drop" ~value:"ALL" a);
  Alcotest.(check bool) "read-only rootfs" true (contains "--read-only" a);
  Alcotest.(check bool) "removes the container" true (contains "--rm" a);
  Alcotest.(check bool) "runs as the caller" true (adjacent ~flag:"--user" ~value:"501:20" a);
  Alcotest.(check bool) "caps memory" true (adjacent ~flag:"--memory" ~value:"2g" a)

(* RFC-0400: the guest's tree is its work volume. A host playground path on
   the boot argv would put the tree back on virtiofs, where every file the
   guest touches pins a host vnode -- the mount that panicked the host. *)
let test_never_mounts_the_host_playground () =
  let a = argv () in
  List.iter
    (fun arg ->
       if String.length arg >= 16 && String.equal (String.sub arg 0 16) "/base/.masc/play"
       then Alcotest.failf "turn_start_argv mounts the host playground: %s" arg)
    a;
  Alcotest.(check bool)
    "the work volume is mounted at its guest root"
    true
    (adjacent ~flag:"--volume" ~value:("masc-keeper-work-probe:" ^ M.work_volume_guest_root) a);
  Alcotest.(check bool)
    "starts on the work volume"
    true
    (adjacent ~flag:"--workdir" ~value:M.work_volume_guest_root a)

(* Network_none has to reach the command as an argument. An empty list here
   would leave the guest on the default network while the profile reported
   "none" -- the shape of #31178, one layer down. *)
let test_closed_network_is_spelled_on_the_command () =
  Alcotest.(check (list string))
    "none closes the network"
    [ "--network"; "none" ]
    (M.network_args ~dns:(Some "1.1.1.1") Profile.Network_none);
  (* inherit uses container's NAT, which routes outside. What it needs is a
     nameserver: the guest's resolver points at the gateway and the gateway
     refuses DNS from inside, so an inherit guest with no --dns routes fine
     and resolves nothing -- which reads as a dead network and is what made
     an earlier version refuse inherit on a claim that was wrong. *)
  Alcotest.(check (list string))
    "inherit carries the nameserver"
    [ "--dns"; "1.1.1.1" ]
    (M.network_args ~dns:(Some "1.1.1.1") Profile.Network_inherit);
  Alcotest.(check (list string))
    "an empty nameserver passes no --dns"
    []
    (M.network_args ~dns:(Some "") Profile.Network_inherit);
  Alcotest.(check bool)
    "the closed network reaches the boot argv"
    true
    (adjacent ~flag:"--network" ~value:"none" (argv ~network:Profile.Network_none ()));
  Alcotest.(check bool)
    "an inherit guest is given a resolver"
    true
    (adjacent ~flag:"--dns" ~value:"1.1.1.1" (argv ~network:Profile.Network_inherit ()))

let inspect_result status stdout stderr = status, stdout, stderr

let test_image_probe_uses_structured_evidence () =
  let present =
    M.classify_image_probe
      ~listing_shape:M.Listing_json_array
      ~inspect:(inspect_result (Unix.WEXITED 0) {|[{"configuration":{}}]|} "")
      ~listing:None
  in
  (match present with
   | M.Image_present -> ()
   | _ -> Alcotest.fail "valid inspect JSON must establish image presence");
  let missing =
    M.classify_image_probe
      ~listing_shape:M.Listing_json_array
      ~inspect:(inspect_result (Unix.WEXITED 1) "any human prose" "any stderr")
      ~listing:(Some (inspect_result (Unix.WEXITED 0) "[]" ""))
  in
  (match missing with
   | M.Image_missing -> ()
   | _ -> Alcotest.fail "a healthy structured listing must distinguish a missing image");
  let service_dead =
    M.classify_image_probe
      ~listing_shape:M.Listing_json_array
      ~inspect:(inspect_result (Unix.WEXITED 1) "same exit code" "")
      ~listing:(Some (inspect_result (Unix.WEXITED 1) "" "service unavailable"))
  in
  (match service_dead with
   | M.Image_probe_failed { phase = M.Image_list; _ } -> ()
   | _ -> Alcotest.fail "an unreadable image store must stay probe-failed");
  let malformed =
    M.classify_image_probe
      ~listing_shape:M.Listing_json_array
      ~inspect:(inspect_result (Unix.WEXITED 0) "not json" "")
      ~listing:None
  in
  (match malformed with
   | M.Image_probe_failed { phase = M.Image_inspect; _ } -> ()
   | _ -> Alcotest.fail "successful status with malformed JSON must fail closed");
  let malformed_listing =
    M.classify_image_probe
      ~listing_shape:M.Listing_json_array
      ~inspect:(inspect_result (Unix.WEXITED 1) "" "")
      ~listing:(Some (inspect_result (Unix.WEXITED 0) "not json" ""))
  in
  (match malformed_listing with
   | M.Image_probe_failed { phase = M.Image_list; _ } -> ()
   | _ -> Alcotest.fail "malformed listing JSON must not establish image absence");
  let cli_missing =
    M.classify_image_probe
      ~listing_shape:M.Listing_json_array
      ~inspect:(inspect_result (Unix.WEXITED 127) "" "not found")
      ~listing:None
  in
  match cli_missing with
  | M.Image_cli_unavailable -> ()
  | _ -> Alcotest.fail "exit 127 must preserve the CLI-unavailable class"

(* ── Refusal wiring ─────────────────────────────────────────────
   The profile parses, the argv builder exists, and nothing starts the
   guest yet. These pin the contract of that gap: every dispatch surface
   refuses with the shared sentence instead of running docker. *)

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let microvm_meta ~name : Masc.Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("trace_id", `String ("trace-" ^ name))
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  (* A guest that reached dispatch was booted on a runtime, so the fixture
     carries one. Durable meta leaves the field empty and the TOML resolve
     fills it; skipping it here would test a state no booted guest is in. *)
  | Ok meta ->
    { meta with
      sandbox_profile = Profile.Micro_vm
    ; microvm_backend = Some Backend.Apple_container
    }
  | Error e -> Alcotest.fail e

(* Off Micro_vm the runtime field is empty: the TOML load refuses the key
   there, and a Docker keeper carrying one would be a second place for the
   answer to live. *)
let docker_meta ~name =
  { (microvm_meta ~name) with
    sandbox_profile = Profile.Docker
  ; microvm_backend = None
  }

let refusal = Profile.backend_unimplemented_message Profile.Micro_vm

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f

let test_live_structured_image_probe () =
  match Sys.getenv_opt "MASC_MICROVM_IMAGE_PROBE_LIVE" with
  | None -> ()
  | Some _ ->
    with_eio_fs @@ fun () ->
    (match
       M.image_probe_for
         Backend.Apple_container
         ~image:"masc-keeper-sandbox:local"
         ~timeout_sec:15.0
     with
     | M.Image_present -> ()
     | _ -> Alcotest.fail "present image did not produce Image_present");
    match
      M.image_probe_for
        Backend.Apple_container
        ~image:"masc-proof-definitely-missing:never"
        ~timeout_sec:15.0
    with
    | M.Image_missing -> ()
    | _ -> Alcotest.fail "a definitely absent image did not produce Image_missing"

let test_factory_resolves_microvm_to_a_profile_carrying_runtime () =
  with_eio_fs @@ fun () ->
  let base = temp_dir "microvm_factory_" in
  let config = Masc.Workspace.default_config base in
  let meta = microvm_meta ~name:"vm-runtime-factory" in
  let factory = Masc.Keeper_sandbox_factory.create ~config ~meta () in
  (match
     Masc.Keeper_sandbox_factory.resolve
       factory
       ~cwd:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta)
   with
   | Runtime { guest_profile = Micro_vm_guest; _ } -> ()
   | Runtime { guest_profile = Docker_guest; _ } ->
     Alcotest.fail "microvm factory froze a Docker contract"
   | No_factory ->
     Alcotest.fail "expected a runtime for Micro_vm"
   | Remote_ssh_profile ->
     Alcotest.fail "microvm meta must never resolve to Remote_ssh_profile");
  Masc.Keeper_sandbox_factory.cleanup factory

let test_guest_target_follows_the_factory_contract () =
  with_eio_fs @@ fun () ->
  let base = temp_dir "guest_target_contract_" in
  let config = Masc.Workspace.default_config base in
  let resolve (meta : Masc.Keeper_meta_contract.keeper_meta) =
    let factory = Masc.Keeper_sandbox_factory.create ~config ~meta () in
    let result =
      match
        Masc.Keeper_sandbox_factory.resolve
          factory
          ~cwd:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta)
      with
      | Runtime binding ->
        Masc.Keeper_sandbox_shell_ir_target.guest_target
          ~binding
          ~meta
          ~cwd:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta)
          ~timeout_sec:60.0
          ()
      | No_factory -> Alcotest.fail "expected a guest runtime"
      | Remote_ssh_profile -> Alcotest.fail "expected a guest, not remote SSH"
    in
    Masc.Keeper_sandbox_factory.cleanup factory;
    match result, meta.sandbox_profile with
    (* A guest endpoint runs one command per shim connection, as an OpenSSH
       endpoint does: no pipeline runner, so a pipeline is dispatched stage
       by stage. *)
    | Ok { target = Masc_exec.Sandbox_target.Micro_vm { pipeline_runner = None; _ }; _ }
      , Profile.Micro_vm
    | Ok { target = Masc_exec.Sandbox_target.Docker { pipeline_runner = Some _; _ }; _ }
      , Profile.Docker -> ()
    | Ok { target = Masc_exec.Sandbox_target.Micro_vm { pipeline_runner = Some _; _ }; _ }
      , Profile.Micro_vm ->
      Alcotest.fail "a microvm target carried a pipeline runner the shim cannot honour"
    | Ok { target = Masc_exec.Sandbox_target.Docker { pipeline_runner = None; _ }; _ }
      , Profile.Docker ->
      Alcotest.fail "the Docker target lost its pipeline runner"
    | Ok _, _ -> Alcotest.fail "guest target kind differs from the keeper profile"
    | Error error, _ -> Alcotest.fail error.message
  in
  resolve (microvm_meta ~name:"microvm-contract-probe");
  resolve (docker_meta ~name:"docker-contract-probe")

let test_guest_target_refuses_a_profile_mismatch () =
  with_eio_fs @@ fun () ->
  let base = temp_dir "guest_target_mismatch_" in
  let config = Masc.Workspace.default_config base in
  let docker = docker_meta ~name:"contract-mismatch" in
  let microvm = { docker with sandbox_profile = Profile.Micro_vm } in
  let assert_mismatch ~factory_meta ~caller_meta =
    let factory = Masc.Keeper_sandbox_factory.create ~config ~meta:factory_meta () in
    let result =
      match
        Masc.Keeper_sandbox_factory.resolve
          factory
          ~cwd:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config caller_meta)
      with
      | Runtime binding ->
        Masc.Keeper_sandbox_shell_ir_target.guest_target
          ~binding
          ~meta:caller_meta
          ~cwd:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config caller_meta)
          ~timeout_sec:60.0
          ()
      | No_factory -> Alcotest.fail "expected a guest runtime"
      | Remote_ssh_profile -> Alcotest.fail "expected a guest, not remote SSH"
    in
    Masc.Keeper_sandbox_factory.cleanup factory;
    match result with
    | Ok _ -> Alcotest.fail "a mismatched factory and caller profile reached dispatch"
    | Error error ->
      Alcotest.(check (option string))
        "typed mismatch code"
        (Some "sandbox_profile_contract_mismatch")
        (match List.assoc_opt "code" error.fields with
         | Some (`String code) -> Some code
         | Some _ | None -> None)
  in
  assert_mismatch ~factory_meta:docker ~caller_meta:microvm;
  assert_mismatch ~factory_meta:microvm ~caller_meta:docker

(* RFC-0400 C: the guest's tree is its work volume. Every docker-shaped exec
   entrypoint refuses a microvm keeper before touching any CLI, so a runtime
   that says it is running needs no container behind it here. *)
let test_docker_shaped_exec_refuses_a_microvm_keeper () =
  with_eio_fs @@ fun () ->
  let base = temp_dir "microvm_exec_refusal_" in
  let config = Masc.Workspace.default_config base in
  let meta = microvm_meta ~name:"vm-exec-refusal" in
  let runtime =
    Masc.Keeper_turn_sandbox_runtime.For_testing.create_minimal
      ~config ~meta
      ~state:(Running { container_name = "masc-keeper-vm-vm-exec-refusal-deadbeef" })
  in
  let refused label = function
    | Error message ->
      Alcotest.(check bool) (label ^ " names the remote lane") true
        (String.starts_with ~prefix:"microvm_exec_is_remote:" message)
    | Ok _ -> Alcotest.failf "%s built a docker-shaped exec for a microvm keeper" label
  in
  refused "exec_argv"
    (Masc.Keeper_turn_sandbox_runtime.exec_argv
       ~validate_cached_container:false runtime ~cwd:base ~command_argv:[ "true" ]);
  refused "run_bash_with_status"
    (Masc.Keeper_turn_sandbox_runtime.run_bash_with_status
       ~timeout_sec:1.0 runtime ~cwd:base ~cmd:"true" ());
  refused "run_exec_pipeline_with_status"
    (Masc.Keeper_turn_sandbox_runtime.run_exec_pipeline_with_status
       ~timeout_sec:1.0 runtime ~cwd:base
       ~stages:[ { Masc.Keeper_turn_sandbox_runtime.command_argv = [ "true" ]; cwd = None } ])
;;

(* spawn hands back an argv to background on the host; there is none for a
   tree the shim reaches over one framed connection. Resolving the factory
   does not boot anything, so this runs without the container CLI. *)
let test_spawn_does_not_cross_the_guest_boundary () =
  with_eio_fs @@ fun () ->
  let base = temp_dir "microvm_spawn_refusal_" in
  let config = Masc.Workspace.default_config base in
  let meta = microvm_meta ~name:"vm-spawn-refusal" in
  let factory = Masc.Keeper_sandbox_factory.create ~config ~meta () in
  let result =
    Masc.Keeper_tool_in_process_runtime.spawn_sandbox_argv
      ~turn_sandbox_factory:(Some factory)
      ~cwd:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta)
      ~command_argv:[ "sleep"; "1" ]
  in
  Masc.Keeper_sandbox_factory.cleanup factory;
  match result with
  | Error message ->
    Alcotest.(check bool) "names the boundary" true
      (Astring.String.is_infix ~affix:"microvm boundary" message)
  | Ok _ -> Alcotest.fail "spawn built an argv to background for a microvm keeper"
;;

(* What the keeper is shown: its host root is the bookkeeping bundle, not a
   guest path, and the cwd echo and execution location repeat that bundle
   -- the remote lane owns the guest spelling. *)
let test_echoes_name_the_host_bundle () =
  let base = temp_dir "microvm_echo_bundle_" in
  let config = Masc.Workspace.default_config base in
  let meta = microvm_meta ~name:"vm-echo-bundle" in
  let host_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Alcotest.(check string) "host root is the bundle, not playground/microvm"
    (Filename.concat base ".masc/playground/vm-echo-bundle/")
    host_root;
  let sandbox = Masc.Keeper_sandbox.of_meta ~config ~meta in
  Alcotest.(check bool) "no container root for a tree the guest owns" true
    (Option.is_none sandbox.container_root);
  let response =
    Masc.Keeper_cwd_response.of_sandbox ~sandbox ~host_cwd:host_root
      ~container_cwd_for_docker:"/home/keeper/playground/vm-echo-bundle"
  in
  Alcotest.(check string) "cwd echo is the host bundle" host_root
    (Masc.Keeper_cwd_response.keeper_visible response);
  let location =
    Masc.Keeper_sandbox_repo_path.execution_location_json
      ~config ~meta ~args:(`Assoc []) ~cwd:host_root
  in
  (match Yojson.Safe.Util.member "cwd" location with
   | `String cwd ->
     Alcotest.(check bool) "execution location is not a guest path" false
       (String.starts_with ~prefix:"/home/keeper/" cwd);
     Alcotest.(check bool) "execution location names the bundle" true
       (Astring.String.is_infix ~affix:".masc/playground/vm-echo-bundle" cwd)
   | _ -> Alcotest.fail "execution location has no cwd")
;;

let test_turn_start_argv_shape () =
  let a =
    apple_boot_argv
    @@ M.turn_start_argv_for
      Backend.Apple_container
      ~container_name:"masc-keeper-turn-probe"
      ~label_args:[ "--label"; "masc.mcp.kind=turn" ]
      ~uid:501
      ~gid:20
      ~memory:"2g"
      ~cpus:None
      ~network_args:(M.network_args ~dns:None Profile.Network_none)
      ~mount_args:[ "-v"; "/base/.masc/config:/home/keeper/.masc/config:ro" ]
      ~image:"masc-keeper-sandbox:local"
      ~constraints:Backend.all_guest_constraints
  in
  List.iter
    (fun flag ->
       if contains flag a
       then Alcotest.failf "turn_start_argv passes %s (container rejects it)" flag)
    M.unsupported_docker_flags;
  (* The caller's projections have to reach the guest, and they have to sit
     before the image: container reads everything after the image name as the
     command. A mount that lands after it becomes an argument to [tail]. *)
  if not (contains "/base/.masc/config:/home/keeper/.masc/config:ro" a)
  then Alcotest.fail "turn_start_argv drops mount_args";
  (match
     ( index_of "-v" a
     , index_of "masc-keeper-sandbox:local" a )
   with
   | Some mount_at, Some image_at when mount_at < image_at -> ()
   | _ -> Alcotest.fail "mount_args must precede the image");
  (match List.rev a with
   | "/dev/null" :: "-f" :: "tail" :: image :: _ ->
     Alcotest.(check string) "detached hold process follows the image"
       "masc-keeper-sandbox:local" image
   | rest ->
     Alcotest.failf
       "turn_start_argv must end with <image> tail -f /dev/null, got: %s"
       (String.concat " " (List.rev rest)));
  List.iter
    (fun needle ->
       if not (contains needle a)
       then Alcotest.failf "turn_start_argv is missing %s" needle)
    [ "-d"; "--rm"; "--read-only"; "--label" ];
  if contains "--cpus" a
  then Alcotest.fail "cpus:None must pass no --cpus";
  let sized =
    apple_boot_argv
    @@ M.turn_start_argv_for
      Backend.Apple_container
      ~container_name:"masc-keeper-turn-probe"
      ~label_args:[]
      ~uid:501
      ~gid:20
      ~memory:"8g"
      ~cpus:(Some "8")
      ~network_args:[]
      ~mount_args:[]
      ~image:"masc-keeper-sandbox:local"
      ~constraints:Backend.all_guest_constraints
  in
  if not (adjacent ~flag:"--cpus" ~value:"8" sized)
  then Alcotest.fail "cpus:Some must pass --cpus <count>";
  if not (adjacent ~flag:"--memory" ~value:"8g" sized)
  then Alcotest.fail "memory must reach --memory"

let test_inspect_state_parser () =
  let running =
    {|[{"configuration":{"id":"x"},"status":{"state":"running","startedDate":"now"}}]|}
  in
  let stopped =
    {|[{"configuration":{"id":"x"},"status":{"state":"stopped"}}]|}
  in
  (match M.running_of_inspect_json_for Backend.Apple_container running with
   | Ok true -> ()
   | Ok false | Error _ -> Alcotest.fail "running JSON must parse as running");
  (match M.running_of_inspect_json_for Backend.Apple_container stopped with
   | Ok false -> ()
   | Ok true | Error _ -> Alcotest.fail "stopped JSON must parse as not running");
  match M.running_of_inspect_json_for Backend.Apple_container "not json" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "garbage must be an Error, not a state"

let test_docker_shell_entrypoint_refuses_microvm () =
  let base = temp_dir "microvm_refuse_shell_" in
  let config = Masc.Workspace.default_config base in
  let meta = microvm_meta ~name:"vm-refuse-shell" in
  match
    Masc.Keeper_sandbox_docker.run_docker_shell_command_with_status
      ~config
      ~meta
      ~cwd:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta)
      ~timeout_sec:5.0
      ~cmd:"true"
      ~network_mode:Profile.Network_none
  with
  | Error message ->
    Alcotest.(check string) "shared refusal sentence" refusal message
  | Ok _ ->
    Alcotest.fail "docker shell entrypoint executed for a Micro_vm keeper"

let test_docker_bash_entrypoint_refuses_microvm () =
  let base = temp_dir "microvm_refuse_bash_" in
  let config = Masc.Workspace.default_config base in
  let meta = microvm_meta ~name:"vm-refuse-bash" in
  let response =
    Masc.Keeper_sandbox_docker.run_docker_bash
      ~turn_sandbox_runtime:None
      ~config
      ~meta
      ~cwd:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta)
      ~timeout_sec:5.0
      ~cmd:"true"
      ~network_mode:Profile.Network_none
  in
  if not (Astring.String.is_infix ~affix:refusal response)
  then
    Alcotest.failf
      "bash entrypoint did not refuse with the shared sentence; got: %s"
      response

(* Live smoke: starts a real guest through the turn runtime and runs one
   command in it. Opt-in via MASC_MICROVM_LIVE=1 — it needs Apple's
   [container] CLI, the sandbox image in container's store, and ~5s for
   the VM boot, none of which a CI runner has. *)
let test_live_turn_runtime_cat () =
  match Sys.getenv_opt "MASC_MICROVM_LIVE" with
  | None | Some "" -> ()
  | Some _ ->
    with_eio_fs @@ fun () ->
    let base = temp_dir "microvm_live_" in
    let config = Masc.Workspace.default_config base in
    let meta = microvm_meta ~name:"vm-live" in
    let host_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
    let rec mkdir_p dir =
      if not (Sys.file_exists dir)
      then (
        mkdir_p (Filename.dirname dir);
        Unix.mkdir dir 0o755)
    in
    mkdir_p host_root;
    let prepare_identity runtime =
      match
        Masc.Keeper_turn_sandbox_runtime.prepare_github_identity_secret_files
          ~timeout_sec:60.0
          runtime
      with
      | Ok (path :: _) -> path
      | Ok [] -> Alcotest.fail "guest identity preparation returned no snapshot path"
      | Error message ->
        Alcotest.failf "guest GitHub identity preparation failed: %s" message
    in
    (* A turn's runtime comes from its factory, as in dispatch; the binding
       is what the Execute target is built from. *)
    let turn () =
      let factory = Masc.Keeper_sandbox_factory.create ~config ~meta () in
      match Masc.Keeper_sandbox_factory.resolve factory ~cwd:host_root with
      | Runtime binding -> factory, binding
      | No_factory | Remote_ssh_profile ->
        Alcotest.fail "a microvm meta must resolve to a guest runtime"
    in
    (* The guest's tree is its work volume, so the probe is written there by
       the guest itself and read back over the same lane: the host bundle
       holds nothing the guest sees. *)
    let cat (binding : Masc.Keeper_sandbox_factory.runtime_binding) =
      let target =
        match
          Masc.Keeper_sandbox_shell_ir_target.guest_target
            ~binding ~meta ~cwd:host_root ~timeout_sec:60.0 ()
        with
        | Ok { target; _ } -> target
        | Error error -> Alcotest.failf "guest target: %s" error.message
      in
      let runner =
        match target with
        | Masc_exec.Sandbox_target.Micro_vm { runner; _ } -> runner
        | _ -> Alcotest.fail "a microvm binding must build a Micro_vm target"
      in
      match
        runner
          ~on_stdout_chunk:None
          ~on_stderr_chunk:None
          ~stdin_content:None
          ~argv:[ "sh"; "-c"; "printf hello-from-microvm > probe.txt && cat probe.txt" ]
          ~env:[||]
          ~cwd:(Some host_root)
      with
      | Unix.WEXITED 0, out, _ ->
        if not (Astring.String.is_infix ~affix:"hello-from-microvm" out)
        then Alcotest.failf "guest cat returned unexpected output: %s" out
      | st, out, err ->
        Alcotest.failf
          "guest cat failed: %s: %s %s"
          (match st with
           | Unix.WEXITED n -> Printf.sprintf "exit %d" n
           | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
           | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
          out
          err
    in
    let final_snapshot_dir = ref None in
    Fun.protect
      ~finally:(fun () ->
        match
          Masc.Keeper_turn_sandbox_runtime.teardown_keeper_sandbox ~config ~meta ()
        with
        | Ok () -> ()
        | Error message -> Alcotest.failf "teardown failed: %s" message)
      (fun () ->
         (* Turn 1 pays the boot. *)
         let factory1, turn1 = turn () in
         let boot_started = Unix.gettimeofday () in
         let first_secret = prepare_identity turn1.runtime in
         let first_snapshot_dir = Filename.dirname first_secret in
         cat turn1;
         let booted_in = Unix.gettimeofday () -. boot_started in
         Masc.Keeper_sandbox_factory.cleanup factory1;
         if not (Sys.file_exists first_snapshot_dir)
         then Alcotest.fail "turn cleanup removed the running guest's identity";
         (* Turn 2 must adopt the surviving guest, not boot a second one. *)
         let factory2, turn2 = turn () in
         let reuse_started = Unix.gettimeofday () in
         let second_secret = prepare_identity turn2.runtime in
         Alcotest.(check string)
           "the adopted guest keeps the same identity snapshot"
           first_secret
           second_secret;
         cat turn2;
         let reused_in = Unix.gettimeofday () -. reuse_started in
         Masc.Keeper_sandbox_factory.cleanup factory2;
         (* The boot dominates turn 1 (>=2s VM start); adoption must not
            pay it again. Generous bounds — this pins reuse, not speed. *)
         if reused_in >= booted_in
         then
           Alcotest.failf
             "turn 2 (%.1fs) was not faster than turn 1 (%.1fs); the guest \
              was rebooted instead of adopted"
             reused_in
             booted_in;
         (* A central login change replaces both the guest and its immutable
            snapshot. The next turn must not keep using the old token or try
            Docker's rm command against an Apple container guest. *)
         mkdir_p (Masc.Workspace.keepers_runtime_dir config);
         let identity_dir =
           match
             Masc.Keeper_github_identity.ensure_config_dir
               ~config
               ~keeper_name:meta.name
           with
           | Ok path -> path
           | Error message -> Alcotest.failf "cannot prepare test identity: %s" message
         in
         let hosts_path = Filename.concat identity_dir "hosts.yml" in
         let oc = open_out hosts_path in
         output_string oc "github.com:\n  oauth_token: fake-test-token\n";
         close_out oc;
         Unix.chmod hosts_path 0o600;
         let factory3, turn3 = turn () in
         let third_secret = prepare_identity turn3.runtime in
         let third_snapshot_dir = Filename.dirname third_secret in
         final_snapshot_dir := Some third_snapshot_dir;
         if String.equal first_secret third_secret
         then Alcotest.fail "identity refresh reused the superseded snapshot";
         if Sys.file_exists first_snapshot_dir
         then Alcotest.fail "identity refresh left the superseded snapshot on disk";
         cat turn3;
         Masc.Keeper_sandbox_factory.cleanup factory3);
    Option.iter
      (fun snapshot_dir ->
         if Sys.file_exists snapshot_dir
         then Alcotest.fail "guest teardown left its identity snapshot on disk")
      !final_snapshot_dir;
    (* After teardown the stable name must be gone. *)
    (match
       Masc.Keeper_turn_sandbox_runtime.teardown_keeper_sandbox ~config ~meta ()
     with
     | Ok () -> ()
     | Error message ->
       Alcotest.failf "teardown of an absent guest must be Ok: %s" message)

(* The config mount and the config env are one decision made twice. #31353
   gave the guest the mount and left the env behind, which put the config at
   a path no process in the guest was told about. These pin them together. *)

let env_container_root = "/keeper"

let with_config_base f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-microvm-env-%d" (Unix.getpid ()))
  in
  let masc = Filename.concat root ".masc" in
  let config = Filename.concat masc "config" in
  List.iter
    (fun dir -> try Sys.mkdir dir 0o700 with Sys_error _ -> ())
    [ root; masc; config ];
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun dir -> try Sys.rmdir dir with Sys_error _ -> ())
        [ config; masc; root ])
    (fun () -> f root)

(* The env a microvm guest is given: the config pairs the remote lane injects
   into every shim request, which the Docker lane spells as [--env] argv. *)
let microvm_env ~base_path =
  Masc.Keeper_sandbox_runtime.docker_config_env
    ~base_path
    ~container_root:env_container_root

let config_mounted ~base_path =
  Masc.Keeper_sandbox_runtime.docker_config_mount_args
    ~base_path
    ~container_root:env_container_root
  <> []

let test_guest_env_follows_the_config_mount () =
  (* Both read the same host config root, so a guest that was given the
     mount must also be given the env naming it. Asserted for a base path
     that has a config and one that does not. *)
  with_config_base (fun base_path ->
    Alcotest.(check bool)
      "a mounted config is a named config"
      (config_mounted ~base_path)
      (microvm_env ~base_path <> []));
  let absent = Filename.concat (Filename.get_temp_dir_name ()) "masc-absent-base" in
  Alcotest.(check bool)
    "an absent config is neither mounted nor named"
    (config_mounted ~base_path:absent)
    (microvm_env ~base_path:absent <> [])

(* The names the shim's config allowlists are the names the pairs carry --
   one list, so a pair the guest's shim would drop cannot be added. And the
   workspace-state stores the guest has no mount for are never named. *)
let test_guest_env_names_exactly_the_config_env () =
  with_config_base (fun base_path ->
    Alcotest.(check (list string))
      "pairs carry the allowlisted names, in order"
      Masc.Keeper_sandbox_runtime.config_env_names
      (List.map fst (microvm_env ~base_path)));
  Alcotest.(check bool)
    "the guest has no workspace-state mounts to name"
    false
    (List.mem "MASC_KEEPER_MOUNTED_STORES" Masc.Keeper_sandbox_runtime.config_env_names)

let test_docker_lane_keeps_the_full_env () =
  with_config_base (fun base_path ->
    let docker_env =
      Masc.Keeper_sandbox_runtime.docker_sandbox_env_args
        ~base_path
        ~container_root:env_container_root
    in
    List.iter
      (fun arg ->
        if not (List.mem arg docker_env)
        then Alcotest.failf "docker lane dropped %S the microvm lane carries" arg)
      (Masc.Keeper_sandbox_runtime.docker_config_env_args
         ~base_path
         ~container_root:env_container_root))

(* task-847: a sandbox has no terminal, so a git that wants to prompt fails
   immediately instead of hanging the call. The credential wiring itself is
   the identity snapshot's knowledge, not this env's — pinned in the
   keeper_github_identity suite. *)
let test_docker_lane_disables_git_terminal_prompts () =
  with_config_base (fun base_path ->
    let docker_env =
      Masc.Keeper_sandbox_runtime.docker_sandbox_env_args
        ~base_path
        ~container_root:env_container_root
    in
    if not (List.mem "GIT_TERMINAL_PROMPT=0" docker_env)
    then Alcotest.fail "docker env is missing GIT_TERMINAL_PROMPT=0";
    List.iter
      (fun stale ->
        if List.exists (fun arg -> arg = stale) docker_env
        then Alcotest.failf "credential wiring leaked back into the env: %S" stale)
      [ "GIT_CONFIG_COUNT=1"
      ; "GIT_CONFIG_KEY_0=credential.https://github.com.helper"
      ])


(* Sweep selection. A guest is keeper-lifetime, so the only safe reason to
   remove one is that the server which booted it is gone -- age would kill a
   keeper that has simply been busy for days. These pin that the rule is
   owner liveness and nothing else, and that an entry the build cannot
   account for is left alone. *)

let sweep_base_path = "/workspace-a"

let entry ?(base_path = sweep_base_path) ?(kind = "keeper-vm") ?owner_pid
    ?(keeper = "probe") id =
  let labels =
    [ "masc.mcp.component", `String Runtime.sandbox_component_label_value
    ; "masc.mcp.base_path_hash", `String (Runtime.base_path_hash base_path)
    ; "masc.mcp.kind", `String kind
    ; "masc.mcp.keeper", `String keeper
    ]
    @ (match owner_pid with Some p -> [ "masc.mcp.owner_pid", `String p ] | None -> [])
  in
  `Assoc [ "configuration", `Assoc [ "id", `String id; "labels", `Assoc labels ] ]

let ids candidates =
  List.map (fun (c : M.sweep_candidate) -> c.M.container_id) candidates

let dead_pid = 999999
let live_pid = 1
let is_pid_alive pid = pid = live_pid

let test_only_guests_whose_owner_is_gone () =
  let listing =
    `List
      [ entry ~owner_pid:(string_of_int live_pid) "alive-owner"
      ; entry ~owner_pid:(string_of_int dead_pid) "dead-owner"
      ]
  in
  Alcotest.(check (list string))
    "only the guest whose server is gone"
    [ "dead-owner" ]
    (ids (M.sweep_candidates_of_json ~base_path:sweep_base_path ~is_pid_alive listing))

(* A turn container carries a different kind and is swept by the docker
   path; taking it here would remove a container mid-turn. *)
let test_leaves_containers_that_are_not_guests () =
  let listing =
    `List [ entry ~kind:"oneshot" ~owner_pid:(string_of_int dead_pid) "turn-container" ]
  in
  Alcotest.(check (list string))
    "a non-guest is not a sweep target"
    []
    (ids (M.sweep_candidates_of_json ~base_path:sweep_base_path ~is_pid_alive listing))

(* Without a usable owner label the build cannot say whose guest it is.
   Guessing -- by age, or by assuming abandonment -- would remove somebody's
   running guest, which is worse than leaking one. *)
let test_leaves_guests_it_cannot_account_for () =
  let listing =
    `List
      [ entry "no-owner-label"
      ; entry ~owner_pid:"not-a-number" "unparseable-owner"
      ]
  in
  Alcotest.(check (list string))
    "an unaccountable guest stays"
    []
    (ids (M.sweep_candidates_of_json ~base_path:sweep_base_path ~is_pid_alive listing))

let test_leaves_foreign_base_guest_untouched () =
  let listing =
    `List [ entry ~base_path:"/workspace-b" ~owner_pid:(string_of_int dead_pid) "foreign-base" ]
  in
  Alcotest.(check (list string))
    "a dead guest from another base path is not a sweep target"
    []
    (ids (M.sweep_candidates_of_json ~base_path:sweep_base_path ~is_pid_alive listing))

let test_sweep_skips_listing_when_cli_is_unavailable () =
  let spawn_count = ref 0 in
  let run_argv ~timeout_sec:_ _argv =
    incr spawn_count;
    Unix.WEXITED 0, "[]"
  in
  let unavailable =
    M.sweep_abandoned_guests
      ~base_path:sweep_base_path
      ~command_available:(fun command ->
        Alcotest.(check string) "microvm executable" "container" command;
        false)
      ~timeout_sec:1.0
      ~is_pid_alive
      ~run_argv
  in
  Alcotest.(check bool) "unavailable result" true (Option.is_none unavailable);
  Alcotest.(check int) "unavailable spawn count" 0 !spawn_count;
  let available =
    M.sweep_abandoned_guests
      ~base_path:sweep_base_path
      ~command_available:(fun _ -> true)
      ~timeout_sec:1.0
      ~is_pid_alive
      ~run_argv
  in
  Alcotest.(check int) "available listing count" 1 !spawn_count;
  match available with
  | None -> Alcotest.fail "available CLI did not run the sweep"
  | Some outcome ->
    Alcotest.(check (list string)) "available removed" [] outcome.M.removed;
    Alcotest.(check int) "available failures" 0 (List.length outcome.M.failed)

let live_entry ~base_path ~keeper_name ~id =
  let label key value = key, `String value in
  let labels =
    [ label Runtime.sandbox_component_label_key Runtime.sandbox_component_label_value
    ; label Runtime.sandbox_base_path_hash_label_key (Runtime.base_path_hash base_path)
    ; label Runtime.sandbox_keeper_label_key (Runtime.sanitize_label_value keeper_name)
    ; label Runtime.sandbox_kind_label_key M.keeper_vm_container_kind
    ; label Runtime.sandbox_network_label_key "inherit"
    ; label Runtime.sandbox_owner_pid_label_key "42"
    ; label Runtime.sandbox_started_at_label_key "123.5"
    ]
  in
  `Assoc
    [ ( "configuration"
      , `Assoc
          [ "id", `String id
          ; "creationDate", `String "2026-09-01T08:13:09Z"
          ; "image", `Assoc [ "reference", `String "masc-keeper-sandbox:local" ]
          ; "labels", `Assoc labels
          ; ( "resources"
            , `Assoc [ "cpus", `Int 4; "memoryInBytes", `Int 2_147_483_648 ] )
          ] )
    ; ( "status"
      , `Assoc
          [ "state", `String "running"
          ; ( "networks"
            , `List
                [ `Assoc
                    [ "hostname", `String id
                    ; "ipv4Address", `String "192.168.64.64/24"
                    ; "ipv4Gateway", `String "192.168.64.1"
                    ; "ipv6Address", `String "fd00::64/64"
                    ]
                ] )
          ] )
    ]

let test_live_container_listing_is_scoped_to_the_keeper () =
  let base_path = "/workspace" in
  let keeper_name = "lane-smith" in
  let visible = live_entry ~base_path ~keeper_name ~id:"lane-vm" in
  let other = live_entry ~base_path ~keeper_name:"edgar.a.poe" ~id:"edgar-vm" in
  match M.live_containers_of_json ~base_path ~keeper_name (`List [ visible; other ]) with
  | Error detail -> Alcotest.fail detail
  | Ok [ container ] ->
    Alcotest.(check string) "Apple Container id" "lane-vm" container.id;
    Alcotest.(check string) "Apple Container image" "masc-keeper-sandbox:local" container.image;
    Alcotest.(check (option bool)) "Apple Container running" (Some true) container.running;
    Alcotest.(check (option string)) "keeper-lifetime kind"
      (Some M.keeper_vm_container_kind) container.container_kind;
    Alcotest.(check (option int)) "actual CPU" (Some 4) container.cpus;
    Alcotest.(check (option int)) "actual memory"
      (Some 2_147_483_648) container.memory_bytes;
    Alcotest.(check (option string)) "actual IPv4"
      (Some "192.168.64.64/24") container.ipv4_address;
    Alcotest.(check (option string)) "actual gateway"
      (Some "192.168.64.1") container.gateway
  | Ok containers ->
    Alcotest.failf "expected exactly one scoped Apple Container VM, got %d" (List.length containers)


(* Build output on a block device instead of the virtiofs share.

   Measured on macOS 26.6.1 / M3 Max, container CLI 1.3.1, writing 20,000
   files and counting host descriptors on the VM process: ext4 volume
   26 -> 26, virtiofs bind mount 26 -> 20,027, [_build] symlinked onto the
   volume 59 -> 61. Three kernel panics between 2026-08-30 and 2026-09-01
   came from that middle row filling [kern.maxvnodes]. *)

let ok_exn = function
  | Ok v -> v
  | Error e -> Alcotest.failf "expected Ok, got Error %S" e
;;

let error_exn = function
  | Ok v -> Alcotest.failf "expected Error, got Ok %S" v
  | Error e -> e
;;

let test_volume_create_argv_carries_a_size () =
  let argv = M.apple_volume_create_argv ~volume_name:"masc-keeper-work-x" ~size:"64g" in
  Alcotest.(check bool) "goes through container" true (contains "container" argv);
  Alcotest.(check bool) "creates a volume" true (adjacent ~flag:"volume" ~value:"create" argv);
  (* The image is sparse -- 4 GiB nominal measured at 84 MB on disk -- so the
     size is a ceiling, not an allocation. *)
  Alcotest.(check bool) "size is passed" true (adjacent ~flag:"-s" ~value:"64g" argv)
;;

let test_work_volume_is_named_and_mounted_at_its_root () =
  Alcotest.(check string)
    "one work volume per keeper"
    "masc-keeper-work-lane-smith"
    (ok_exn (M.work_volume_name ~keeper_name:"lane-smith"));
  ignore (error_exn (M.work_volume_name ~keeper_name:"has space") : string);
  Alcotest.(check bool)
    "mounted at the guest work root"
    true
    (adjacent
       ~flag:"--volume"
       ~value:("masc-keeper-work-lane-smith:" ^ M.work_volume_guest_root)
       (M.work_volume_mount_args ~volume_name:"masc-keeper-work-lane-smith"));
  Alcotest.(check string)
    "keeper root sits on the volume"
    "/masc-work/lane-smith"
    (M.keeper_work_root ~keeper_name:"lane-smith")
;;

let test_shim_travels_read_only_with_its_config () =
  Alcotest.(check bool)
    "shim dir is a read-only mount"
    true
    (adjacent
       ~flag:"--volume"
       ~value:("/host/.masc/microvm/shim:" ^ M.shim_guest_dir ^ ":ro")
       (M.shim_mount_args ~host_dir:"/host/.masc/microvm/shim"));
  Alcotest.(check string) "shim path" "/opt/masc-exec-shim/masc-exec-shim" M.shim_guest_path;
  (* The allowlist names the config env the endpoint injects: the shim drops
     request env it was not told to accept, and the guest was given the
     config mount, so the names that point at it must get through. *)
  Alcotest.(check string)
    "config names the work root, the image's PATH and the config env"
    "remote_root=/masc-work\npath=/home/opam/.opam/5.5/bin:/usr/bin\nenv_allowlist=MASC_BASE_PATH,MASC_BASE_PATH_INPUT,MASC_CONFIG_DIR\n"
    (M.shim_config_content ~payload_path:"/home/opam/.opam/5.5/bin:/usr/bin")
;;

(* Existence is proved by root's mkdir; use only by a write as the keeper's
   own uid. A tree imported under another uid passes [ls] and fails every
   Write, so the probe runs as that uid and names the owner on failure. *)
let test_keeper_work_root_write_probe_runs_as_the_keeper () =
  let argv =
    M.keeper_work_root_write_probe_argv
      ~container_name:"masc-keeper-vm-x" ~uid:502 ~gid:20 ~keeper_name:"lane-smith"
  in
  Alcotest.(check bool) "runs as the keeper's uid, not root" true
    (adjacent ~flag:"--user" ~value:"502:20" argv);
  Alcotest.(check bool) "targets the keeper root" true
    (String.equal (List.nth argv (List.length argv - 1)) "/masc-work/lane-smith");
  let script =
    match List.rev argv with
    | _root :: _name :: script :: "-c" :: "sh" :: _ -> script
    | _ -> Alcotest.fail "probe is not a sh -c script with the root as $1"
  in
  List.iter
    (fun needle ->
       Alcotest.(check bool) (needle ^ " is in the probe") true
         (Astring.String.is_infix ~affix:needle script))
    [ "mktemp"; "unlink"; "stat -c"; "owner=%u:%g"; "exit 1" ]
;;

let test_keeper_work_root_is_created_as_root_with_a_mode () =
  let argv =
    M.keeper_work_root_mkdir_argv ~container_name:"masc-keeper-vm-x" ~keeper_name:"lane-smith"
  in
  Alcotest.(check bool) "runs as root" true (adjacent ~flag:"--user" ~value:"0:0" argv);
  Alcotest.(check bool) "explicit mode" true (adjacent ~flag:"-m" ~value:"0777" argv);
  Alcotest.(check bool) "creates the keeper root" true (contains "/masc-work/lane-smith" argv)
;;

(* The running guest as a remote endpoint: the argv the remote runner spawns
   is [container exec] into this guest, the shim it names is the mounted one,
   and the identity it injects is the snapshot the guest already mounts. *)
let test_running_guest_is_a_remote_endpoint () =
  let base = temp_dir "microvm_remote_endpoint_" in
  (* A config root on the host means the guest was booted with the config
     mount, so the endpoint must name it to every request. *)
  List.iter
    (fun dir -> try Sys.mkdir dir 0o700 with Sys_error _ -> ())
    [ Filename.concat base ".masc"; Filename.concat base ".masc/config" ];
  let config = Masc.Workspace.default_config base in
  let meta = microvm_meta ~name:"lane-smith" in
  let container_name = "masc-keeper-vm-lane-smith-deadbeef" in
  let runtime =
    Masc.Keeper_turn_sandbox_runtime.For_testing.create_minimal
      ~config ~meta ~state:(Running { container_name })
  in
  match
    Masc.Keeper_turn_sandbox_runtime.microvm_remote_endpoint_of_running
      runtime ~container_name
  with
  | Error message -> Alcotest.fail message
  | Ok endpoint ->
    let argv = Masc.Keeper_sandbox_remote.transport_argv endpoint in
    Alcotest.(check bool) "execs into the guest" true
      (adjacent ~flag:"exec" ~value:"-i" argv && contains container_name argv);
    Alcotest.(check bool) "names the mounted shim" true (contains M.shim_guest_path argv);
    Alcotest.(check bool) "hands the shim its config" true
      (adjacent ~flag:"--env" ~value:("MASC_EXEC_SHIM_CONFIG=" ^ M.shim_config_guest_path) argv);
    Alcotest.(check bool) "starts in the work root" true
      (adjacent ~flag:"-w" ~value:M.work_volume_guest_root argv);
    Alcotest.(check string) "keeper root is on the work volume" "/masc-work/lane-smith"
      (Masc.Keeper_sandbox_remote.remote_keeper_root endpoint);
    Alcotest.(check string) "endpoint is named after the guest" container_name
      (Masc.Keeper_sandbox_remote.name endpoint);
    let injected = Masc.Keeper_sandbox_remote.injected_env endpoint in
    Alcotest.(check (option string)) "the config mount is named by its env"
      (Some "/tmp/masc-runtime/.masc/config")
      (List.assoc_opt "MASC_CONFIG_DIR" injected);
    Alcotest.(check bool) "the lane's own env still leads" true
      (List.mem_assoc "GH_CONFIG_DIR" injected);
    (match Masc.Keeper_sandbox_remote.transport endpoint with
     | Masc.Keeper_sandbox_remote.Container_exec
         (guest : Masc.Keeper_sandbox_remote.container_exec) ->
       (* The prefix arrives prebuilt, so what this pins is that the argv the
          transport hands out is that prefix with the shim appended -- not a
          second assembly the transport does on its own. *)
       Alcotest.(check (list string)) "the transport appends only the shim"
         (guest.prefix @ [ guest.shim_path ])
         argv;
       (* [create_minimal] runs as 0:0, so this is the runtime's own pair
          reaching the exec rather than a value the prefix invented. *)
       Alcotest.(check bool) "execs as the runtime's uid:gid" true
         (adjacent ~flag:"--user" ~value:"0:0" argv)
     | Masc.Keeper_sandbox_remote.Openssh _ -> Alcotest.fail "a guest is not an OpenSSH endpoint");
    let docker =
      Masc.Keeper_turn_sandbox_runtime.For_testing.create_minimal
        ~config ~meta:(docker_meta ~name:"lane-smith") ~state:(Running { container_name })
    in
    (match
       Masc.Keeper_turn_sandbox_runtime.microvm_remote_endpoint_of_running
         docker ~container_name
     with
     | Ok _ -> Alcotest.fail "a Docker keeper must not become a guest endpoint"
     | Error message ->
       Alcotest.(check bool) "refusal is named" true
         (String.starts_with ~prefix:"microvm_remote_endpoint_requires_microvm:" message))
;;

(* The volume probe's ambiguity: [container volume inspect] exits 1 for an
   absent volume and for a stopped container system alike. *)

let wexited code stdout stderr = Unix.WEXITED code, stdout, stderr

let listing_json names =
  "["
  ^ String.concat
      ","
      (List.map
         (fun n ->
           Printf.sprintf {|{"id":%S,"configuration":{"name":%S,"format":"ext4"}}|} n n)
         names)
  ^ "]"
;;

let test_volume_names_of_json_reads_ids () =
  let json = Yojson.Safe.from_string (listing_json [ "a"; "masc-keeper-work-polisher" ]) in
  match M.volume_names_of_json json with
  | Error e -> Alcotest.failf "expected Ok, got %S" e
  | Ok names ->
    Alcotest.(check (list string))
      "ids in order"
      [ "a"; "masc-keeper-work-polisher" ]
      names
;;

let test_volume_names_of_json_refuses_non_arrays () =
  match M.volume_names_of_json (`String "nope") with
  | Ok _ -> Alcotest.fail "expected Error for a non-array payload"
  | Error _ -> ()
;;

let test_volume_probe_exit_zero_is_present () =
  Alcotest.(check bool)
    "inspect 0 needs no listing"
    true
    (M.classify_volume_probe
       ~volume_name:"v"
       ~inspect:(wexited 0 "{}" "")
       ~listing:None
     = M.Volume_present)
;;

let test_volume_probe_confirms_exit_one_against_the_listing () =
  (* The point of the second command: exit 1 alone does not distinguish
     "no such volume" from a stopped container system, and creating over an
     existing volume would land on a keeper's build cache. *)
  Alcotest.(check bool)
    "absent when the listing does not carry it"
    true
    (M.classify_volume_probe
       ~volume_name:"masc-keeper-work-polisher"
       ~inspect:(wexited 1 "" "not found")
       ~listing:(Some (wexited 0 (listing_json [ "other" ]) ""))
     = M.Volume_absent);
  Alcotest.(check bool)
    "present when the listing does carry it, despite inspect exiting 1"
    true
    (M.classify_volume_probe
       ~volume_name:"masc-keeper-work-polisher"
       ~inspect:(wexited 1 "" "not found")
       ~listing:(Some (wexited 0 (listing_json [ "masc-keeper-work-polisher" ]) ""))
     = M.Volume_present)
;;

let test_volume_probe_refuses_to_guess () =
  let failed = function
    | M.Volume_probe_failed _ -> true
    | _ -> false
  in
  Alcotest.(check bool)
    "exit 1 with no listing is not read as absence"
    true
    (failed
       (M.classify_volume_probe
          ~volume_name:"v"
          ~inspect:(wexited 1 "" "")
          ~listing:None));
  Alcotest.(check bool)
    "a failing listing is not read as absence"
    true
    (failed
       (M.classify_volume_probe
          ~volume_name:"v"
          ~inspect:(wexited 1 "" "")
          ~listing:(Some (wexited 125 "" "container system is not running"))));
  Alcotest.(check bool)
    "invalid listing JSON is not read as absence"
    true
    (failed
       (M.classify_volume_probe
          ~volume_name:"v"
          ~inspect:(wexited 1 "" "")
          ~listing:(Some (wexited 0 "not json" ""))));
  Alcotest.(check bool)
    "an unexpected inspect status is not read as presence"
    true
    (failed
       (M.classify_volume_probe ~volume_name:"v" ~inspect:(wexited 3 "" "") ~listing:None))
;;

let () =
  Alcotest.run
    "keeper_sandbox_microvm"
    [ ( "argv"
      , [ Alcotest.test_case "omits flags container rejects" `Quick
            test_omits_flags_container_rejects
        ; Alcotest.test_case "keeps the hardening container accepts" `Quick
            test_keeps_the_hardening_container_accepts
        ; Alcotest.test_case "never mounts the host playground" `Quick
            test_never_mounts_the_host_playground
        ; Alcotest.test_case "closed network is spelled on the command" `Quick
            test_closed_network_is_spelled_on_the_command
        ; Alcotest.test_case "image probe uses structured evidence" `Quick
            test_image_probe_uses_structured_evidence
        ; Alcotest.test_case "live structured image probe" `Slow
            test_live_structured_image_probe
        ; Alcotest.test_case "sweeps only guests whose owner is gone" `Quick
            test_only_guests_whose_owner_is_gone
        ; Alcotest.test_case "lists only this Keeper's Apple Container VM" `Quick
            test_live_container_listing_is_scoped_to_the_keeper
        ; Alcotest.test_case "leaves containers that are not guests" `Quick
            test_leaves_containers_that_are_not_guests
        ; Alcotest.test_case "leaves a foreign-base guest untouched" `Quick
            test_leaves_foreign_base_guest_untouched
        ; Alcotest.test_case "leaves guests it cannot account for" `Quick
            test_leaves_guests_it_cannot_account_for
        ; Alcotest.test_case "skips listing when CLI is unavailable" `Quick
            test_sweep_skips_listing_when_cli_is_unavailable
        ] )
    ; ( "refusal"
      , [ Alcotest.test_case "docker shell entrypoint refuses" `Quick
            test_docker_shell_entrypoint_refuses_microvm
        ; Alcotest.test_case "docker bash entrypoint refuses" `Quick
            test_docker_bash_entrypoint_refuses_microvm
        ] )
    ; ( "turn"
      , [ Alcotest.test_case "factory resolves to a profile-carrying runtime" `Quick
            test_factory_resolves_microvm_to_a_profile_carrying_runtime
        ; Alcotest.test_case "guest target follows the factory contract" `Quick
            test_guest_target_follows_the_factory_contract
        ; Alcotest.test_case "guest target refuses a profile mismatch" `Quick
            test_guest_target_refuses_a_profile_mismatch
        ; Alcotest.test_case "docker-shaped exec refuses a microvm keeper" `Quick
            test_docker_shaped_exec_refuses_a_microvm_keeper
        ; Alcotest.test_case "spawn does not cross the guest boundary" `Quick
            test_spawn_does_not_cross_the_guest_boundary
        ; Alcotest.test_case "echoes name the host bundle" `Quick
            test_echoes_name_the_host_bundle
        ; Alcotest.test_case "turn start argv shape" `Quick
            test_turn_start_argv_shape
        ; Alcotest.test_case "inspect state parser" `Quick
            test_inspect_state_parser
        ; Alcotest.test_case "live guest cat (MASC_MICROVM_LIVE=1)" `Slow
            test_live_turn_runtime_cat
        ] )
    ; ( "work volume"
      , [ Alcotest.test_case "work volume is named and mounted at its root" `Quick
            test_work_volume_is_named_and_mounted_at_its_root
        ; Alcotest.test_case "create argv carries a size" `Quick
            test_volume_create_argv_carries_a_size
        ; Alcotest.test_case "shim travels read-only with its config" `Quick
            test_shim_travels_read_only_with_its_config
        ; Alcotest.test_case "keeper work root is created as root with a mode" `Quick
            test_keeper_work_root_is_created_as_root_with_a_mode
        ; Alcotest.test_case "keeper work root write probe runs as the keeper" `Quick
            test_keeper_work_root_write_probe_runs_as_the_keeper
        ; Alcotest.test_case "running guest is a remote endpoint" `Quick
            test_running_guest_is_a_remote_endpoint
        ] )
    ; ( "work volume provisioning"
      , [ Alcotest.test_case "volume names parse from the listing" `Quick
            test_volume_names_of_json_reads_ids
        ; Alcotest.test_case "listing must be an array" `Quick
            test_volume_names_of_json_refuses_non_arrays
        ; Alcotest.test_case "exit 0 is present" `Quick
            test_volume_probe_exit_zero_is_present
        ; Alcotest.test_case "exit 1 is confirmed against the listing" `Quick
            test_volume_probe_confirms_exit_one_against_the_listing
        ; Alcotest.test_case "ambiguity is never read as absence" `Quick
            test_volume_probe_refuses_to_guess
        ] )
    ; ( "guest env"
      , [ Alcotest.test_case "env follows the config mount" `Quick
            test_guest_env_follows_the_config_mount
        ; Alcotest.test_case "names exactly the config env" `Quick
            test_guest_env_names_exactly_the_config_env
        ; Alcotest.test_case
            "docker lane disables git terminal prompts"
            `Quick
            test_docker_lane_disables_git_terminal_prompts
        ; Alcotest.test_case "docker lane keeps the full env" `Quick
            test_docker_lane_keeps_the_full_env
        ] )
    ]
