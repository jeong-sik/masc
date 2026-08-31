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
  let factory = Masc.Keeper_sandbox_factory.create ~config ~meta () in
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
   | No_factory | Local_profile ->
     Alcotest.fail "expected a runtime for Micro_vm"
   | Remote_ssh_profile ->
     Alcotest.fail "microvm meta must never resolve to Remote_ssh_profile");
  Masc.Keeper_sandbox_factory.cleanup factory

let test_turn_start_argv_shape () =
  let a =
    M.turn_start_argv
      ~container_name:"masc-keeper-turn-probe"
      ~label_args:[ "--label"; "masc.mcp.kind=turn" ]
      ~uid:501
      ~gid:20
      ~memory:"2g"
      ~cpus:None
      ~host_root:"/base/.masc/playground/microvm/probe"
      ~container_root:"/home/keeper/playground/probe"
      ~network_args:(M.network_args ~dns:None Profile.Network_none)
      ~mount_args:[ "-v"; "/base/.masc/config:/home/keeper/.masc/config:ro" ]
      ~image:"masc-keeper-sandbox:local"
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
    M.turn_start_argv
      ~container_name:"masc-keeper-turn-probe"
      ~label_args:[]
      ~uid:501
      ~gid:20
      ~memory:"8g"
      ~cpus:(Some "8")
      ~host_root:"/base/.masc/playground/microvm/probe"
      ~container_root:"/home/keeper/playground/probe"
      ~network_args:[]
      ~mount_args:[]
      ~image:"masc-keeper-sandbox:local"
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
         let turn1 =
           Masc.Keeper_turn_sandbox_runtime.create ~config ~meta ()
         in
         let boot_started = Unix.gettimeofday () in
         let first_secret = prepare_identity turn1 in
         let first_snapshot_dir = Filename.dirname first_secret in
         cat turn1;
         let booted_in = Unix.gettimeofday () -. boot_started in
         Masc.Keeper_turn_sandbox_runtime.cleanup turn1;
         if not (Sys.file_exists first_snapshot_dir)
         then Alcotest.fail "turn cleanup removed the running guest's identity";
         (* Turn 2 must adopt the surviving guest, not boot a second one. *)
         let turn2 =
           Masc.Keeper_turn_sandbox_runtime.create ~config ~meta ()
         in
         let reuse_started = Unix.gettimeofday () in
         let second_secret = prepare_identity turn2 in
         Alcotest.(check string)
           "the adopted guest keeps the same identity snapshot"
           first_secret
           second_secret;
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
         let turn3 =
           Masc.Keeper_turn_sandbox_runtime.create ~config ~meta ()
         in
         let third_secret = prepare_identity turn3 in
         let third_snapshot_dir = Filename.dirname third_secret in
         final_snapshot_dir := Some third_snapshot_dir;
         if String.equal first_secret third_secret
         then Alcotest.fail "identity refresh reused the superseded snapshot";
         if Sys.file_exists first_snapshot_dir
         then Alcotest.fail "identity refresh left the superseded snapshot on disk";
         cat turn3;
         Masc.Keeper_turn_sandbox_runtime.cleanup turn3);
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

let microvm_env ~base_path =
  Masc.Keeper_sandbox_runtime.sandbox_exec_env_args
    ~microvm:true
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

let test_guest_env_omits_stores_it_has_no_mount_for () =
  with_config_base (fun base_path ->
    let names_stores =
      List.exists
        (fun arg ->
          String.length arg >= 26
          && String.equal (String.sub arg 0 26) "MASC_KEEPER_MOUNTED_STORES")
        (microvm_env ~base_path)
    in
    Alcotest.(check bool)
      "the guest has no workspace-state mounts to name"
      false
      names_stores)

let test_docker_lane_keeps_the_full_env () =
  with_config_base (fun base_path ->
    let docker_env =
      Masc.Keeper_sandbox_runtime.sandbox_exec_env_args
        ~microvm:false
        ~base_path
        ~container_root:env_container_root
    in
    List.iter
      (fun arg ->
        if not (List.mem arg docker_env)
        then Alcotest.failf "docker lane dropped %S the microvm lane carries" arg)
      (microvm_env ~base_path))

(* task-847: a sandbox has no terminal, so a git that wants to prompt fails
   immediately instead of hanging the call. The credential wiring itself is
   the identity snapshot's knowledge, not this env's — pinned in the
   keeper_github_identity suite. *)
let test_docker_lane_disables_git_terminal_prompts () =
  with_config_base (fun base_path ->
    let docker_env =
      Masc.Keeper_sandbox_runtime.sandbox_exec_env_args
        ~microvm:false
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

let entry ?(kind = "keeper-vm") ?owner_pid ?(keeper = "probe") id =
  let labels =
    [ "masc.mcp.kind", `String kind; "masc.mcp.keeper", `String keeper ]
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
    (ids (M.sweep_candidates_of_json ~is_pid_alive listing))

(* A turn container carries a different kind and is swept by the docker
   path; taking it here would remove a container mid-turn. *)
let test_leaves_containers_that_are_not_guests () =
  let listing =
    `List [ entry ~kind:"oneshot" ~owner_pid:(string_of_int dead_pid) "turn-container" ]
  in
  Alcotest.(check (list string))
    "a non-guest is not a sweep target"
    []
    (ids (M.sweep_candidates_of_json ~is_pid_alive listing))

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
    (ids (M.sweep_candidates_of_json ~is_pid_alive listing))

let test_sweep_skips_listing_when_cli_is_unavailable () =
  let spawn_count = ref 0 in
  let run_argv ~timeout_sec:_ _argv =
    incr spawn_count;
    Unix.WEXITED 0, "[]"
  in
  let unavailable =
    M.sweep_abandoned_guests
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
        ; Alcotest.test_case "sweeps only guests whose owner is gone" `Quick
            test_only_guests_whose_owner_is_gone
        ; Alcotest.test_case "leaves containers that are not guests" `Quick
            test_leaves_containers_that_are_not_guests
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
        ; Alcotest.test_case "turn start argv shape" `Quick
            test_turn_start_argv_shape
        ; Alcotest.test_case "inspect state parser" `Quick
            test_inspect_state_parser
        ; Alcotest.test_case "live guest cat (MASC_MICROVM_LIVE=1)" `Slow
            test_live_turn_runtime_cat
        ] )
    ; ( "guest env"
      , [ Alcotest.test_case "env follows the config mount" `Quick
            test_guest_env_follows_the_config_mount
        ; Alcotest.test_case "omits stores it has no mount for" `Quick
            test_guest_env_omits_stores_it_has_no_mount_for
        ; Alcotest.test_case
            "docker lane disables git terminal prompts"
            `Quick
            test_docker_lane_disables_git_terminal_prompts
        ; Alcotest.test_case "docker lane keeps the full env" `Quick
            test_docker_lane_keeps_the_full_env
        ] )
    ]
