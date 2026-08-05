open Alcotest

module KSD = Masc.Keeper_sandbox_docker
module KT = Keeper_types

(* [sandbox_profile] and [network_mode] still live on the keeper_meta record —
   Keeper_sandbox_docker.effective_sandbox_profile reads them — but they left
   the JSON wire schema, so keeper_meta_json_parse now rejects them as fields
   outside the current schema. They arrive from keeper.toml instead. The fixture
   therefore parses the wire fields and sets the two record fields directly,
   which is what this suite is about. *)
let make_meta ~name ~sandbox_profile ~network_mode =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String (Masc.Keeper_identity.keeper_agent_name name)
      ; "trace_id", `String ("trace-" ^ name)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    { meta with Masc.Keeper_meta_contract.sandbox_profile; network_mode }
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

let test_local_profile_stays_local_when_docker_playground_enabled () =
  check bool
    "test action enabled Docker playground"
    true
    (Env_config_sandbox.Runtime.docker_playground_enabled ());
  let meta =
    make_meta
      ~name:"local-keeper"
      ~sandbox_profile:Keeper_types_profile_sandbox.Local
      ~network_mode:Keeper_types_profile_sandbox.Network_inherit
  in
  check_effective
    "declared local"
    (Keeper_types_profile_sandbox.Local, Keeper_types_profile_sandbox.Network_inherit)
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

let () =
  run
    "Keeper local profile with Docker playground"
    [ "routing",
      [ test_case
          "local profile stays local when Docker playground is enabled"
          `Quick
          test_local_profile_stays_local_when_docker_playground_enabled
      ; test_case "docker profile stays docker" `Quick test_docker_profile_stays_docker
      ]
    ]
