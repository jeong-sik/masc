let () =
  Unix.unsetenv "MASC_KEEPER_METRICS_MAX_BYTES";
  Unix.unsetenv "MASC_KEEPER_METRICS_MAX_ROTATED";
  Unix.unsetenv "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC";
  Unix.unsetenv "MASC_KEEPER_SNAPSHOT_SEC";
  Unix.unsetenv "MASC_KEEPER_WORK_AS_HEARTBEAT";
  Unix.unsetenv "MASC_KEEPER_SLEEP_CHUNK_SEC";
  Unix.unsetenv "MASC_KEEPER_SUPERVISOR_SWEEP_SEC";
  Unix.unsetenv "MASC_KEEPER_DEBUG";
  Config_boot_overrides.reset_for_tests ();
  Config_boot_overrides.set "MASC_KEEPER_METRICS_MAX_BYTES" "17";
  Config_boot_overrides.set "MASC_KEEPER_METRICS_MAX_ROTATED" "2";
  Config_boot_overrides.set "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" "23";
  Config_boot_overrides.set "MASC_KEEPER_SNAPSHOT_SEC" "45";
  Config_boot_overrides.set "MASC_KEEPER_WORK_AS_HEARTBEAT" "false";
  Config_boot_overrides.set "MASC_KEEPER_SLEEP_CHUNK_SEC" "1.5";
  Config_boot_overrides.set "MASC_KEEPER_SUPERVISOR_SWEEP_SEC" "11";
  Config_boot_overrides.set "MASC_KEEPER_DEBUG" "true";
  Printf.printf "%s=%s\n" "MASC_KEEPER_METRICS_MAX_BYTES" (string_of_int (Env_config_keeper.KeeperMetrics.max_file_bytes ()));
  Printf.printf "%s=%s\n" "MASC_KEEPER_METRICS_MAX_ROTATED" (string_of_int (Env_config_keeper.KeeperMetrics.max_rotated_files ()));
  Printf.printf "%s=%s\n" "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" (string_of_int (Env_config_keeper.KeeperKeepalive.interval_sec ()));
  Printf.printf "%s=%s\n" "MASC_KEEPER_SNAPSHOT_SEC" (string_of_int (Env_config_keeper.KeeperRuntime.snapshot_sec ()));
  Printf.printf "%s=%s\n" "MASC_KEEPER_WORK_AS_HEARTBEAT" (string_of_bool (Env_config_keeper.WorkAsHeartbeat.enabled ()));
  Printf.printf "%s=%s\n" "MASC_KEEPER_SLEEP_CHUNK_SEC" ((Printf.sprintf "%g") (Env_config_keeper.KeeperKeepalive.sleep_chunk_sec ()));
  Printf.printf "%s=%s\n" "MASC_KEEPER_SUPERVISOR_SWEEP_SEC" ((Printf.sprintf "%g") (Env_config_keeper.KeeperSupervisor.sweep_interval_sec ()));
  Printf.printf "%s=%s\n" "MASC_KEEPER_DEBUG" (string_of_bool (Env_config_keeper.KeeperRuntime.debug ()));
  Unix.putenv "MASC_KEEPER_METRICS_MAX_BYTES" "100";
  Printf.printf "environment_metric_bytes=%d\n" (Env_config_keeper.KeeperMetrics.max_file_bytes ())
