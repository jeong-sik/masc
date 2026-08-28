(* The argv is built before anything can run it, so these tests are what say
   it is right. Measured against container CLI 1.3.0 on 2026-08-28: every
   flag asserted here was accepted by a live `container run`, and the two in
   [unsupported_docker_flags] were rejected with "Unknown option". *)

module M = Masc.Keeper_sandbox_microvm
module Profile = Keeper_types_profile_sandbox

let argv ?(network = Profile.Network_none) () =
  M.run_argv
    ~container_name:"masc-keeper-turn-probe"
    ~container_root:"/home/keeper/playground/probe"
    ~container_cwd:"/home/keeper/playground/probe"
    ~host_root:"/base/.masc/playground/microvm/probe"
    ~image:"masc-keeper-sandbox:local"
    ~network_args:(M.network_args ~dns:(Some "1.1.1.1") network)
    ~uid:501
    ~gid:20
    ~env_args:[ "--env"; "MASC_PROBE=1" ]
    ~memory:"2g"

let contains needle haystack = List.exists (String.equal needle) haystack

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
           "run_argv passes %s, which container run rejects with \"Unknown \
            option\" -- every call would fail"
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

let test_mounts_the_keeper_root_at_the_guest_root () =
  let a = argv () in
  Alcotest.(check bool)
    "mounts host root at container root"
    true
    (adjacent
       ~flag:"--volume"
       ~value:"/base/.masc/playground/microvm/probe:/home/keeper/playground/probe"
       a);
  Alcotest.(check bool)
    "starts in the guest cwd"
    true
    (adjacent ~flag:"--workdir" ~value:"/home/keeper/playground/probe" a)

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
    "the closed network reaches run_argv"
    true
    (adjacent ~flag:"--network" ~value:"none" (argv ~network:Profile.Network_none ()));
  Alcotest.(check bool)
    "an inherit guest is given a resolver"
    true
    (adjacent ~flag:"--dns" ~value:"1.1.1.1" (argv ~network:Profile.Network_inherit ()))

let test_image_and_shell_come_last () =
  let a = argv () in
  match List.rev a with
  | "-s" :: "-l" :: "bash" :: image :: _ ->
    Alcotest.(check string) "image precedes the shell" "masc-keeper-sandbox:local" image
  | rest ->
    Alcotest.failf
      "argv must end with <image> bash -l -s, got: %s"
      (String.concat " " (List.rev rest))

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
      ; ("allowed_paths", `List [ `String "*" ])
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> { meta with sandbox_profile = Profile.Micro_vm }
  | Error e -> Alcotest.fail e

let refusal = Profile.backend_unimplemented_message Profile.Micro_vm

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f

let test_factory_resolves_microvm_to_a_profile_carrying_runtime () =
  with_eio_fs @@ fun () ->
  let base = temp_dir "microvm_factory_" in
  let config = Masc.Workspace.default_config base in
  let meta = microvm_meta ~name:"vm-runtime-factory" in
  let factory = Masc.Keeper_sandbox_factory.create ~config ~meta ~turn_id:7 () in
  (match
     Masc.Keeper_sandbox_factory.resolve
       factory
       ~cwd:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta)
   with
   | Runtime _ ->
     (* The runtime carries the profile; every CLI it builds branches on
        it, which the argv pins below and the docker-entrypoint refusals
        keep honest. *)
     ()
   | Backend_unimplemented _ ->
     Alcotest.fail
       "factory still refuses Micro_vm; the turn runtime now carries the \
        profile and must be resolved"
   | No_factory | Local_profile ->
     Alcotest.fail "expected a runtime for Micro_vm");
  Masc.Keeper_sandbox_factory.cleanup factory

let test_turn_start_argv_shape () =
  let a =
    M.turn_start_argv
      ~container_name:"masc-keeper-turn-probe"
      ~label_args:[ "--label"; "masc.mcp.kind=turn" ]
      ~uid:501
      ~gid:20
      ~memory:"2g"
      ~host_root:"/base/.masc/playground/microvm/probe"
      ~container_root:"/home/keeper/playground/probe"
      ~network_args:(M.network_args ~dns:None Profile.Network_none)
      ~image:"masc-keeper-sandbox:local"
  in
  List.iter
    (fun flag ->
       if contains flag a
       then Alcotest.failf "turn_start_argv passes %s (container rejects it)" flag)
    M.unsupported_docker_flags;
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
    [ "-d"; "--rm"; "--read-only"; "--label" ]

let test_inspect_state_parser () =
  let running =
    {|[{"configuration":{"id":"x"},"status":{"state":"running","startedDate":"now"}}]|}
  in
  let stopped =
    {|[{"configuration":{"id":"x"},"status":{"state":"stopped"}}]|}
  in
  (match M.running_of_inspect_json running with
   | Ok true -> ()
   | Ok false | Error _ -> Alcotest.fail "running JSON must parse as running");
  (match M.running_of_inspect_json stopped with
   | Ok false -> ()
   | Ok true | Error _ -> Alcotest.fail "stopped JSON must parse as not running");
  match M.running_of_inspect_json "not json" with
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
    let oc = open_out (Filename.concat host_root "probe.txt") in
    output_string oc "hello-from-microvm\n";
    close_out oc;
    let cat runtime =
      match
        Masc.Keeper_turn_sandbox_runtime.run_command_with_status
          ~timeout_sec:60.0
          runtime
          ~cwd:host_root
          ~command_argv:[ "cat"; "probe.txt" ]
          ~max_bytes:4096
          ()
      with
      | Ok (Unix.WEXITED 0, out) ->
        if not (Astring.String.is_infix ~affix:"hello-from-microvm" out)
        then Alcotest.failf "guest cat returned unexpected output: %s" out
      | Ok (st, out) ->
        Alcotest.failf
          "guest cat failed: %s: %s"
          (match st with
           | Unix.WEXITED n -> Printf.sprintf "exit %d" n
           | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
           | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
          out
      | Error message -> Alcotest.failf "guest cat errored: %s" message
    in
    Fun.protect
      ~finally:(fun () ->
        match
          Masc.Keeper_turn_sandbox_runtime.teardown_keeper_vm ~config ~meta ()
        with
        | Ok () -> ()
        | Error message -> Alcotest.failf "teardown failed: %s" message)
      (fun () ->
         (* Turn 1 pays the boot. *)
         let turn1 =
           Masc.Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:99 ()
         in
         let boot_started = Unix.gettimeofday () in
         cat turn1;
         let booted_in = Unix.gettimeofday () -. boot_started in
         Masc.Keeper_turn_sandbox_runtime.cleanup turn1;
         (* Turn 2 must adopt the surviving guest, not boot a second one. *)
         let turn2 =
           Masc.Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:100 ()
         in
         let reuse_started = Unix.gettimeofday () in
         cat turn2;
         let reused_in = Unix.gettimeofday () -. reuse_started in
         Masc.Keeper_turn_sandbox_runtime.cleanup turn2;
         (* The boot dominates turn 1 (>=2s VM start); adoption must not
            pay it again. Generous bounds — this pins reuse, not speed. *)
         if reused_in >= booted_in
         then
           Alcotest.failf
             "turn 2 (%.1fs) was not faster than turn 1 (%.1fs); the guest \
              was rebooted instead of adopted"
             reused_in
             booted_in);
    (* After teardown the stable name must be gone. *)
    (match
       Masc.Keeper_turn_sandbox_runtime.teardown_keeper_vm ~config ~meta ()
     with
     | Ok () -> ()
     | Error message ->
       Alcotest.failf "teardown of an absent guest must be Ok: %s" message)

let () =
  Alcotest.run
    "keeper_sandbox_microvm"
    [ ( "argv"
      , [ Alcotest.test_case "omits flags container rejects" `Quick
            test_omits_flags_container_rejects
        ; Alcotest.test_case "keeps the hardening container accepts" `Quick
            test_keeps_the_hardening_container_accepts
        ; Alcotest.test_case "mounts the keeper root at the guest root" `Quick
            test_mounts_the_keeper_root_at_the_guest_root
        ; Alcotest.test_case "closed network is spelled on the command" `Quick
            test_closed_network_is_spelled_on_the_command
        ; Alcotest.test_case "image and shell come last" `Quick
            test_image_and_shell_come_last
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
        ; Alcotest.test_case "turn start argv shape" `Quick
            test_turn_start_argv_shape
        ; Alcotest.test_case "inspect state parser" `Quick
            test_inspect_state_parser
        ; Alcotest.test_case "live guest cat (MASC_MICROVM_LIVE=1)" `Slow
            test_live_turn_runtime_cat
        ] )
    ]
