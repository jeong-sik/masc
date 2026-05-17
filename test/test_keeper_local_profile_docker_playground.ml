open Alcotest

module KSD = Masc_mcp.Keeper_shell_docker
module KT = Masc_mcp.Keeper_types

let make_meta ~name ~sandbox_profile ~network_mode =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String ("agent-" ^ name)
      ; "trace_id", `String ("trace-" ^ name)
      ; "goal", `String "local profile routing regression"
      ; "sandbox_profile", `String (KT.sandbox_profile_to_string sandbox_profile)
      ; "network_mode", `String (KT.network_mode_to_string network_mode)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let check_effective label expected meta ~in_playground =
  let profile, network = KSD.effective_sandbox_profile ~meta ~in_playground in
  let expected_profile, expected_network = expected in
  check string
    (label ^ " profile")
    (KT.sandbox_profile_to_string expected_profile)
    (KT.sandbox_profile_to_string profile);
  check string
    (label ^ " network")
    (KT.network_mode_to_string expected_network)
    (KT.network_mode_to_string network)

let test_local_profile_stays_local_when_docker_playground_enabled () =
  check bool
    "test action enabled Docker playground"
    true
    Env_config_keeper.DockerPlayground.enabled;
  let meta =
    make_meta
      ~name:"local-keeper"
      ~sandbox_profile:KT.Local
      ~network_mode:KT.Network_inherit
  in
  check_effective
    "inside playground"
    (KT.Local, KT.Network_inherit)
    meta
    ~in_playground:true;
  check_effective
    "outside playground"
    (KT.Local, KT.Network_inherit)
    meta
    ~in_playground:false

let test_docker_profile_stays_docker () =
  let meta =
    make_meta
      ~name:"docker-keeper"
      ~sandbox_profile:KT.Docker
      ~network_mode:KT.Network_none
  in
  check_effective
    "inside playground"
    (KT.Docker, KT.Network_none)
    meta
    ~in_playground:true;
  check_effective
    "outside playground"
    (KT.Docker, KT.Network_none)
    meta
    ~in_playground:false

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
