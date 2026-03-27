open Masc_mcp

let expect_error ~label ~expected = function
  | Error message -> Alcotest.(check string) label expected message
  | Ok _ -> Alcotest.fail (label ^ ": expected error")

let with_test_config f =
  let base = Test_command_plane_v2_support.temp_dir () in
  Fun.protect
    ~finally:(fun () -> Test_command_plane_v2_support.cleanup_dir base)
    (fun () -> Test_command_plane_v2_support.with_eio_test base f)

let test_dispatch_assign_requires_operation_id () =
  with_test_config @@ fun config ->
  expect_error
    ~label:"dispatch_assign missing operation_id"
    ~expected:"operation_id is required. Call masc_operation_start first."
    (Command_plane_v2.dispatch_assign_json config ~actor:"owner"
       (`Assoc [ ("target_unit_id", `String "platoon-alpha") ]))

let test_dispatch_escalate_requires_operation_id () =
  with_test_config @@ fun config ->
  expect_error
    ~label:"dispatch_escalate missing operation_id"
    ~expected:"operation_id is required. Call masc_operation_start first."
    (Command_plane_v2.dispatch_escalate_json config ~actor:"owner" (`Assoc []))

let test_unit_reparent_requires_unit_id () =
  with_test_config @@ fun config ->
  expect_error
    ~label:"unit_reparent missing unit_id"
    ~expected:"unit_id is required"
    (Command_plane_v2.unit_reparent_json config ~actor:"owner"
       (`Assoc [ ("parent_unit_id", `String "company-main") ]))

let test_policy_update_requires_unit_id () =
  with_test_config @@ fun config ->
  expect_error
    ~label:"policy_update missing unit_id"
    ~expected:"unit_id is required"
    (Command_plane_v2.policy_update_json config ~actor:"owner"
       (`Assoc [ ("policy", `Assoc []); ("budget", `Assoc []) ]))
