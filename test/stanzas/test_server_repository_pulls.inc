(test
 (name test_server_repository_pulls)
 (modules test_server_repository_pulls)
 (libraries alcotest unix yojson masc masc.server masc.repo_manager
   masc.config_dir_resolver masc.keeper_types_profile_sandbox))
