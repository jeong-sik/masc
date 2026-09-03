(* RFC-0405. The Micro_vm profile says a keeper's tree sits on a guest behind
   a hypervisor; it does not say which runtime supplies one. These pin the two
   things that differ between runtimes — the argv, and the parse of what the
   runtime answers — against the CLIs they were read from. *)

module Backend = Masc.Keeper_microvm_backend
module Microvm = Masc.Keeper_sandbox_microvm

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
  (* dockercompat is nerdctl inspect's default mode, so the template masc
     already sends Docker is reused rather than a second document parsed. *)
  check
    (Alcotest.list Alcotest.string)
    "nerdctl inspect uses Docker's template"
    [ "nerdctl"; "inspect"; "--format"; "{{json .State.Running}}"; "g" ]
    (Microvm.inspect_argv_for Backend.Nerdctl_kata ~container_name:"g")
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
