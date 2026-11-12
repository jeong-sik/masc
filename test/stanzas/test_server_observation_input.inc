(test
 (name test_server_observation_input)
 (modules test_server_observation_input)
 (libraries masc masc_server masc_test_deps masc.keeper_registry masc.runtime alcotest yojson eio eio.mock eio_main))
