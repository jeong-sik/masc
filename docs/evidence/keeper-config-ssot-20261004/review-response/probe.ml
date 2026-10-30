let keys = ["MASC_KEEPER_METRICS_MAX_BYTES";"MASC_KEEPER_METRICS_MAX_ROTATED";
 "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC";"MASC_KEEPER_SNAPSHOT_SEC";
 "MASC_KEEPER_WORK_AS_HEARTBEAT";"MASC_KEEPER_SLEEP_CHUNK_SEC";
 "MASC_KEEPER_SUPERVISOR_SWEEP_SEC";"MASC_KEEPER_DEBUG"]
let () =
 List.iter Unix.unsetenv ("MASC_PARSE_WARN"::"MASC_CONFIG_DIR"::keys);
 let base_path = Sys.argv.(1) in
 let dir = Filename.concat base_path ".masc" in Unix.mkdir dir 0o700;
 let dir = Filename.concat dir "config" in Unix.mkdir dir 0o700;
 let path=Filename.concat dir "runtime.toml" in
 let write text = let oc=open_out path in Fun.protect ~finally:(fun()->close_out oc) (fun()->output_string oc text) in
 let load () = match Keeper_runtime_config.load_and_apply ~base_path with
 | Ok _ -> "accepted" | Error {kind=Keeper_runtime_config.Validate;_} -> "rejected"
 | Error error -> failwith (Keeper_runtime_config.load_failure_to_string error) in
 List.iter (fun (name,text) -> Config_boot_overrides.reset_for_tests (); write text;
   Printf.printf "%s=%s\n" name (load ()))
 ["sweep_zero","[supervisor]\nsweep_sec=0.0\n";
  "sweep_above_max","[supervisor]\nsweep_sec=121.0\n";
  "zero_backups","[metrics]\nmax_rotated=0\n";
  "valid_bounds","[supervisor]\nsweep_sec=11.0\n[metrics]\nmax_rotated=2\n"];
 Config_boot_overrides.reset_for_tests ();
 List.iter (fun raw -> Unix.putenv "MASC_KEEPER_SUPERVISOR_SWEEP_SEC" raw;
   Printf.printf "sweep_env_%s=%g\n" raw (Env_config_keeper.KeeperSupervisor.sweep_interval_sec ()))
 ["0";"121";"nan";"infinity"];
 Unix.unsetenv "MASC_KEEPER_SUPERVISOR_SWEEP_SEC";
 Unix.putenv "MASC_KEEPER_METRICS_MAX_ROTATED" "0";
 Printf.printf "backup_env_zero=%d\n" (Env_config_keeper.KeeperMetrics.max_rotated_files ());
 Unix.unsetenv "MASC_KEEPER_METRICS_MAX_ROTATED";
 Unix.putenv "MASC_PARSE_WARN" "true";
 let rejected = ref 0 in
 List.iter (fun key -> Unix.putenv key "malformed";
   List.iter (fun exists -> if exists then write "[metrics]\nmax_bytes=17\n"
     else if Sys.file_exists path then Sys.remove path;
     Config_boot_overrides.reset_for_tests ();
     if load () = "rejected" then incr rejected) [false;true];
   Unix.unsetenv key) keys;
 Printf.printf "strict_boot_rejections=%d/16\n" !rejected
