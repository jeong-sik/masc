(test
 (name test_server_github_run_reader)
 (modules test_server_github_run_reader)
 (libraries alcotest unix masc masc.server masc.config_dir_resolver
   masc_test_deps eio_main))
