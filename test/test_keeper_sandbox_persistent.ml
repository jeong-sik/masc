(** Contracts of the keeper-lifetime Docker container.

    The container is persistent: one per keeper, adopted across turns and
    server restarts, removed only when the keeper is. Two things make that
    safe, and both are testable without a docker daemon:

    - the name is a pure function of (keeper, network mode, base path), so
      any process of this keeper computes the same name and adoption is just
      a probe;
    - the stale-container sweep keeps a persistent container whose owning
      process died (that is its normal state between server generations) and
      removes one that stopped. *)

open Alcotest

let meta_for name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail
;;

let minimal base_path name =
  Masc.Keeper_turn_sandbox_runtime.For_testing.create_minimal
    ~config:(Masc.Workspace.default_config base_path)
    ~meta:(meta_for name)
    ~state:Masc.Keeper_turn_sandbox_runtime.Not_started
;;

let container_name = Masc.Keeper_turn_sandbox_runtime.For_testing.keeper_docker_container_name

let () =
  run "keeper_sandbox_persistent"
    [ ( "container_name"
      , [ test_case "stable across runtimes of the same keeper" `Quick
            (fun () ->
              check string
                "two processes of one keeper compute one name"
                (container_name (minimal "/tmp/masc-persistent-test" "alpha"))
                (container_name (minimal "/tmp/masc-persistent-test" "alpha")))
        ; test_case "distinct per keeper and per base path" `Quick
            (fun () ->
              check bool
                "two keepers never share a container"
                false
                (String.equal
                   (container_name (minimal "/tmp/masc-persistent-test" "alpha"))
                   (container_name (minimal "/tmp/masc-persistent-test" "beta")));
              check bool
                "one keeper on two base paths never shares a container"
                false
                (String.equal
                   (container_name (minimal "/tmp/masc-persistent-test" "alpha"))
                   (container_name
                      (minimal "/tmp/masc-persistent-test-other" "alpha"))))
        ; test_case "the network mode is part of the name" `Quick
            (fun () ->
              (* create_minimal fixes Network_none, so the structural fact
                 under test is that the none spelling appears in the name;
                 the inherit spelling is the same format string slot. *)
              let name = container_name (minimal "/tmp/masc-persistent-test" "alpha") in
              check bool
                "none appears as a name segment"
                true
                (List.exists
                   (String.equal "none")
                   (String.split_on_char '-' name)))
        ] )
    ]
;;
