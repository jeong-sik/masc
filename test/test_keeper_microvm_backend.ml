(* RFC-0405. The Micro_vm profile says a keeper's tree sits on a guest behind
   a hypervisor; it does not say which runtime supplies one. These pin the two
   things that differ between runtimes — the argv, and the parse of what the
   runtime answers — against the CLIs they were read from. *)

module Backend = Masc.Keeper_microvm_backend
module Microvm = Masc.Keeper_sandbox_microvm
module Profile = Keeper_types_profile_sandbox

let check = Alcotest.check
let fail = Alcotest.fail

(* ── The vocabulary is closed and derived ───────────────────────────── *)

let test_every_backend_round_trips_its_spelling () =
  List.iter
    (fun backend ->
      let spelling = Backend.to_string backend in
      match Backend.of_string spelling with
      | Some parsed when parsed = backend -> ()
      | Some _ -> Alcotest.failf "%s parsed back as another backend" spelling
      | None -> Alcotest.failf "%s is not accepted by of_string" spelling)
    Backend.all
;;

let test_valid_strings_is_derived_not_typed_again () =
  check
    (Alcotest.list Alcotest.string)
    "the advertised spellings are exactly the constructors'"
    (List.map Backend.to_string Backend.all)
    Backend.valid_strings
;;

let test_an_unknown_spelling_is_refused () =
  match Backend.of_string "firecracker" with
  | None -> ()
  | Some backend ->
    Alcotest.failf
      "an unimplemented runtime resolved to %s"
      (Backend.to_string backend)
;;

(* ── argv: read from each CLI's own help, not guessed ───────────────── *)

let test_each_backend_drives_its_own_executable () =
  check Alcotest.string "apple" "container" (Backend.cli_name Backend.Apple_container);
  check Alcotest.string "microsandbox" "msb" (Backend.cli_name Backend.Microsandbox)
;;

let test_removal_is_spelled_per_runtime () =
  check
    (Alcotest.list Alcotest.string)
    "container deletes"
    [ "container"; "delete"; "--force"; "g" ]
    (Microvm.delete_force_argv_for Backend.Apple_container ~container_name:"g");
  check
    (Alcotest.list Alcotest.string)
    "msb removes"
    [ "msb"; "remove"; "--force"; "g" ]
    (Microvm.delete_force_argv_for Backend.Microsandbox ~container_name:"g")
;;

(* [msb inspect] prints a human table unless the machine form is asked for, so
   the flag is not decoration: without it the parser below never sees JSON. *)
let test_microsandbox_inspect_asks_for_the_machine_form () =
  check
    (Alcotest.list Alcotest.string)
    "msb inspect is asked for json"
    [ "msb"; "inspect"; "g"; "--format"; "json" ]
    (Microvm.inspect_argv_for Backend.Microsandbox ~container_name:"g");
  check
    (Alcotest.list Alcotest.string)
    "container inspect already answers json"
    [ "container"; "inspect"; "g" ]
    (Microvm.inspect_argv_for Backend.Apple_container ~container_name:"g")
;;

(* nerdctl drives containerd, whose default runtime shares the host kernel.
   Without the shim named, a keeper that declared microvm would get a
   container — the isolation would be weaker than the profile it asked for,
   and nothing in the argv would say so. *)
let test_only_the_containerd_backend_names_a_runtime () =
  check
    (Alcotest.list Alcotest.string)
    "nerdctl names the Kata shim"
    [ "--runtime"; "io.containerd.kata.v2" ]
    (Backend.run_runtime_args Backend.Nerdctl_kata);
  List.iter
    (fun backend ->
      check
        (Alcotest.list Alcotest.string)
        (Backend.to_string backend ^ " is a microVM runtime already")
        []
        (Backend.run_runtime_args backend))
    [ Backend.Apple_container; Backend.Microsandbox ]
;;

let test_kata_removal_and_inspect_are_dockers_grammar () =
  check
    (Alcotest.list Alcotest.string)
    "nerdctl rm --force"
    [ "nerdctl"; "rm"; "--force"; "g" ]
    (Microvm.delete_force_argv_for Backend.Nerdctl_kata ~container_name:"g");
  (* nerdctl's reference documents --mode and no default for it, so the mode
     is on the argv. The template masc already sends Docker resolves only in
     dockercompat; taken from an unstated default it would print an empty
     line the day that default moved, and an empty line reads as "not
     running" -- which takes a live guest down. *)
  check
    (Alcotest.list Alcotest.string)
    "nerdctl inspect names the mode Docker's template resolves in"
    [ "nerdctl"; "inspect"; "--mode"; "dockercompat"; "--format"
    ; "{{json .State.Running}}"; "g" ]
    (Microvm.inspect_argv_for Backend.Nerdctl_kata ~container_name:"g")
;;

(* ── the boot, and the guarantees it asks for by name ──────────────── *)

(* The network tokens come from the runtime's own builder rather than being
   typed in. A closed network is an isolation property that is not a
   [guest_constraint], so a fixture spelling Apple's [--network none] for all
   three would make every assertion below blind to the one axis whose flags
   actually differ between them. *)
type boot_refusal =
  | Network_refused of string
  | Constraints_refused of Microvm.constraint_refusal list

let boot ?(network = Profile.Network_none) ?(constraints = Backend.all_guest_constraints)
      backend
  : (string list, boot_refusal) result
  =
  match Microvm.network_args_for backend ~dns:(Some "1.1.1.1") ~policy_proxy:None network with
  | Error detail -> Error (Network_refused detail)
  | Ok network_args ->
    (match
       Microvm.turn_start_argv_for
         backend
         ~container_name:"g"
         ~label_args:[ "--label"; "masc.mcp.kind=keeper-vm" ]
         ~uid:501
         ~gid:20
         ~memory:"2g"
         ~cpus:None
         ~network_args
         ~mount_args:[ "-v"; "h:c:ro" ]
         ~image:"img"
         ~constraints
     with
     | Ok argv -> Ok argv
     | Error refusals -> Error (Constraints_refused refusals))
;;

let booted label backend =
  match boot backend with
  | Ok argv -> argv
  | Error (Network_refused detail) -> fail (label ^ ": " ^ detail)
  | Error (Constraints_refused refusals) ->
    fail (label ^ ": " ^ Microvm.constraint_refusals_message backend refusals)
;;

(* The whole boot argv, spelled out. Before #32837 this call took no backend
   at all, so a keeper naming msb booted under `container` and was then
   stopped with `msb stop` — two runtimes for one guest, and nothing able to
   reap the one that actually booted. *)
let test_boot_argv_is_each_runtimes_own () =
  check
    (Alcotest.list Alcotest.string)
    "container boots the guest it will later stop"
    ([ "container"; "run"; "-d"; "--name"; "g" ]
     @ [ "--label"; "masc.mcp.kind=keeper-vm" ]
     @ [ "--label"; "masc.mcp.microvm_backend=apple_container" ]
     @ [ "--user"; "501:20" ]
     @ [ "--cap-drop"; "ALL"; "--read-only"; "--rm" ]
     @ [ "--memory"; "2g" ]
     @ [ "-v"; "h:c:ro" ]
     @ [ "--workdir"; Microvm.work_volume_guest_root ]
     @ [ "--network"; "none" ]
     @ [ "img"; "tail"; "-f"; "/dev/null" ])
    (booted "apple" Backend.Apple_container);
  (* containerd's default runtime shares the host kernel, so a Kata boot that
     forgets the shim is a container wearing this profile's name. *)
  check
    (Alcotest.list Alcotest.string)
    "nerdctl names the Kata shim on the boot it builds"
    ([ "nerdctl"; "run"; "-d"; "--name"; "g" ]
     @ [ "--label"; "masc.mcp.kind=keeper-vm" ]
     @ [ "--label"; "masc.mcp.microvm_backend=nerdctl_kata" ]
     @ [ "--user"; "501:20" ]
     @ [ "--cap-drop"; "ALL"; "--read-only"; "--rm" ]
     @ [ "--memory"; "2g" ]
     @ [ "--runtime"; "io.containerd.kata.v2" ]
     @ [ "-v"; "h:c:ro" ]
     @ [ "--workdir"; Microvm.work_volume_guest_root ]
     @ [ "--network"; "none" ]
     @ [ "img"; "tail"; "-f"; "/dev/null" ])
    (booted "nerdctl" Backend.Nerdctl_kata);
  match boot Backend.Microsandbox with
  | Ok argv ->
    Alcotest.failf
      "msb booted without the isolation it cannot spell: %s"
      (String.concat " " argv)
  | Error (Network_refused detail) ->
    fail ("msb refused a closed network it can spell with --no-net: " ^ detail)
  | Error (Constraints_refused refusals) ->
    check
      (Alcotest.list Alcotest.string)
      "msb names both guarantees it has no flag for"
      [ "drop_all_capabilities"; "read_only_rootfs" ]
      (List.map
         (fun (refusal : Microvm.constraint_refusal) ->
           Backend.guest_constraint_to_string refusal.guest_constraint)
         refusals)
;;

(* The load-bearing one. Either every isolation token this runtime has a flag
   for is on the boot argv, or the boot is an Error. An [Ok] argv missing one
   is a keeper running with a weaker sandbox than the profile it declared and
   nothing saying so — the failure the whole table exists to prevent. *)
let test_an_isolation_guarantee_is_never_silently_dropped () =
  List.iter
    (fun backend ->
      match boot backend with
      | Error (Network_refused _) | Error (Constraints_refused _) -> ()
      | Ok argv ->
        List.iter
          (fun guest_constraint ->
            match
              ( Backend.constraint_class guest_constraint
              , Backend.run_constraint_argv backend guest_constraint )
            with
            | Backend.Lifecycle, _ -> ()
            | Backend.Isolation, Backend.Not_expressible _ ->
              Alcotest.failf
                "%s booted Ok while unable to express %s"
                (Backend.to_string backend)
                (Backend.guest_constraint_to_string guest_constraint)
            | Backend.Isolation, Backend.Expressed tokens ->
              List.iter
                (fun token ->
                  if not (List.exists (String.equal token) argv)
                  then
                    Alcotest.failf
                      "%s boot argv dropped %s from %s"
                      (Backend.to_string backend)
                      token
                      (Backend.guest_constraint_to_string guest_constraint))
                tokens)
          Backend.all_guest_constraints)
    Backend.all
;;

(* A guarantee teardown covers by other means is recorded on the guest rather
   than refused, so "it booted" and "it booted without this" are different
   observable states. *)
let test_a_lifecycle_drop_is_recorded_on_the_guest () =
  match boot ~constraints:[ Backend.Remove_on_exit ] Backend.Microsandbox with
  | Error (Network_refused detail) -> fail ("the network refused the boot: " ^ detail)
  | Error (Constraints_refused _) -> fail "a lifecycle-only guarantee refused the boot"
  | Ok argv ->
    check
      Alcotest.bool
      "the drop travels as a label"
      true
      (List.exists
         (String.equal "masc.mcp.microvm_dropped=remove_on_exit")
         argv)
;;

(* Every pair answered, so a runtime added later cannot be half-registered:
   the compiler asks for all three and a blank reason would land here. *)
let test_every_runtime_answers_every_guarantee () =
  List.iter
    (fun backend ->
      List.iter
        (fun guest_constraint ->
          match Backend.run_constraint_argv backend guest_constraint with
          | Backend.Expressed [] ->
            Alcotest.failf
              "%s claims to express %s with no tokens"
              (Backend.to_string backend)
              (Backend.guest_constraint_to_string guest_constraint)
          | Backend.Expressed _ -> ()
          | Backend.Not_expressible "" ->
            Alcotest.failf
              "%s refuses %s without saying why"
              (Backend.to_string backend)
              (Backend.guest_constraint_to_string guest_constraint)
          | Backend.Not_expressible _ -> ())
        Backend.all_guest_constraints)
    Backend.all
;;

(* ── exec, and the separator that is not a constant ─────────────────── *)

(* msb reads the first bare word after its options as another option and
   stops, so the command has to follow [--]. Apple and nerdctl take it bare.
   A separator treated as a constant would break one runtime or the other. *)
let test_the_command_separator_is_per_runtime () =
  check
    (Alcotest.list Alcotest.string)
    "container takes the command bare"
    [ "container"; "exec"; "--user"; "1:2"; "-w"; "/w"; "g"; "sh" ]
    (Microvm.exec_argv_for
       Backend.Apple_container
       ~container_name:"g"
       ~uid:1
       ~gid:2
       ~container_cwd:"/w"
       ~stdin:false
       ~command_argv:[ "sh" ]);
  check
    (Alcotest.list Alcotest.string)
    "msb needs the separator and spells stdin --stream"
    [ "msb"; "exec"; "--stream"; "--user"; "1:2"; "-w"; "/w"; "g"; "--"; "sh" ]
    (Microvm.exec_argv_for
       Backend.Microsandbox
       ~container_name:"g"
       ~uid:1
       ~gid:2
       ~container_cwd:"/w"
       ~stdin:true
       ~command_argv:[ "sh" ]);
  check
    (Alcotest.list Alcotest.string)
    "nerdctl is Docker's grammar"
    [ "nerdctl"; "exec"; "-i"; "--user"; "1:2"; "-w"; "/w"; "g"; "sh" ]
    (Microvm.exec_argv_for
       Backend.Nerdctl_kata
       ~container_name:"g"
       ~uid:1
       ~gid:2
       ~container_cwd:"/w"
       ~stdin:true
       ~command_argv:[ "sh" ])
;;

let shim_prefix backend =
  Microvm.shim_exec_prefix_for
    backend
    ~container_name:"g"
    ~uid:1
    ~gid:2
    ~remote_root:"/masc-work"
    ~shim_config_path:"/opt/masc-exec-shim/masc-exec-shim.conf"
;;

(* The prefix carries two things the shim cannot run without: where its
   config is, and which identity it runs as. All three CLIs document the env
   entry; msb's --user documents a guest user name and no uid:gid form, so
   the identity is the half that cannot be said and the prefix refuses rather
   than sending a value read from no help output. *)
let test_the_shim_prefix_refuses_where_the_identity_cannot_be_named () =
  check
    (Alcotest.list Alcotest.string)
    "container carries the config env"
    [ "container"; "exec"; "-i"; "--user"; "1:2"; "-w"; "/masc-work"
    ; "--env"; "MASC_EXEC_SHIM_CONFIG=/opt/masc-exec-shim/masc-exec-shim.conf"
    ; "g" ]
    (match shim_prefix Backend.Apple_container with
     | Ok argv -> argv
     | Error detail -> fail detail);
  check
    (Alcotest.list Alcotest.string)
    "nerdctl carries it too"
    [ "nerdctl"; "exec"; "-i"; "--user"; "1:2"; "-w"; "/masc-work"
    ; "--env"; "MASC_EXEC_SHIM_CONFIG=/opt/masc-exec-shim/masc-exec-shim.conf"
    ; "g" ]
    (match shim_prefix Backend.Nerdctl_kata with
     | Ok argv -> argv
     | Error detail -> fail detail);
  match shim_prefix Backend.Microsandbox with
  | Error detail ->
    (* The refusal has to name the identity, not the environment: msb has
       -e/--env, and a reason that says otherwise sends the next reader to
       read a help page that contradicts it. *)
    check
      Alcotest.bool
      "the refusal names the identity it cannot express"
      true
      (Astring.String.is_infix ~affix:"--user" detail)
  | Ok argv ->
    Alcotest.failf
      "msb was handed a --user value its help does not carry: %s"
      (String.concat " " argv)
;;

(* A closed network is an isolation property that is not a
   [guest_constraint], so nothing in the guarantee table asks a runtime about
   it. This is where it is asked. msb rejects Docker's [--network] and
   [--dns] at argument parsing ("unexpected argument '--network' found",
   0.6.16) and spells its own [--no-net] / [--net] / [--dns-nameserver]; sent
   Apple's tokens it would fail every boot, and left with no tokens at all it
   would run open while the profile reported "none". *)
let test_the_network_policy_is_spelled_per_runtime () =
  let ok label backend network =
    match Microvm.network_args_for backend ~dns:(Some "1.1.1.1") ~policy_proxy:None network with
    | Ok args -> args
    | Error detail -> fail (label ^ ": " ^ detail)
  in
  check
    (Alcotest.list Alcotest.string)
    "container closes with Docker's spelling"
    [ "--network"; "none" ]
    (ok "container" Backend.Apple_container Profile.Network_none);
  check
    (Alcotest.list Alcotest.string)
    "nerdctl takes Docker's grammar too"
    [ "--network"; "none" ]
    (ok "nerdctl" Backend.Nerdctl_kata Profile.Network_none);
  check
    (Alcotest.list Alcotest.string)
    "msb closes with its own"
    [ "--no-net" ]
    (ok "msb" Backend.Microsandbox Profile.Network_none);
  check
    (Alcotest.list Alcotest.string)
    "container's inherit carries the nameserver"
    [ "--dns"; "1.1.1.1" ]
    (ok "container" Backend.Apple_container Profile.Network_inherit);
  (* An unmeasured default is not an open network by omission. *)
  match
    Microvm.network_args_for
      Backend.Microsandbox
      ~dns:(Some "1.1.1.1")
      ~policy_proxy:None
      Profile.Network_inherit
  with
  | Ok args ->
    Alcotest.failf
      "msb was handed an inherit network this build has not measured: %s"
      (String.concat " " args)
  | Error detail ->
    check
      Alcotest.bool
      "the refusal names the mode it cannot express"
      true
      (Astring.String.is_infix ~affix:"inherit" detail)
;;

(* No runtime may emit a token another runtime's CLI rejects. Apple's and
   nerdctl's [--network] is exactly such a token for msb, so the closed mode
   is checked to be spelled differently rather than merely non-empty. *)
let test_no_runtime_borrows_anothers_network_spelling () =
  let closed backend =
    match Microvm.network_args_for backend ~dns:None ~policy_proxy:None Profile.Network_none with
    | Ok args -> args
    | Error detail ->
      fail (Backend.to_string backend ^ " cannot close its network: " ^ detail)
  in
  List.iter
    (fun backend ->
      let args = closed backend in
      check
        Alcotest.bool
        (Backend.to_string backend ^ " emits some closing token")
        true
        (args <> []))
    Backend.all;
  check
    Alcotest.bool
    "msb does not receive Docker's --network"
    false
    (List.exists (String.equal "--network") (closed Backend.Microsandbox))
;;

(* ── the surfaces that reap, and the ones that cannot ──────────────── *)

(* This is the surface #32837 is about: a listing that cannot be scoped reads
   as "no guests", and a guest nothing lists is a guest nothing reaps. *)
let test_only_a_labelled_listing_is_offered () =
  (match Microvm.container_listing_for Backend.Apple_container with
   | Microvm.Labelled_json_array argv ->
     check
       (Alcotest.list Alcotest.string)
       "container lists with labels"
       [ "container"; "list"; "-a"; "--format"; "json" ]
       argv
   | Microvm.Listing_not_established reason ->
     fail ("container's own listing was refused: " ^ reason));
  List.iter
    (fun backend ->
      match Microvm.container_listing_for backend with
      | Microvm.Listing_not_established reason ->
        check
          Alcotest.bool
          (Backend.to_string backend ^ " says why it cannot be scoped")
          true
          (String.length reason > 0)
      | Microvm.Labelled_json_array argv ->
        Alcotest.failf
          "%s offered a listing this build cannot scope: %s"
          (Backend.to_string backend)
          (String.concat " " argv))
    [ Backend.Microsandbox; Backend.Nerdctl_kata ]
;;

let test_the_log_tail_flag_is_per_runtime () =
  check
    (Alcotest.list Alcotest.string)
    "container takes -n"
    [ "container"; "logs"; "-n"; "50"; "vm-1" ]
    (Microvm.logs_tail_argv_for Backend.Apple_container ~tail:50 ~container_id:"vm-1");
  check
    (Alcotest.list Alcotest.string)
    "msb rejects -n and takes --tail"
    [ "msb"; "logs"; "--tail"; "50"; "vm-1" ]
    (Microvm.logs_tail_argv_for Backend.Microsandbox ~tail:50 ~container_id:"vm-1");
  check
    (Alcotest.list Alcotest.string)
    "nerdctl documents --tail"
    [ "nerdctl"; "logs"; "--tail"; "50"; "vm-1" ]
    (Microvm.logs_tail_argv_for Backend.Nerdctl_kata ~tail:50 ~container_id:"vm-1")
;;

(* nerdctl has no [image list]; its listing is [images] with a Go template
   that prints one object per line. Read with the array check, a healthy
   listing would look malformed and "the image is missing" would become "the
   probe could not say". *)
let test_the_image_listing_argv_and_shape_agree () =
  check
    (Alcotest.list Alcotest.string)
    "container asks for an array"
    [ "container"; "image"; "list"; "--format"; "json" ]
    (Microvm.image_listing_argv_for Backend.Apple_container);
  check
    (Alcotest.list Alcotest.string)
    "msb asks for an array too"
    [ "msb"; "image"; "list"; "--format"; "json" ]
    (Microvm.image_listing_argv_for Backend.Microsandbox);
  check
    (Alcotest.list Alcotest.string)
    "nerdctl has images, not image list"
    [ "nerdctl"; "images"; "--format"; "{{json .}}" ]
    (Microvm.image_listing_argv_for Backend.Nerdctl_kata);
  let shape_is_lines backend =
    match Microvm.image_listing_shape_for backend with
    | Microvm.Json_lines -> true
    | Microvm.Json_array | Microvm.Json_object -> false
  in
  check Alcotest.bool "container is an array" false (shape_is_lines Backend.Apple_container);
  check Alcotest.bool "msb is an array" false (shape_is_lines Backend.Microsandbox);
  check Alcotest.bool "nerdctl is lines" true (shape_is_lines Backend.Nerdctl_kata)
;;

(* The single-image inspect is a separate question from the listing, and the
   three runtimes disagree on both the flag and the shape. msb answers a
   human table with no flag and a bare object with one; nerdctl documents
   [--mode] with no default, so the mode is named rather than inherited. *)
let test_the_image_inspect_argv_and_shape_agree () =
  let image = "masc-keeper-sandbox:local" in
  check
    (Alcotest.list Alcotest.string)
    "container inspects with no flag"
    [ "container"; "image"; "inspect"; image ]
    (Microvm.image_inspect_argv_for Backend.Apple_container ~image);
  check
    (Alcotest.list Alcotest.string)
    "msb has to be asked for the machine form"
    [ "msb"; "image"; "inspect"; "--format"; "json"; image ]
    (Microvm.image_inspect_argv_for Backend.Microsandbox ~image);
  check
    (Alcotest.list Alcotest.string)
    "nerdctl names the mode rather than assuming a default"
    [ "nerdctl"; "image"; "inspect"; "--mode"; "dockercompat"; image ]
    (Microvm.image_inspect_argv_for Backend.Nerdctl_kata ~image);
  let shape_label backend =
    match Microvm.image_inspect_shape_for backend with
    | Microvm.Json_array -> "array"
    | Microvm.Json_object -> "object"
    | Microvm.Json_lines -> "lines"
  in
  check Alcotest.string "container answers an array" "array"
    (shape_label Backend.Apple_container);
  check Alcotest.string "msb answers an object" "object"
    (shape_label Backend.Microsandbox);
  check Alcotest.string "nerdctl answers Docker's array" "array"
    (shape_label Backend.Nerdctl_kata)
;;

(* Neither of the other two can be handed Apple's volume grammar, and a
   create over a volume that already holds a keeper's tree is what the
   existence check exists to prevent. Only the refusing arms are exercised
   here: Apple's runs a process. *)
let test_the_work_volume_refuses_where_its_grammar_is_unknown () =
  List.iter
    (fun backend ->
      match
        Microvm.ensure_work_volume_for
          backend
          ~volume_name:"masc-keeper-work-probe"
          ~size:"4g"
          ~timeout_sec:1.0
      with
      | Error detail ->
        check
          Alcotest.bool
          (Backend.to_string backend ^ " names the code")
          true
          (String.length detail > 0
           && String.starts_with ~prefix:"microvm_work_volume_unsupported:" detail)
      | Ok _ ->
        Alcotest.failf
          "%s provisioned a work volume with a grammar this build has not read"
          (Backend.to_string backend))
    [ Backend.Microsandbox; Backend.Nerdctl_kata ]
;;

(* ── the parse ──────────────────────────────────────────────────────── *)

let running = function
  | Ok state -> state
  | Error detail -> fail ("state was not read: " ^ detail)
;;

let test_each_parser_reads_its_own_runtimes_shape () =
  check
    Alcotest.bool
    "container: a nested lowercase state"
    true
    (running
       (Microvm.running_of_inspect_json_for
          Backend.Apple_container
          {|[{"status":{"state":"running"}}]|}));
  check
    Alcotest.bool
    "msb: a flat capitalised status"
    true
    (running
       (Microvm.running_of_inspect_json_for
          Backend.Microsandbox
          {|{"name":"g","status":"Running"}|}));
  check
    Alcotest.bool
    "nerdctl: the bare State.Running literal"
    true
    (running (Microvm.running_of_inspect_json_for Backend.Nerdctl_kata "true"));
  check
    Alcotest.bool
    "nerdctl: false is stopped"
    false
    (running (Microvm.running_of_inspect_json_for Backend.Nerdctl_kata "false"));
  check
    Alcotest.bool
    "msb: stopped is stopped"
    false
    (running
       (Microvm.running_of_inspect_json_for
          Backend.Microsandbox
          {|{"name":"g","status":"Stopped"}|}))
;;

(* The load-bearing one. A parser that answered [Ok false] to a shape it did
   not recognise would report a live guest as gone, and the caller would boot
   a second guest beside the first. *)
let test_an_unrecognised_shape_is_an_error_not_a_no () =
  let refuses label backend raw =
    match Microvm.running_of_inspect_json_for backend raw with
    | Error _ -> ()
    | Ok state ->
      Alcotest.failf "%s read an unknown shape as running=%b" label state
  in
  refuses
    "container given msb's shape"
    Backend.Apple_container
    {|{"name":"g","status":"Running"}|};
  refuses
    "msb given container's shape"
    Backend.Microsandbox
    {|[{"status":{"state":"running"}}]|};
  (* A Go template that stops resolving prints an empty line. Read as "not
     running" it takes a live guest down and boots a second beside it. *)
  refuses "nerdctl given an empty template result" Backend.Nerdctl_kata "";
  refuses "nerdctl given a whole document" Backend.Nerdctl_kata {|{"State":{"Running":true}}|};
  refuses "container given rubbish" Backend.Apple_container "not json at all";
  refuses "msb given rubbish" Backend.Microsandbox "not json at all"
;;

(* ── the host default ───────────────────────────────────────────────── *)

(* A keeper that declared Micro_vm and got a different isolation than the one
   it named is worse than a keeper that did not boot. Where no backend is the
   platform answer, there is no answer. *)
let test_the_host_default_is_apple_or_nothing () =
  match Backend.default_for_host () with
  | None | Some Backend.Apple_container -> ()
  | Some other ->
    Alcotest.failf
      "a host assumed %s without the keeper naming it"
      (Backend.to_string other)
;;

(* ── the resolve, which is what dispatch reads ──────────────────────── *)

(* Durable meta carries a placeholder, and the TOML is the authority. These
   pin the three answers effective_meta_of_profile_defaults can give for the
   Micro_vm profile, because a wrong one hands a keeper a runtime its own file
   never named. *)
let profile_defaults ?backend ?(profile = Masc.Keeper_types_profile.Micro_vm) () =
  { Masc.Keeper_types_profile.empty_keeper_profile_defaults with
    manifest_path = Some ".masc/config/keepers/probe.toml"
  ; sandbox_profile = Some profile
  ; microvm_backend = backend
  }
;;

(* Durable meta as the decoder leaves it: the backend is a placeholder there,
   which is the state this resolve has to answer from. *)
let placeholder_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "probe"; "trace_id", `String "trace-probe" ])
  with
  | Ok meta -> meta
  | Error err -> fail err
;;

let resolve defaults =
  Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
    defaults
    (placeholder_meta ())
;;

let test_a_declared_backend_wins () =
  match resolve (profile_defaults ~backend:Backend.Microsandbox ()) with
  | Error detail -> Alcotest.failf "a declared backend was refused: %s" detail
  | Ok meta ->
    (match meta.microvm_backend with
     | Some Backend.Microsandbox -> ()
     | Some other ->
       Alcotest.failf "declared microsandbox, resolved %s" (Backend.to_string other)
     | None -> fail "a declared backend did not reach the meta")
;;

(* Off Micro_vm the field stays empty: the TOML load already refuses the key
   there, and a second place for the answer to live is a second place for it
   to disagree. *)
let test_a_non_microvm_profile_carries_no_backend () =
  List.iter
    (fun profile ->
      match resolve (profile_defaults ~profile ()) with
      | Error _ -> ()
      | Ok meta ->
        (match meta.microvm_backend with
         | None -> ()
         | Some backend ->
           Alcotest.failf
             "a %s keeper carried microvm_backend = %s"
             (Masc.Keeper_types_profile.sandbox_profile_to_string profile)
             (Backend.to_string backend)))
    [ Masc.Keeper_types_profile.Docker ]
;;

let () =
  Alcotest.run
    "keeper_microvm_backend"
    [ ( "vocabulary"
      , [ Alcotest.test_case "every backend round-trips its spelling" `Quick
            test_every_backend_round_trips_its_spelling
        ; Alcotest.test_case "valid_strings is derived from the constructors" `Quick
            test_valid_strings_is_derived_not_typed_again
        ; Alcotest.test_case "an unimplemented runtime is refused" `Quick
            test_an_unknown_spelling_is_refused
        ] )
    ; ( "argv"
      , [ Alcotest.test_case "each backend drives its own executable" `Quick
            test_each_backend_drives_its_own_executable
        ; Alcotest.test_case "only the containerd backend names a runtime" `Quick
            test_only_the_containerd_backend_names_a_runtime
        ; Alcotest.test_case "kata removal and inspect are Docker's grammar" `Quick
            test_kata_removal_and_inspect_are_dockers_grammar
        ; Alcotest.test_case "removal is spelled per runtime" `Quick
            test_removal_is_spelled_per_runtime
        ; Alcotest.test_case "msb inspect asks for the machine form" `Quick
            test_microsandbox_inspect_asks_for_the_machine_form
        ; Alcotest.test_case "the boot argv is each runtime's own" `Quick
            test_boot_argv_is_each_runtimes_own
        ; Alcotest.test_case "the command separator is per runtime" `Quick
            test_the_command_separator_is_per_runtime
        ; Alcotest.test_case "the log tail flag is per runtime" `Quick
            test_the_log_tail_flag_is_per_runtime
        ; Alcotest.test_case "the image listing argv and shape agree" `Quick
            test_the_image_listing_argv_and_shape_agree
        ; Alcotest.test_case "the image inspect argv and shape agree" `Quick
            test_the_image_inspect_argv_and_shape_agree
        ] )
    ; ( "guarantees"
      , [ Alcotest.test_case "an isolation guarantee is never silently dropped"
            `Quick test_an_isolation_guarantee_is_never_silently_dropped
        ; Alcotest.test_case "a lifecycle drop is recorded on the guest" `Quick
            test_a_lifecycle_drop_is_recorded_on_the_guest
        ; Alcotest.test_case "every runtime answers every guarantee" `Quick
            test_every_runtime_answers_every_guarantee
        ; Alcotest.test_case
            "the shim prefix refuses where the identity cannot be named"
            `Quick test_the_shim_prefix_refuses_where_the_identity_cannot_be_named
        ; Alcotest.test_case "the network policy is spelled per runtime" `Quick
            test_the_network_policy_is_spelled_per_runtime
        ; Alcotest.test_case "no runtime borrows another's network spelling"
            `Quick test_no_runtime_borrows_anothers_network_spelling
        ] )
    ; ( "reaping"
      , [ Alcotest.test_case "only a labelled listing is offered" `Quick
            test_only_a_labelled_listing_is_offered
        ; Alcotest.test_case "the work volume refuses an unknown grammar" `Quick
            test_the_work_volume_refuses_where_its_grammar_is_unknown
        ] )
    ; ( "state"
      , [ Alcotest.test_case "each parser reads its own runtime's shape" `Quick
            test_each_parser_reads_its_own_runtimes_shape
        ; Alcotest.test_case "an unrecognised shape is an error, not a no" `Quick
            test_an_unrecognised_shape_is_an_error_not_a_no
        ; Alcotest.test_case "the host default is Apple or nothing" `Quick
            test_the_host_default_is_apple_or_nothing
        ] )
    ; ( "resolve"
      , [ Alcotest.test_case "a declared backend wins" `Quick
            test_a_declared_backend_wins
        ; Alcotest.test_case "a non-microvm profile carries no backend" `Quick
            test_a_non_microvm_profile_carries_no_backend
        ] )
    ]
;;
