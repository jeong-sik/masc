; Keeper bootstrap polling/settle interval SSOT

(test
 (name test_env_config_keeper_bootstrap_intervals)
 (modules test_env_config_keeper_bootstrap_intervals)
 (libraries masc_test_deps)
 (deps
  ../lib/server/server_bootstrap_loops.ml
  ../lib/server/server_runtime_bootstrap.ml))
