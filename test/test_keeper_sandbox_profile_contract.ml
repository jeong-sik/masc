open Alcotest

module KSD = Masc.Keeper_sandbox_docker
module KT = Keeper_types

let make_meta ~name ~sandbox_profile ~network_mode =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String ("agent-" ^ name)
      ; "trace_id", `String ("trace-" ^ name)
      ; "goal", `String "local profile routing regression"
      ; "sandbox_profile", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox_profile)
      ; "network_mode", `String (Keeper_types_profile_sandbox.network_mode_to_string network_mode)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let check_effective label expected meta =
  let profile, network = KSD.effective_sandbox_profile ~meta in
  let expected_profile, expected_network = expected in
  check string
    (label ^ " profile")
    (Keeper_types_profile_sandbox.sandbox_profile_to_string expected_profile)
    (Keeper_types_profile_sandbox.sandbox_profile_to_string profile);
  check string
    (label ^ " network")
    (Keeper_types_profile_sandbox.network_mode_to_string expected_network)
    (Keeper_types_profile_sandbox.network_mode_to_string network)

let test_explicit_local_profile_stays_local () =
  let meta =
    make_meta
      ~name:"local-keeper"
      ~sandbox_profile:Keeper_types_profile_sandbox.Local
      ~network_mode:Keeper_types_profile_sandbox.Network_host
  in
  check_effective
    "declared local"
    (Keeper_types_profile_sandbox.Local, Keeper_types_profile_sandbox.Network_host)
    meta

let test_docker_profile_stays_docker () =
  let meta =
    make_meta
      ~name:"docker-keeper"
      ~sandbox_profile:Keeper_types_profile_sandbox.Docker
      ~network_mode:Keeper_types_profile_sandbox.Network_none
  in
  check_effective
    "declared docker"
    (Keeper_types_profile_sandbox.Docker, Keeper_types_profile_sandbox.Network_none)
    meta

let test_network_mode_wire_contract_is_host_or_none () =
  check string
    "missing profile fails safe to docker"
    "docker"
    (Keeper_types_profile_sandbox.default_sandbox_profile
     |> Keeper_types_profile_sandbox.sandbox_profile_to_string);
  check
    (list string)
    "canonical values"
    [ "none"; "host" ]
    Keeper_types_profile_sandbox.valid_network_mode_strings;
  check bool
    "host parses"
    true
    (Option.equal
       ( = )
       (Some Keeper_types_profile_sandbox.Network_host)
       (Keeper_types_profile_sandbox.network_mode_of_string "host"));
  check bool
    "removed inherit value is rejected"
    true
    (Option.is_none (Keeper_types_profile_sandbox.network_mode_of_string "inherit"));
  check string
    "local default is explicit host"
    "host"
    (Keeper_types_profile_sandbox.default_network_mode_for_profile
       Keeper_types_profile_sandbox.Local
     |> Keeper_types_profile_sandbox.network_mode_to_string)

let test_local_none_pair_is_rejected () =
  match
    Keeper_types_profile_sandbox.validate_network_mode_for_profile
      ~sandbox_profile:Keeper_types_profile_sandbox.Local
      ~network_mode:Keeper_types_profile_sandbox.Network_none
  with
  | Ok () -> fail "local + none cannot be enforced and must be rejected"
  | Error message ->
    check bool
      "error explains unenforceable local network isolation"
      true
      (String_util.contains_substring message "only enforceable")

let test_keeper_meta_json_rejects_removed_inherit_network_mode () =
  let json =
    `Assoc
      [ "name", `String "legacy-network-mode"
      ; "agent_name", `String "agent-legacy-network-mode"
      ; "trace_id", `String "trace-legacy-network-mode"
      ; "goal", `String "reject removed network mode"
      ; "sandbox_profile", `String "local"
      ; "network_mode", `String "inherit"
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok _ -> fail "removed inherit network mode must not be coerced to host"
  | Error error ->
    check bool
      "error names canonical values"
      true
      (String.equal
         error
         "meta parse error: invalid network_mode: \"inherit\" (expected: none or host)")

let () =
  run
    "Keeper sandbox profile contract"
    [ "routing",
      [ test_case
          "explicit local profile stays local"
          `Quick
          test_explicit_local_profile_stays_local
      ; test_case "docker profile stays docker" `Quick test_docker_profile_stays_docker
      ; test_case
          "network mode wire contract is host or none"
          `Quick
          test_network_mode_wire_contract_is_host_or_none
      ; test_case
          "keeper meta JSON rejects removed inherit network mode"
          `Quick
          test_keeper_meta_json_rejects_removed_inherit_network_mode
      ; test_case "local + none is rejected" `Quick test_local_none_pair_is_rejected
      ]
    ]
