module Mcp_server = Masc.Mcp_server
module Registry = Keeper_compaction_wake_registry

let keeper_name =
  match Keeper_id.Keeper_name.of_string "compaction-state-resource" with
  | Ok value -> value
  | Error error -> Alcotest.fail error
;;

let create_state suffix =
  Mcp_server.For_testing.create_state
    ~base_path:
      (Filename.concat
         (Filename.get_temp_dir_name ())
         ("masc-compaction-wake-" ^ suffix))
;;

let test_accessor_identity_and_state_isolation () =
  Eio_main.run
  @@ fun _env ->
  let first_state = create_state "first" in
  let second_state = create_state "second" in
  let first_registry =
    Mcp_server.keeper_compaction_wake_registry first_state
  in
  let same_first_registry =
    Mcp_server.keeper_compaction_wake_registry first_state
  in
  let second_registry =
    Mcp_server.keeper_compaction_wake_registry second_state
  in
  Alcotest.(check bool)
    "same state returns stable registry identity"
    true
    (first_registry == same_first_registry);
  Alcotest.(check bool)
    "different states own different registries"
    false
    (first_registry == second_registry);
  Eio.Switch.run
  @@ fun sw ->
  (match Registry.register ~sw first_registry keeper_name with
   | Ok _ -> ()
   | Error Registry.Already_registered ->
     Alcotest.fail "fresh state registry already contained the Keeper");
  (match Registry.wake second_registry keeper_name with
   | Registry.Not_registered -> ()
   | Registry.Signaled | Registry.Coalesced ->
     Alcotest.fail "registration leaked into another server state");
  match Registry.wake same_first_registry keeper_name with
  | Registry.Signaled -> ()
  | Registry.Coalesced | Registry.Not_registered ->
    Alcotest.fail "same state accessor did not reach its registered Keeper"
;;

let () =
  Alcotest.run
    "mcp server compaction wake registry"
    [ ( "state ownership"
      , [ Alcotest.test_case
            "stable accessor and isolated states"
            `Quick
            test_accessor_identity_and_state_isolation
        ] )
    ]
;;
