open Alcotest
module Agent = Masc.Keeper_microvm_agent_socket
module Plan = Masc.Keeper_microvm_boot_plan
module Sandbox = Masc.Keeper_sandbox_microvm
module Backend = Masc.Keeper_microvm_backend
module Inventory = Masc.Keeper_microvm_guest_inventory
module Size = Keeper_microvm_guest_size

let value = function Ok value -> value | Error detail -> fail detail

(* The keeper's own parts of the plan, as requested_apple_plan passes them. *)
let fixture_image = "fixture:image"
let fixture_size = {Size.memory = value (Size.memory_of_string "2g"); cpus = value (Size.cpus_of_int 4)}
let fixture_mounts =
  [ Plan.Host_dir {source = "/host/identity"; destination = "/guest/identity"; read_only = true}
  ; Plan.Named_volume {name = "masc-keeper-work-fixture"; destination = Sandbox.work_volume_guest_root}
  ; Plan.Host_dir {source = "/host/shim"; destination = Sandbox.shim_guest_dir; read_only = true} ]
let fixture_environment = ["GH_CONFIG_DIR", "/guest/identity"]
let fixture_labels = ["masc.mcp.keeper", "fixture"; Sandbox.microvm_backend_label_key, "apple_container"]

let plan_publishing host_socket =
  Agent.plan ~uid:502 ~gid:20 ~host_socket ~image:fixture_image ~guest_size:fixture_size
    ~mounts:fixture_mounts ~network:Plan.Network_none ~environment:fixture_environment
    ~labels:fixture_labels

let host_socket = Agent.host_path ~base_path:"/Users/keeper/me" ~guest_name:"masc-keeper-vm-fixture"
let agent_plan = plan_publishing host_socket

(* ── where the socket is ─────────────────────────────────────────────── *)

let test_the_host_path_is_named_by_the_guest () =
  let path guest_name = Agent.host_path ~base_path:"/Users/keeper/me" ~guest_name in
  check string "the same guest names the same socket" (path "masc-keeper-vm-a") (path "masc-keeper-vm-a");
  check bool "another guest names another" true (path "masc-keeper-vm-a" <> path "masc-keeper-vm-b");
  let directory = Config_dir_resolver.microvm_agent_socket_dir ~base_path:"/Users/keeper/me" in
  check string "under the agent directory" directory (Filename.dirname (path "masc-keeper-vm-a"));
  let name = Filename.basename (path "masc-keeper-vm-a") in
  check bool "sixteen hex digits and .sock" true
    (String.length name = 21 && Filename.check_suffix name ".sock"
     && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
          (Filename.chop_suffix name ".sock"))

(* The longest guest name a keeper can have: the name module cuts a long
   keeper name to its limit. *)
let longest_guest_name ~base_path =
  Masc.Keeper_sandbox_container_name.(
    make
      (Micro_vm_persistent
         { keeper_name = String.make 200 'k'
         ; network_mode = Keeper_types_profile_sandbox.Network_inherit
         ; base_path })
    |> to_string)

(* Under a home directory base path: a name spelled into the path would pass
   macOS's limit. *)
let test_the_longest_guest_name_fits_the_socket_limit () =
  let base_path = "/Users/a-rather-long-account-name/me" in
  let path = Agent.host_path ~base_path ~guest_name:(longest_guest_name ~base_path) in
  check bool "the plan's socket path check accepts it" true
    (Plan.validate (plan_publishing path) = Ok ())

(* Linux's [sun_path] holds 108 bytes, the last a NUL. *)
let linux_socket_path_limit = 107

(* apple/container 1.6.1's vminitd connects to a published guest socket under
   the guest's root as it sees it, and refuses a path past the limit with "is
   too long for a Unix Domain Socket path". *)
let vminitd_path ~guest_name = "/run/container/" ^ guest_name ^ "/rootfs" ^ Agent.guest_path

let test_vminitd_reaches_the_agent_of_the_longest_guest_name () =
  let guest_name = longest_guest_name ~base_path:"/Users/keeper/me" in
  let path = vminitd_path ~guest_name in
  check bool
    (Printf.sprintf "%d bytes fit the socket path" (String.length path))
    true
    (String.length path <= linux_socket_path_limit)

let test_a_base_path_too_long_for_a_socket_is_refused () =
  let path = Agent.host_path ~base_path:("/" ^ String.make 90 'b') ~guest_name:"masc-keeper-vm-fixture" in
  match Plan.validate (plan_publishing path) with
  | Error [Plan.Invalid_published_socket {path = refused; problem = Plan.Too_long _}] ->
    check string "the host path is named" path refused
  | Error _ | Ok () -> fail "a host socket past the limit is refused before boot"

(* ── the agent plan ──────────────────────────────────────────────────── *)

let test_the_agent_plan_starts_the_agent_as_root () =
  check string "root first process" "0:0" agent_plan.user;
  check (list string) "the shim serves the guest socket for the keeper's ids"
    [Sandbox.shim_guest_path; Exec_ssh_protocol.Relay.serve_flag; Agent.guest_path; "502:20"]
    agent_plan.command;
  check bool "the agent re-mounts the root itself" false
    (List.mem Backend.Read_only_rootfs agent_plan.isolation);
  check bool "every other constraint holds, in order" true
    (agent_plan.isolation
     = List.filter (fun c -> c <> Backend.Read_only_rootfs) Backend.all_guest_constraints);
  check (list string) "three capabilities come back"
    ["CAP_SETUID"; "CAP_SETGID"; "CAP_SYS_ADMIN"]
    (List.map Plan.capability_to_string agent_plan.capabilities_added);
  check bool "the socket is published" true
    (agent_plan.published_sockets = [{Plan.host_path = host_socket; guest_path = Agent.guest_path}])

(* The agent hands its own environment and working directory to every
   request, so the shim finds its config and a writable HOME. *)
let test_the_agent_carries_what_each_request_runs_with () =
  let inherited = List.length fixture_environment in
  let added = List.filteri (fun index _ -> index >= inherited) agent_plan.environment in
  check (list (pair string string)) "the environment a request runs with"
    (Sandbox.request_environment ~shim_config_path:Sandbox.shim_config_guest_path) added;
  check string "a request starts on the work volume"
    Sandbox.work_volume_guest_root agent_plan.working_directory;
  check bool "the identity wiring comes first, unchanged" true
    (List.filteri (fun index _ -> index < inherited) agent_plan.environment = fixture_environment)

let test_the_relay_version_is_part_of_the_plan () =
  check (pair string string) "the relay label"
    ("masc.mcp.agent_relay", string_of_int Exec_ssh_protocol.Relay.version) Agent.relay_label;
  check bool "carried as a stable label" true (List.mem Agent.relay_label agent_plan.labels);
  let other_relay = {agent_plan with labels = fixture_labels @ [fst Agent.relay_label, "0"]} in
  check bool "another relay version is another plan" true
    (Plan.digest other_relay <> Plan.digest agent_plan)

let test_the_rest_is_the_keepers () =
  check bool "image, size, mounts and network are the keeper's" true
    (agent_plan.image = fixture_image && agent_plan.guest_size = fixture_size
     && agent_plan.mounts = fixture_mounts && agent_plan.network = Plan.Network_none);
  check bool "the plan is admissible" true (Plan.validate agent_plan = Ok ());
  match Sandbox.apple_turn_start_argv ~container_name:"fixture" ~plan:agent_plan
          ~lifecycle_labels:[] ~dns:None ~policy_proxy:None with
  | Error _ -> fail "the agent plan renders"
  | Ok argv ->
    check bool "the rendered boot publishes the socket" true
      (List.mem (host_socket ^ ":" ^ Agent.guest_path) argv)

(* ── how a running guest is reached ──────────────────────────────────── *)

let facts_publishing published_sockets : Plan.facts =
  { plan_label = None; image = "fixture:image"
  ; image_identity =
      ({ descriptor_digest = "sha256:fixture"
       ; platform = { architecture = "arm64"; os = "linux"; variant = None } }
       : Masc.Keeper_microvm_image_command.identity)
  ; cpus = 4; memory_bytes = 2_147_483_648L; user = "0:0"
  ; working_directory = Sandbox.work_volume_guest_root; command = agent_plan.command
  ; mounts = []; read_only = false; cap_drop = ["ALL"]
  ; cap_add = List.map Plan.capability_to_string agent_plan.capabilities_added
  ; published_sockets; use_init = false; networks = []; environment = []; labels = [] }

let test_only_its_own_socket_is_the_agent () =
  let base_path = "/Users/keeper/me" and guest_name = "masc-keeper-vm-fixture" in
  let publishes published =
    Agent.publishes_agent ~base_path ~guest_name (facts_publishing published) in
  let own = {Plan.host_path = Agent.host_path ~base_path ~guest_name; guest_path = Agent.guest_path} in
  check bool "the agent socket at its own host path" true (publishes [own]);
  check bool "nothing published" false (publishes []);
  check bool "another guest's host path" false
    (publishes [{own with host_path = Agent.host_path ~base_path ~guest_name:"masc-keeper-vm-other"}]);
  check bool "another guest-side path" false
    (publishes [{own with guest_path = "/run/other.sock"}])

(* ── the host path before boot ───────────────────────────────────────── *)

let with_base f =
  let base = Filename.temp_dir "masc-agent-socket-" "" in
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Filename.quote_command "rm" ["-rf"; base])))
    (fun () -> f (Filename.concat (Filename.concat base "microvm") "agent"))

let leave_a_socket path =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.bind fd (Unix.ADDR_UNIX path))

let kind path = (Unix.lstat path).Unix.st_kind
let reads = ref 0
let presence answer () = incr reads; answer

let test_a_missing_directory_is_made_private () =
  with_base (fun directory ->
    reads := 0;
    let path = Filename.concat directory "a.sock" in
    check bool "prepared" true
      (Agent.prepare_host_socket ~guest_presence:(presence (Ok Inventory.Absent)) path = Ok ());
    check int "0700" 0o700 (Unix.lstat directory).Unix.st_perm;
    check int "nothing to remove, so the runtime is not asked" 0 !reads)

let test_an_open_directory_is_closed () =
  with_base (fun directory ->
    Unix.mkdir (Filename.dirname directory) 0o700;
    Unix.mkdir directory 0o755;
    Unix.chmod directory 0o755;
    check bool "prepared" true
      (Agent.prepare_host_socket ~guest_presence:(presence (Ok Inventory.Absent))
         (Filename.concat directory "a.sock") = Ok ());
    check int "0700" 0o700 (Unix.lstat directory).Unix.st_perm)

let test_a_left_socket_goes_only_with_its_guest () =
  with_base (fun directory ->
    let path = Filename.concat directory "a.sock" in
    let prepare answer = Agent.prepare_host_socket ~guest_presence:(presence answer) path in
    check bool "the directory" true (prepare (Ok Inventory.Absent) = Ok ());
    leave_a_socket path;
    (match prepare (Ok Inventory.Present) with
     | Error Agent.Guest_still_present -> ()
     | Ok () | Error _ -> fail "a listed guest keeps the socket");
    check bool "kept while its guest is listed" true (kind path = Unix.S_SOCK);
    (match prepare (Error "listing timed out") with
     | Error (Agent.Guest_presence_unknown _) -> ()
     | Ok () | Error _ -> fail "an unanswered listing keeps the socket");
    check bool "kept while nobody knows" true (kind path = Unix.S_SOCK);
    check bool "removed once the guest is gone" true (prepare (Ok Inventory.Absent) = Ok ());
    check bool "gone" false (Sys.file_exists path))

let test_what_is_not_a_socket_is_left_alone () =
  with_base (fun directory ->
    let path = Filename.concat directory "a.sock" in
    let prepare () = Agent.prepare_host_socket ~guest_presence:(presence (Ok Inventory.Absent)) path in
    check bool "the directory" true (prepare () = Ok ());
    Out_channel.with_open_bin path (fun channel -> output_string channel "operator note");
    (match prepare () with
     | Error (Agent.Path_occupied {path = occupied}) -> check string "named" path occupied
     | Ok () | Error _ -> fail "a regular file is not removed");
    check bool "still there" true (kind path = Unix.S_REG))

(* Kinds come from lstat: a linked directory is not used, and a link where
   the socket goes is left in place even when its target is a socket. *)
let test_links_are_not_followed () =
  with_base (fun directory ->
    let elsewhere = Filename.concat (Filename.dirname directory) "elsewhere" in
    Unix.mkdir (Filename.dirname directory) 0o700;
    Unix.mkdir elsewhere 0o700;
    Unix.symlink elsewhere directory;
    let path = Filename.concat directory "a.sock" in
    let prepare () = Agent.prepare_host_socket ~guest_presence:(presence (Ok Inventory.Absent)) path in
    (match prepare () with
     | Error (Agent.Directory_unusable {path = refused; _}) ->
       check string "the linked directory is named" directory refused
     | Ok () | Error _ -> fail "a linked directory is refused");
    Unix.unlink directory;
    check bool "a real directory" true (prepare () = Ok ());
    let target = Filename.concat elsewhere "b.sock" in
    leave_a_socket target;
    Unix.symlink target path;
    (match prepare () with
     | Error (Agent.Path_occupied {path = occupied}) -> check string "named" path occupied
     | Ok () | Error _ -> fail "a link where the socket goes is not removed");
    check bool "the link stays" true (kind path = Unix.S_LNK);
    check bool "and its target" true (kind target = Unix.S_SOCK))

let test_a_directory_that_is_a_file_is_refused () =
  with_base (fun directory ->
    Unix.mkdir (Filename.dirname directory) 0o700;
    Out_channel.with_open_bin directory (fun _ -> ());
    match Agent.prepare_host_socket ~guest_presence:(presence (Ok Inventory.Absent))
            (Filename.concat directory "a.sock") with
    | Error (Agent.Directory_unusable {path; _}) -> check string "the directory is named" directory path
    | Ok () | Error _ -> fail "a file where the directory goes is refused")

let () =
  run "keeper_microvm_agent_socket"
    [ "host path",
      [ test_case "named by the guest" `Quick test_the_host_path_is_named_by_the_guest
      ; test_case "the longest guest name fits" `Quick test_the_longest_guest_name_fits_the_socket_limit
      ; test_case "vminitd reaches the agent of the longest name" `Quick
          test_vminitd_reaches_the_agent_of_the_longest_guest_name
      ; test_case "a base path too long is refused" `Quick test_a_base_path_too_long_for_a_socket_is_refused ]
    ; "plan",
      [ test_case "the agent starts as root" `Quick test_the_agent_plan_starts_the_agent_as_root
      ; test_case "carries what each request runs with" `Quick
          test_the_agent_carries_what_each_request_runs_with
      ; test_case "the relay version is part of the plan" `Quick test_the_relay_version_is_part_of_the_plan
      ; test_case "the rest is the keeper's" `Quick test_the_rest_is_the_keepers ]
    ; "reached",
      [ test_case "only its own socket is the agent" `Quick test_only_its_own_socket_is_the_agent ]
    ; "before boot",
      [ test_case "a missing directory is made private" `Quick test_a_missing_directory_is_made_private
      ; test_case "an open directory is closed" `Quick test_an_open_directory_is_closed
      ; test_case "a left socket goes only with its guest" `Quick test_a_left_socket_goes_only_with_its_guest
      ; test_case "what is not a socket is left alone" `Quick test_what_is_not_a_socket_is_left_alone
      ; test_case "links are not followed" `Quick test_links_are_not_followed
      ; test_case "a directory that is a file is refused" `Quick test_a_directory_that_is_a_file_is_refused ] ]
