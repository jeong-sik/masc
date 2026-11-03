open Alcotest
module Plan = Masc.Keeper_microvm_boot_plan
module Sandbox = Masc.Keeper_sandbox_microvm
module Backend = Masc.Keeper_microvm_backend
module Size = Keeper_microvm_guest_size
module Image_command = Masc.Keeper_microvm_image_command

let value = function Ok value -> value | Error detail -> fail detail

let plan : Plan.t =
  { image = "fixture:image"
  ; guest_size = {Size.memory = value (Size.memory_of_string "2g"); cpus = value (Size.cpus_of_int 4)}
  ; user = "502:20"; working_directory = "/masc-work"
  ; command = ["tail"; "-f"; "/dev/null"]
  ; mounts =
      [ Plan.Named_volume {name = "masc-keeper-work-fixture"; destination = "/masc-work"}
      ; Plan.Host_dir {source = "/private-fixture/identity"; destination = "/guest/identity"; read_only = true} ]
  ; isolation = Backend.all_guest_constraints
  ; capabilities_added = []
  ; published_sockets = []
  ; network = Plan.Network_none
  ; environment = ["GH_CONFIG_DIR", "/guest/identity"; "GIT_AUTHOR_NAME", "fixture"]
  ; labels = ["masc.mcp.keeper", "fixture"; Sandbox.microvm_backend_label_key, "apple_container"]
  }

(* A guest whose first process is the shim's agent (RFC
   microvm-guest-agent-over-socket 3.6): root first process, a writable root,
   three capabilities given back and one published socket. *)
let agent_socket =
  {Plan.host_path = "/host/agents/fixture.sock"; guest_path = "/run/masc-agent/agent.sock"}

let agent_plan =
  { plan with
    user = "0:0"
  ; command = ["/opt/masc-exec-shim/masc-exec-shim"; "--serve"; agent_socket.guest_path; "502:20"]
  ; isolation = List.filter (fun guest_constraint -> guest_constraint <> Backend.Read_only_rootfs)
      Backend.all_guest_constraints
  ; capabilities_added = [Plan.Cap_setuid; Plan.Cap_setgid; Plan.Cap_sys_admin]
  ; published_sockets = [agent_socket]
  }

(* Shape observed from Apple 1.3.1, with independent synthetic values;
   publishedSockets and useInit as 1.6.1 reports them for every guest.
   Executable/user/network/mount variants are runtime wire shapes, not plan JSON.
   [None] leaves a key out. *)
let inspect ?(memory = `Int 2_147_483_648) ?(mount_kind = "volume") ?(extra = [])
    ?(published_sockets = Some (`List [])) ?(use_init = Some (`Bool false)) () =
  let optional key = function None -> [] | Some value -> [key, value] in
  let config =
    [ "id", `String "fixture"
    ; "image", `Assoc ["reference", `String "fixture:image"; "descriptor", `Assoc ["digest", `String "sha256:fixture-image"]]
    ; "platform", `Assoc ["architecture", `String "arm64"; "os", `String "linux"]
    ; "resources", `Assoc ["cpus", `Int 4; "memoryInBytes", memory]
    ; "initProcess", `Assoc
        [ "user", `Assoc ["raw", `Assoc ["userString", `String "502:20"]]
        ; "workingDirectory", `String "/masc-work"
        ; "executable", `String "tail"; "arguments", `List [`String "-f"; `String "/dev/null"]
        ; "environment", `List (List.map (fun value -> `String value)
            ["PATH=/image/bin"; "GH_CONFIG_DIR=/guest/identity"; "GIT_AUTHOR_NAME=fixture"]) ]
    ; "mounts", `List
        [ `Assoc ["destination", `String "/tmp"; "source", `String "tmpfs";
            "options", `List []; "type", `Assoc ["tmpfs", `Assoc []]]
        ; `Assoc ["destination", `String "/masc-work"; "source", `String "/runtime/volume.img";
            "options", `List []; "type", `Assoc [mount_kind, `Assoc ["name", `String "masc-keeper-work-fixture"]]]
        ; `Assoc ["destination", `String "/guest/identity"; "source", `String "/private-fixture/identity";
            "options", `List [`String "ro"]; "type", `Assoc ["virtiofs", `Assoc []]] ]
    ; "readOnly", `Bool true; "capDrop", `List [`String "ALL"]; "capAdd", `List [] ]
    @ optional "publishedSockets" published_sockets
    @ optional "useInit" use_init
    @ [ "networks", `List []
      ; "labels", `Assoc (List.map (fun (key, value) -> key, `String value)
          ((Plan.label_key, Plan.digest plan) :: plan.labels)) ]
  in
  Yojson.Safe.to_string (`List [`Assoc ["id", `String "fixture"; "configuration", `Assoc (extra @ config)]])

let reading raw = Sandbox.apple_guest_facts ~container_name:"fixture" raw
let facts () = match reading (inspect ()) with
  | Plan.Facts facts -> facts
  | Plan.Unreadable detail -> fail detail

(* An arm64/linux image inspection of [reference] whose descriptor is
   [descriptor_digest]. *)
let image_command_for ?(reference = plan.image) ?(descriptor_digest = "sha256:fixture-image") entrypoint =
  let identity : Image_command.identity =
    {descriptor_digest; platform={architecture="arm64"; os="linux"; variant=None}} in
  let config = `Assoc ["Entrypoint", `List (List.map (fun v -> `String v) entrypoint);
    "Cmd", `List [`String "/bin/bash"]] in
  let raw = Yojson.Safe.to_string (`List [`Assoc [
    "id", `String "fixture-image";
    "configuration", `Assoc ["name", `String reference;
      "descriptor", `Assoc ["digest", `String identity.descriptor_digest]];
    "variants", `List [`Assoc [
      "platform", `Assoc ["architecture", `String "arm64"; "os", `String "linux"];
      "config", `Assoc ["architecture", `String "arm64"; "os", `String "linux"; "config", config]]]]]) in
  match Image_command.of_apple_inspect ~reference ~identity raw with
  | Ok value -> value | Error error -> fail (Image_command.error_message error)

let image_command = image_command_for []

let test_requested_security_changes_digest () =
  let changes =
    [ {plan with image = "other:image"}
    ; {plan with user = "0:0"}
    ; {plan with guest_size = {plan.guest_size with cpus = value (Size.cpus_of_int 2)}}
    ; {plan with guest_size = {plan.guest_size with memory = value (Size.memory_of_string "4g")}}
    ; {plan with command = ["sh"]}
    ; {plan with working_directory = "/elsewhere"}
    ; {plan with mounts = [Plan.Host_dir {source = "/different/identity"; destination = "/guest/identity"; read_only = true}]}
    ; {plan with mounts = [Plan.Host_dir {source = "/private-fixture/identity"; destination = "/guest/identity"; read_only = false}]}
    ; {plan with isolation = [Backend.Read_only_rootfs]}
    ; {plan with capabilities_added = [Plan.Cap_sys_admin]}
    ; {plan with published_sockets = [agent_socket]}
    ; {plan with published_sockets = [{agent_socket with host_path = "/host/agents/other.sock"}]}
    ; {plan with network = Plan.Network_inherit}
    ; {plan with environment = ["GH_CONFIG_DIR", "/other/identity"]}
    ; {plan with labels = ["masc.mcp.keeper", "another"]} ] in
  List.iter (fun changed -> check bool "changed requested authority has a new digest"
    false (Plan.digest plan = Plan.digest changed)) changes;
  check string "enumeration order does not invent plan changes" (Plan.digest plan)
    (Plan.digest {plan with mounts = List.rev plan.mounts; isolation = List.rev plan.isolation;
      environment = List.rev plan.environment; labels = List.rev plan.labels});
  check string "the order of given-back capabilities is not identity" (Plan.digest agent_plan)
    (Plan.digest {agent_plan with capabilities_added = List.rev agent_plan.capabilities_added});
  let second = {Plan.host_path = "/host/agents/second.sock"; guest_path = "/run/masc-agent/second.sock"} in
  check string "the order of published sockets is not identity"
    (Plan.digest {agent_plan with published_sockets = [agent_socket; second]})
    (Plan.digest {agent_plan with published_sockets = [second; agent_socket]})

(* Running Apple guests carry this digest as their boot plan label, so another
   value here replaces every running guest on its next boot check. A plan
   that adds no capability and publishes no socket keeps it. Change it only
   on purpose. *)
let test_an_exec_plan_keeps_its_digest () =
  check string "the exec fixture's digest"
    "0fd01693d44a732172f3845c1e736d236804031152deb3ce45c05f8992315b25" (Plan.digest plan)

let test_label_separates_change_from_runtime_disagreement () =
  check bool "complete runtime facts match" true
    (Plan.assess ~image_command:(Ok image_command) ~identity_reading:Plan.Identity_readable ~plan ~policy_environment:[] (reading (inspect ())) = Plan.Matches_plan);
  let changed = reading (inspect ~memory:(`Int 4_294_967_296) ()) in
  List.iter (fun _ -> match Plan.assess ~image_command:(Ok image_command) ~identity_reading:Plan.Identity_readable ~plan ~policy_environment:[] changed with
    | Plan.Refuse (Plan.Runtime_reports_other_than_asked [Plan.Resources]) -> ()
    | _ -> fail "same plan with different runtime memory must preserve/refuse, repeatedly") [(); ()];
  let facts = facts () in
  match Plan.assess ~image_command:(Ok image_command) ~identity_reading:Plan.Identity_readable ~plan ~policy_environment:[]
    (Plan.Facts {facts with plan_label = None; memory_bytes = 4_294_967_296L}) with
  | Plan.Replace [Plan.Plan_label; Plan.Resources] -> ()
  | _ -> fail "an unknown requested plan permits replacement and reports observed differences"

let test_identity_refusal_priority () =
  let assess = Plan.assess ~image_command:(Ok image_command) ~plan ~policy_environment:[] ~identity_reading:Plan.Identity_unreadable in
  (match assess (Plan.Unreadable "missing runtime facts") with
   | Plan.Refuse (Plan.Guest_facts_unreadable _) -> ()
   | _ -> fail "unreadable facts cannot authorize replacement");
  (match assess (Plan.Facts { (facts ()) with plan_label=None }) with
   | Plan.Replace (Plan.Plan_label :: _) -> ()
   | _ -> fail "changed plan precedes identity replacement");
  (match assess (reading (inspect ~memory:(`Int 4_294_967_296) ())) with
   | Plan.Replace [Plan.Identity_snapshot] -> ()
   | _ -> fail "unreadable snapshot precedes same-label disagreement refusal");
  let policy = {plan with network=Plan.Network_policy {name="fixture-policy"}} in
  (match Plan.assess ~image_command:(Ok image_command) ~plan:policy ~policy_environment:[]
      ~identity_reading:Plan.Identity_unreadable
      (Plan.Facts {(facts ()) with plan_label=Some (Plan.digest policy)}) with
   | Plan.Replace [Plan.Policy_route] -> ()
   | _ -> fail "stale policy route precedes identity replacement")

let test_unreadable_is_not_replacement () =
  let malformed =
    [ inspect ~mount_kind:"unknown-filesystem" ()
    ; inspect ~extra:["readOnly", `Bool false] ()
    ; inspect ~memory:(`Float 2_147_483_648.) ()
    ; "[]"; "{}"; "not-json" ] in
  List.iter (fun raw ->
    match Plan.assess ~image_command:(Ok image_command) ~identity_reading:Plan.Identity_readable ~plan ~policy_environment:[] (reading raw) with
    | Plan.Refuse (Plan.Guest_facts_unreadable _) -> ()
    | _ -> fail "unreadable facts cannot authorize replacement") malformed;
  match Sandbox.apple_guest_facts ~container_name:"another-guest" (inspect ()) with
  | Plan.Unreadable _ -> () | Plan.Facts _ -> fail "inspect row belonged to a different name"

let test_all_runtime_security_disagreements_are_named () =
  let original = facts () in
  let changed = {original with user = "0:0"; command = ["sh"];
    working_directory = "/other"; mounts = []; read_only = false;
    cap_add = ["CAP_SYS_ADMIN"]; published_sockets = [agent_socket]; use_init = true;
    networks = ["default"]; environment = []; labels = []} in
  check bool "all differing security axes are retained" true
    (Plan.differences ~image_command plan changed = [Plan.User; Plan.Working_directory; Plan.Command;
      Plan.Mounts; Plan.Root_filesystem; Plan.Capabilities; Plan.Published_sockets;
      Plan.Init_process; Plan.Network; Plan.Environment; Plan.Labels])

(* The facts an agent guest reports when the runtime did what its plan asked. *)
let agent_facts () =
  { (facts ()) with
    plan_label = Some (Plan.digest agent_plan)
  ; user = "0:0"
  ; command = agent_plan.command
  ; read_only = false
  ; cap_add = List.map Plan.capability_to_string agent_plan.capabilities_added
  ; published_sockets = [agent_socket]
  ; use_init = false
  }

let test_an_agent_guest_is_compared_on_its_grants () =
  let assess facts =
    Plan.assess ~image_command:(Ok image_command) ~identity_reading:Plan.Identity_readable
      ~plan:agent_plan ~policy_environment:[] (Plan.Facts facts)
  in
  (match assess (agent_facts ()) with
   | Plan.Matches_plan -> ()
   | _ -> fail "an agent guest with every grant it asked for matches its plan");
  (match assess {(agent_facts ()) with cap_add = List.rev (agent_facts ()).cap_add} with
   | Plan.Matches_plan -> ()
   | _ -> fail "the runtime may list the capabilities in another order");
  (match assess {(agent_facts ()) with cap_add = ["CAP_SETUID"; "CAP_SETGID"]} with
   | Plan.Refuse (Plan.Runtime_reports_other_than_asked [Plan.Capabilities]) -> ()
   | _ -> fail "a missing capability is a capability difference");
  (match assess {(agent_facts ()) with published_sockets = []} with
   | Plan.Refuse (Plan.Runtime_reports_other_than_asked [Plan.Published_sockets]) -> ()
   | _ -> fail "a socket the runtime did not publish is a difference");
  (match assess {(agent_facts ()) with use_init = true} with
   | Plan.Refuse (Plan.Runtime_reports_other_than_asked [Plan.Init_process]) -> ()
   | _ -> fail "an init in front of the agent is a difference");
  match Plan.assess ~image_command:(Ok image_command) ~identity_reading:Plan.Identity_readable
      ~plan ~policy_environment:[] (Plan.Facts (agent_facts ())) with
  | Plan.Replace (Plan.Plan_label :: _) -> ()
  | _ -> fail "an agent guest is another plan for an exec-per-request Keeper"

let test_the_parser_reads_published_sockets_and_init () =
  let socket = `Assoc ["containerPath", `String agent_socket.guest_path;
    "hostPath", `String agent_socket.host_path] in
  (match reading (inspect ~published_sockets:(Some (`List [socket])) ~use_init:(Some (`Bool true)) ()) with
   | Plan.Facts facts ->
     check bool "the published socket" true (facts.published_sockets = [agent_socket]);
     check bool "the runtime's init" true facts.use_init
   | Plan.Unreadable detail -> fail detail);
  List.iter (fun raw -> match reading raw with
    | Plan.Unreadable _ -> ()
    | Plan.Facts _ -> fail "a guest without the field is unreadable, not a guest without sockets")
    [ inspect ~published_sockets:None ()
    ; inspect ~use_init:None ()
    ; inspect ~published_sockets:(Some (`List [`Assoc ["containerPath", `String "/run/a.sock"]])) () ]

(* Apple container 1.6.1 booted a guest from [Sandbox.apple_turn_start_argv]
   of this plan, and the fixture is its [container inspect] while the agent
   answered (docs/evidence/2026-11-03-microvm-request-transport/
   agent-plan-boot-results.json). The runtime reported every host path as it
   was given, so the fixture carries this plan's host paths and the plan
   label that covers them. The volume image paths are the runtime's own; the
   parser reads a volume by its name. *)
let booted_agent_plan : Plan.t =
  { image = "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"
  ; guest_size = {Size.memory = value (Size.memory_of_string "1g"); cpus = value (Size.cpus_of_int 1)}
  ; user = "0:0"; working_directory = "/masc-work"
  ; command = ["/opt/masc-exec-shim/masc-exec-shim"; "--serve"; "/run/masc-agent/agent.sock"; "502:20"]
  ; mounts =
      [ Plan.Host_dir {source = "/host/masc/identity/fixture-agent"; destination = "/masc-identity"; read_only = true}
      ; Plan.Named_volume {name = "fixture-agent-work"; destination = "/masc-work"}
      ; Plan.Named_volume {name = "fixture-agent-build"; destination = "/masc-build"}
      ; Plan.Host_dir {source = "/host/masc/shim"; destination = "/opt/masc-exec-shim"; read_only = true} ]
  ; isolation = [Backend.Drop_all_capabilities; Backend.Remove_on_exit; Backend.Scratch_tmpfs]
  ; capabilities_added = [Plan.Cap_setuid; Plan.Cap_setgid; Plan.Cap_sys_admin]
  ; published_sockets =
      [{Plan.host_path = "/host/masc/agents/fixture-agent.sock"; guest_path = "/run/masc-agent/agent.sock"}]
  ; network = Plan.Network_none
  ; environment = ["HOME", "/tmp"; "MASC_EXEC_SHIM_CONFIG", "/opt/masc-exec-shim/masc-exec-shim.conf";
                   "GH_CONFIG_DIR", "/masc-identity"]
  ; labels = ["masc.mcp.keeper", "fixture-agent"; Sandbox.microvm_backend_label_key, "apple_container"]
  }

let test_a_booted_agent_guest_matches_its_plan () =
  let raw = In_channel.with_open_bin "fixtures/apple-container-1.6.1-agent-guest-inspect.json"
      In_channel.input_all in
  let image_command = image_command_for ~reference:booted_agent_plan.image
      ~descriptor_digest:"sha256:5f289f8d70f7a0867865e23c146f726b670edec956ad20aa982956aa378957a4" [] in
  match Plan.assess ~image_command:(Ok image_command) ~identity_reading:Plan.Identity_readable
      ~plan:booted_agent_plan ~policy_environment:[]
      (Sandbox.apple_guest_facts ~container_name:"fixture-agent" raw) with
  | Plan.Matches_plan -> ()
  | Plan.Replace differences ->
    fail ("replaced: " ^ Plan.refusal_message (Plan.Runtime_reports_other_than_asked differences))
  | Plan.Refuse refusal -> fail (Plan.refusal_message refusal)

let test_command_refusal_reports_fields_without_values () =
  let requested_secret = "requested-private-credential" in
  let observed_secret = "observed-private-credential" in
  let plan = {plan with environment = ["CREDENTIAL", requested_secret]} in
  let actual = {(facts ()) with plan_label = Some (Plan.digest plan);
    command = ["opam"; "exec"; "--"; "tail"; "-f"; "/dev/null"];
    environment = ["CREDENTIAL", observed_secret]} in
  match Plan.assess ~image_command:(Ok image_command)
      ~identity_reading:Plan.Identity_readable ~plan ~policy_environment:[] (Plan.Facts actual) with
  | Plan.Refuse refusal ->
    let message = Plan.refusal_message refusal in
    check string "diagnostic identifies the actual mismatched fields"
      "runtime guest facts disagree with the requested plan (fields: command, environment); guest preserved"
      message;
    List.iter (fun secret -> check bool "diagnostic does not expose credential values" false
      (Astring.String.is_infix ~affix:secret message)) [requested_secret; observed_secret]
  | Plan.Matches_plan | Plan.Replace _ -> fail "same-plan command mismatch must preserve and refuse"

let test_image_command_refusal_preserves_diagnostic () =
  check string "image metadata failure remains a distinct preservation refusal"
    "runtime image command unavailable; guest preserved: fixture metadata unavailable"
    (Plan.refusal_message (Plan.Image_command_unavailable "fixture metadata unavailable"))

let flag_value flag argv =
  let rec find = function
    | key :: value :: _ when key = flag -> Some value
    | _ :: rest -> find rest | [] -> None in
  find argv

let boot plan dns policy_proxy =
  match Sandbox.apple_turn_start_argv ~container_name:"fixture" ~plan
    ~lifecycle_labels:["masc.mcp.owner_pid", "123"] ~dns ~policy_proxy with
  | Ok argv -> argv
  | Error (Sandbox.Apple_invalid_boot_plan errors) ->
    fail (String.concat "; " (List.map Plan.invalid_plan_message errors))
  | Error (Sandbox.Apple_network_unavailable detail) -> fail detail
  | Error (Sandbox.Apple_constraints_unexpressible _) -> fail "unexpected constraint refusal"

let test_boot_projects_the_labelled_plan () =
  let argv = boot plan (Some "192.0.2.53") None in
  check (option string) "requested user" (Some plan.user) (flag_value "--user" argv);
  check (option string) "requested memory" (Some "2048m") (flag_value "--memory" argv);
  check (option string) "requested CPU" (Some "4") (flag_value "--cpus" argv);
  check (option string) "requested working directory" (Some plan.working_directory) (flag_value "--workdir" argv);
  check (option string) "requested executable replaces the image entrypoint"
    (Some "tail") (flag_value "--entrypoint" argv);
  check bool "argv labels the same plan it projects" true
    (List.mem (Plan.label_key ^ "=" ^ Plan.digest plan) argv);
  check bool "snapshot source is the plan's read-only mount" true
    (List.mem "/private-fixture/identity:/guest/identity:ro" argv);
  check bool "requested arguments follow the image" true
    (List.rev [plan.image; "-f"; "/dev/null"] = List.take 3 (List.rev argv));
  check bool "an exec-per-request plan publishes nothing and gives nothing back" false
    (List.mem "--publish-socket" argv || List.mem "--cap-add" argv)

let values_of flag argv =
  let rec collect = function
    | key :: value :: rest when key = flag -> value :: collect rest
    | _ :: rest -> collect rest
    | [] -> []
  in
  collect argv

let position flag argv =
  let rec find index = function
    | key :: _ when key = flag -> index
    | _ :: rest -> find (index + 1) rest
    | [] -> fail (flag ^ " is missing")
  in
  find 0 argv

let test_an_agent_plan_asks_for_its_grants () =
  let argv = boot agent_plan None None in
  check (option string) "the first process starts as root" (Some "0:0") (flag_value "--user" argv);
  check bool "the root is left writable for the agent to remount" false (List.mem "--read-only" argv);
  check (list string) "the capabilities the agent needs come back"
    (List.map Plan.capability_to_string agent_plan.capabilities_added) (values_of "--cap-add" argv);
  check bool "they come back after everything is dropped" true
    (position "--cap-drop" argv < position "--cap-add" argv);
  check (list string) "the agent's socket is published"
    [agent_socket.host_path ^ ":" ^ agent_socket.guest_path] (values_of "--publish-socket" argv);
  check (option string) "the shim is the first process" (Some (List.hd agent_plan.command))
    (flag_value "--entrypoint" argv)

let test_ephemeral_routes_do_not_change_plan_identity () =
  let inherit_plan = {plan with network = Plan.Network_inherit} in
  let first = boot inherit_plan (Some "192.0.2.53") None in
  let second = boot inherit_plan (Some "192.0.2.54") None in
  let label = Plan.label_key ^ "=" ^ Plan.digest inherit_plan in
  check bool "DNS reaches execution without changing its plan label" true
    (first <> second && List.mem label first && List.mem label second);
  let policy_plan = {plan with network = Plan.Network_policy {name = "fixture-policy"}} in
  let proxy port = Some {Sandbox.gateway = "192.0.2.1"; port} in
  let first = boot policy_plan None (proxy 32101) in
  let second = boot policy_plan None (proxy 32102) in
  let label = Plan.label_key ^ "=" ^ Plan.digest policy_plan in
  check bool "policy port reaches execution without changing stable identity" true
    (first <> second && List.mem label first && List.mem label second);
  let facts = { (facts ()) with plan_label = Some (Plan.digest policy_plan);
    networks = ["fixture-policy"] } in
  (match Plan.assess ~image_command:(Ok image_command) ~identity_reading:Plan.Identity_readable ~plan:policy_plan ~policy_environment:["HTTPS_PROXY", "http://192.0.2.1:32102"]
    (Plan.Facts facts) with
  | Plan.Replace [Plan.Policy_route] -> ()
  | _ -> fail "stable policy plan still replaces a stale execution route");
  (* Approved RFC 4.1 step 3 precedes step 5: stale policy replacement is
     intentional even when another runtime fact also disagrees. *)
  match Plan.assess ~image_command:(Ok image_command) ~identity_reading:Plan.Identity_readable ~plan:policy_plan ~policy_environment:["HTTPS_PROXY", "http://192.0.2.1:32102"]
    (Plan.Facts {facts with read_only = false}) with
  | Plan.Replace [Plan.Policy_route] -> ()
  | _ -> fail "the documented stale-route decision must keep its priority"

let require_invalid_boot expected plan ~lifecycle_labels ~policy_proxy =
  match Sandbox.apple_turn_start_argv ~container_name:"fixture" ~plan
    ~lifecycle_labels ~dns:None ~policy_proxy with
  | Error (Sandbox.Apple_invalid_boot_plan errors) ->
    check bool "direct renderer refuses the actual ambiguity" true (List.mem expected errors)
  | Error (Sandbox.Apple_network_unavailable _)
  | Error (Sandbox.Apple_constraints_unexpressible _)
  | Ok _ -> fail "invalid plan must fail admission before producing any Boot argv"

let test_renderer_rejects_order_sensitive_duplicates () =
  let environment = ["GH_CONFIG_DIR", "/first"; "GH_CONFIG_DIR", "/second"] in
  let labels = ["masc.mcp.keeper", "first"; "masc.mcp.keeper", "second"] in
  let mounts =
    [ Plan.Host_dir {source = "/first"; destination = "/guest/identity"; read_only = true}
    ; Plan.Host_dir {source = "/second"; destination = "/guest/identity"; read_only = true} ] in
  List.iter (fun reverse ->
    let order values = if reverse then List.rev values else values in
    List.iter (fun (expected, invalid) ->
      require_invalid_boot expected invalid ~lifecycle_labels:[] ~policy_proxy:None;
      match Plan.assess ~image_command:(Ok image_command) ~identity_reading:Plan.Identity_readable ~plan:invalid ~policy_environment:[] (Plan.Facts (facts ())) with
      | Plan.Refuse (Plan.Invalid_requested_plan errors) ->
        check bool "invalid request is no comparison authority" true (List.mem expected errors)
      | _ -> fail "invalid requested plan must not authorize adoption or replacement")
      [ Plan.Duplicate_environment_key "GH_CONFIG_DIR", {plan with environment = order environment}
      ; Plan.Duplicate_label_key "masc.mcp.keeper", {plan with labels = order labels}
      ; Plan.Duplicate_mount_destination "/guest/identity", {plan with mounts = order mounts} ])
    [false; true]

(* One byte over the macOS host limit. *)
let long_host_path = "/" ^ String.make 98 'h' ^ ".sock"

let test_duplicate_grants_are_refused () =
  List.iter (fun (expected, invalid) ->
    require_invalid_boot expected invalid ~lifecycle_labels:[] ~policy_proxy:None)
    [ Plan.Duplicate_capability Plan.Cap_setuid,
      {agent_plan with capabilities_added = [Plan.Cap_setuid; Plan.Cap_setuid]}
    ; Plan.Capabilities_without_drop_all,
      {agent_plan with isolation = [Backend.Remove_on_exit; Backend.Scratch_tmpfs]}
    ; Plan.Invalid_published_socket {path = "agents/fixture.sock"; problem = Plan.Not_absolute},
      {agent_plan with published_sockets = [{agent_socket with host_path = "agents/fixture.sock"}]}
    ; Plan.Invalid_published_socket {path = "/host/a:b.sock"; problem = Plan.Contains_colon},
      {agent_plan with published_sockets = [{agent_socket with host_path = "/host/a:b.sock"}]}
    ; Plan.Invalid_published_socket
        {path = long_host_path; problem = Plan.Too_long {bytes = 104; limit = 103}},
      {agent_plan with published_sockets = [{agent_socket with host_path = long_host_path}]}
    ; Plan.Duplicate_published_socket agent_socket.host_path,
      {agent_plan with published_sockets =
        [agent_socket; {agent_socket with guest_path = "/run/masc-agent/other.sock"}]}
    ; Plan.Duplicate_published_socket agent_socket.guest_path,
      {agent_plan with published_sockets =
        [agent_socket; {agent_socket with host_path = "/host/agents/other.sock"}]} ]

let test_renderer_rejects_implicit_and_execution_collisions () =
  let reject expected invalid =
    require_invalid_boot expected invalid ~lifecycle_labels:[] ~policy_proxy:None in
  reject Plan.Missing_executable {plan with command = []};
  reject Plan.Missing_executable {plan with command = [""]};
  reject (Plan.Duplicate_mount_destination Backend.scratch_guest_root)
    {plan with mounts = Plan.Tmpfs {destination = Backend.scratch_guest_root} :: plan.mounts};
  reject (Plan.Duplicate_constraint Backend.Drop_all_capabilities)
    {plan with isolation = Backend.Drop_all_capabilities :: plan.isolation};
  List.iter (fun key -> reject (Plan.Reserved_plan_label key)
    {plan with labels = (key, "caller-value") :: plan.labels})
    [Plan.label_key; "masc.mcp.owner_pid"; "masc.mcp.started_at"];
  reject (Plan.Invalid_environment_key "name=value")
    {plan with environment = ["name=value", "payload"]};
  reject (Plan.Invalid_label_key "name=value")
    {plan with labels = ["name=value", "payload"]};
  require_invalid_boot (Plan.Unexpected_lifecycle_label "masc.mcp.keeper") plan
    ~lifecycle_labels:["masc.mcp.keeper", "other"] ~policy_proxy:None;
  require_invalid_boot (Plan.Duplicate_lifecycle_label "masc.mcp.owner_pid") plan
    ~lifecycle_labels:["masc.mcp.owner_pid", "1"; "masc.mcp.owner_pid", "2"] ~policy_proxy:None;
  require_invalid_boot (Plan.Execution_environment_collision "HTTPS_PROXY")
    {plan with network = Plan.Network_policy {name = "fixture-policy"};
      environment = ("HTTPS_PROXY", "stable-but-colliding") :: plan.environment}
    ~lifecycle_labels:[] ~policy_proxy:(Some {Sandbox.gateway = "192.0.2.1"; port = 32102})

let test_valid_plan_keeps_command_order_semantic () =
  check bool "valid plan admitted" true (Plan.validate plan = Ok ());
  check bool "command order remains significant" false
    (Plan.digest plan = Plan.digest {plan with command = List.rev plan.command})

let test_explicit_entrypoint_preserves_image_binding () =
  let wrapped = image_command_for ["opam"; "exec"; "--"] in
  let facts = facts () in
  let assess = Plan.assess ~plan ~policy_environment:[] ~identity_reading:Plan.Identity_readable in
  check bool "explicit entrypoint overrides the image default" true
    (assess ~image_command:(Ok wrapped) (Plan.Facts facts) = Plan.Matches_plan);
  check bool "canonical guest reference with the same queried image content is an alias" true
    (assess ~image_command:(Ok wrapped)
      (Plan.Facts {facts with image="registry.example.test/library/fixture:image"}) = Plan.Matches_plan);
  (match assess ~image_command:(Ok wrapped)
      (Plan.Facts {facts with command=["opam"; "exec"; "--"; "tail"; "-f"; "/dev/null"]}) with
   | Plan.Refuse (Plan.Runtime_reports_other_than_asked [Plan.Command]) -> ()
   | _ -> fail "the image entrypoint cannot prefix an explicitly overridden command");
  (match assess ~image_command:(Ok wrapped)
      (Plan.Facts {facts with command=["opam"; "exec"; "--"; "sh"]}) with
   | Plan.Refuse (Plan.Runtime_reports_other_than_asked [Plan.Command]) -> ()
   | _ -> fail "a matching image prefix cannot authorize another command");
  (match assess ~image_command:(Error "configuration unavailable") (Plan.Facts facts) with
   | Plan.Refuse (Plan.Image_command_unavailable _) -> ()
   | _ -> fail "missing image metadata preserves and refuses a same-label guest");
  let foreign = {facts with image_identity={facts.image_identity with descriptor_digest="sha256:foreign"}} in
  match assess ~image_command:(Ok wrapped) (Plan.Facts foreign) with
  | Plan.Refuse (Plan.Image_command_unavailable _) -> ()
  | _ -> fail "another guest image cannot borrow an image command observation"

let () = run "Keeper Apple boot plan"
  [ "authority", [test_case "explicit entrypoint preserves image binding and exact argv" `Quick test_explicit_entrypoint_preserves_image_binding
                 ; test_case "requested security changes identity" `Quick test_requested_security_changes_digest
                 ; test_case "same plan disagrees with runtime" `Quick test_label_separates_change_from_runtime_disagreement
                 ; test_case "identity and runtime refusal order" `Quick test_identity_refusal_priority
                 ; test_case "unreadable facts preserve guest" `Quick test_unreadable_is_not_replacement
                 ; test_case "every security disagreement is retained" `Quick test_all_runtime_security_disagreements_are_named
                 ; test_case "an agent guest is compared on its grants" `Quick test_an_agent_guest_is_compared_on_its_grants
                 ; test_case "an exec plan keeps its digest" `Quick test_an_exec_plan_keeps_its_digest
                 ; test_case "the parser reads published sockets and init" `Quick test_the_parser_reads_published_sockets_and_init
                 ; test_case "a guest booted from an agent plan matches it" `Quick test_a_booted_agent_guest_matches_its_plan
                 ; test_case "command refusal names fields without credentials" `Quick test_command_refusal_reports_fields_without_values
                 ; test_case "image command refusal preserves its diagnostic" `Quick test_image_command_refusal_preserves_diagnostic]
  ; "boot", [test_case "actual Apple argv projects its labelled plan" `Quick test_boot_projects_the_labelled_plan
             ; test_case "an agent plan asks for its grants" `Quick test_an_agent_plan_asks_for_its_grants
             ; test_case "malformed grants are refused" `Quick test_duplicate_grants_are_refused
             ; test_case "ephemeral routing is outside plan identity" `Quick test_ephemeral_routes_do_not_change_plan_identity
             ; test_case "renderer refuses duplicate keys in both orders" `Quick test_renderer_rejects_order_sensitive_duplicates
             ; test_case "renderer refuses implicit and execution collisions" `Quick test_renderer_rejects_implicit_and_execution_collisions
             ; test_case "valid command order remains semantic" `Quick test_valid_plan_keeps_command_order_semantic] ]
