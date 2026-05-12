(** RFC-0070 Phase 3b-iii — tests for [Keeper_sandbox_plan].

    Pins the real [of_request] contract: validation, determinism,
    accessor invariants, container_name derivation alignment with
    [Keeper_container_name.derive]. *)

open Alcotest
open Masc_mcp

let plan_error_pp ppf = function
  | Keeper_sandbox_plan.Invalid_meta s -> Format.fprintf ppf "Invalid_meta %S" s
  | Keeper_sandbox_plan.Invalid_command s -> Format.fprintf ppf "Invalid_command %S" s

let plan_error_eq a b =
  match a, b with
  | Keeper_sandbox_plan.Invalid_meta x, Keeper_sandbox_plan.Invalid_meta y ->
      String.equal x y
  | Keeper_sandbox_plan.Invalid_command x, Keeper_sandbox_plan.Invalid_command y ->
      String.equal x y
  | _ -> false

let plan_t = testable Keeper_sandbox_plan.pp Keeper_sandbox_plan.equal
let plan_error_t = testable plan_error_pp plan_error_eq

(* ── Validation: empty inputs rejected ────────────────────────── *)

let test_empty_meta_rejected () =
  let res =
    Keeper_sandbox_plan.of_request ~turn_id:1 ~attempt:0 ~meta_name:"" ~cmd:"ls"
  in
  check
    (result plan_t plan_error_t)
    "empty meta → Invalid_meta"
    (Error (Keeper_sandbox_plan.Invalid_meta ""))
    res

let test_empty_cmd_rejected () =
  let res =
    Keeper_sandbox_plan.of_request ~turn_id:1 ~attempt:0 ~meta_name:"k" ~cmd:""
  in
  check
    (result plan_t plan_error_t)
    "empty cmd → Invalid_command"
    (Error (Keeper_sandbox_plan.Invalid_command ""))
    res

(* ── Payload semantics: error carries offending value (Phase 3b-iii contract) ── *)

let test_invalid_meta_payload_is_offending () =
  let res =
    Keeper_sandbox_plan.of_request ~turn_id:1 ~attempt:0 ~meta_name:"" ~cmd:"x"
  in
  match res with
  | Error (Keeper_sandbox_plan.Invalid_meta payload) ->
      check string "Invalid_meta payload = offending meta_name (\"\")" "" payload
  | _ -> fail "expected Invalid_meta"

let test_invalid_command_payload_is_offending () =
  let res =
    Keeper_sandbox_plan.of_request ~turn_id:1 ~attempt:0 ~meta_name:"k" ~cmd:""
  in
  match res with
  | Error (Keeper_sandbox_plan.Invalid_command payload) ->
      check string "Invalid_command payload = offending cmd (\"\")" "" payload
  | _ -> fail "expected Invalid_command"

(* ── Happy path: returns Ok with populated fields ─────────────── *)

let test_happy_returns_ok () =
  let res =
    Keeper_sandbox_plan.of_request ~turn_id:5 ~attempt:0 ~meta_name:"alice" ~cmd:"echo hi"
  in
  match res with
  | Ok _ -> ()
  | Error _ -> fail "well-formed inputs should yield Ok"

let happy_plan () =
  match
    Keeper_sandbox_plan.of_request ~turn_id:5 ~attempt:0 ~meta_name:"alice" ~cmd:"echo hi"
  with
  | Ok p -> p
  | Error _ -> failwith "test fixture: of_request returned Error"

let test_image_is_default () =
  check string "image = default_image"
    Keeper_sandbox_plan.default_image
    (Keeper_sandbox_plan.image (happy_plan ()))

let test_command_round_trip () =
  check string "command = cmd arg" "echo hi"
    (Keeper_sandbox_plan.command (happy_plan ()))

let test_timeout_default () =
  check (float 0.0) "timeout_budget_sec = default"
    Keeper_sandbox_plan.default_timeout_budget_sec
    (Keeper_sandbox_plan.timeout_budget_sec (happy_plan ()))

(* ── Determinism: same inputs ⇒ same plan ─────────────────────── *)

let test_determinism () =
  let a = happy_plan () in
  let b = happy_plan () in
  check bool "deterministic plan" true (Keeper_sandbox_plan.equal a b)

(* ── Container_name derivation alignment ──────────────────────── *)

let test_container_name_matches_derive () =
  let plan =
    match
      Keeper_sandbox_plan.of_request ~turn_id:7 ~attempt:3 ~meta_name:"persona" ~cmd:"x"
    with
    | Ok p -> p
    | Error _ -> failwith "test fixture"
  in
  let expected =
    Keeper_container_name.derive
      ~algo:Keeper_hash_algo.SHA_256
      ~turn_id:7
      ~attempt:3
      ~suffix:"persona"
  in
  check bool "Plan container_name = direct Container_name.derive output"
    true
    (Keeper_container_name.equal (Keeper_sandbox_plan.container_name plan) expected)

(* ── Distinct turn_id / attempt / meta yields distinct plans ── *)

let test_distinct_turn () =
  let a =
    match
      Keeper_sandbox_plan.of_request ~turn_id:1 ~attempt:0 ~meta_name:"k" ~cmd:"x"
    with
    | Ok p -> p
    | Error _ -> failwith "fix"
  in
  let b =
    match
      Keeper_sandbox_plan.of_request ~turn_id:2 ~attempt:0 ~meta_name:"k" ~cmd:"x"
    with
    | Ok p -> p
    | Error _ -> failwith "fix"
  in
  check bool "distinct turn_id → distinct plan" false (Keeper_sandbox_plan.equal a b)

let () =
  run "Keeper_sandbox_plan"
    [
      ( "validation",
        [
          test_case "empty meta rejected" `Quick test_empty_meta_rejected;
          test_case "empty cmd rejected" `Quick test_empty_cmd_rejected;
          test_case "Invalid_meta payload = offending meta_name"
            `Quick
            test_invalid_meta_payload_is_offending;
          test_case "Invalid_command payload = offending cmd"
            `Quick
            test_invalid_command_payload_is_offending;
        ] );
      ( "happy path",
        [
          test_case "of_request returns Ok" `Quick test_happy_returns_ok;
          test_case "image = default" `Quick test_image_is_default;
          test_case "command round-trip" `Quick test_command_round_trip;
          test_case "timeout = default" `Quick test_timeout_default;
        ] );
      ("determinism", [ test_case "same inputs → same plan" `Quick test_determinism ]);
      ( "derivation alignment",
        [
          test_case "container_name matches direct derive"
            `Quick
            test_container_name_matches_derive;
        ] );
      ( "uniqueness",
        [ test_case "distinct turn_id → distinct plan" `Quick test_distinct_turn ] );
    ]
