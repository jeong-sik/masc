(** Contracts of the keeper-lifetime Docker container and microVM guest.

    The container is persistent: one per keeper, adopted across turns and
    server restarts, removed only when the keeper is. Two things make that
    safe, and both are testable without a docker daemon:

    - the name is a pure function of (keeper, network mode, base path, resolved image reference), so
      any process of this keeper computes the same name and adoption is just
      a probe;
    - the stale-container sweep keeps a persistent container whose owning
      process died (that is its normal state between server generations) and
      removes one that stopped.

    The guest name has one more contract: the runtime has to accept it.
    Apple's [container] refuses a name over 63 characters at boot, so a
    keeper whose name did not fit could not start on any turn. *)

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

module Profile = Keeper_types_profile_sandbox

let guest_base_path = "/tmp/masc-persistent-test"

let guest_name ?(base_path = guest_base_path) ~network_mode keeper_name =
  Masc.Keeper_turn_sandbox_runtime.For_testing_microvm.microvm_container_name
    ~config:(Masc.Workspace.default_config base_path)
    ~keeper_name
    ~network_mode
;;

(* apple/container ManagedContainer.nameValid, the same in 1.3.1 and 1.4.1:
   at most 63 characters and ^[a-zA-Z0-9][a-zA-Z0-9_.-]+$. Written out here
   rather than read from the name module, so the test is the runtime's rule
   and not the implementation's idea of it. *)
let apple_container_name_max_length = 63

let apple_container_accepts name =
  let alphanumeric = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
    | _ -> false
  in
  let length = String.length name in
  length >= 2
  && length <= apple_container_name_max_length
  && alphanumeric name.[0]
  && String.for_all (fun c -> alphanumeric c || c = '_' || c = '.' || c = '-') name
;;

(* The keeper whose Read and Execute failed for days with "container ID ...
   is not a valid container ID". *)
let refused_keeper = "kidsnote-slack-context-collector"

(* The guest-name segment that names the base path: eight hex characters of
   its hash, as the name has always carried. *)
let base_path_hash_segment_length = 8

let base_path_segment base_path =
  String.sub
    (Masc.Keeper_sandbox_runtime.base_path_hash base_path)
    0
    base_path_hash_segment_length
;;

let segments name = String.split_on_char '-' name

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
    ; ( "microvm_guest_name"
      , [ test_case "a keeper name that made a 64-character guest name now boots" `Quick
            (fun () ->
              let spelled_in_full =
                String.concat
                  "-"
                  [ "masc-keeper-vm"
                  ; refused_keeper
                  ; "inherit"
                  ; base_path_segment guest_base_path
                  ]
              in
              check int "the name Apple refused" 64 (String.length spelled_in_full);
              let name = guest_name ~network_mode:Profile.Network_inherit refused_keeper in
              check bool
                (Printf.sprintf "Apple's container accepts %s" name)
                true
                (apple_container_accepts name);
              check bool
                "the cut name still says which keeper, mode and base path"
                true
                (String.starts_with ~prefix:"masc-keeper-vm-kidsnote-slack" name
                 && List.mem "inherit" (segments name)
                 && List.mem (base_path_segment guest_base_path) (segments name));
              check string
                "every process of the keeper computes the same guest"
                name
                (guest_name ~network_mode:Profile.Network_inherit refused_keeper))
        ; test_case "cut names keep keepers, modes and base paths apart" `Quick
            (fun () ->
              let sibling = refused_keeper ^ "s" in
              let pairs =
                [ ( "two keepers sharing the kept characters"
                  , guest_name ~network_mode:Profile.Network_inherit refused_keeper
                  , guest_name ~network_mode:Profile.Network_inherit sibling )
                ; ( "one keeper in two network modes"
                  , guest_name ~network_mode:Profile.Network_inherit refused_keeper
                  , guest_name ~network_mode:Profile.Network_policy refused_keeper )
                ; ( "one keeper on two base paths"
                  , guest_name ~network_mode:Profile.Network_inherit refused_keeper
                  , guest_name
                      ~base_path:(guest_base_path ^ "-other")
                      ~network_mode:Profile.Network_inherit
                      refused_keeper )
                ]
              in
              List.iter
                (fun (what, left, right) ->
                   check bool what false (String.equal left right))
                pairs)
        ; test_case "a name that fits is spelled as it always was" `Quick
            (fun () ->
              check
                string
                "no cut, no digest"
                (String.concat
                   "-"
                   [ "masc-keeper-vm"; "alpha"; "none"; base_path_segment guest_base_path ])
                (guest_name ~network_mode:Profile.Network_none "alpha"))
        ; test_case "the longest keeper id fits in every mode" `Quick
            (fun () ->
              (* Validation.Id_shape admits 64 characters with one namespace
                 colon, and the colon is escaped to three characters. *)
              let longest = "Keeper:" ^ String.make 57 'x' in
              List.iter
                (fun network_mode ->
                   let name = guest_name ~network_mode longest in
                   check bool
                     (Printf.sprintf "Apple's container accepts %s" name)
                     true
                     (apple_container_accepts name))
                Profile.all_network_modes)
        ] )
    ]
;;
